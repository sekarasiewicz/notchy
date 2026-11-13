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

    /// Snapshotting glyphs goes through ScreenCaptureKit, and macOS shows its
    /// purple "screen is being captured" indicator for every capture. Off by
    /// default; the panel falls back to app icons.
    @Published var captureGlyphs = false {
        didSet { UserDefaults.standard.set(captureGlyphs, forKey: "captureGlyphs"); if !captureGlyphs { hiddenImages = [:] } }
    }

    /// Set while an item from the hidden section is being shown for a click.
    private var revealTask: Task<Void, Never>?

    /// Every status item window seen so far. Auto-fold only reacts to a
    /// window that has never been seen, i.e. a new icon arriving; reacting to
    /// "something is off screen" would undo the user's own unfold a moment
    /// later, since the overflow is still there.
    private var knownWindowIDs: Set<CGWindowID>?

    /// Autosave names double as defaults keys, keep them short and stable.
    private var mainItem: NSStatusItem
    private var divider: DividerItem
    private var refreshTimer: Timer?
    private var popover: NSPopover?

    private init() {
        autoCollapse = UserDefaults.standard.object(forKey: "autoCollapse") as? Bool ?? true
        captureGlyphs = UserDefaults.standard.object(forKey: "captureGlyphs") as? Bool ?? false
        // Seed slots so the divider starts just left of the Notchy icon.
        // Higher preferred position = further left.
        if StatusItemDefaults.preferredPosition("NotchyMain") == nil {
            StatusItemDefaults.setPreferredPosition(0, "NotchyMain")
        }
        (mainItem, divider) = Self.makeStatusItems()

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

    /// Status items pick up spacing defaults only when created.
    func recreateStatusItems() {
        let collapsed = isHiddenSectionCollapsed
        if collapsed { divider.setCollapsed(false) }
        divider.remove()
        let position = StatusItemDefaults.preferredPosition("NotchyMain")
        NSStatusBar.system.removeStatusItem(mainItem)
        StatusItemDefaults.setPreferredPosition(position, "NotchyMain")
        (mainItem, divider) = Self.makeStatusItems()
        mainItem.button?.target = self
        mainItem.button?.action = #selector(togglePanel(_:))
        divider.setTarget(self, action: #selector(toggleHiddenSection(_:)))
        isHiddenSectionCollapsed = false
        if collapsed { setHiddenSectionCollapsed(true) }
        refresh()
    }

    private static func makeStatusItems() -> (NSStatusItem, DividerItem) {
        let main = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        main.autosaveName = "NotchyMain"
        main.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Notchy"
        )
        let divider = DividerItem(spacerName: "NotchySpacer", chevronName: "NotchyDivider", seedPosition: 40)
        return (main, divider)
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
                guard let item = (self.items + self.hiddenSectionItems).first(where: { $0.key.contains(key) }) else { fputs("=== reveal: not found\n", stderr); return }
                fputs("=== reveal \(item.key)\n", stderr)
                self.reveal(item)
            }
        }
        if let key = ProcessInfo.processInfo.environment["NOTCHY_HIDE_TEST"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                await self.refreshOnly()
                if let item = self.items.first(where: { $0.key.contains(key) }) { fputs("=== hide \(item.key)\n", stderr); self.hide(item) }
                try? await Task.sleep(for: .seconds(4))
                if let item = self.items.first(where: { $0.key.contains(key) }) { fputs("=== show \(item.key)\n", stderr); self.show(item) }
            }
        }
        if ProcessInfo.processInfo.environment["NOTCHY_MISPLACE_TEST"] != nil {
            // Reproduce a chevron dragged left of its spacer, then fold.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                await self.refreshOnly()
                if let spacer = self.spacerItem, let chevron = self.dividerItem {
                    fputs("=== misplacing chevron left of spacer\n", stderr)
                    try? await MenuBarItemMover.move(chevron, to: .leftOf(spacer))
                }
                try? await Task.sleep(for: .seconds(2))
                fputs("=== folding\n", stderr)
                self.setHiddenSectionCollapsed(true)
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
        refoldIfLeaking()
        // Something no longer fits: fold the hidden section so the visible
        // ones get their room back. Expanding again is the user's call.
        let windowIDs = Set(items.filter { !$0.isOwnedByNotchy && $0.ownerPID != nil }.map(\.windowID))
        let newcomers = knownWindowIDs.map { windowIDs.subtracting($0) } ?? windowIDs
        knownWindowIDs = (knownWindowIDs ?? []).union(windowIDs)
        if autoCollapse, !isHiddenSectionCollapsed, !foldInProgress, revealTask == nil, captureTask == nil,
           ContinuousClock.now >= foldRetryAfter,
           !newcomers.isEmpty, !lostItems.isEmpty, !hiddenSectionItems.isEmpty {
            fputs("=== auto-fold: new \(newcomers.count) item(s), lost \(lostItems.map(\.key))\n", stderr)
            // Snapshot first: once folded, these windows cannot be captured.
            let snapshot = captureGlyphs ? items.filter { $0.isOnScreen && !$0.isOwnedByNotchy } : []
            captureTask = Task { @MainActor in
                defer { captureTask = nil }
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
    ///
    /// macOS 27 is the other way round: the button has a window again, while
    /// the scan cannot read labels off our own slots reliably. There the
    /// window's position picks the slot.
    var dividerItem: MenuBarItem? {
        if Platform.hasUnifiedMenuBar { return ownItem(for: divider.chevron) }
        return items.first { $0.isOwnedByNotchy && ($0.axDescription == DividerItem.accessibilityDescription || $0.title == DividerItem.accessibilityDescription) }
    }

    var dividerFrame: CGRect? { dividerItem?.frame }

    var spacerItem: MenuBarItem? {
        if Platform.hasUnifiedMenuBar {
            // Whatever of ours is neither the chevron nor the main icon.
            let others = [dividerItem?.id, ownItem(for: mainItem)?.id]
            return items.first { $0.isOwnedByNotchy && !others.contains($0.id) }
        }
        return items.first { $0.isOwnedByNotchy && ($0.axDescription == "Notchy spacer" || $0.title == "Notchy spacer") }
    }

    private func ownItem(for statusItem: NSStatusItem) -> MenuBarItem? {
        guard let minX = statusItem.button?.window?.frame.minX else { return nil }
        let nearest = items.filter(\.isOwnedByNotchy).min { abs($0.frame.minX - minX) < abs($1.frame.minX - minX) }
        return nearest.flatMap { abs($0.frame.minX - minX) <= 2 ? $0 : nil }
    }

    private var enforcingOrder = false

    /// Spacer directly left of the chevron, both located.
    private var spacerIsSeated: Bool {
        guard let spacer = spacerItem, let chevron = dividerItem else { return false }
        return abs(spacer.frame.maxX - chevron.frame.minX) <= 1
    }
    private var foldInProgress = false

    /// macOS 27 only: the hidden section as it was just before folding.
    private var foldedItems: [MenuBarItem] = []

    /// The spacer only works directly left of the chevron. Other apps' items
    /// can slip in between (positions are restored per app), so nudge it back.
    private var reseatRetryAfter: ContinuousClock.Instant = .now
    private static let reseatSettle: Duration = Platform.hasUnifiedMenuBar ? .milliseconds(1200) : .milliseconds(400)

    private func enforceDividerOrder() {
        guard !isHiddenSectionCollapsed, !foldInProgress, !enforcingOrder, revealTask == nil,
              ContinuousClock.now >= reseatRetryAfter,
              spacerItem != nil, dividerItem != nil, !spacerIsSeated
        else { return }
        enforcingOrder = true
        // Recreating a status item is noisy (Control Center logs scene
        // disconnects) and occasionally does not land where asked, so do not
        // hammer it.
        reseatRetryAfter = .now + .seconds(30)
        Task { @MainActor in
            defer { enforcingOrder = false }
            fputs("=== re-seating spacer next to chevron\n", stderr)
            divider.reseatSpacer()
            try? await Task.sleep(for: Self.reseatSettle)
            await refreshOnly()
            if !spacerIsSeated { fputs("=== spacer still not seated\n", stderr) }
        }
    }

    /// Items to the left of the divider, i.e. the ones the divider can hide.
    /// While folded, anything still drawn on the left is pinned by macOS
    /// (the screen recording indicator, for one) and not ours to manage.
    var hiddenSectionItems: [MenuBarItem] {
        if Platform.hasUnifiedMenuBar, isHiddenSectionCollapsed {
            // Folded items drop out of the bar's accessibility tree, so the
            // list is what was there when the fold happened, minus anything
            // that has quit or come back into view since.
            let drawn = Set(items.filter(\.isOnScreen).map(\.key))
            return foldedItems.filter { item in
                !drawn.contains(item.key) && item.ownerPID.map { kill($0, 0) == 0 } ?? false
            }
        }
        guard let wall = dividerFrame else { return [] }
        return items.filter {
            !$0.isOwnedByNotchy && $0.frame.maxX <= wall.minX && !(isHiddenSectionCollapsed && $0.isOnScreen)
        }
    }

    /// Items macOS keeps on screen no matter what: drawn left of the fold
    /// while folded.
    var pinnedItems: [MenuBarItem] {
        guard isHiddenSectionCollapsed, let wall = dividerFrame else { return [] }
        return items.filter { !$0.isOwnedByNotchy && $0.frame.maxX <= wall.minX && $0.isOnScreen }
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
        guard captureGlyphs, captureTask == nil else { return }
        // Only what is missing: every capture lights up the system indicator.
        let visible = items.filter { $0.isOnScreen && !$0.isOwnedByNotchy && hiddenImages[$0.key] == nil }
        guard !visible.isEmpty else { return }
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

    /// How long the bar takes to draw the section again after an unfold.
    /// macOS 27 animates the items back in.
    private static let unfoldSettle: Duration = Platform.hasUnifiedMenuBar ? .milliseconds(700) : .milliseconds(300)

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
                try? await Task.sleep(for: Self.unfoldSettle)
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
            let before = Self.onScreenWindowIDs()
            if let clickable = items.first(where: { $0.key == item.key }), clickable.isOnScreen {
                try? await MenuBarItemMover.click(clickable)
            }
            guard wasCollapsed else { return }
            // Whatever the click opened (a menu, a Control Center panel, a
            // popover) shows up as new on-screen windows. Fold back once they
            // are gone, or after a generous timeout if nothing ever opened.
            try? await Task.sleep(for: .milliseconds(400))
            let opened = Self.onScreenWindowIDs().subtracting(before)
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline, !Task.isCancelled,
                  NSEvent.pressedMouseButtons != 0 || !opened.isDisjoint(with: Self.onScreenWindowIDs()) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !Task.isCancelled { setHiddenSectionCollapsed(true) }
        }
    }

    /// Ids of everything currently drawn, status item windows excluded so
    /// our own unfold/fold does not count as something opening.
    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids = Set<CGWindowID>()
        for info in infos {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowLayer as String] as? Int) != statusLevel else { continue }
            ids.insert(id)
        }
        return ids
    }

    // MARK: Section membership

    /// Move an item into the hidden section: directly left of the spacer.
    func hide(_ item: MenuBarItem) {
        Task { @MainActor in
            let wasCollapsed = isHiddenSectionCollapsed
            if wasCollapsed { setHiddenSectionCollapsed(false); try? await Task.sleep(for: Self.unfoldSettle) }
            await refreshOnly()
            guard let target = spacerItem ?? dividerItem, let fresh = items.first(where: { $0.key == item.key }) else { return }
            try? await MenuBarItemMover.move(fresh, to: .leftOf(target))
            await refreshOnly()
            if wasCollapsed { setHiddenSectionCollapsed(true) }
            refresh()
        }
    }

    /// Move an item into the visible section: directly right of the chevron.
    func show(_ item: MenuBarItem) {
        Task { @MainActor in
            let wasCollapsed = isHiddenSectionCollapsed
            if wasCollapsed { setHiddenSectionCollapsed(false); try? await Task.sleep(for: Self.unfoldSettle) }
            await refreshOnly()
            guard let chevron = dividerItem, let fresh = items.first(where: { $0.key == item.key }) else { return }
            try? await MenuBarItemMover.move(fresh, to: .rightOf(chevron))
            await refreshOnly()
            if wasCollapsed { setHiddenSectionCollapsed(true) }
            refresh()
        }
    }

    private func refreshOnly() async {
        items = await MenuBarScanner.scan()
    }

    @objc private func toggleHiddenSection(_ sender: Any?) {
        setHiddenSectionCollapsed(!isHiddenSectionCollapsed)
    }

    func setHiddenSectionCollapsed(_ collapsed: Bool) {
        guard collapsed else {
            divider.setCollapsed(false)
            isHiddenSectionCollapsed = false
            foldedItems = []
            refresh()
            return
        }
        guard !foldInProgress else { return }
        foldInProgress = true
        Task { @MainActor in
            defer { foldInProgress = false }
            await foldSafely()
        }
    }

    /// Folding stretches the spacer, so the spacer has to sit directly left of
    /// the chevron or the chevron itself gets pushed off screen, taking the
    /// only way back with it. The user can ⌘-drag the chevron anywhere, so
    /// check every time and bail out if the fold still went wrong.
    private var foldRetryAfter: ContinuousClock.Instant = .now

    private func foldSafely() async {
        await refreshOnly()
        if !spacerIsSeated {
            divider.reseatSpacer()
            try? await Task.sleep(for: Self.reseatSettle)
            await refreshOnly()
        }
        guard spacerIsSeated else {
            fputs("=== fold aborted: spacer not next to chevron\n", stderr)
            foldRetryAfter = .now + .seconds(30)
            return
        }
        if Platform.hasUnifiedMenuBar {
            foldedItems = hiddenSectionItems
            await stretchSpacerUntilHidden()
            refresh()
            return
        }
        divider.setCollapsed(true)
        isHiddenSectionCollapsed = true
        try? await Task.sleep(for: .milliseconds(500))
        await refreshOnly()
        if let chevron = dividerItem, !chevron.isOnScreen {
            fputs("=== fold undone: chevron went off screen\n", stderr)
            divider.setCollapsed(false)
            isHiddenSectionCollapsed = false
        }
        refresh()
    }

    // MARK: Folding on macOS 27

    /// Spacer lengths worth trying, best first. Measured on macOS 27.2, where
    /// a status item's slot is its length plus 10 pt:
    ///
    /// - a slot wider than half the screen is thrown away and hides nothing;
    /// - below that, a spacer too wide to fit beside the notch (or the app's
    ///   menus) goes into the system's overflow together with everything on
    ///   its left. A really wide one makes all of it vanish without a trace;
    ///   one that only just fails to fit leaves the system's own `«` arrow
    ///   next to our chevron.
    ///
    /// The first is the tidier result, the second the fallback.
    private func foldLengths(chevron: MenuBarItem) -> [CGFloat] {
        let screen = NSScreen.screens.first { $0.frame.minX <= chevron.frame.midX && chevron.frame.midX < $0.frame.maxX }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let widest = (screen.frame.width / 2 - 40).rounded()
        let leftLimit = screen.auxiliaryTopRightArea?.minX ?? Self.frontmostMenusEnd() ?? screen.frame.minX + screen.frame.width * 0.3
        let justTooWide = (chevron.frame.minX - leftLimit + 16).rounded()
        return justTooWide > 40 && justTooWide < widest ? [widest, justTooWide] : [widest]
    }

    /// Right edge of the frontmost app's menus, which is where status items
    /// run out of room on a display without a notch.
    private static func frontmostMenusEnd() -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let bar: AXUIElement = Accessibility.attribute(element, kAXMenuBarAttribute),
              let menus: [AXUIElement] = Accessibility.attribute(bar, kAXChildrenAttribute)
        else { return nil }
        return menus.map { Accessibility.frame(of: $0).maxX }.max()
    }

    /// Something from the folded section is being drawn left of the chevron.
    private var foldLeaks: Bool {
        guard let wall = dividerFrame else { return true }
        let folded = Set(foldedItems.map(\.key)).subtracting(Self.pinnedByMacOS)
        return items.contains { folded.contains($0.key) && $0.isOnScreen && $0.frame.maxX <= wall.minX }
    }

    /// Items macOS keeps drawing through any fold. Counting them as a leak
    /// would make every fold look failed while one of them is up.
    private static let pinnedByMacOS: Set<String> = [
        "com.apple.menuextra.audiovideo", // camera / microphone / screen capture indicator
    ]

    /// Stretch the spacer, look at what the bar made of it, and try the next
    /// length if the section is still showing. Leaves the section unfolded
    /// when nothing works.
    private func stretchSpacerUntilHidden() async {
        guard let chevron = dividerItem else { return }
        for length in foldLengths(chevron: chevron) {
            divider.setCollapsed(true, length: length)
            isHiddenSectionCollapsed = true
            if await foldSettles() { return }
            let folded = Set(foldedItems.map(\.key))
            let showing = items.filter { folded.contains($0.key) && $0.isOnScreen }.map(\.key)
            fputs("=== fold with a \(Int(length)) pt spacer did not hide the section: chevron \(dividerItem.map { "\($0.isOnScreen)" } ?? "missing"), showing \(showing)\n", stderr)
        }
        fputs("=== fold undone: no spacer length worked\n", stderr)
        divider.setCollapsed(false)
        isHiddenSectionCollapsed = false
        foldedItems = []
        foldRetryAfter = .now + .seconds(30)
    }

    /// The bar takes a second or more to rearrange after the spacer changes
    /// and passes through half-hidden states on the way, so wait for the
    /// folded picture to hold over two scans in a row.
    private func foldSettles() async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(2500)
        var good = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            await refreshOnly()
            good = dividerItem?.isOnScreen == true && !foldLeaks ? good + 1 : 0
            if good == 2 { return true }
        }
        return false
    }

    /// What fits changes with the frontmost app's menus and with displays
    /// coming and going, so a fold that held a minute ago may not hold now.
    private func refoldIfLeaking() {
        guard Platform.hasUnifiedMenuBar, isHiddenSectionCollapsed, !foldInProgress, revealTask == nil,
              ContinuousClock.now >= foldRetryAfter, foldLeaks
        else { return }
        fputs("=== folded section is showing again, re-folding\n", stderr)
        foldInProgress = true
        foldRetryAfter = .now + .seconds(10)
        Task { @MainActor in
            defer { foldInProgress = false }
            await stretchSpacerUntilHidden()
        }
    }

    // MARK: Panel

    func closePanel() {
        popover?.performClose(nil)
    }

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
