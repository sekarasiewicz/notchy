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
    private var signalSource: DispatchSourceSignal?

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

    /// `kill`/`pkill` send SIGTERM, which skips `applicationShouldTerminate`.
    /// Route it through a normal terminate so status items get removed.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        signalSource = source
    }

    /// Two copies fighting over the same status items make a mess of the
    /// bar, so any other running copy is asked to quit. Its own teardown
    /// unfolds and removes its items before it exits.
    private func terminateOtherInstances() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        .filter { $0.processIdentifier != ownPID }
        .forEach { $0.terminate() }
    }
}
