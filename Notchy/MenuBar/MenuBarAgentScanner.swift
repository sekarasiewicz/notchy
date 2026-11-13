import AppKit
import ApplicationServices

/// Which menu bar this system has.
nonisolated enum Platform {
    /// macOS 27 draws every status item inside one MenuBarAgent window per
    /// display. There are no per-item windows to list, capture or aim events
    /// at any more, so scanning, clicking and moving all take another route.
    static let hasUnifiedMenuBar: Bool = {
        if #available(macOS 27.0, *) { true } else { false }
    }()
}

/// Reads the menu bar on macOS 27 and later.
///
/// MenuBarAgent exposes the bar as an accessibility window whose children are
/// slots, one per item, in no particular order. A slot wraps either one of
/// the system's own extras (an `AXMenuBarItem` owned by MenuBarAgent) or a
/// button that still belongs to the app which created the status item, so
/// the slot's frame says where the item is and the wrapped element's pid says
/// whose it is. Measured on macOS 27.2.
nonisolated enum MenuBarAgentScanner {
    static let agentBundleID = "com.apple.MenuBarAgent"

    /// The system's own "show hidden items" arrow. While collapsed, the items
    /// that did not fit are stacked underneath it.
    private static let overflowIndicatorID = "menu-bar-overflow-indicator"

    static func scanSync() -> [MenuBarItem] {
        guard Accessibility.isTrusted,
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first
        else { return [] }
        let agentPID = agent.processIdentifier
        let app = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(app, 0.5)

        // One window per display; only the active display's window resolves
        // other apps' buttons, and it is the one with the most slots.
        let windows: [AXUIElement] = Accessibility.attribute(app, kAXWindowsAttribute) ?? []
        let bars: [[AXUIElement]] = windows.map { Accessibility.attribute($0, kAXChildrenAttribute) ?? [] }
        guard let slots = bars.max(by: { $0.count < $1.count }) else { return [] }

        struct Raw {
            let frame: CGRect
            let pid: pid_t
            let element: AXUIElement
            let identifier: String?
            let title: String?
            let description: String?
        }

        var raws: [Raw] = []
        var overflowFrame: CGRect?
        for slot in slots {
            let element = wrappedElement(in: slot)
            let identifier: String? = Accessibility.attribute(element, kAXIdentifierAttribute)
            let frame = Accessibility.frame(of: slot)
            if let identifier, identifier.hasPrefix(overflowIndicatorID) {
                if identifier == overflowIndicatorID { overflowFrame = frame }
                continue
            }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            raws.append(Raw(
                frame: frame,
                pid: pid,
                element: element,
                identifier: identifier,
                title: Accessibility.attribute(element, kAXTitleAttribute),
                description: Accessibility.attribute(element, kAXDescriptionAttribute)
            ))
        }
        raws.sort { $0.frame.minX < $1.frame.minX }

        var seenPerApp: [pid_t: Int] = [:]
        return raws.map { raw in
            let index = seenPerApp[raw.pid, default: 0]
            seenPerApp[raw.pid] = index + 1
            // The system's own extras have no app worth naming; their
            // description ("Battery") is the name.
            let owner = raw.pid == agentPID ? nil : NSRunningApplication(processIdentifier: raw.pid)
            let bundleID = raw.pid == agentPID ? agentBundleID : owner?.bundleIdentifier
            let key = MenuBarItem.key(
                bundleID: bundleID, indexInApp: index,
                title: raw.title, axDescription: raw.description, axIdentifier: raw.identifier
            )
            let overflowed = overflowFrame.map { $0.intersects(raw.frame) } ?? false
            return MenuBarItem(
                windowID: SyntheticWindowID.id(for: key),
                frame: raw.frame,
                isOnScreen: !overflowed && raw.frame.width > 0,
                ownerPID: raw.pid,
                bundleID: bundleID,
                appName: owner?.localizedName,
                indexInApp: index,
                title: raw.title,
                axDescription: raw.description,
                axIdentifier: raw.identifier,
                element: raw.element
            )
        }
    }

    /// Slots nest the real element inside one or two plain groups.
    private static func wrappedElement(in slot: AXUIElement) -> AXUIElement {
        var current = slot
        for _ in 0..<4 {
            guard let role: String = Accessibility.attribute(current, kAXRoleAttribute), role == kAXGroupRole,
                  let children: [AXUIElement] = Accessibility.attribute(current, kAXChildrenAttribute),
                  let first = children.first
            else { break }
            current = first
        }
        return current
    }
}

/// Items have no window of their own on macOS 27, but the rest of the app
/// tells items apart by window id. Hand out a stable stand-in per item key.
nonisolated enum SyntheticWindowID {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: [String: CGWindowID] = [:]
    /// Far above anything the window server hands out in practice.
    nonisolated(unsafe) private static var next: CGWindowID = 0x4E00_0000

    static func id(for key: String) -> CGWindowID {
        lock.lock()
        defer { lock.unlock() }
        if let id = ids[key] { return id }
        next += 1
        ids[key] = next
        return next
    }
}
