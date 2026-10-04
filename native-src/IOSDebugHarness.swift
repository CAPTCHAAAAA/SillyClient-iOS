#if DEBUG
import Foundation
import WebKit

private typealias ProbeNodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

public final class IOSDebugHarness {
    private let directory: URL
    private var timer: Timer?
    private var lastRequest = ""
    private let methods: Set<String> = [
        "getPlatform", "getAppVersion", "getStatus", "getSafeInsets", "scanInstances",
        "getInstanceInfo", "provisionAndStart", "stop", "returnToTavern", "enterImmersive",
        "exitImmersive", "closeTavern", "reloadTavern", "setPullToRefresh", "openExternalUrl",
        "scanInstanceMaintenance", "applyInstanceMaintenance", "listInstanceMaintenanceRecovery",
        "restoreInstanceMaintenance", "migrateInstance", "uninstallInstance", "getLogs",
        "checkLegacyInstances", "migrateLegacyInstances", "renameInstance", "relocateInstance"
    ]

    static let bridgeInvocationScript = """
        const diagnostic = value => {
            const tooLarge = method + ': Native method failed; diagnostic exceeded safe limit';
            if (typeof value === 'string' && value.length > 4096) return tooLarge;
            let text = typeof value === 'string' ? value : 'Native method rejected without a diagnostic';
            const pending = [options];
            let remaining = 128;
            while (pending.length && remaining-- > 0) {
                const current = pending.pop();
                if (!current || typeof current !== 'object') continue;
                for (const [key, secret] of Object.entries(current)) {
                    if (typeof secret === 'string' && secret && /password|passwd|secret|token|api[_-]?key|authorization|credential/i.test(key)) {
                        if (secret.length > 2048) {
                            const start = text.indexOf(secret.slice(0, 64));
                            if (start >= 0) text = text.slice(0, start) + '[redacted]';
                        } else {
                            text = text.split(secret).join('[redacted]');
                            if (text.length > 4096) return tooLarge;
                        }
                    } else if (secret && typeof secret === 'object') {
                        pending.push(secret);
                    }
                }
            }
            if (pending.length) return 'Native method failed; sensitive-option scan limit reached';
            return text
                .replace(/(https?:\\/\\/)[^\\s/?#]*@/gi, '$1[redacted]@')
                .replace(/\\b(Basic|Bearer)\\s+[^\\s"'<>;,]+/gi, '$1 [redacted]')
                .replace(/([?&](?:password|passwd|secret|token|access[_-]?token|refresh[_-]?token|api[_-]?key|auth|authorization|credential)=)[^&#\\s]*/gi, '$1[redacted]')
                .replace(/(["']?(?:password|passwd|secret|token|api[_-]?key|authorization|credential)["']?\\s*[:=]\\s*)(?:"[^"]*"|'[^']*'|[^\\s,;]+)/gi, '$1[redacted]')
                .slice(0, 2048);
        };
        try {
            const plugin = window.Capacitor?.Plugins?.TarvenEnv;
            if (!plugin || typeof plugin[method] !== 'function') throw new Error('Native bridge method is unavailable');
            return { success: true, result: (await plugin[method](options)) ?? null };
        } catch (error) {
            const code = typeof error?.code === 'number' && Number.isFinite(error.code) ? String(error.code)
                : typeof error?.code === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(error.code) ? error.code : '';
            const message = typeof error?.message === 'string' ? error.message
                : typeof error === 'string' ? error : 'Native method rejected without a diagnostic';
            return { success: false, error: diagnostic(method + (code ? ' [' + code + ']' : '') + ': ' + message) };
        }
        """

    static func webKitFailureDescription(_ error: Error) -> String {
        let native = error as NSError
        let domain = String(native.domain.prefix(80))
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "WebKit bridge evaluation failed (\(domain):\(native.code))"
    }

    public init() {
        directory = Self.testDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    deinit { timer?.invalidate() }

    private static func testDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ios-test", isDirectory: true)
    }

    private func respond(_ id: String, _ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        try? data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
    }

    private func poll() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
              data.count <= 65536,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,80}\\z", options: .regularExpression) != nil,
              id != lastRequest else { return }
        lastRequest = id
        if request["action"] as? String == "nativeTests" {
            let result = IOSNativeTests.run { [weak self] progress in
                guard let self = self else { return }
                var report = progress
                report["requestId"] = id
                guard let data = try? JSONSerialization.data(withJSONObject: report) else { return }
                try? data.write(to: self.directory.appendingPathComponent("native-module-progress.json"), options: .atomic)
            }
            respond(id, ["success": true, "result": result])
            return
        }
        if request["action"] as? String == "installationRoot" {
            do {
                guard let options = request["options"] as? [String: Any], let path = options["path"] as? String else {
                    throw IOSFileError.invalid("A synthetic sandbox installation root is required")
                }
                let store = IOSInstanceStore.shared
                let selected = try store.files.checked(IOSInstallationLocations.path(path))
                guard selected.path != store.documents.path else { throw IOSFileError.invalid("Select a test subdirectory") }
                let root = try store.locations.select(selected)
                respond(id, ["success": true, "result": ["path": root.path, "installPathMode": "root", "persistentAuthorization": true]])
            } catch { respond(id, ["success": false, "error": error.localizedDescription]) }
            return
        }
        guard let webView = TavernViewController.shared.consoleWebView else {
            respond(id, ["success": false, "error": "Console WebView is unavailable"])
            return
        }
        if request["action"] as? String == "console" {
            webView.evaluateJavaScript("({loggingEnabled: window.Capacitor?.isLoggingEnabled})") { [weak self] result, error in
                if let error = error {
                    self?.respond(id, ["success": false, "error": Self.webKitFailureDescription(error)])
                } else {
                    self?.respond(id, ["success": true, "result": result ?? NSNull()])
                }
            }
            return
        }
        if request["action"] as? String == "evalConsole" {
            let rawScript = (request["script"] as? String) ?? ((request["options"] as? [String: Any])?["script"] as? String)
            guard let script = rawScript else {
                respond(id, ["success": false, "error": "Missing script parameter"])
                return
            }
            let wrappedScript = """
            (function() {
                try {
                    return (function() {
                        \(script)
                    })();
                } catch (e) {
                    return "eval_error: " + String(e);
                }
            })()
            """
            webView.evaluateJavaScript(wrappedScript) { [weak self] result, error in
                if let error = error {
                    self?.respond(id, ["success": false, "error": Self.webKitFailureDescription(error)])
                } else {
                    self?.respond(id, ["success": true, "result": result ?? NSNull()])
                }
            }
            return
        }
        if request["action"] as? String == "tavern" {
            guard let tavern = TavernViewController.shared.tavernWebView else {
                respond(id, ["success": false, "error": "Tavern WebView is unavailable"])
                return
            }
            tavern.evaluateJavaScript("""
                (function() {
                    try {
                        return JSON.stringify({
                            url: location.href || '',
                            ready: document.readyState || '',
                            hasChat: Boolean(document.querySelector('#chat')),
                            hasInput: Boolean(document.querySelector('#send_textarea')),
                            title: document.title || '',
                            hasClient: typeof window.SillyTavern?.getContext === 'function' && typeof window.jQuery === 'function'
                        });
                    } catch (e) {
                        return JSON.stringify({ ready: 'loading', error: String(e) });
                    }
                })()
                """) { [weak self] result, error in
                if let str = result as? String,
                   let data = str.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.respond(id, ["success": true, "result": obj, "error": ""])
                } else if error == nil, let dict = result as? [String: Any] {
                    self?.respond(id, ["success": true, "result": dict, "error": ""])
                } else {
                    self?.respond(id, ["success": false, "result": NSNull(),
                                      "error": error?.localizedDescription ?? "Evaluation failed"])
                }
            }
            return
        }
        guard let method = request["method"] as? String, methods.contains(method) else {
            respond(id, ["success": false, "error": "Unsupported test method"])
            return
        }
        webView.callAsyncJavaScript(Self.bridgeInvocationScript, arguments: ["method": method, "options": request["options"] as? [String: Any] ?? [:]],
            in: nil, in: .page) { [weak self] result in
                switch result {
                case .success(let value):
                    guard let response = value as? [String: Any], response["success"] as? Bool != nil else {
                        self?.respond(id, ["success": false, "error": "Native bridge returned an invalid test response"])
                        return
                    }
                    self?.respond(id, response)
                case .failure(let error):
                    self?.respond(id, ["success": false, "error": Self.webKitFailureDescription(error)])
                }
            }
    }

    public static func runRuntimeProbe() {
        let directory = testDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = directory.appendingPathComponent("runtime-probe.json")
        guard let script = Bundle.main.path(forResource: "ios-runtime-probe", ofType: "mjs")
                ?? Bundle(for: IOSDebugHarness.self).path(forResource: "ios-runtime-probe", ofType: "mjs") else {
            try? "{\"success\":false,\"error\":\"Runtime probe resource is missing\"}".write(to: report, atomically: true, encoding: .utf8)
            return
        }
        let thread = Thread {
            signal(SIGPIPE, SIG_IGN)
            setenv("SILLYCLIENT_PROBE_REPORT", report.path, 1)
            var symbol = dlsym(dlopen(nil, RTLD_NOW), "node_start")
            if symbol == nil, let handle = dlopen((Bundle.main.privateFrameworksPath ?? "") + "/NodeMobile.framework/NodeMobile", RTLD_NOW) {
                symbol = dlsym(handle, "node_start")
            }
            guard let symbol = symbol else {
                try? "{\"success\":false,\"error\":\"node_start symbol is missing\"}".write(to: report, atomically: true, encoding: .utf8)
                return
            }
            let start = unsafeBitCast(symbol, to: ProbeNodeStart.self)
            let arguments = ["node", script]
            var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            pointers.append(nil)
            let code = pointers.withUnsafeMutableBufferPointer { start(Int32(arguments.count), $0.baseAddress) }
            pointers.forEach { if let pointer = $0 { free(pointer) } }
            NSLog("[IOSDebugHarness] Capability probe returned %d", code)
        }
        thread.stackSize = 4 * 1024 * 1024
        thread.name = "com.sillyclient.runtime-probe"
        thread.start()
    }
}
#endif
