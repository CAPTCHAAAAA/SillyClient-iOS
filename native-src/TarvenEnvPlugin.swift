import Foundation
import Capacitor
import UIKit
import WebKit
import UniformTypeIdentifiers

@objc(TarvenEnvPlugin)
public final class TarvenEnvPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "TarvenEnv"
    public let jsName = "TarvenEnv"
    private let io = DispatchQueue(label: "com.sillyclient.instance-io", qos: .userInitiated)
    private let store = IOSInstanceStore.shared
    private var pendingPickerCall: CAPPluginCall?
    private var pendingPickerAction = ""
    private var pendingInstanceId = ""
    private var scopedDirectories: [String: URL] = [:]
    private var viewSession: (String, URL, Bool)?
    private var pendingViewSession: (String, URL, Bool)?
    private var viewGeneration: UInt64 = 0
    deinit { for directory in scopedDirectories.values { directory.stopAccessingSecurityScopedResource() } }

    public var pluginMethods: [CAPPluginMethod] {
        var names = [
            "getPlatform", "getAppVersion", "getStatus", "getSafeInsets", "scanInstances",
            "provisionAndStart", "enterImmersive", "openExternalUrl", "exitImmersive", "returnToTavern",
            "closeTavern", "stop", "getLogs", "fetchReleases", "getInstanceInfo", "pingUrl",
            "getContentOpenMode", "setContentOpenMode", "setRemoteBasicAuth", "getRemoteBasicAuthStatus",
            "clearRemoteBasicAuth", "pickDirectory", "pickImage", "pickZipFile", "saveTextFile",
            "readTextFile", "migrateInstance", "sendCommand", "reloadTavern", "clearWebViewData",
            "setPullToRefresh", "uninstallInstance", "cleanGarbage", "deleteGarbageItem", "openFilesApp",
            "setSecret", "getSecret", "deleteSecret", "checkUpdate", "scanInstanceMaintenance",
            "applyInstanceMaintenance", "listInstanceMaintenanceRecovery", "restoreInstanceMaintenance"
        ]
        #if DEBUG
        names.append("dismissPickerForTesting")
        #endif
        return names.map { CAPPluginMethod(name: $0, returnType: CAPPluginReturnPromise) }
    }

    public override func load() {
        super.load()
        NodeRunner.shared.setEventHandlers(log: { [weak self] id, operation, line in
            self?.notifyListeners("log", data: ["instanceId": id, "operationId": operation, "line": line])
        }, status: { [weak self] state in
            var value = state
            value["tavernRunning"] = state["serverReady"]
            self?.notifyListeners("mode", data: value)
        })
    }
    private func perform(_ call: CAPPluginCall, _ body: @escaping () throws -> [String: Any]) {
        io.async {
            do { call.resolve(try body()) }
            catch { call.reject(error.localizedDescription) }
        }
    }
    private func id(_ call: CAPPluginCall) throws -> String { try IOSInstanceStore.identity(call.getString("instanceId")) }
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.10.0" }
    @objc func getPlatform(_ call: CAPPluginCall) {
        call.resolve(["platform": "ios", "externalTakeoverSupported": false, "arbitraryRuntimeVersionsSupported": false])
    }
    @objc func getAppVersion(_ call: CAPPluginCall) { call.resolve(["version": version]) }
    @objc func getStatus(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let local = NodeRunner.shared.status
            if local["instanceId"] != nil { call.resolve(local) }
            else if let session = self.viewSession, session.2 {
                call.resolve(["serverReady": false, "mode": "remote", "url": session.1.absoluteString,
                    "instanceId": session.0, "tavernRunning": true])
            } else { call.resolve(local) }
        }
    }
    @objc func getSafeInsets(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let window = UIApplication.shared.windows.first { $0.isKeyWindow }
            let insets = window?.safeAreaInsets ?? .zero
            let scale = window?.screen.scale ?? UIScreen.main.scale
            call.resolve(["top": insets.top * scale, "bottom": insets.bottom * scale,
                "left": insets.left * scale, "right": insets.right * scale])
        }
    }
    @objc func scanInstances(_ call: CAPPluginCall) { perform(call) { ["instances": try self.store.records()] } }
    @objc func getInstanceInfo(_ call: CAPPluginCall) { perform(call) { try self.store.info(self.id(call)) } }

    private func reserveLocal(instance: String, operation: String) throws {
        guard viewSession?.2 != true, pendingViewSession?.2 != true else {
            throw IOSFileError.invalid("Close the current remote Tavern before preparing a local instance")
        }
        try NodeRunner.shared.reserve(instance: instance, operation: operation)
        viewGeneration += 1
        pendingViewSession = nil
        viewSession = nil
    }
    @objc func provisionAndStart(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            do {
                let instance = try self.id(call)
                let operation = try IOSInstanceStore.identity(call.getString("operationId") ?? UUID().uuidString)
                let port = call.getInt("port") ?? 8000
                try self.reserveLocal(instance: instance, operation: operation)
                self.io.async {
                    do {
                        self.notifyListeners("progress", data: ["instanceId": instance, "operationId": operation,
                            "percent": 10, "stage": "Preparing the pinned iOS runtime"])
                        let directory = try self.store.prepare(instance: instance, operation: operation,
                            version: call.getString("version"), localZip: call.getString("localZipPath"),
                            installPath: call.getString("installPath"), port: port, config: call.getObject("config"),
                            preinstall: call.getObject("preinstall"), companion: call.getObject("companionPreset"))
                        NodeRunner.shared.startPrepared(instance: instance, operation: operation, server: directory,
                            data: directory.appendingPathComponent("data"), config: directory.appendingPathComponent("config.yaml"),
                            port: port, ipv4: try self.store.ipv4(directory)) { result in
                                DispatchQueue.main.async {
                                    switch result {
                                    case .success(let status):
                                        let current = NodeRunner.shared.status
                                        guard current["serverReady"] as? Bool == true,
                                              current["instanceId"] as? String == instance,
                                              current["operationId"] as? String == operation else {
                                            call.reject("The ready response belongs to an obsolete local session")
                                            return
                                        }
                                        if (call.getObject("config")?["keepAlive"] as? Bool) == true { KeepAliveService.shared.start() }
                                        else { KeepAliveService.shared.stop() }
                                        self.notifyListeners("ready", data: ["ready": true, "instanceId": instance,
                                            "operationId": operation, "port": port, "url": status["url"] ?? ""])
                                        call.resolve(["ready": true, "instanceId": instance, "operationId": operation])
                                    case .failure(let error): call.reject(error.localizedDescription)
                                    }
                                }
                            }
                    } catch {
                        NodeRunner.shared.failProvision(instance: instance, operation: operation, error: error)
                        call.reject(error.localizedDescription)
                    }
                }
            } catch { call.reject(error.localizedDescription) }
        }
    }

    private func show(instance: String, url: URL, remote: Bool, hint: Bool = true,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard pendingViewSession == nil else { throw IOSFileError.invalid("A Tavern view is already opening") }
            if remote {
                guard NodeRunner.shared.status["instanceId"] == nil else {
                    throw IOSFileError.invalid("Stop the current local operation before opening a remote Tavern")
                }
            }
            viewGeneration += 1
            let generation = viewGeneration
            if UserDefaults.standard.string(forKey: "contentOpenMode") == "browser" {
                pendingViewSession = (instance, url, remote)
                UIApplication.shared.open(url, options: [:]) { opened in
                    guard self.viewGeneration == generation else {
                        completion(.failure(IOSFileError.invalid("The browser response belongs to an obsolete Tavern session")))
                        return
                    }
                    self.pendingViewSession = nil
                    guard opened else {
                        completion(.failure(IOSFileError.invalid("System browser could not open this Tavern")))
                        return
                    }
                    if !remote {
                        let current = NodeRunner.shared.status
                        guard current["serverReady"] as? Bool == true, current["instanceId"] as? String == instance,
                              let currentURL = URL(string: current["url"] as? String ?? ""),
                              IOSNavigationPolicy.sameOrigin(currentURL, url) else {
                            completion(.failure(IOSFileError.invalid("The local Tavern stopped while its browser was opening")))
                            return
                        }
                    }
                    self.viewSession = (instance, url, remote)
                    completion(.success(()))
                }
                return
            }
            let auth = remote ? try IOSRemoteCredentials.read(instance, for: url) : nil
            guard TavernViewController.shared.enterImmersive(url: url, showGestureHint: hint,
                username: auth?.0, password: auth?.1) else { throw IOSFileError.invalid("Tavern WebView is not available") }
            viewSession = (instance, url, remote)
            completion(.success(()))
        } catch { completion(.failure(error)) }
    }
    private func completeView(_ call: CAPPluginCall, _ result: Result<Void, Error>) {
        switch result {
        case .success: call.resolve(["success": true])
        case .failure(let error): call.reject(error.localizedDescription)
        }
    }
    @objc func enterImmersive(_ call: CAPPluginCall) {
        guard call.getString("instanceId") != nil else { openExternalUrl(call); return }
        DispatchQueue.main.async {
            do {
                let instance = try self.id(call)
                let url = try IOSNavigationPolicy.validatedURL(call.getString("url") ?? "")
                let local = (try? self.store.directory(instance)) != nil
                if local {
                    let status = NodeRunner.shared.status
                    guard status["serverReady"] as? Bool == true, status["instanceId"] as? String == instance,
                          let current = URL(string: status["url"] as? String ?? ""),
                          IOSNavigationPolicy.sameOrigin(current, url) else {
                        throw IOSFileError.invalid("The requested local Tavern session is not ready")
                    }
                }
                self.show(instance: instance, url: url, remote: !local, hint: call.getBool("showGestureHint") ?? true) {
                    self.completeView(call, $0)
                }
            } catch { call.reject(error.localizedDescription) }
        }
    }
    @objc func openExternalUrl(_ call: CAPPluginCall) {
        do {
            let url = try IOSNavigationPolicy.validatedURL(call.getString("url") ?? "")
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { opened in
                    if opened { call.resolve(["success": true]) } else { call.reject("System browser could not open this URL") }
                }
            }
        } catch { call.reject(error.localizedDescription) }
    }
    @objc func exitImmersive(_ call: CAPPluginCall) {
        DispatchQueue.main.async { TavernViewController.shared.exitImmersive(); call.resolve(["success": true]) }
    }
    @objc func returnToTavern(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            do {
                let status = NodeRunner.shared.status
                if status["serverReady"] as? Bool == true, let instance = status["instanceId"] as? String,
                   let url = URL(string: status["url"] as? String ?? "") {
                    self.show(instance: instance, url: url, remote: false) { self.completeView(call, $0) }
                } else if let session = self.viewSession, session.2 {
                    self.show(instance: session.0, url: session.1, remote: true) { self.completeView(call, $0) }
                } else {
                    throw IOSFileError.invalid("No ready Tavern session exists")
                }
            } catch { call.reject(error.localizedDescription) }
        }
    }
    @objc func closeTavern(_ call: CAPPluginCall) { stop(call) }
    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if NodeRunner.shared.status["instanceId"] == nil,
               let remote = self.pendingViewSession ?? self.viewSession, remote.2 {
                if call.getString("operationId") != nil
                    || (call.getString("instanceId") != nil && call.getString("instanceId") != remote.0) {
                    call.reject("The requested remote session is no longer current"); return
                }
                self.viewGeneration += 1
                self.pendingViewSession = nil
                self.viewSession = nil
                TavernViewController.shared.clearTavernSession()
                call.resolve(["success": true])
                return
            }
            let generation = self.viewGeneration
            NodeRunner.shared.stop(instance: call.getString("instanceId"), operation: call.getString("operationId")) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        if self.viewGeneration == generation {
                            self.viewGeneration += 1
                            self.pendingViewSession = nil
                            self.viewSession = nil
                            TavernViewController.shared.clearTavernSession()
                        }
                        if NodeRunner.shared.status["serverReady"] as? Bool != true { KeepAliveService.shared.stop() }
                        call.resolve(["success": true])
                    case .failure(let error): call.reject(error.localizedDescription)
                    }
                }
            }
        }
    }
    @objc func getLogs(_ call: CAPPluginCall) {
        call.resolve(["logs": NodeRunner.shared.getLogs(limit: call.getInt("limit") ?? 200, instance: call.getString("instanceId"))])
    }
    @objc func sendCommand(_ call: CAPPluginCall) {
        let command = (call.getString("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message: String
        switch command {
        case "status": message = "iOS NodeMobile: \(NodeRunner.shared.status["state"] ?? "unknown"), port \(NodeRunner.shared.status["port"] ?? 0)"
        case "gc": NodeRunner.shared.triggerGarbageCollection(); message = "Host and worker garbage collection requested"
        case "help": message = "Supported iOS commands: status, gc, help"
        default: call.reject("Arbitrary shell commands are unsupported on iOS"); return
        }
        NodeRunner.shared.appendLog(message)
        call.resolve(["success": true])
    }
    @objc func reloadTavern(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if TavernViewController.shared.reloadTavern() { call.resolve(["success": true]) }
            else { call.reject("No Tavern page is loaded") }
        }
    }
    @objc func setPullToRefresh(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if TavernViewController.shared.setPullToRefresh(call.getBool("enabled") ?? false) { call.resolve(["success": true]) }
            else { call.reject("Tavern WebView is unavailable") }
        }
    }
    @objc func clearWebViewData(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.viewGeneration += 1
            let generation = self.viewGeneration
            self.pendingViewSession = nil
            self.viewSession = nil
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                if self.viewGeneration == generation { TavernViewController.shared.clearTavernSession() }
                call.resolve(["success": true])
            }
        }
    }
    @objc func getContentOpenMode(_ call: CAPPluginCall) {
        call.resolve(["mode": UserDefaults.standard.string(forKey: "contentOpenMode") ?? "webview"])
    }
    @objc func setContentOpenMode(_ call: CAPPluginCall) {
        guard let mode = call.getString("mode"), ["webview", "browser"].contains(mode) else { call.reject("Invalid content open mode"); return }
        UserDefaults.standard.set(mode, forKey: "contentOpenMode")
        call.resolve(["mode": mode])
    }
    @objc func setRemoteBasicAuth(_ call: CAPPluginCall) {
        perform(call) {
            let instance = try self.id(call)
            try IOSRemoteCredentials.save(instance, username: call.getString("username") ?? "", password: call.getString("password"))
            return ["configured": true, "username": call.getString("username") ?? ""]
        }
    }
    @objc func getRemoteBasicAuthStatus(_ call: CAPPluginCall) {
        perform(call) { try IOSRemoteCredentials.status(self.id(call)) }
    }
    @objc func clearRemoteBasicAuth(_ call: CAPPluginCall) {
        perform(call) { try IOSRemoteCredentials.clear(self.id(call)); return ["success": true] }
    }
    @objc func pingUrl(_ call: CAPPluginCall) {
        do {
            let url = try IOSNavigationPolicy.validatedURL(call.getString("url") ?? "")
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            let suppliedUsername = call.getString("username")
            let suppliedPassword = call.getString("password")
            guard (suppliedUsername == nil) == (suppliedPassword == nil) else {
                throw IOSFileError.invalid("Supply both username and password when verifying new credentials")
            }
            let stored = suppliedUsername == nil
                ? try call.getString("instanceId").flatMap { try IOSRemoteCredentials.read($0, for: url) } : nil
            let username = suppliedUsername ?? stored?.0
            let password = suppliedPassword ?? stored?.1
            if let username = username, let password = password {
                request.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            }
            IOSBoundedHTTP.send(request, maximumBytes: 65536) { result in
                let code: Int
                switch result {
                case .success(let response): code = response.0.statusCode
                case .failure:
                    call.resolve(["online": false, "statusCode": 0, "authRequired": false, "error": "Connection failed"])
                    return
                }
                if (200..<300).contains(code),
                   let username = suppliedUsername, let password = suppliedPassword {
                    do { try IOSRemoteCredentials.recordVerifiedPreflight(url: url, username: username, password: password) }
                    catch { call.reject(error.localizedDescription); return }
                }
                call.resolve(["online": (200..<300).contains(code), "statusCode": code,
                    "authRequired": code == 401, "error": ""])
            }
        } catch { call.reject(error.localizedDescription) }
    }
    private func releases(_ path: String, completion: @escaping (Result<Any, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(path)")!)
        request.timeoutInterval = 15
        request.setValue("SillyClient-iOS/\(version)", forHTTPHeaderField: "User-Agent")
        IOSBoundedHTTP.send(request, maximumBytes: 2 * 1024 * 1024) { result in
            do {
                let (response, bytes) = try result.get()
                guard response.statusCode == 200 else {
                    throw IOSFileError.invalid("Release metadata could not be retrieved")
                }
                completion(.success(try JSONSerialization.jsonObject(with: bytes)))
            } catch { completion(.failure(error)) }
        }
    }
    @objc func fetchReleases(_ call: CAPPluginCall) {
        releases("SillyTavern/SillyTavern/releases?per_page=15") { result in
            switch result {
            case .success(let value):
                guard let list = value as? [[String: Any]] else { call.reject("Release metadata is invalid"); return }
                call.resolve(["releases": list.map { ["tag": $0["tag_name"] ?? "", "zipballUrl": $0["zipball_url"] ?? "",
                    "prerelease": $0["prerelease"] ?? false] }])
            case .failure(let error): call.reject(error.localizedDescription)
            }
        }
    }
    @objc func checkUpdate(_ call: CAPPluginCall) {
        releases("CAPTCHAAAAA/SillyClient/releases/latest") { result in
            switch result {
            case .success(let value):
                guard let metadata = value as? [String: Any], let raw = metadata["tag_name"] as? String else {
                    call.reject("Application release metadata is invalid"); return
                }
                let latest = raw.replacingOccurrences(of: "^v+", with: "", options: .regularExpression)
                call.resolve(["currentVersion": self.version, "latestVersion": latest,
                    "updateAvailable": self.version.compare(latest, options: .numeric) == .orderedAscending,
                    "releaseUrl": metadata["html_url"] ?? "", "publishedAt": metadata["published_at"] ?? ""])
            case .failure(let error): call.reject(error.localizedDescription)
            }
        }
    }
    @objc func migrateInstance(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            do {
                let instance = try self.id(call)
                let operation = try IOSInstanceStore.identity(call.getString("operationId") ?? UUID().uuidString)
                guard let source = call.getString("sourcePath") else { throw IOSFileError.invalid("Migration source is required") }
                try self.reserveLocal(instance: instance, operation: operation)
                let scoped = self.scopedDirectories.removeValue(forKey: source)
                self.io.async {
                    defer { scoped?.stopAccessingSecurityScopedResource() }
                    do {
                        let target = try self.store.migrate(instance: instance, operation: operation, sourcePath: source,
                            targetPath: call.getString("targetPath"), mode: call.getString("mode") ?? "copy",
                            includeSecrets: call.getBool("includeSecrets") ?? false, preinstall: call.getObject("preinstall"),
                            scopedSource: scoped)
                        NodeRunner.shared.stop(instance: instance, operation: operation) { _ in
                            call.resolve(["success": true, "instanceId": instance, "targetPath": target.path])
                        }
                    } catch {
                        NodeRunner.shared.failProvision(instance: instance, operation: operation, error: error)
                        call.reject(error.localizedDescription)
                    }
                }
            } catch { call.reject(error.localizedDescription) }
        }
    }
    @objc func uninstallInstance(_ call: CAPPluginCall) { perform(call) { try self.store.uninstall(self.id(call)) } }
    @objc func scanInstanceMaintenance(_ call: CAPPluginCall) { perform(call) { try IOSInstanceMaintenance.shared.scan(self.id(call)) } }
    @objc func applyInstanceMaintenance(_ call: CAPPluginCall) {
        perform(call) {
            guard let scan = call.getString("scanId"), let items = call.getArray("items") as? [[String: Any]] else {
                throw IOSFileError.invalid("A maintenance plan and exact selections are required")
            }
            return try IOSInstanceMaintenance.shared.apply(instance: self.id(call), scanId: scan, selections: items)
        }
    }
    @objc func listInstanceMaintenanceRecovery(_ call: CAPPluginCall) { perform(call) { try IOSInstanceMaintenance.shared.list(self.id(call)) } }
    @objc func restoreInstanceMaintenance(_ call: CAPPluginCall) {
        perform(call) {
            guard let recovery = call.getString("recoveryId"), let token = call.getString("token") else {
                throw IOSFileError.invalid("A recovery identity and token are required")
            }
            return try IOSInstanceMaintenance.shared.restore(instance: self.id(call), recovery: recovery, token: token)
        }
    }
    @objc func cleanGarbage(_ call: CAPPluginCall) {
        guard call.getBool("dryRun") == true else { call.reject("Use stopped-instance maintenance for supported cleanup"); return }
        call.resolve(["items": [], "totalBytes": 0, "warnings": ["Global garbage deletion is unsupported on iOS"]])
    }
    @objc func deleteGarbageItem(_ call: CAPPluginCall) { call.reject("Arbitrary path deletion is unsupported; use a maintenance token") }
    @objc func setSecret(_ call: CAPPluginCall) { call.reject("Generic secret access is unsupported; use secure remote authentication") }
    @objc func getSecret(_ call: CAPPluginCall) { call.reject("Generic secret access is unsupported; credentials are never returned to JavaScript") }
    @objc func deleteSecret(_ call: CAPPluginCall) { call.reject("Use clearRemoteBasicAuth for managed credentials") }
    @objc func openFilesApp(_ call: CAPPluginCall) {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = store.documents.path
        guard let url = components.url else { call.reject("Files URL could not be constructed"); return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened { call.resolve(["success": true]) } else { call.reject("Files app could not open the Documents directory") }
            }
        }
    }

    private func presentPicker(_ call: CAPPluginCall, action: String, types: [UTType], exporting: URL? = nil) {
        DispatchQueue.main.async {
            guard self.pendingPickerCall == nil, let presenter = self.bridge?.viewController,
                  presenter.presentedViewController == nil, presenter.view.window != nil else {
                call.reject("Another picker is active or the presenter is unavailable"); return
            }
            let picker = exporting.map { UIDocumentPickerViewController(forExporting: [$0], asCopy: true) }
                ?? UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: action != "dir")
            picker.delegate = self
            picker.allowsMultipleSelection = false
            self.pendingPickerCall = call
            self.pendingPickerAction = action
            self.pendingInstanceId = call.getString("instanceId") ?? "default"
            presenter.present(picker, animated: true)
        }
    }
    @objc func pickDirectory(_ call: CAPPluginCall) { presentPicker(call, action: "dir", types: [.folder]) }
    @objc func pickZipFile(_ call: CAPPluginCall) { presentPicker(call, action: "zip", types: [.zip]) }
    @objc func pickImage(_ call: CAPPluginCall) {
        do { _ = try id(call); presentPicker(call, action: "image", types: [.image]) }
        catch { call.reject(error.localizedDescription) }
    }
    @objc func readTextFile(_ call: CAPPluginCall) {
        if let path = call.getString("path") {
            perform(call) {
                let url = try self.store.files.checked(URL(fileURLWithPath: path))
                guard let content = String(data: try self.store.files.data(url, maximum: 2 * 1024 * 1024), encoding: .utf8) else {
                    throw IOSFileError.invalid("Text file is not valid UTF-8")
                }
                return ["content": content, "fileName": url.lastPathComponent]
            }
        } else { presentPicker(call, action: "readText", types: [.json, .plainText, .text]) }
    }
    @objc func saveTextFile(_ call: CAPPluginCall) {
        io.async {
            do {
            guard let content = call.getString("content"), content.utf8.count <= 2 * 1024 * 1024,
                  let name = call.getString("fileName"), name.count <= 160, name != "." && name != "..",
                  name.range(of: "^[A-Za-z0-9_. -]+$", options: .regularExpression) != nil else {
                throw IOSFileError.invalid("Invalid or oversized text export")
            }
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let files = IOSManagedFiles(root: root)
            let directory = root.appendingPathComponent("sillyclient-export-\(UUID().uuidString)")
            try files.createDirectory(directory)
            let target = directory.appendingPathComponent(name)
            try files.write(Data(content.utf8), to: target, replace: false)
            self.presentPicker(call, action: "save", types: [], exporting: target)
            } catch { call.reject(error.localizedDescription) }
        }
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = pendingPickerCall, let selected = urls.first else { pendingPickerCall?.reject("No file was selected"); pendingPickerCall = nil; return }
        let action = pendingPickerAction
        let instance = pendingInstanceId
        pendingPickerCall = nil
        if action == "save" { call.resolve(["success": true]); return }
        let scoped = selected.startAccessingSecurityScopedResource()
        let source = selected.resolvingSymlinksInPath()
        if action == "dir" {
            guard scopedDirectories.count < 8 else { if scoped { selected.stopAccessingSecurityScopedResource() }; call.reject("Too many pending directory imports"); return }
            if scoped {
                scopedDirectories.removeValue(forKey: source.path)?.stopAccessingSecurityScopedResource()
                scopedDirectories[source.path] = selected
            }
            call.resolve(["name": source.lastPathComponent, "path": source.path])
            return
        }
        io.async {
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
            do {
                let sourceFiles = IOSManagedFiles(root: source.deletingLastPathComponent())
                if action == "readText" {
                    guard let content = String(data: try sourceFiles.data(source, maximum: 2 * 1024 * 1024), encoding: .utf8) else {
                        throw IOSFileError.invalid("Text file is not valid UTF-8")
                    }
                    call.resolve(["content": content, "fileName": source.lastPathComponent])
                    return
                }
                let maximum = action == "image" ? 16 * 1024 * 1024 : 256 * 1024 * 1024
                let sourceGuard = try sourceFiles.guardValue(source)
                guard !sourceGuard.isDirectory, sourceGuard.size >= 0, sourceGuard.size <= maximum else {
                    throw IOSFileError.invalid("Selected file exceeds its size limit")
                }
                let root = action == "image" ? self.store.documents
                    : FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                let files = IOSManagedFiles(root: root)
                let destination = action == "image" ? root.appendingPathComponent("covers/\(try IOSInstanceStore.identity(instance))-\(UUID().uuidString).\(source.pathExtension)")
                    : root.appendingPathComponent("sillyclient-import-\(UUID().uuidString).zip")
                try files.createDirectory(destination.deletingLastPathComponent())
                try sourceFiles.copyTree(source, to: destination, destination: files,
                                         budget: IOSInspectionBudget(maxEntries: 1, maxBytes: Int64(maximum)))
                call.resolve(["path": destination.path, "url": destination.absoluteString, "sizeBytes": sourceGuard.size])
            } catch { call.reject(error.localizedDescription) }
        }
    }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPickerCall?.reject("Selection cancelled")
        pendingPickerCall = nil
    }
    #if DEBUG
    @objc func dismissPickerForTesting(_ call: CAPPluginCall) {
        guard ProcessInfo.processInfo.arguments.contains("--sillyclient-test") else { call.reject("Test harness is not enabled"); return }
        DispatchQueue.main.async {
            self.pendingPickerCall?.reject("Test cancelled the picker")
            self.pendingPickerCall = nil
            self.bridge?.viewController?.dismiss(animated: false)
            call.resolve(["dismissed": true])
        }
    }
    #endif
}
