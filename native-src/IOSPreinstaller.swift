import Foundation
import CryptoKit

private final class IOSPinnedDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedBytes: Int64
    private let cancelled: () throws -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?
    private var session: URLSession?

    init(destination: URL, expectedBytes: Int64, cancelled: @escaping () throws -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.cancelled = cancelled
    }

    func run(_ url: URL) throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("SillyClient-iOS/1.11.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 90
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: request).resume()
        let deadline = Date().addingTimeInterval(95)
        do {
            while semaphore.wait(timeout: .now() + 0.25) != .success {
                try cancelled()
                guard Date() < deadline else { throw IOSFileError.invalid("Extension download timed out") }
            }
            try cancelled()
        } catch {
            session?.invalidateAndCancel()
            _ = semaphore.wait(timeout: .now() + 5)
            throw error
        }
        session?.finishTasksAndInvalidate()
        guard let result = result else { throw IOSFileError.invalid("Download produced no verified file") }
        try result.get()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do {
            try cancelled()
            guard totalBytesWritten <= expectedBytes,
                  totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == expectedBytes else {
                throw IOSFileError.invalid("Extension archive exceeds its pinned size")
            }
        } catch { result = .failure(error); downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try cancelled()
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw IOSFileError.invalid("Extension download did not return HTTP 200")
            }
            let source = IOSManagedFiles(root: location.deletingLastPathComponent().resolvingSymlinksInPath())
            let safe = source.root.appendingPathComponent(location.lastPathComponent)
            guard try source.guardValue(safe).size == expectedBytes else {
                throw IOSFileError.invalid("Extension archive size did not match its catalog")
            }
            try source.copyTree(safe, to: destination, destination: IOSManagedFiles(root: destination.deletingLastPathComponent()),
                                budget: IOSInspectionBudget(maxEntries: 1, maxBytes: expectedBytes), cancelled: cancelled)
            result = .success(())
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, result == nil { result = .failure(error) }
        if result == nil { result = .failure(IOSFileError.invalid("Download produced no verified file")) }
        semaphore.signal()
    }
}

enum IOSPreinstaller {
    static func validateManifest(_ manifest: [String: Any], directory: URL) throws {
        let files = IOSManagedFiles(root: directory)
        for key in ["js", "css"] {
            guard let raw = manifest[key], !(raw is NSNull) else { continue }
            guard let asset = raw as? String else { throw IOSFileError.invalid("Extension entry declaration is invalid") }
            if asset.isEmpty { continue }
            let relative = try IOSSafeArchive.relativePath(asset.hasPrefix("./") ? String(asset.dropFirst(2)) : asset)
            guard !(try files.guardValue(directory.appendingPathComponent(relative))).isDirectory else {
                throw IOSFileError.invalid("Extension entry point is not a file")
            }
        }
    }
    private static func resource(_ relative: String) throws -> URL {
        let file = URL(fileURLWithPath: relative)
        for bundle in [Bundle.main, Bundle(for: IOSInstanceStore.self)] {
            if let root = bundle.resourceURL {
                let candidate = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            if let url = bundle.url(forResource: file.deletingPathExtension().lastPathComponent,
                                    withExtension: file.pathExtension) { return url }
        }
        throw IOSFileError.invalid("Preinstallation asset is missing: \(file.lastPathComponent)")
    }

    static func install(staging: URL, instanceId: String, selection: [String: Any]?,
                        companion: [String: Any]?, cancelled: @escaping () throws -> Void) throws {
        let files = IOSManagedFiles(root: staging)
        if let selection = selection {
            guard selection["revision"] as? Int == 1, let ids = selection["extensionIds"] as? [String],
                  ids.count <= 4, Set(ids).count == ids.count else {
                throw IOSFileError.invalid("Unsupported preinstallation selection")
            }
            let catalogURL = try resource("preinstalled-extensions/catalog.json")
            let catalog = try IOSManagedFiles(root: catalogURL.deletingLastPathComponent()).json(catalogURL)
            guard catalog["revision"] as? Int == 1, let extensions = catalog["extensions"] as? [[String: Any]] else {
                throw IOSFileError.invalid("Extension catalog is invalid")
            }
            for id in ids {
                try cancelled()
                guard let item = extensions.first(where: { $0["id"] as? String == id }),
                      let repository = item["repository"] as? String,
                      let commit = item["commit"] as? String,
                      let expectedHash = item["archiveSha256"] as? String,
                      let expectedBytes = item["archiveBytes"] as? Int,
                      let licensePath = item["licensePath"] as? String,
                      repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                      commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                      expectedBytes > 0, expectedBytes <= 32 * 1024 * 1024 else {
                    throw IOSFileError.invalid("Unknown or invalid preinstalled extension")
                }
                let name = String(repository.split(separator: "/")[1])
                let target = staging.appendingPathComponent("data/default-user/extensions/\(name)")
                if files.exists(target) {
                    guard try files.guardValue(target).isDirectory else { throw IOSFileError.invalid("Existing extension is not a directory") }
                    continue
                }
                let cache = staging.appendingPathComponent(".sillyclient-maintenance/download-cache/\(UUID().uuidString)")
                try files.createDirectory(cache)
                let archiveURL = cache.appendingPathComponent("download.zip")
                let url = URL(string: "https://codeload.github.com/\(repository)/zip/\(commit)")!
                try IOSPinnedDownload(destination: archiveURL, expectedBytes: Int64(expectedBytes), cancelled: cancelled).run(url)
                let bytes = try files.data(archiveURL, maximum: expectedBytes)
                let actualHash = IOSManagedFiles.hex(SHA256.hash(data: bytes))
                guard actualHash.uppercased() == expectedHash.uppercased() else {
                    throw IOSFileError.invalid("Extension archive SHA-256 did not match its pinned catalog")
                }
                try files.writeJSON(["revision": 1, "owner": "sillyclient", "instanceId": instanceId,
                    "payload": "download.zip", "sha256": actualHash, "sizeBytes": expectedBytes,
                    "createdAt": Date().timeIntervalSince1970 * 1000], to: cache.appendingPathComponent("owner.json"), replace: false)
                let extracted = staging.appendingPathComponent(".sillyclient-extension-\(UUID().uuidString)")
                try files.createDirectory(extracted)
                defer { if files.exists(extracted) { try? FileManager.default.removeItem(at: files.checked(extracted)) } }
                try IOSSafeArchive.extract(archiveURL, to: extracted, stripSingleRoot: true,
                    maximumBytes: 128 * 1024 * 1024, maximumEntries: 8192, cancelled: cancelled)
                let extractedFiles = IOSManagedFiles(root: extracted)
                let manifest = try extractedFiles.json(extracted.appendingPathComponent("manifest.json"))
                try validateManifest(manifest, directory: extracted)
                guard !(try extractedFiles.data(extracted.appendingPathComponent(try IOSSafeArchive.relativePath(licensePath)))).isEmpty else {
                    throw IOSFileError.invalid("Extension license is missing")
                }
                try cancelled()
                try files.createDirectory(target.deletingLastPathComponent())
                try files.move(extracted, to: target)
                let marker = staging.appendingPathComponent(".sillyclient/preinstalled-extensions/\(id).json")
                try files.createDirectory(marker.deletingLastPathComponent())
                try files.writeJSON(item, to: marker, replace: false)
            }
        }
        if let companion = companion {
            guard companion["bundleId"] as? String == "sc-bordeaux", companion["revision"] as? Int == 1 else {
                throw IOSFileError.invalid("Unsupported companion preset")
            }
            try cancelled()
            let manifestURL = try resource("companion-presets/sc-bordeaux/manifest.json")
            let manifest = try IOSManagedFiles(root: manifestURL.deletingLastPathComponent()).json(manifestURL)
            guard let theme = manifest["theme"] as? [String: Any], let wallpaper = manifest["wallpaper"] as? [String: Any],
                  let settingsSpec = manifest["settings"] as? [String: Any] else { throw IOSFileError.invalid("Preset metadata is invalid") }
            var themeBytes = Data()
            for (index, asset) in [theme, wallpaper].enumerated() {
                guard let source = asset["source"] as? String, let target = asset["target"] as? String,
                      let hash = asset["sha256"] as? String else { throw IOSFileError.invalid("Preset asset is invalid") }
                let relative = try IOSSafeArchive.relativePath(target)
                let bundled = try resource("companion-presets/sc-bordeaux/\(try IOSSafeArchive.relativePath(source))")
                let bytes = try IOSManagedFiles(root: bundled.deletingLastPathComponent()).data(bundled, maximum: 32 * 1024 * 1024)
                guard IOSManagedFiles.hex(SHA256.hash(data: bytes)).uppercased() == hash.uppercased() else {
                    throw IOSFileError.invalid("Preset asset SHA-256 failed")
                }
                let destination = staging.appendingPathComponent(relative)
                guard !files.exists(destination) else { throw IOSFileError.invalid("Preset destination already exists") }
                try files.createDirectory(destination.deletingLastPathComponent())
                try files.write(bytes, to: destination, replace: false)
                if index == 0 { themeBytes = bytes }
            }
            let path = staging.appendingPathComponent("data/default-user/settings.json")
            let baseline = files.exists(path) ? path : staging.appendingPathComponent("default/content/settings.json")
            var settings = try files.json(baseline)
            guard let themeValue = try JSONSerialization.jsonObject(with: themeBytes) as? [String: Any] else {
                throw IOSFileError.invalid("Preset theme is invalid")
            }
            var power = settings["power_user"] as? [String: Any] ?? [:]
            for (key, value) in themeValue where key != "name" { power[key] = value }
            power["theme"] = settingsSpec["themeName"]
            power["theme_fallback"] = settingsSpec["themeName"]
            settings["power_user"] = power
            var background = settings["background"] as? [String: Any] ?? [:]
            for (key, value) in settingsSpec["background"] as? [String: Any] ?? [:] { background[key] = value }
            settings["background"] = background
            try files.createDirectory(path.deletingLastPathComponent())
            try files.writeJSON(settings, to: path)
        }
    }
}
