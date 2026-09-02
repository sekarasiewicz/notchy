import AppKit
import ScreenCaptureKit

/// Snapshots of status item windows via ScreenCaptureKit.
///
/// Only windows the window server is actually drawing can be captured, so the
/// manager keeps a cache keyed by item identity and fills it whenever an item
/// is on screen. Off-screen (folded) items are shown from that cache.
enum ItemImageCapture {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Captures every on-screen item in `items`, returning images keyed by
    /// `MenuBarItem.key`. Items that fail are simply absent.
    static func capture(_ items: [MenuBarItem]) async -> [String: NSImage] {
        guard hasPermission(), !items.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return [:]
        }
        let windows = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var out: [String: NSImage] = [:]
        for item in items where item.isOnScreen {
            guard let window = windows[item.windowID] else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
            out[item.key] = NSImage(cgImage: cgImage, size: window.frame.size)
        }
        return out
    }
}
