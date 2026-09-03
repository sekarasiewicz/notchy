import AppKit
import Combine

/// Tightens or loosens the gaps between all status items.
///
/// AppKit reads two per-host global defaults when an app creates its status
/// items, so changing them only takes effect after every app with an icon is
/// relaunched. Same approach as Ice.
@MainActor
final class MenuBarSpacing: ObservableObject {
    static let shared = MenuBarSpacing()

    private enum Key: String, CaseIterable {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"
        static let systemDefault = 16
    }

    /// Points added to (or, when negative, removed from) the system default.
    @Published var offset: Int = 0
    @Published private(set) var appliedOffset: Int = 0
    @Published private(set) var isApplying = false
    @Published var lastError: String?

    var hasUnappliedChange: Bool { offset != appliedOffset }

    private init() {
        appliedOffset = Self.readOffset()
        offset = appliedOffset
    }

    private static func readOffset() -> Int {
        guard let value = run("defaults", ["-currentHost", "read", "-globalDomain", Key.spacing.rawValue]),
              let spacing = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 0 }
        return spacing - Key.systemDefault
    }

    @discardableResult
    private static func run(_ command: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Writes the defaults, then relaunches every app that owns a status item
    /// (Control Center restarts itself when quit).
    func apply(items: [MenuBarItem]) async {
        guard !isApplying else { return }
        isApplying = true
        lastError = nil
        defer { isApplying = false }

        for key in Key.allCases {
            if offset == 0 {
                Self.run("defaults", ["-currentHost", "delete", "-globalDomain", key.rawValue])
            } else {
                Self.run("defaults", ["-currentHost", "write", "-globalDomain", key.rawValue, "-int", String(Key.systemDefault + offset)])
            }
        }
        appliedOffset = offset

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = Set(items.compactMap(\.ownerPID)).subtracting([ownPID])
        var failed: [String] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != "com.apple.controlcenter"
            else { continue }
            if await !relaunch(app) { failed.append(app.localizedName ?? "pid \(pid)") }
        }
        if let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            _ = await quit(cc)
        }
        // Our own items were created with the old values too.
        MenuBarManager.shared.recreateStatusItems()

        if !failed.isEmpty {
            lastError = "Could not relaunch: " + failed.joined(separator: ", ") + ". Log out and back in to finish."
        }
    }

    private func quit(_ app: NSRunningApplication) async -> Bool {
        app.terminate()
        let deadline = ContinuousClock.now + .seconds(3)
        while !app.isTerminated, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !app.isTerminated { app.forceTerminate() }
        let hardDeadline = ContinuousClock.now + .seconds(2)
        while !app.isTerminated, ContinuousClock.now < hardDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app.isTerminated
    }

    private func relaunch(_ app: NSRunningApplication) async -> Bool {
        guard let url = app.bundleURL, let bundleID = app.bundleIdentifier else { return false }
        guard await quit(app) else { return false }
        // Some apps (Spotlight) respawn on their own.
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { !$0.isTerminated }) {
            return true
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
