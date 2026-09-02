import SwiftUI

@main
struct NotchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
        Accessibility.requestTrust()
        MenuBarManager.shared.start()
        installSignalHandlers()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MenuBarManager.shared.tearDown()
        return .terminateNow
    }

    /// `kill`/`pkill` send SIGTERM, which skips `applicationWillTerminate`.
    /// Route it through a normal terminate so status items get removed.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        signalSource = source
    }

    private var signalSource: DispatchSourceSignal?

    /// Xcode does not kill the previous run of a windowless app, and two copies
    /// fighting over the same status items is confusing. Only a duplicate of
    /// *this exact bundle* is terminated, so a debug build does not quit the
    /// copy installed in /Applications.
    private func terminateOtherInstances() {
        let ownPath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let ownPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        .filter { $0.processIdentifier != ownPID && $0.bundleURL?.resolvingSymlinksInPath().path == ownPath }
        .forEach { $0.terminate() }
    }
}
