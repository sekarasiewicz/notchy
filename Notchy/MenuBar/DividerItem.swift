import AppKit

/// The wall between hidden and visible items. Two status items:
///
/// - `spacer`, immediately left of the chevron. Folding stretches it to the
///   screen width, which pushes everything left of it past the screen edge.
///   The window server then stops drawing the spacer itself, which is why the
///   clickable part has to be a separate item.
/// - `chevron`, the visible `‹`/`›` button that stays put and toggles the fold.
///
/// There is no API to hide another app's status item; this is the trick every
/// menu bar manager relies on.
@MainActor
final class DividerItem {
    static let accessibilityDescription = "Notchy divider"

    private enum Lengths {
        /// AppKit enforces a ~16 pt minimum anyway; Ice removes the layout
        /// constraint behind that, but on macOS 26 the window then stops
        /// following `length`, so the small gap stays.
        static let expanded: CGFloat = 0
        static var collapsed: CGFloat { (NSScreen.main ?? NSScreen.screens[0]).frame.width }
    }

    private(set) var spacer: NSStatusItem
    let chevron: NSStatusItem
    private let spacerName: String
    private let chevronName: String

    private(set) var isCollapsed = false

    init(spacerName: String, chevronName: String, seedPosition: CGFloat) {
        self.spacerName = spacerName
        self.chevronName = chevronName
        // Preferred position is the distance from the right screen edge in
        // points. The spacer has to land just left of the chevron.
        if StatusItemDefaults.preferredPosition(chevronName) == nil {
            StatusItemDefaults.setPreferredPosition(seedPosition, chevronName)
        }
        if StatusItemDefaults.preferredPosition(spacerName) == nil {
            let chevronPosition = StatusItemDefaults.preferredPosition(chevronName) ?? seedPosition
            StatusItemDefaults.setPreferredPosition(chevronPosition + 30, spacerName)
        }

        spacer = Self.makeSpacer(named: spacerName)

        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = chevronName
        chevron.button?.imagePosition = .imageOnly
        chevron.button?.setAccessibilityLabel(Self.accessibilityDescription)
        updateChevron()
    }

    private static func makeSpacer(named name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Lengths.expanded)
        item.autosaveName = name
        item.button?.isEnabled = false
        item.button?.setAccessibilityLabel("Notchy spacer")
        return item
    }

    /// Put the spacer directly left of the chevron, wherever the user has
    /// dragged the chevron to. AppKit places a status item from its stored
    /// preferred position (distance from the right screen edge), so writing
    /// "just past the chevron" and recreating the spacer is enough. No
    /// synthesised events, and it works even when the spacer is off screen.
    func reseatSpacer() {
        guard let chevronPosition = StatusItemDefaults.preferredPosition(chevronName) else { return }
        let wasCollapsed = isCollapsed
        NSStatusBar.system.removeStatusItem(spacer)
        StatusItemDefaults.setPreferredPosition(chevronPosition + 1, spacerName)
        spacer = Self.makeSpacer(named: spacerName)
        if wasCollapsed { spacer.length = Lengths.collapsed }
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        spacer.length = collapsed ? Lengths.collapsed : Lengths.expanded
        updateChevron()
    }

    private func updateChevron() {
        let name = isCollapsed ? "chevron.right" : "chevron.left"
        chevron.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: Self.accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }

    func setTarget(_ target: AnyObject, action: Selector) {
        chevron.button?.target = target
        chevron.button?.action = action
    }

    /// Keep our slots when tearing down; AppKit deletes them otherwise.
    func remove() {
        for item in [spacer, chevron] {
            guard let name = item.autosaveName else { continue }
            let position = StatusItemDefaults.preferredPosition(name)
            NSStatusBar.system.removeStatusItem(item)
            StatusItemDefaults.setPreferredPosition(position, name)
        }
    }
}
