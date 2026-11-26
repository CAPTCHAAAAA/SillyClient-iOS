import Foundation
import CryptoKit

private final class IOSPinnedDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedBytes: Int64
    private let cancelled: () throws -> Void
    private let onProgress: ((Int64, Int64) -> Void)?
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?
    private var session: URLSession?
    private var lastReportedPercent: Int = -1

    init(destination: URL, expectedBytes: Int64, cancelled: @escaping () throws -> Void,
         onProgress: ((Int64, Int64) -> Void)? = nil) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.cancelled = cancelled
        self.onProgress = onProgress
    }

    func run(_ url: URL) throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("SillyClient-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/zip, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: request).resume()
        let deadline = Date().addingTimeInterval(185)
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
        var redirected = request
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do {
            try cancelled()
            guard totalBytesWritten <= expectedBytes,
                  totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == expectedBytes else {
                throw IOSFileError.invalid("Extension archive exceeds its pinned size")
            }
            if expectedBytes > 0 {
                let pct = Int(min(100, (totalBytesWritten * 100) / expectedBytes))
                if pct >= lastReportedPercent + 10 || pct == 100 {
                    lastReportedPercent = pct
                    onProgress?(totalBytesWritten, expectedBytes)
                }
            }
        } catch { result = .failure(error); downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try cancelled()
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw IOSFileError.invalid("Extension download returned HTTP \(code)")
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
    static let defaultMirrorPrefixes: [String] = [
        "https://gh-proxy.com/",
        "https://gh-proxy.org/",
        "",
        "https://edgeone.gh-proxy.com/",
        "https://ghproxy.vip/",
        "https://v6.gh-proxy.org/"
    ]

    static func mirrorCandidates(for rawUrl: String, preferredPrefix: String? = nil) -> [(prefix: String, label: String, url: URL)] {
        var ordered: [String] = []
        if let preferred = preferredPrefix, defaultMirrorPrefixes.contains(preferred) {
            ordered.append(preferred)
        }
        for prefix in defaultMirrorPrefixes where !ordered.contains(prefix) {
            ordered.append(prefix)
        }
        return ordered.compactMap { prefix in
            let full = prefix.isEmpty ? rawUrl : "\(prefix)\(rawUrl)"
            guard let url = URL(string: full) else { return nil }
            let label = prefix.isEmpty ? "direct" : (url.host ?? prefix)
            return (prefix: prefix, label: label, url: url)
        }
    }

    static func requireCompatible(clientVersion: String, minimumVersion: String?) throws {
        guard let minimum = minimumVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !minimum.isEmpty else { return }
        func parseParts(_ text: String) throws -> [Int] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
            let core = normalized.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? normalized
            let parts = core.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else {
                throw IOSFileError.invalid("Cannot validate SillyTavern version compatibility")
            }
            return parts
        }
        let actual = try parseParts(clientVersion)
        let required = try parseParts(minimum)
        for index in 0..<3 {
            if actual[index] > required[index] { return }
            if actual[index] < required[index] {
                throw IOSFileError.invalid("Extension requires SillyTavern \(minimum) or newer")
            }
        }
        if clientVersion.contains("-") && !minimum.contains("-") {
            throw IOSFileError.invalid("Extension requires stable SillyTavern \(minimum) or newer")
        }
    }

    static func validateManifest(_ manifest: [String: Any], directory: URL,
                                 expectedVersion: String? = nil, clientVersion: String? = nil) throws {
        let files = IOSManagedFiles(root: directory)
        var verifiedEntries = 0
        for key in ["js", "css"] {
            guard let raw = manifest[key], !(raw is NSNull) else { continue }
            let assets: [String]
            if let single = raw as? String {
                assets = single.isEmpty ? [] : [single]
            } else if let list = raw as? [String] {
                assets = list.filter { !$0.isEmpty }
            } else {
                throw IOSFileError.invalid("Extension entry declaration is invalid")
            }
            for asset in assets {
                let relative = try IOSSafeArchive.relativePath(asset.hasPrefix("./") ? String(asset.dropFirst(2)) : asset)
                let entryGuard = try files.guardValue(directory.appendingPathComponent(relative))
                guard !entryGuard.isDirectory else {
                    throw IOSFileError.invalid("Extension entry point is not a file")
                }
                verifiedEntries += 1
            }
        }
        if let expectedVersion = expectedVersion {
            guard let displayName = manifest["display_name"] as? String,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IOSFileError.invalid("Extension manifest display_name is missing")
            }
            guard let version = manifest["version"] as? String,
                  !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  version == expectedVersion else {
                throw IOSFileError.invalid("Pinned extension manifest version mismatch")
            }
            guard verifiedEntries > 0 else {
                throw IOSFileError.invalid("Extension manifest has no JavaScript or CSS entry")
            }
        }
        if let clientVersion = clientVersion {
            if let minRaw = manifest["minimum_client_version"], !(minRaw is NSNull) {
                guard let minimum = minRaw as? String else {
                    throw IOSFileError.invalid("Invalid extension minimum_client_version")
                }
                try requireCompatible(clientVersion: clientVersion, minimumVersion: minimum)
            }
        }
    }

    static func writeGitMetadata(directory: URL, repository: String, commit: String, branch: String = "main") throws {
        let files = IOSManagedFiles(root: directory)
        let gitDir = directory.appendingPathComponent(".git")
        for sub in ["refs/heads", "refs/remotes/origin", "objects/info", "objects/pack"] {
            try files.createDirectory(gitDir.appendingPathComponent(sub))
        }
        let remoteUrl = "https://github.com/\(repository).git"
        try files.write(Data("ref: refs/heads/\(branch)\n".utf8), to: gitDir.appendingPathComponent("HEAD"))
        let configText = """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = false
        \tbare = false
        \tlogallrefupdates = true
        [remote "origin"]
        \turl = \(remoteUrl)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "\(branch)"]
        \tremote = origin
        \tmerge = refs/heads/\(branch)

        """
        try files.write(Data(configText.utf8), to: gitDir.appendingPathComponent("config"))
        try files.write(Data("\(commit)\n".utf8), to: gitDir.appendingPathComponent("refs/heads/\(branch)"))
        try files.write(Data("\(commit)\n".utf8), to: gitDir.appendingPathComponent("refs/remotes/origin/\(branch)"))
    }
    private static func resource(_ relative: String) throws -> URL {
        let bundles = [Bundle.main, Bundle(for: IOSInstanceStore.self)]
        for bundle in bundles {
            if let root = bundle.resourceURL {
                let candidate = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        let file = URL(fileURLWithPath: relative)
        for bundle in bundles {
            if let url = bundle.url(forResource: file.deletingPathExtension().lastPathComponent,
                                    withExtension: file.pathExtension) { return url }
        }
        throw IOSFileError.invalid("Preinstallation asset is missing: \(file.lastPathComponent)")
    }

    static func install(staging: URL, instanceId: String, selection: [String: Any]?,
                        companion: [String: Any]?,
                        onProgress: ((Int, String) -> Void)? = nil,
                        cancelled: @escaping () throws -> Void) throws {
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
            let packageURL = staging.appendingPathComponent("package.json")
            let clientVersion: String? = files.exists(packageURL)
                ? (try? files.json(packageURL)["version"] as? String)
                : nil
            var preferredMirrorPrefix: String?
            let totalCount = max(1, ids.count)
            for (index, id) in ids.enumerated() {
                try cancelled()
                guard let item = extensions.first(where: { $0["id"] as? String == id }),
                      let repository = item["repository"] as? String,
                      let commit = item["commit"] as? String,
                      let expectedHash = item["archiveSha256"] as? String,
                      let expectedBytes = item["archiveBytes"] as? Int,
                      let expectedVersion = item["version"] as? String,
                      let licensePath = item["licensePath"] as? String,
                      repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                      commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                      expectedBytes > 0, expectedBytes <= 32 * 1024 * 1024 else {
                    throw IOSFileError.invalid("Unknown or invalid preinstalled extension")
                }
                if let clientVersion = clientVersion {
                    try requireCompatible(clientVersion: clientVersion, minimumVersion: item["minimumClientVersion"] as? String)
                }
                let name = String(repository.split(separator: "/")[1])
                let target = staging.appendingPathComponent("data/default-user/extensions/\(name)")
                if files.exists(target) {
                    guard try files.guardValue(target).isDirectory else { throw IOSFileError.invalid("Existing extension is not a directory") }
                    let existingFiles = IOSManagedFiles(root: target)
                    let existingManifestURL = target.appendingPathComponent("manifest.json")
                    guard existingFiles.exists(existingManifestURL) else {
                        throw IOSFileError.invalid("Existing incomplete extension preserved: \(id)")
                    }
                    let existingManifest = try existingFiles.json(existingManifestURL)
                    try validateManifest(existingManifest, directory: target, clientVersion: clientVersion)
                    continue
                }
                let basePct = 15 + (index * 60) / totalCount
                let spanPct = max(1, 60 / totalCount)
                onProgress?(basePct, "Downloading preinstalled extension: \(name) (\(index + 1)/\(totalCount))")
                let cache = staging.appendingPathComponent(".sillyclient-maintenance/download-cache/\(UUID().uuidString)")
                try files.createDirectory(cache)
                defer { if files.exists(cache) { try? FileManager.default.removeItem(at: files.checked(cache)) } }
                let archiveURL = cache.appendingPathComponent("download.zip")
                let rawUrl = "https://codeload.github.com/\(repository)/zip/\(commit)"
                let candidates = mirrorCandidates(for: rawUrl, preferredPrefix: preferredMirrorPrefix)
                var downloaded = false
                var mirrorFailures: [String] = []
                for candidate in candidates {
                    try cancelled()
                    if files.exists(archiveURL) {
                        try? FileManager.default.removeItem(at: files.checked(archiveURL))
                    }
                    do {
                        try IOSPinnedDownload(destination: archiveURL, expectedBytes: Int64(expectedBytes), cancelled: cancelled) { written, total in
                            let subPct = total > 0 ? Int((written * Int64(spanPct - 2)) / total) : 0
                            onProgress?(min(78, basePct + subPct), "Downloading \(name) via \(candidate.label) (\(index + 1)/\(totalCount))")
                        }.run(candidate.url)
                        let bytes = try files.data(archiveURL, maximum: expectedBytes)
                        let actualHash = IOSManagedFiles.hex(SHA256.hash(data: bytes))
                        guard actualHash.uppercased() == expectedHash.uppercased() else {
                            throw IOSFileError.invalid("Extension archive SHA-256 did not match its pinned catalog")
                        }
                        preferredMirrorPrefix = candidate.prefix
                        downloaded = true
                        break
                    } catch {
                        try cancelled()
                        if files.exists(archiveURL) {
                            try? FileManager.default.removeItem(at: files.checked(archiveURL))
                        }
                        mirrorFailures.append("\(candidate.label): \(error.localizedDescription)")
                    }
                }
                guard downloaded else {
                    let detail = mirrorFailures.joined(separator: "; ")
                    throw IOSFileError.invalid("Failed to download preinstalled extension \(name) from all mirrors (\(detail))")
                }
                onProgress?(min(79, basePct + spanPct - 1), "Extracting preinstalled extension: \(name) (\(index + 1)/\(totalCount))")
                let extracted = staging.appendingPathComponent(".sillyclient-extension-\(UUID().uuidString)")
                try files.createDirectory(extracted)
                defer { if files.exists(extracted) { try? FileManager.default.removeItem(at: files.checked(extracted)) } }
                try IOSSafeArchive.extract(archiveURL, to: extracted, stripSingleRoot: true,
                    maximumBytes: 128 * 1024 * 1024, maximumEntries: 8192, cancelled: cancelled)
                let extractedFiles = IOSManagedFiles(root: extracted)
                let manifest = try extractedFiles.json(extracted.appendingPathComponent("manifest.json"))
                try validateManifest(manifest, directory: extracted, expectedVersion: expectedVersion, clientVersion: clientVersion)
                guard !(try extractedFiles.data(extracted.appendingPathComponent(try IOSSafeArchive.relativePath(licensePath)))).isEmpty else {
                    throw IOSFileError.invalid("Extension license is missing")
                }
                try writeGitMetadata(directory: extracted, repository: repository, commit: commit)
                try cancelled()
                try files.createDirectory(target.deletingLastPathComponent())
                try files.move(extracted, to: target)
                let marker = staging.appendingPathComponent(".sillyclient/preinstalled-extensions/\(id).json")
                try files.createDirectory(marker.deletingLastPathComponent())
                try files.writeJSON(item, to: marker, replace: false)
            }
        }
        if let companion = companion {
            guard companion["bundleId"] as? String == "sc-bordeaux", companion["revision"] as? Int == 3 else {
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
