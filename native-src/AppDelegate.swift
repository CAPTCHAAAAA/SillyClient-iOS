import UIKit
import WebKit
import Capacitor
import SillyClientCore

class SillyBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        if let bridge = bridge {
            _ = (bridge as AnyObject).perform(NSSelectorFromString("registerPluginType:"), with: TarvenEnvPlugin.self)
        }
    }

    override var prefersStatusBarHidden: Bool { TavernViewController.shared.prefersStatusBarHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { TavernViewController.shared.prefersHomeIndicatorAutoHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #if DEBUG
    private var testHarness: IOSDebugHarness?
    #endif

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        let rootVC = TavernViewController.shared
        let bridgeVC = SillyBridgeViewController()
        bridgeVC.loadViewIfNeeded()
        if let bridge = bridgeVC.bridge {
            _ = (bridge as AnyObject).perform(NSSelectorFromString("registerPluginType:"), with: TarvenEnvPlugin.self)
        }
        rootVC.addChild(bridgeVC)
        if let webView = bridgeVC.webView { rootVC.registerConsoleWebView(webView) }
        bridgeVC.didMove(toParent: rootVC)
        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sillyclient-runtime-probe") {
            IOSDebugHarness.runRuntimeProbe()
        } else if ProcessInfo.processInfo.arguments.contains("--sillyclient-test") {
            testHarness = IOSDebugHarness()
        }
        #endif
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        backgroundTask = application.beginBackgroundTask(withName: "com.sillyclient.backgroundTask") { [weak self] in
            guard let self = self, self.backgroundTask != .invalid else { return }
            application.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        TavernViewController.shared.ensureActiveConnection()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        KeepAliveService.shared.stop()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Test orchestration is not exposed through a public URL scheme.
        return false
    }
}
