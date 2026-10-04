import Foundation
import Yams
import CryptoKit
import CoreFoundation

final class IOSInstanceStore {
    static let shared = IOSInstanceStore()
    let documents: URL
    let files: IOSManagedFiles
    private let fm = FileManager.default
    private static let userDataMarkers = Set(["settings.json", "characters", "chats", "group chats",
                                              "groups", "worlds", "themes", "backgrounds"])

    init(root: URL? = nil) {
        documents = (root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .resolvingSymlinksInPath().standardizedFileURL
        files = IOSManagedFiles(root: documents)
    }

    static func identity(_ raw: String?) throws -> String {
        guard let value = raw, value.range(of: "^[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil else {
            throw IOSFileError.invalid("An explicit valid instance identity is required")
        }
        return value
    }

    private var registryURL: URL { documents.appendingPathComponent("instances-registry.json") }
    func registry() throws -> [String: [String: Any]] {
        guard files.exists(registryURL) else { return [:] }
        guard let value = try files.json(registryURL) as? [String: [String: Any]], value.count <= 256 else {
            throw IOSFileError.invalid("Instance registry is invalid or exceeds its limit")
        }
        return value
    }

    func directory(_ raw: String, requireExisting: Bool = true, maintenance: Bool = false) throws -> URL {
        let id = try Self.identity(raw)
        let records = try registry()
        if let record = records[id], record["isTakeover"] as? Bool == true {
            throw IOSFileError.invalid("External takeover is unsupported on iOS; its source was preserved")
        }
        let defaultURL = documents.appendingPathComponent(id == "default" ? "SillyTavern" : "instances/\(id)")
        let target = (records[id]?["path"] as? String).map { URL(fileURLWithPath: $0) } ?? defaultURL
        let safe = try files.checked(target, allowMissing: !requireExisting)
        guard safe == defaultURL || safe == documents.appendingPathComponent("instances/\(id)") else {
            throw IOSFileError.invalid("The instance is not in its managed directory")
        }
        if requireExisting {
            guard try files.guardValue(safe).isDirectory else { throw IOSFileError.invalid("Instance directory is unavailable") }
        }
        return safe
    }

    func records() throws -> [[String: Any]] {
        var ids = Set(try registry().keys)
        if files.exists(documents.appendingPathComponent("SillyTavern")) { ids.insert("default") }
        let parent = documents.appendingPathComponent("instances")
        if files.exists(parent) {
            for child in try files.children(parent, limit: 256) {
                if (try? Self.identity(child.lastPathComponent)) != nil { ids.insert(child.lastPathComponent) }
            }
        }
        var result: [[String: Any]] = []
        for id in ids.sorted() {
            if let info = try? info(id) { result.append(info) }
        }
        return result
    }

    func info(_ id: String) throws -> [String: Any] {
        let target = try directory(id)
        let root = try files.guardValue(target)
        let record = try registry()[id] ?? [:]
        let package = target.appendingPathComponent("package.json")
        let version = files.exists(package) ? (try files.json(package)["version"] as? String ?? "local") : "local"
        let status = NodeRunner.shared.status
        let active = status["instanceId"] as? String == id
        return ["instanceId": id, "version": version, "path": target.path, "installPath": target.path,
            "hasServer": files.exists(target.appendingPathComponent("server.js")),
            "sizeBytes": record["sizeBytes"] as? Int64 ?? 0,
            "createdAt": record["createdAt"] ?? Double(root.birthSeconds) * 1000,
            "lastUsedAt": record["lastUsedAt"] ?? Double(root.modifiedSeconds) * 1000,
            "totalUsageMs": record["totalUsageMs"] ?? 0,
            "status": active ? status["state"] ?? "starting" : "stopped",
            "uptimeSeconds": active ? status["uptimeSeconds"] ?? 0 : 0, "isTakeover": false]
    }

    private func register(_ id: String, directory: URL) throws {
        var value = try registry()
        guard value[id] == nil, value.count < 256 else { throw IOSFileError.invalid("Instance is already registered or registry is full") }
        let now = Date().timeIntervalSince1970 * 1000
        value[id] = ["instanceId": id, "path": directory.path, "isTakeover": false,
            "createdAt": now, "lastUsedAt": now, "totalUsageMs": 0]
        try files.writeJSON(value, to: registryURL)
    }

    private func bundleRuntime() throws -> URL {
        for value in [Bundle.main.bundleURL.appendingPathComponent("sillytavern"),
                      Bundle.main.resourceURL?.appendingPathComponent("sillytavern")] {
            if let value = value, fm.fileExists(atPath: value.appendingPathComponent("server.js").path) { return value }
        }
        throw IOSFileError.invalid("The pinned iOS runtime is missing")
    }

    @discardableResult
    func validateRuntime(_ directory: URL, files managed: IOSManagedFiles) throws -> String {
        for name in ["server.js", "ios-loader.mjs", "package.json", "dist/ios-frontend/manifest.json"] {
            guard managed.exists(directory.appendingPathComponent(name)),
                  !(try managed.guardValue(directory.appendingPathComponent(name))).isDirectory else {
                throw IOSFileError.invalid("This instance has no complete prepared iOS runtime; copy its data into a new instance")
            }
        }
        guard try managed.guardValue(directory.appendingPathComponent("node_modules")).isDirectory else {
            throw IOSFileError.invalid("The prepared iOS runtime dependencies are missing")
        }
        let manifest = try managed.json(directory.appendingPathComponent("dist/ios-frontend/manifest.json"))
        let package = try managed.json(directory.appendingPathComponent("package.json"))
        guard let version = package["version"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest["format"] as? Int == 1, manifest["version"] as? String == version else {
            throw IOSFileError.invalid("The runtime and its prebuilt frontend do not match")
        }
        return version
    }

    func prepare(instance id: String, operation: String, version: String?, localZip: String?,
                 installPath: String?, port: Int, config: [String: Any]?,
                 preinstall: [String: Any]?, companion: [String: Any]?) throws -> URL {
        guard (1...65535).contains(port) else { throw IOSFileError.invalid("Invalid port") }
        guard localZip == nil else {
            throw IOSFileError.invalid("Arbitrary server ZIP versions are unsupported; import their user data instead")
        }
        let target = try directory(id, requireExisting: false)
        if let requested = installPath, !requested.isEmpty, URL(fileURLWithPath: requested).standardizedFileURL != target {
            throw IOSFileError.invalid("Custom installation paths are unsupported on iOS")
        }
        let selected = (version ?? "stable").replacingOccurrences(of: "^v+", with: "", options: .regularExpression)
        if files.exists(target) {
            let actual = try validateRuntime(target, files: files)
            let bundle = try bundleRuntime()
            let bundledFiles = IOSManagedFiles(root: bundle)
            let pinned = try validateRuntime(bundle, files: bundledFiles)
            guard try files.data(target.appendingPathComponent("ios-loader.mjs"))
                    == bundledFiles.data(bundle.appendingPathComponent("ios-loader.mjs")),
                  actual == pinned else {
                throw IOSFileError.invalid("This instance uses an older or incompatible iOS runtime; copy its data into a new instance")
            }
            guard selected == "stable" || selected == "local" || selected == actual else {
                throw IOSFileError.invalid("The selected version differs from the installed iOS runtime")
            }
            guard preinstall == nil, companion == nil else {
                throw IOSFileError.invalid("Preinstallation only applies to a new instance or copy migration")
            }
            try NodeRunner.shared.provisionMutation(instance: id, operation: operation) {
                try updateConfig(target, port: port, config: config)
            }
            return target
        }
        let source = try bundleRuntime()
        let sourceFiles = IOSManagedFiles(root: source)
        let pinned = try validateRuntime(source, files: sourceFiles)
        guard selected == "stable" || selected == pinned else {
            throw IOSFileError.invalid("This iOS build supports pinned SillyTavern \(pinned), not \(selected)")
        }
        let parent = documents.appendingPathComponent(".sillyclient-staging")
        try files.createDirectory(parent)
        let staging = parent.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: source, to: staging)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: files.checked(staging)) } }
        try NodeRunner.shared.checkCurrent(instance: id, operation: operation)
        try updateConfig(staging, port: port, config: config, dataRoot: target.appendingPathComponent("data"))
        try IOSPreinstaller.install(staging: staging, instanceId: id, selection: preinstall, companion: companion) {
            try NodeRunner.shared.checkCurrent(instance: id, operation: operation)
        }
        try files.createDirectory(target.deletingLastPathComponent())
        try NodeRunner.shared.provisionMutation(instance: id, operation: operation) {
            guard !files.exists(target), try registry()[id] == nil else {
                throw IOSFileError.invalid("Instance destination was created by another operation")
            }
            try files.move(staging, to: target)
            committed = true
            do { try register(id, directory: target) }
            catch { throw IOSFileError.invalid("The prepared instance was preserved at \(target.path), but registration failed: \(error.localizedDescription)") }
        }
        return target
    }

    func updateConfig(_ directory: URL, port: Int, config: [String: Any]?, dataRoot: URL? = nil) throws {
        let path = directory.appendingPathComponent("config.yaml")
        var value: [String: Any] = [:]
        if files.exists(path) {
            guard let text = String(data: try files.data(path), encoding: .utf8),
                  let parsed = try Yams.load(yaml: text) as? [String: Any] else {
                throw IOSFileError.invalid("The existing YAML configuration is invalid")
            }
            value = parsed
        }
        if let config = config {
            func boolean(_ name: String, _ defaultValue: Bool) throws -> Bool {
                guard let raw = config[name] else { return defaultValue }
                guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw IOSFileError.invalid("Invalid Boolean configuration: \(name)")
                }
                return number.boolValue
            }
            let ipv4 = try boolean("ipv4", true)
            let ipv6 = try boolean("ipv6", false)
            guard ipv4 || ipv6 else { throw IOSFileError.invalid("Enable at least one IP protocol") }
            guard let heartbeat = (config["heartbeat"] ?? NSNumber(value: 0)) as? NSNumber,
                  CFGetTypeID(heartbeat) != CFBooleanGetTypeID(), heartbeat.doubleValue.isFinite,
                  heartbeat.doubleValue.rounded() == heartbeat.doubleValue, (0...3600).contains(heartbeat.intValue) else {
                throw IOSFileError.invalid("Invalid heartbeat interval")
            }
            value["listen"] = try boolean("listen", false)
            var protocolValue = value["protocol"] as? [String: Any] ?? [:]
            protocolValue["ipv4"] = ipv4
            protocolValue["ipv6"] = ipv6
            value["protocol"] = protocolValue
            value["dnsPreferIPv6"] = try boolean("dnsIpv6", false)
            value["heartbeatInterval"] = heartbeat.intValue
            value["enableKeepAlive"] = try boolean("keepAlive", false)
        }
        value["dataRoot"] = (dataRoot ?? directory.appendingPathComponent("data")).path
        value["port"] = port
        var browser = value["browserLaunch"] as? [String: Any] ?? [:]
        browser["enabled"] = false
        value["browserLaunch"] = browser
        if value["listen"] == nil { value["listen"] = false }
        if value["protocol"] == nil { value["protocol"] = ["ipv4": true, "ipv6": false] }
        try files.write(Data(Yams.dump(object: value).utf8), to: path)
    }

    func ipv4(_ directory: URL) throws -> Bool {
        guard let text = String(data: try files.data(directory.appendingPathComponent("config.yaml")), encoding: .utf8),
              let parsed = try Yams.load(yaml: text) as? [String: Any] else {
            throw IOSFileError.invalid("Instance configuration is invalid")
        }
        return (parsed["protocol"] as? [String: Any])?["ipv4"] as? Bool ?? true
    }

    func migrationDataDirectory(_ source: URL, files sourceFiles: IOSManagedFiles, portableBackup: Bool = false) throws -> URL {
        guard try sourceFiles.guardValue(source).isDirectory else { throw IOSFileError.invalid("Migration source is not a directory") }
        var backup = source
        var entries = try sourceFiles.children(backup, limit: 512)
        if !sourceFiles.exists(backup.appendingPathComponent("data")), entries.count == 1,
           try sourceFiles.guardValue(entries[0]).isDirectory,
           sourceFiles.exists(entries[0].appendingPathComponent("data")) {
            backup = entries[0]
            entries = try sourceFiles.children(backup, limit: 512)
        }
        let data = backup.appendingPathComponent("data")
        if portableBackup, sourceFiles.exists(data) {
            guard try sourceFiles.guardValue(data).isDirectory else { throw IOSFileError.invalid("Migration data root is not a directory") }
            return data
        }
        let configuration = backup.appendingPathComponent("config.yaml")
        if sourceFiles.exists(configuration) {
            guard let text = String(data: try sourceFiles.data(configuration), encoding: .utf8),
                  let value = try Yams.load(yaml: text) as? [String: Any] else {
                throw IOSFileError.invalid("The migration source has invalid YAML configuration")
            }
            if let raw = value["dataRoot"] {
                guard let path = raw as? String, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw IOSFileError.invalid("The migration dataRoot is invalid")
                }
                let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : backup.appendingPathComponent(path)
                let checked = try sourceFiles.checked(candidate)
                guard try sourceFiles.guardValue(checked).isDirectory,
                      checked.path == source.path || checked.path.hasPrefix(source.path + "/") else {
                    throw IOSFileError.invalid("Select the external dataRoot directory itself to grant access")
                }
                return checked
            }
        }
        if sourceFiles.exists(data) {
            guard try sourceFiles.guardValue(data).isDirectory else { throw IOSFileError.invalid("Migration data root is not a directory") }
            return data
        }
        let dataOnly = entries.contains { Self.userDataMarkers.contains($0.lastPathComponent) }
            || entries.contains { child in
                (try? sourceFiles.guardValue(child).isDirectory) == true
                    && (sourceFiles.exists(child.appendingPathComponent("settings.json"))
                        || sourceFiles.exists(child.appendingPathComponent("characters"))
                        || child.lastPathComponent == "default-user")
            }
        guard dataOnly, !sourceFiles.exists(backup.appendingPathComponent("server.js")),
              !sourceFiles.exists(backup.appendingPathComponent("node_modules")) else {
            throw IOSFileError.invalid("No user data root was found; select a data directory or backup containing data")
        }
        return backup
    }

    func migrationDataTarget(_ source: URL, files sourceFiles: IOSManagedFiles, dataRoot: URL) throws -> URL {
        let entries = try sourceFiles.children(source, limit: 512)
        let userDirectories = Set(entries.filter { child in
            (try? sourceFiles.guardValue(child).isDirectory) == true
                && (child.lastPathComponent == "default-user"
                    || sourceFiles.exists(child.appendingPathComponent("settings.json"))
                    || sourceFiles.exists(child.appendingPathComponent("characters")))
        }.map(\.path))
        let singleUser = entries.contains {
            Self.userDataMarkers.contains($0.lastPathComponent) && !userDirectories.contains($0.path)
        }
        let nestedUsers = !userDirectories.isEmpty
        guard !singleUser || !nestedUsers else {
            throw IOSFileError.invalid("Ambiguous user data layout; select the data root or a single user directory")
        }
        return singleUser ? dataRoot.appendingPathComponent("default-user") : dataRoot
    }

    func migrate(instance id: String, operation: String, sourcePath: String, targetPath: String?,
                 mode: String, includeSecrets: Bool, preinstall: [String: Any]?, scopedSource: URL? = nil) throws -> URL {
        guard mode == "copy" else {
            throw IOSFileError.invalid("iOS cannot safely persist arbitrary external takeover; use copy migration")
        }
        let target = try directory(id, requireExisting: false)
        guard !files.exists(target), try registry()[id] == nil else { throw IOSFileError.invalid("Migration target already exists") }
        if let custom = targetPath, !custom.isEmpty, URL(fileURLWithPath: custom).standardizedFileURL != target {
            throw IOSFileError.invalid("Custom migration destinations are unsupported on iOS")
        }
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard source != target, !source.path.hasPrefix(target.path + "/"), !target.path.hasPrefix(source.path + "/") else {
            throw IOSFileError.invalid("Migration source and target must not overlap")
        }
        let sourceFiles: IOSManagedFiles
        if let scoped = scopedSource, scoped.resolvingSymlinksInPath().standardizedFileURL == source {
            sourceFiles = IOSManagedFiles(root: source)
        } else if source.path.hasPrefix(documents.path + "/") { sourceFiles = files }
        else {
            let temporary = fm.temporaryDirectory.resolvingSymlinksInPath()
            sourceFiles = IOSManagedFiles(root: temporary)
        }
        _ = try sourceFiles.checked(source)
        let parent = documents.appendingPathComponent(".sillyclient-staging")
        try files.createDirectory(parent)
        let staging = parent.appendingPathComponent(UUID().uuidString)
        let runtime = try bundleRuntime()
        try validateRuntime(runtime, files: IOSManagedFiles(root: runtime))
        try fm.copyItem(at: runtime, to: staging)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: files.checked(staging)) } }
        let cancelled = { try NodeRunner.shared.checkCurrent(instance: id, operation: operation) }
        let included: (String) -> Bool = { relative in
            !relative.split(separator: "/").contains(where: {
                $0 == ".git" || $0 == "node_modules"
                    || (!includeSecrets && ($0 == "secrets.json" || $0 == "secrets.json.enc"))
            })
        }
        let imported = parent.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(imported)
        defer { try? fm.removeItem(at: files.checked(imported)) }
        let dataSource: URL
        let dataFiles: IOSManagedFiles
        if source.pathExtension.lowercased() == "zip" {
            let sourceGuard = try sourceFiles.guardValue(source)
            guard !sourceGuard.isDirectory, sourceGuard.size <= 256 * 1024 * 1024 else {
                throw IOSFileError.invalid("Migration archive exceeds its compressed limit")
            }
            let archive = imported.appendingPathComponent("source.zip")
            try sourceFiles.copyTree(source, to: archive, destination: files,
                budget: IOSInspectionBudget(maxEntries: 1, maxBytes: 256 * 1024 * 1024), cancelled: cancelled)
            let extracted = imported.appendingPathComponent("extracted")
            try files.createDirectory(extracted)
            try IOSSafeArchive.extract(archive, to: extracted, stripSingleRoot: false, include: included, cancelled: cancelled)
            dataSource = try migrationDataDirectory(extracted, files: files, portableBackup: true)
            dataFiles = files
        } else {
            dataSource = try migrationDataDirectory(source, files: sourceFiles)
            dataFiles = sourceFiles
        }
        let dataTarget = staging.appendingPathComponent("data")
        let copyTarget = try migrationDataTarget(dataSource, files: dataFiles, dataRoot: dataTarget)
        if files.exists(dataTarget) { try fm.removeItem(at: files.checked(dataTarget)) }
        try dataFiles.copyTree(dataSource, to: copyTarget, destination: files, include: included, cancelled: cancelled)
        try updateConfig(staging, port: 8000, config: nil, dataRoot: target.appendingPathComponent("data"))
        try IOSPreinstaller.install(staging: staging, instanceId: id, selection: preinstall, companion: nil, cancelled: cancelled)
        try files.createDirectory(target.deletingLastPathComponent())
        try NodeRunner.shared.provisionMutation(instance: id, operation: operation) {
            guard !files.exists(target) else { throw IOSFileError.invalid("Migration target is occupied") }
            try files.move(staging, to: target)
            committed = true
            do { try register(id, directory: target) }
            catch { throw IOSFileError.invalid("The copied data was preserved at \(target.path), but registration failed: \(error.localizedDescription)") }
        }
        return target
    }

    func uninstall(_ id: String) throws -> [String: Any] {
        var records = try registry()
        if records[id]?["isTakeover"] as? Bool == true {
            try NodeRunner.shared.beginMaintenance(instance: id)
            defer { NodeRunner.shared.endMaintenance(instance: id) }
            try NodeRunner.shared.stoppedMutation(instance: id) {
                records.removeValue(forKey: id)
                try files.writeJSON(records, to: registryURL)
            }
            return ["success": true, "freedBytes": 0]
        }
        let source = try directory(id)
        let identity = try files.guardValue(source).identity
        try NodeRunner.shared.beginMaintenance(instance: id)
        defer { NodeRunner.shared.endMaintenance(instance: id) }
        let deleted = documents.appendingPathComponent(".sillyclient-removed")
        try files.createDirectory(deleted)
        let target = deleted.appendingPathComponent(UUID().uuidString)
        try NodeRunner.shared.stoppedMutation(instance: id) {
            guard try files.guardValue(source).identity == identity else { throw IOSFileError.invalid("Instance directory changed") }
            try files.move(source, to: target)
            records.removeValue(forKey: id)
            do { try files.writeJSON(records, to: registryURL) }
            catch {
                if !files.exists(source), (try? files.guardValue(target).identity) == identity {
                    do { try files.move(target, to: source) }
                    catch { throw IOSFileError.invalid("Removal was not committed; instance data was preserved at \(target.path)") }
                }
                throw IOSFileError.invalid("Removal was not committed; instance data was preserved")
            }
        }
        try fm.removeItem(at: files.checked(target))
        return ["success": true, "freedBytes": 0]
    }
}
