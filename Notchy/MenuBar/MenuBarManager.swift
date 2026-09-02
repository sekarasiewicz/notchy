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

    /// Window ids present when the user last expanded by hand. Auto-fold
    /// stays quiet until the set changes, otherwise expanding would be undone
    /// on the next tick while the overflow still exists.
    private var expandedWithWindows: Set<CGWindowID>?

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

        divider = DividerItem(spacerName: "NotchySpacer", chevronName: "NotchyDivider", seedPosition: 40)

        mainItem.button?.target = self
        mainItem.button?.action = #selector(togglePanel(_:))
        divider.setTarget(self, action: #selector(toggleHiddenSection(_:)))
    }

    /// Built once; hosting a SwiftUI view costs a visible fraction of a second.
    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuPanel().environmentObject(self)
        )
        self.popover = popover
        return popover
    }

    func start() {
        _ = makePopover()
        refresh()
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["NOTCHY_MOVE_TEST"] {
            // Move the item whose key contains `key` right next to the divider.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                await self.refreshOnly()
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
                await self.refreshOnly()
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
                try? await Task.sleep(for: .seconds(7))
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
    /// removing it, and removing a stretched spacer does not make the bar
    /// re-layout, so the folded icons would stay off screen. Unfold first,
    /// let the bar settle, then take our items down.
    ///
    /// Synchronous on purpose: this runs from `applicationShouldTerminate`,
    /// where main-actor tasks would never get scheduled.
    func tearDown() {
        refreshTimer?.invalidate()
        revealTask?.cancel()
        if isHiddenSectionCollapsed {
            divider.setCollapsed(false)
            Self.spin(.milliseconds(400))
        }
        divider.remove()
        let position = StatusItemDefaults.preferredPosition("NotchyMain")
        NSStatusBar.system.removeStatusItem(mainItem)
        StatusItemDefaults.setPreferredPosition(position, "NotchyMain")
        Self.spin(.milliseconds(200))
    }

    /// Pump the run loop so AppKit can talk to Control Center before we exit.
    private static func spin(_ duration: Duration) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
    }

    private var refreshTask: Task<Void, Never>?

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil }
            let started = ContinuousClock.now
            items = await MenuBarScanner.scan()
            #if DEBUG
            if ProcessInfo.processInfo.environment["NOTCHY_DUMP"] != nil {
                fputs("=== scan took \(ContinuousClock.now - started)\n", stderr)
            }
            #endif
            didRefresh()
        }
    }

    private func didRefresh() {
        enforceDividerOrder()
        // Something no longer fits: fold the hidden section so the visible
        // ones get their room back. Expanding again is the user's call.
        let windowIDs = Set(items.filter { !$0.isOwnedByNotchy }.map(\.windowID))
        if autoCollapse, !isHiddenSectionCollapsed, revealTask == nil, !lostItems.isEmpty, !hiddenSectionItems.isEmpty,
           expandedWithWindows != windowIDs {
            fputs("=== auto-fold: lost \(lostItems.map(\.key))\n", stderr)
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
        items.first { $0.isOwnedByNotchy && ($0.axDescription == DividerItem.accessibilityDescription || $0.title == DividerItem.accessibilityDescription) }
    }

    var dividerFrame: CGRect? { dividerItem?.frame }

    var spacerItem: MenuBarItem? {
        items.first { $0.isOwnedByNotchy && ($0.axDescription == "Notchy spacer" || $0.title == "Notchy spacer") }
    }

    private var enforcingOrder = false

    /// The spacer only works directly left of the chevron. Other apps' items
    /// can slip in between (positions are restored per app), so nudge it back.
    private func enforceDividerOrder() {
        guard !isHiddenSectionCollapsed, !enforcingOrder, revealTask == nil,
              let spacer = spacerItem, let chevron = dividerItem,
              spacer.frame.maxX != chevron.frame.minX
        else { return }
        enforcingOrder = true
        Task { @MainActor in
            defer { enforcingOrder = false }
            try? await MenuBarItemMover.move(spacer, to: .leftOf(chevron))
            await refreshOnly()
        }
    }

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
            await refreshOnly()
            guard let fresh = items.first(where: { $0.key == item.key }) else { return }
            if !fresh.isOnScreen {
                // Still no room even when expanded: park it next to the
                // divider so it is at least reachable.
                if let divider = dividerItem {
                    try? await MenuBarItemMover.move(fresh, to: .rightOf(divider))
                    await refreshOnly()
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

    private func refreshOnly() async {
        items = await MenuBarScanner.scan()
    }

    @objc private func toggleHiddenSection(_ sender: Any?) {
        setHiddenSectionCollapsed(!isHiddenSectionCollapsed)
    }

    func setHiddenSectionCollapsed(_ collapsed: Bool) {
        divider.setCollapsed(collapsed)
        isHiddenSectionCollapsed = collapsed
        if !collapsed {
            expandedWithWindows = Set(items.filter { !$0.isOwnedByNotchy }.map(\.windowID))
        }
        refresh()
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = mainItem.button else { return }
        let popover = self.popover ?? makePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        refresh()
    }
}
