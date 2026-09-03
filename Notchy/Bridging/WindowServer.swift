import Foundation
import CoreGraphics
import os

/// Thin, safe wrappers over the private window server calls.
nonisolated enum WindowServer {
    private static let log = Logger(subsystem: "dev.karasiewicz.Notchy", category: "WindowServer")

    private static var connection: CGSConnectionID { CGSMainConnectionID() }

    private static func windowCount() -> Int {
        var count: Int32 = 0
        let result = CGSGetWindowCount(connection, 0, &count)
        guard result == .success else {
            log.error("CGSGetWindowCount failed: \(result.rawValue)")
            return 0
        }
        return Int(count)
    }

    private static func onScreenWindowCount() -> Int {
        var count: Int32 = 0
        let result = CGSGetOnScreenWindowCount(connection, 0, &count)
        guard result == .success else {
            log.error("CGSGetOnScreenWindowCount failed: \(result.rawValue)")
            return 0
        }
        return Int(count)
    }

    /// Every window the window server treats as a menu bar item, regardless of
    /// whether it currently fits on screen. This is the whole point: items pushed
    /// off the edge or under the notch are still in this list.
    static func menuBarItemWindows() -> [CGWindowID] {
        var list = [CGWindowID](repeating: 0, count: windowCount())
        var realCount: Int32 = 0
        let result = CGSGetProcessMenuBarWindowList(connection, 0, Int32(list.count), &list, &realCount)
        guard result == .success else {
            log.error("CGSGetProcessMenuBarWindowList failed: \(result.rawValue)")
            return []
        }
        return Array(list[..<Int(realCount)])
    }

    static func onScreenWindows() -> Set<CGWindowID> {
        var list = [CGWindowID](repeating: 0, count: onScreenWindowCount())
        var realCount: Int32 = 0
        let result = CGSGetOnScreenWindowList(connection, 0, Int32(list.count), &list, &realCount)
        guard result == .success else {
            log.error("CGSGetOnScreenWindowList failed: \(result.rawValue)")
            return []
        }
        return Set(list[..<Int(realCount)])
    }

    /// Live frame in global CG coordinates (origin top-left of the main display).
    /// Fresher than the CGWindowList snapshot, which matters while items move.
    static func frame(of window: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        let result = CGSGetScreenRectForWindow(connection, window, &rect)
        guard result == .success else { return nil }
        return rect
    }
}
