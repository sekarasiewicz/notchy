import AppKit
import SwiftUI
import Combine

/// Owns Notchy's own status items and the periodically refreshed picture of
/// everyone else's.
@MainActor
final class MenuBarManager: ObservableObject {
    static let shared = MenuBarManager()

    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var isHiddenSectionCollapsed = false
    @Published private(set) var hiddenImages: [String: NSImage] = [:]
    @Published var autoCollapse = true {
        didSet { UserDefaults.standard.set(autoCollapse, forKey: "autoCollapse"); refresh() }
    }

    /// Set while an item from the hidden section is being shown for a click.
    private var revealTask: Task<Void, Never>?

    /// Autosave names double as defaults keys, keep them short and stable.
    private let mainItem: NSStatusItem
    private let divider: DividerItem
    private var refreshTimer: Timer?
    private var popover: NSPopover?

    private init() {
        autoCollapse = UserDefaults.standard.object(forKey: "autoCollapse") as? Bool ?? true
        // Seed slots so the divider starts just left of the Notchy icon.
        // Higher preferred position = further left.
        if StatusItemDefaults.preferredPosition("NotchyMain") == nil {
            StatusItemDefaults.setPreferredPosition(0, "NotchyMain")
        }
        mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainItem.autosaveName = "NotchyMain"
        mainItem.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Notchy"
        )

        divider = DividerItem(autosaveName: "NotchyDivider", seedPosition: 1)

        mainItem.button?.target = self
        mainItem.button?.action = #selector(togglePanel(_:))
        divider.setTarget(self, action: #selector(toggleHiddenSection(_:)))
    }

    func start() {
        refresh()
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["NOTCHY_MOVE_TEST"] {
            // Move the item whose key contains `key` right next to the divider.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.refresh()
                guard let item = self.items.first(where: { $0.key.contains(key) }), let divider = self.dividerItem else {
                    fputs("=== move test: item or divider not found\n", stderr); return
                }
                fputs("=== moving \(item.key) right of divider\n", stderr)
                do {
                    try await MenuBarItemMover.move(item, to: .rightOf(divider))
                    fputs("=== move OK\n", stderr)
                } catch {
                    fputs("=== move FAILED: \(error)\n", stderr)
                }
                self.refresh()
            }
        }
        if let key = ProcessInfo.processInfo.environment["NOTCHY_REVEAL_TEST"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.refresh()
                let snapshot = self.items.filter { $0.isOnScreen && !$0.isOwnedByNotchy }
                self.hiddenImages.merge(await ItemImageCapture.capture(snapshot)) { _, new in new }
                self.setHiddenSectionCollapsed(true)
                try? await Task.sleep(for: .seconds(2))
                guard let item = self.items.first(where: { $0.key.contains(key) }) else { fputs("=== reveal: not found\n", stderr); return }
                fputs("=== reveal \(item.key)\n", stderr)
                self.reveal(item)
            }
        }
        if ProcessInfo.processInfo.environment["NOTCHY_OPEN_PANEL"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self.togglePanel(nil)
            }
        }
        if ProcessInfo.processInfo.environment["NOTCHY_COLLAPSE_TEST"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                fputs("=== collapsing\n", stderr)
                self.setHiddenSectionCollapsed(true)
                try? await Task.sleep(for: .seconds(3))
                self.refresh()
                try? await Task.sleep(for: .seconds(1))
                fputs("=== expanding\n", stderr)
                self.setHiddenSectionCollapsed(false)
            }
        }
        #endif
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in MenuBarManager.shared.refresh() }
        }
    }

    /// Control Center keeps drawing a status item whose owner died without
    /// removing it. Take ours down explicitly so a relaunch does not leave
    /// ghosts in the bar.
    func tearDown() {
        refreshTimer?.invalidate()
        divider.remove()
        let position = StatusItemDefaults.preferredPosition("NotchyMain")
        NSStatusBar.system.removeStatusItem(mainItem)
        StatusItemDefaults.setPreferredPosition(position, "NotchyMain")
    }

    func refresh() {
        items = MenuBarScanner.scan()
        // Something no longer fits: fold the hidden section so the visible
        // ones get their room back. Expanding again is the user's call.
        if autoCollapse, !isHiddenSectionCollapsed, revealTask == nil, !lostItems.isEmpty, !hiddenSectionItems.isEmpty {
            // Snapshot first: once folded, these windows cannot be captured.
            let snapshot = items.filter { $0.isOnScreen && !$0.isOwnedByNotchy }
            Task { @MainActor in
                let fresh = await ItemImageCapture.capture(snapshot)
                hiddenImages.merge(fresh) { _, new in new }
                setHiddenSectionCollapsed(true)
            }
            return
        }
        refreshImages()
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCHY_DUMP"] != nil {
            let wall = dividerFrame.map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "?"
            fputs("--- scan, divider at \(wall)\n", stderr)
            for item in items {
                fputs("\(item.isOnScreen ? "  on " : "  OFF") \(String(item.windowID).padding(toLength: 6, withPad: " ", startingAt: 0)) \(item.key.padding(toLength: 44, withPad: " ", startingAt: 0)) \(Int(item.frame.minX))-\(Int(item.frame.maxX))\n", stderr)
            }
        }
        #endif
    }

    // MARK: Sections

    /// On macOS 26 `NSStatusBarButton.window` is nil (the window lives in
    /// Control Center), so our own items are located the same way as everyone
    /// else's: through the scan.
    var dividerItem: MenuBarItem? {
        items.first { $0.isOwnedByNotchy && $0.axDescription == DividerItem.accessibilityDescription }
    }

    var dividerFrame: CGRect? { dividerItem?.frame }

    /// Items to the left of the divider, i.e. the ones the divider can hide.
    var hiddenSectionItems: [MenuBarItem] {
        guard let wall = dividerFrame else { return [] }
        return items.filter { !$0.isOwnedByNotchy && $0.frame.maxX <= wall.minX }
    }

    var visibleSectionItems: [MenuBarItem] {
        guard let wall = dividerFrame else { return items }
        return items.filter { !$0.isOwnedByNotchy && $0.frame.minX >= wall.maxX }
    }

    /// Items the window server knows about but has no room to draw.
    var lostItems: [MenuBarItem] {
        items.filter { !$0.isOwnedByNotchy && !$0.isOnScreen }
    }

    private var captureTask: Task<Void, Never>?

    /// Refresh snapshots of whatever is currently drawn. Folded items keep
    /// their last snapshot.
    private func refreshImages() {
        guard captureTask == nil else { return }
        let visible = items.filter { $0.isOnScreen && !$0.isOwnedByNotchy }
        captureTask = Task { @MainActor in
            defer { captureTask = nil }
            let fresh = await ItemImageCapture.capture(visible)
            hiddenImages.merge(fresh) { _, new in new }
        }
    }

    /// App icon for items we never managed to snapshot.
    func fallbackIcon(for item: MenuBarItem) -> NSImage? {
        item.ownerPID.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
    }

    /// Expand the hidden section just long enough to click `item`, then fold
    /// it back once its menu has had a chance to close.
    func reveal(_ item: MenuBarItem) {
        popover?.performClose(nil)
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            defer { revealTask = nil }
            let wasCollapsed = isHiddenSectionCollapsed
            if wasCollapsed {
                setHiddenSectionCollapsed(false)
                try? await Task.sleep(for: .milliseconds(300))
            }
            refreshOnly()
            guard let fresh = items.first(where: { $0.key == item.key }) else { return }
            if !fresh.isOnScreen {
                // Still no room even when expanded: park it next to the
                // divider so it is at least reachable.
                if let divider = dividerItem {
                    try? await MenuBarItemMover.move(fresh, to: .rightOf(divider))
                    refreshOnly()
                }
            }
            if let clickable = items.first(where: { $0.key == item.key }), clickable.isOnScreen {
                try? await MenuBarItemMover.click(clickable)
            }
            guard wasCollapsed else { return }
            // Fold back once the item's menu or popover is gone, or after a
            // generous timeout in case it never opened anything.
            try? await Task.sleep(for: .milliseconds(500))
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline, !Task.isCancelled,
                  NSEvent.pressedMouseButtons != 0 || Self.isMenuOpen() {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !Task.isCancelled { setHiddenSectionCollapsed(true) }
        }
    }

    /// True while any app has a menu or status item popover on screen.
    private static func isMenuOpen() -> Bool {
        let popUp = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return infos.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int else { return false }
            // Menus sit at the pop-up level; status item popovers one below.
            return layer == popUp || layer == popUp - 1
        }
    }

    private func refreshOnly() {
        items = MenuBarScanner.scan()
    }

    @objc private func toggleHiddenSection(_ sender: Any?) {
        setHiddenSectionCollapsed(!isHiddenSectionCollapsed)
    }

    func setHiddenSectionCollapsed(_ collapsed: Bool) {
        divider.setCollapsed(collapsed)
        isHiddenSectionCollapsed = collapsed
        refresh()
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = mainItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuPanel().environmentObject(self)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        if !ItemImageCapture.hasPermission() { ItemImageCapture.requestPermission() }
        refresh()
    }
}
