import AppKit

/// Reads the current set of menu bar items.
///
/// On macOS 26 every status item window belongs to Control Center, so the
/// window list only tells us *where* items are and whether they are drawn.
/// Accessibility tells us *whose* they are. The two are matched by horizontal
/// overlap, which also weeds out ghost windows Control Center keeps around
/// after an app quits.
nonisolated enum MenuBarScanner {
    /// Runs off the main thread; the AX walk takes tens of milliseconds even
    /// with the no-extras cache warm.
    static func scan() async -> [MenuBarItem] {
        await Task.detached(priority: .userInitiated) { scanSync() }.value
    }

    static func scanSync() -> [MenuBarItem] {
        let windows = statusItemWindows()
        var extras = Accessibility.allExtras()

        var items: [MenuBarItem] = []
        for window in windows {
            // The AX frame is the button inside the window, so centres agree
            // to within a pixel or two while edges do not. Anything looser
            // mislabels neighbours while items animate past each other.
            let matchIndex = extras.firstIndex { extra in
                abs(extra.frame.midX - window.bounds.midX) <= 3 && abs(extra.frame.midY - window.bounds.midY) <= 3
            }
            let extra = matchIndex.map { extras.remove(at: $0) }
            items.append(MenuBarItem(
                windowID: window.id,
                frame: window.bounds,
                isOnScreen: window.isOnScreen,
                ownerPID: extra?.ownerPID,
                bundleID: extra?.bundleID,
                appName: extra?.appName,
                indexInApp: extra?.index ?? 0,
                title: extra?.title,
                axDescription: extra?.description,
                axIdentifier: extra?.identifier,
                element: extra?.element
            ))
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    private struct StatusWindow {
        let id: CGWindowID
        let bounds: CGRect
        let isOnScreen: Bool
    }

    private static func statusItemWindows() -> [StatusWindow] {
        let menuBarIDs = Set(WindowServer.menuBarItemWindows())
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        guard let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  menuBarIDs.contains(id),
                  (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            // Live frame beats the snapshot while things are moving.
            let frame = WindowServer.frame(of: id) ?? bounds
            return StatusWindow(id: id, bounds: frame, isOnScreen: onScreen)
        }
    }
}
