import Foundation
import Yams
import CryptoKit
import CoreFoundation

final class IOSInstanceStore {
    static let shared = IOSInstanceStore()
    let documents: URL
    let files: IOSManagedFiles
    let locations: IOSInstallationLocations
    private let fm = FileManager.default
    private static let userDataMarkers = Set(["settings.json", "characters", "chats", "group chats",
                                              "groups", "worlds", "themes", "backgrounds"])

    init(root: URL? = nil, locations: IOSInstallationLocations? = nil) {
        documents = (root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .resolvingSymlinksInPath().standardizedFileURL
        files = IOSManagedFiles(root: documents)
        self.locations = locations ?? IOSInstallationLocations(documents: documents)
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

    private func recordPath(_ record: [String: Any]) throws -> URL {
        if let relative = record["documentsRelativePath"] as? String {
            return documents.appendingPathComponent(try IOSSafeArchive.relativePath(relative))
        }
        guard let raw = record["path"] as? String else { throw IOSFileError.invalid("Registered instance path is missing") }
        return try IOSInstallationLocations.path(raw)
    }

    func location(_ raw: String, installPath: String? = nil, installPathMode: String? = nil,
                  requireExisting: Bool = true) throws -> IOSInstallationLocation {
        let id = try Self.identity(raw)
        let records = try registry()
        let mode = installPathMode ?? "exact"
        guard mode == "exact" || mode == "root" else { throw IOSFileError.invalid("Invalid installation path mode") }
        if let record = records[id], record["isTakeover"] as? Bool == true {
            throw IOSFileError.invalid("External takeover is unsupported on iOS; its source was preserved")
        }
        let defaultURL = documents.appendingPathComponent(id == "default" ? "SillyTavern" : "instances/\(id)")
        let requested = try installPath.map { try IOSInstallationLocations.path($0) }
        guard mode != "root" || requested != nil else { throw IOSFileError.invalid("Root installation mode requires an explicit absolute root") }
        let requestedTarget = requested.map { mode == "root" ? $0.appendingPathComponent(id) : $0 }
        let registered = try records[id].map { try recordPath($0) }
        if let registered = registered, let requestedTarget = requestedTarget, registered.path != requestedTarget.path {
            throw IOSFileError.invalid("The requested path conflicts with the registered instance location")
        }
        let target = registered ?? requestedTarget ?? defaultURL
        let location = try locations.acquire(target, grantId: records[id]?["grantId"] as? String)
        guard target.path != location.root.path, target.path != documents.appendingPathComponent("instances").path else {
            throw IOSFileError.invalid("An installation root cannot itself be an instance")
        }
        if IOSInstallationLocations.contains(documents, target) {
            let relative = String(target.path.dropFirst(documents.path.count + 1))
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".sillyclient") }),
                  !["covers", "instances-registry.json"].contains(String(relative.split(separator: "/").first ?? "")) else {
                throw IOSFileError.invalid("The installation path conflicts with launcher-owned storage")
            }
        }
        for (other, record) in records where other != id {
            let path = try recordPath(record)
            guard !IOSInstallationLocations.contains(path, target), !IOSInstallationLocations.contains(target, path) else {
                throw IOSFileError.invalid("Installation paths cannot overlap another registered instance")
            }
        }
        for legacy in [documents.appendingPathComponent("SillyTavern"), documents.appendingPathComponent("instances")] {
            if target.path != defaultURL.path, legacy.path != target.path, location.files.exists(legacy),
               IOSInstallationLocations.contains(target, legacy) || (legacy.lastPathComponent == "SillyTavern" && IOSInstallationLocations.contains(legacy, target)) {
                throw IOSFileError.invalid("The installation path overlaps existing managed storage")
            }
        }
        let managed = location.files
        if requireExisting || registered != nil {
            let guardValue = try managed.guardValue(target)
            guard guardValue.isDirectory else { throw IOSFileError.invalid("Instance directory is unavailable") }
            if let expected = records[id]?["directoryIdentity"] as? String, expected != guardValue.identity {
                throw IOSFileError.invalid("The registered instance directory was replaced; its contents were preserved")
            }
        }
        return location
    }

    func directory(_ raw: String, requireExisting: Bool = true, maintenance: Bool = false) throws -> URL {
        try location(raw, requireExisting: requireExisting).directory
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
        let registered = try registry()
        for id in ids.sorted() {
            do { result.append(try info(id)) }
            catch {
                if let record = registered[id] {
                    var unavailable = record
                    unavailable["instanceId"] = id
                    unavailable["installPath"] = try recordPath(record).path
                    unavailable["status"] = "unavailable"
                    unavailable["hasServer"] = false
                    unavailable["error"] = error.localizedDescription
                    result.append(unavailable)
                }
            }
        }
        return result
    }

    func info(_ id: String, installPath: String? = nil) throws -> [String: Any] {
        let location = try location(id, installPath: installPath)
        defer { withExtendedLifetime(location) {} }
        let target = location.directory
        let files = location.files
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

    private var ownershipName: String { ".sillyclient-installation.json" }

    private func register(_ id: String, location: IOSInstallationLocation) throws {
        var value = try registry()
        guard value[id] == nil, value.count < 256 else { throw IOSFileError.invalid("Instance is already registered or registry is full") }
        let now = Date().timeIntervalSince1970 * 1000
        let directory = location.directory
        var record: [String: Any] = ["instanceId": id, "path": directory.path, "isTakeover": false,
            "directoryIdentity": try location.files.guardValue(directory).identity,
            "rootIdentity": location.rootIdentity,
            "createdAt": now, "lastUsedAt": now, "totalUsageMs": 0]
        if let grant = location.grantId { record["grantId"] = grant }
        else { record["documentsRelativePath"] = String(directory.path.dropFirst(documents.path.count + 1)) }
        value[id] = record
        try files.writeJSON(value, to: registryURL)
    }

    private func ownership(_ id: String, location: IOSInstallationLocation, at directory: URL) throws {
        var receipt: [String: Any] = ["revision": 1, "owner": "sillyclient", "instanceId": id,
            "path": location.directory.path, "rootIdentity": location.rootIdentity,
            "directoryIdentity": try location.files.guardValue(directory).identity]
        if let grant = location.grantId { receipt["grantId"] = grant }
        try location.files.writeJSON(receipt, to: directory.appendingPathComponent(ownershipName), replace: false)
    }

    private func recoverRegistration(_ id: String, location: IOSInstallationLocation) throws {
        let receipt = try location.files.json(location.directory.appendingPathComponent(ownershipName))
        guard receipt["revision"] as? Int == 1, receipt["owner"] as? String == "sillyclient",
              receipt["instanceId"] as? String == id, receipt["path"] as? String == location.directory.path,
              receipt["rootIdentity"] as? String == location.rootIdentity,
              receipt["grantId"] as? String == location.grantId,
              receipt["directoryIdentity"] as? String == (try location.files.guardValue(location.directory).identity) else {
            throw IOSFileError.invalid("The existing destination is not a recoverable launcher-owned instance")
        }
        try register(id, location: location)
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
                 installPath: String?, installPathMode: String? = nil, port: Int, config: [String: Any]?,
                 preinstall: [String: Any]?, companion: [String: Any]?) throws -> URL {
        guard (1...65535).contains(port) else { throw IOSFileError.invalid("Invalid port") }
        guard localZip == nil else {
            throw IOSFileError.invalid("Arbitrary server ZIP versions are unsupported; import their user data instead")
        }
        let location = try location(id, installPath: installPath, installPathMode: installPathMode, requireExisting: false)
        defer { withExtendedLifetime(location) {} }
        let target = location.directory
        let files = location.files
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
            // Persisted creation selections are not an instruction to reinstall an existing runtime.
            try NodeRunner.shared.provisionMutation(instance: id, operation: operation) {
                if try registry()[id] == nil {
                    let legacy = documents.appendingPathComponent(id == "default" ? "SillyTavern" : "instances/\(id)")
                    if target.path == legacy.path, !files.exists(target.appendingPathComponent(ownershipName)) {
                        try ownership(id, location: location, at: target)
                    }
                    try recoverRegistration(id, location: location)
                }
                try updateConfig(target, port: port, config: config, files: files)
            }
            return target
        }
        let source = try bundleRuntime()
        let sourceFiles = IOSManagedFiles(root: source)
        let pinned = try validateRuntime(source, files: sourceFiles)
        guard selected == "stable" || selected == pinned else {
            throw IOSFileError.invalid("This iOS build supports pinned SillyTavern \(pinned), not \(selected)")
        }
        guard try registry().count < 256 else { throw IOSFileError.invalid("Instance registry is full") }
        let parent = target.deletingLastPathComponent()
        try files.createDirectory(parent)
        let staging = parent.appendingPathComponent(".sillyclient-staging-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: files.checked(staging)) } }
        try NodeRunner.shared.checkCurrent(instance: id, operation: operation)
        try updateConfig(staging, port: port, config: config, dataRoot: target.appendingPathComponent("data"), files: files)
        try IOSPreinstaller.install(staging: staging, instanceId: id, selection: preinstall, companion: companion) {
            try NodeRunner.shared.checkCurrent(instance: id, operation: operation)
        }
        try ownership(id, location: location, at: staging)
        try NodeRunner.shared.provisionMutation(instance: id, operation: operation) {
            guard !files.exists(target), try registry()[id] == nil else {
                throw IOSFileError.invalid("Instance destination was created by another operation")
            }
            try files.move(staging, to: target)
            committed = true
            do { try register(id, location: location) }
            catch { throw IOSFileError.invalid("The prepared instance was preserved at \(target.path), but registration failed: \(error.localizedDescription)") }
        }
        return target
    }

    func updateConfig(_ directory: URL, port: Int, config: [String: Any]?, dataRoot: URL? = nil,
                      files supplied: IOSManagedFiles? = nil) throws {
        let lease: IOSInstallationLocation? = supplied == nil ? try locations.acquire(directory) : nil
        defer { withExtendedLifetime(lease) {} }
        let files = supplied ?? lease!.files
        let path = directory.appendingPathComponent("config.yaml")
        var value: [String: Any] = [:]
        if files.exists(path) {
            guard let text = String(data: try files.data(path), encoding: .utf8),
                  let parsed = try Yams.load(yaml: text) as? [String: Any] else {
                throw IOSFileError.invalid("The existing YAML configuration is invalid")
            }
            value = parsed
        }
        func mapping(_ name: String) throws -> [String: Any] {
            guard let raw = value[name] else { return [:] }
            guard let map = raw as? [String: Any] else {
                throw IOSFileError.invalid("Existing YAML \(name) must be a mapping; its original contents were preserved")
            }
            return map
        }
        var protocolValue = try mapping("protocol")
        var browser = try mapping("browserLaunch")
        if let config = config {
            guard Set(config.keys).isSubset(of: Set(["listen", "ipv4", "ipv6", "dnsIpv6", "heartbeat", "keepAlive"])) else {
                throw IOSFileError.invalid("Unknown instance configuration option")
            }
            func boolean(_ name: String, _ defaultValue: Bool) throws -> Bool {
                guard let raw = config[name] else { return defaultValue }
                guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw IOSFileError.invalid("Invalid Boolean configuration: \(name)")
                }
                return number.boolValue
            }
            let ipv4 = try boolean("ipv4", protocolValue["ipv4"] as? Bool ?? true)
            let ipv6 = try boolean("ipv6", protocolValue["ipv6"] as? Bool ?? false)
            guard ipv4 || ipv6 else { throw IOSFileError.invalid("Enable at least one IP protocol") }
            guard let heartbeat = (config["heartbeat"] ?? value["heartbeatInterval"] ?? NSNumber(value: 0)) as? NSNumber,
                  CFGetTypeID(heartbeat) != CFBooleanGetTypeID(), heartbeat.doubleValue.isFinite,
                  heartbeat.doubleValue.rounded() == heartbeat.doubleValue, (0...2147483647).contains(heartbeat.intValue) else {
                throw IOSFileError.invalid("Invalid heartbeat interval")
            }
            value["listen"] = try boolean("listen", value["listen"] as? Bool ?? false)
            protocolValue["ipv4"] = ipv4
            protocolValue["ipv6"] = ipv6
            value["protocol"] = protocolValue
            value["dnsPreferIPv6"] = try boolean("dnsIpv6", value["dnsPreferIPv6"] as? Bool ?? false)
            value["heartbeatInterval"] = heartbeat.intValue
            value["enableKeepAlive"] = try boolean("keepAlive", value["enableKeepAlive"] as? Bool ?? false)
        }
        value["dataRoot"] = (dataRoot ?? directory.appendingPathComponent("data")).path
        value["port"] = port
        browser["enabled"] = false
        value["browserLaunch"] = browser
        if value["listen"] == nil { value["listen"] = false }
        if value["protocol"] == nil { value["protocol"] = ["ipv4": true, "ipv6": false] }
        try files.write(Data(Yams.dump(object: value).utf8), to: path)
    }

    func ipv4(_ directory: URL) throws -> Bool {
        let location = try locations.acquire(directory)
        defer { withExtendedLifetime(location) {} }
        let files = location.files
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
                 installPathMode: String? = nil, mode: String, includeSecrets: Bool,
                 preinstall: [String: Any]?, scopedSource: URL? = nil) throws -> URL {
        guard mode == "copy" else {
            throw IOSFileError.invalid("iOS cannot safely persist arbitrary external takeover; use copy migration")
        }
        let location = try location(id, installPath: targetPath, installPathMode: installPathMode, requireExisting: false)
        defer { withExtendedLifetime(location) {} }
        let target = location.directory
        let files = location.files
        guard !files.exists(target), try registry()[id] == nil else { throw IOSFileError.invalid("Migration target already exists") }
        guard try registry().count < 256 else { throw IOSFileError.invalid("Instance registry is full") }
        let source = try IOSInstallationLocations.path(sourcePath)
        guard source.path != target.path, !source.path.hasPrefix(target.path + "/"), !target.path.hasPrefix(source.path + "/") else {
            throw IOSFileError.invalid("Migration source and target must not overlap")
        }
        let sourceFiles: IOSManagedFiles
        if let scoped = scopedSource, scoped.resolvingSymlinksInPath().standardizedFileURL.path == source.path {
            sourceFiles = IOSManagedFiles(root: source)
        } else if source.path.hasPrefix(documents.path + "/") { sourceFiles = self.files }
        else {
            let temporary = fm.temporaryDirectory.resolvingSymlinksInPath()
            sourceFiles = IOSManagedFiles(root: temporary)
        }
        _ = try sourceFiles.checked(source)
        let parent = target.deletingLastPathComponent()
        try files.createDirectory(parent)
        let staging = parent.appendingPathComponent(".sillyclient-staging-\(UUID().uuidString)")
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
        let imported = parent.appendingPathComponent(".sillyclient-import-\(UUID().uuidString)")
        try files.createExclusiveDirectory(imported)
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
        try updateConfig(staging, port: 8000, config: nil, dataRoot: target.appendingPathComponent("data"), files: files)
        try IOSPreinstaller.install(staging: staging, instanceId: id, selection: preinstall, companion: nil, cancelled: cancelled)
        try ownership(id, location: location, at: staging)
        try NodeRunner.shared.provisionMutation(instance: id, operation: operation) {
            guard !files.exists(target) else { throw IOSFileError.invalid("Migration target is occupied") }
            try files.move(staging, to: target)
            committed = true
            do { try register(id, location: location) }
            catch { throw IOSFileError.invalid("The copied data was preserved at \(target.path), but registration failed: \(error.localizedDescription)") }
        }
        return target
    }

    func uninstall(_ id: String, installPath: String? = nil) throws -> [String: Any] {
        var records = try registry()
        let cleanId = id.hasPrefix("scan-") ? String(id.dropFirst(5)) : id
        let isTakeover = (records[cleanId]?["isTakeover"] as? Bool == true) || (records[id]?["isTakeover"] as? Bool == true)
        if isTakeover {
            try NodeRunner.shared.beginMaintenance(instance: id)
            defer { NodeRunner.shared.endMaintenance(instance: id) }
            try NodeRunner.shared.stoppedMutation(instance: id) {
                records.removeValue(forKey: id)
                records.removeValue(forKey: cleanId)
                try self.files.writeJSON(records, to: self.registryURL)
            }
            return ["success": true, "freedBytes": 0]
        }
        let location = try location(id, installPath: installPath)
        defer { withExtendedLifetime(location) {} }
        let source = location.directory
        let files = location.files
        let legacy = documents.appendingPathComponent(id == "default" ? "SillyTavern" : "instances/\(id)")
        let legacyClean = documents.appendingPathComponent(cleanId == "default" ? "SillyTavern" : "instances/\(cleanId)")
        let instancesDir = documents.appendingPathComponent("instances")
        let isLauncherChild = source.path == legacy.path || source.path == legacyClean.path
            || source.path.hasPrefix(instancesDir.path + "/")
            || files.exists(source.appendingPathComponent(ownershipName))
        guard records[id] != nil || records[cleanId] != nil || isLauncherChild else {
            throw IOSFileError.invalid("Uninstall requires a registered instance; unregistered selected contents were preserved")
        }
        let identity = try files.guardValue(source).identity
        try NodeRunner.shared.beginMaintenance(instance: id)
        defer { NodeRunner.shared.endMaintenance(instance: id) }
        let target = source.deletingLastPathComponent().appendingPathComponent(".sillyclient-removed-\(UUID().uuidString)")
        try NodeRunner.shared.stoppedMutation(instance: id) {
            guard try files.guardValue(source).identity == identity else { throw IOSFileError.invalid("Instance directory changed") }
            try files.move(source, to: target)
            records.removeValue(forKey: id)
            records.removeValue(forKey: cleanId)
            do { try self.files.writeJSON(records, to: registryURL) }
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

    func rename(instanceId: String, newName: String) throws -> [String: Any] {
        let oldId = try Self.identity(instanceId)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IOSFileError.invalid("A non-empty new instance name is required")
        }
        var records = try registry()
        var record = records[oldId] ?? [:]
        record["name"] = trimmed
        records[oldId] = record
        try self.files.writeJSON(records, to: registryURL)
        let dir = try? directory(oldId)
        return [
            "success": true,
            "oldId": oldId,
            "newId": oldId,
            "oldPath": dir?.path ?? "",
            "newPath": dir?.path ?? ""
        ]
    }

    func relocate(instanceId: String, targetPath: String?) throws -> [String: Any] {
        let id = try Self.identity(instanceId)
        let sourceDir = try directory(id)
        if targetPath == nil || targetPath == sourceDir.path {
            return ["success": true, "instanceId": id, "oldPath": sourceDir.path, "newPath": sourceDir.path, "unchanged": true]
        }
        let target = try IOSInstallationLocations.path(targetPath!)
        guard target.path != sourceDir.path else {
            return ["success": true, "instanceId": id, "oldPath": sourceDir.path, "newPath": sourceDir.path, "unchanged": true]
        }
        try files.move(sourceDir, to: target)
        var records = try registry()
        var record = records[id] ?? [:]
        record["path"] = target.path
        record["documentsRelativePath"] = nil
        records[id] = record
        try self.files.writeJSON(records, to: registryURL)
        return ["success": true, "instanceId": id, "oldPath": sourceDir.path, "newPath": target.path, "unchanged": false]
    }
}
