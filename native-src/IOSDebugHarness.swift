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
        "restoreInstanceMaintenance", "uninstallInstance", "getLogs"
    ]

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
              let id = request["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
              id != lastRequest else { return }
        lastRequest = id
        if request["action"] as? String == "nativeTests" {
            respond(id, ["success": true, "result": IOSNativeTests.run()])
            return
        }
        guard let webView = TavernViewController.shared.consoleWebView else {
            respond(id, ["success": false, "error": "Console WebView is unavailable"])
            return
        }
        if request["action"] as? String == "tavern" {
            guard let tavern = TavernViewController.shared.tavernWebView else {
                respond(id, ["success": false, "error": "Tavern WebView is unavailable"])
                return
            }
            tavern.evaluateJavaScript("""
                ({url: location.href, ready: document.readyState, hasChat: !!document.querySelector('#chat'),
                  hasInput: !!document.querySelector('#send_textarea'), title: document.title,
                  hasClient: typeof window.SillyTavern?.getContext === 'function' && typeof window.jQuery === 'function'})
                """) { [weak self] result, error in
                self?.respond(id, ["success": error == nil, "result": result ?? NSNull(),
                                  "error": error?.localizedDescription ?? ""])
            }
            return
        }
        guard let method = request["method"] as? String, methods.contains(method) else {
            respond(id, ["success": false, "error": "Unsupported test method"])
            return
        }
        webView.callAsyncJavaScript("""
            const plugin = window.Capacitor?.Plugins?.TarvenEnv;
            if (!plugin || typeof plugin[method] !== 'function') throw new Error('Native bridge method is unavailable: ' + method);
            return await plugin[method](options);
            """, arguments: ["method": method, "options": request["options"] as? [String: Any] ?? [:]],
            in: nil, in: .page) { [weak self] result in
                switch result {
                case .success(let value): self?.respond(id, ["success": true, "result": value])
                case .failure(let error): self?.respond(id, ["success": false, "error": error.localizedDescription])
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
