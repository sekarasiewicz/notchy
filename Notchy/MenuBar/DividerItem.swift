import AppKit

/// A status item that acts as a wall. Everything to its left is "behind" it.
/// Collapsing the wall means stretching it to an absurd width, which pushes all
/// items to its left past the screen edge. There is no API to hide another
/// app's status item; this is the trick every menu bar manager relies on.
@MainActor
final class DividerItem {
    enum Lengths {
        static let normal: CGFloat = NSStatusItem.variableLength
        static let collapsed: CGFloat = 10_000
    }

    let autosaveName: String
    let statusItem: NSStatusItem

    private(set) var isCollapsed = false

    init(autosaveName: String, seedPosition: CGFloat?) {
        self.autosaveName = autosaveName
        if let seedPosition, StatusItemDefaults.preferredPosition(autosaveName) == nil {
            StatusItemDefaults.setPreferredPosition(seedPosition, autosaveName)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: Lengths.normal)
        statusItem.autosaveName = autosaveName
        statusItem.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: Self.accessibilityDescription)
        statusItem.button?.imagePosition = .imageOnly
    }

    static let accessibilityDescription = "Notchy divider"

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        statusItem.length = collapsed ? Lengths.collapsed : Lengths.normal
        // A 10 000 pt wide button would flash its highlight; disable the cell
        // while collapsed so clicks do nothing visible.
        statusItem.button?.cell?.isEnabled = !collapsed
        statusItem.button?.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.left",
            accessibilityDescription: Self.accessibilityDescription
        )
    }

    func setTarget(_ target: AnyObject, action: Selector) {
        statusItem.button?.target = target
        statusItem.button?.action = action
    }

    /// Keep our slot when tearing down; AppKit deletes it otherwise.
    func remove() {
        let position = StatusItemDefaults.preferredPosition(autosaveName)
        NSStatusBar.system.removeStatusItem(statusItem)
        StatusItemDefaults.setPreferredPosition(position, autosaveName)
    }
}
