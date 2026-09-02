import AppKit
import ApplicationServices

/// One status item, stitched together from two sources:
/// the window server (window id, whether it is drawn) and Accessibility
/// (which app owns it, its title). Neither source alone is enough on macOS 26.
struct MenuBarItem: Identifiable, Hashable {
    let windowID: CGWindowID
    /// Global CG coordinates, origin top-left.
    let frame: CGRect
    /// False when the item exists but the window server has no room to draw it:
    /// pushed off the edge, or squeezed out by the notch.
    let isOnScreen: Bool

    let ownerPID: pid_t?
    let bundleID: String?
    let appName: String?
    /// Position among the owning app's items, left to right.
    let indexInApp: Int
    let title: String?
    let axDescription: String?
    let axIdentifier: String?
    let element: AXUIElement?

    var id: CGWindowID { windowID }

    /// Identity that survives relaunches: bundle id plus a per-app hint.
    /// Apple's own items carry a proper identifier; third-party ones rarely
    /// have any text, so their slot index has to do.
    var key: String {
        if let axIdentifier, !axIdentifier.isEmpty { return axIdentifier }
        let app = bundleID ?? "<null>"
        if let title, !title.isEmpty { return "\(app):\(title)" }
        if let axDescription, !axDescription.isEmpty { return "\(app):\(axDescription)" }
        return "\(app)#\(indexInApp)"
    }

    var displayName: String {
        if let axDescription, !axDescription.isEmpty, bundleID != Bundle.main.bundleIdentifier {
            return appName.map { "\($0) · \(axDescription)" } ?? axDescription
        }
        return appName ?? title ?? "Unknown"
    }

    var isOwnedByNotchy: Bool {
        ownerPID == ProcessInfo.processInfo.processIdentifier
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.windowID == rhs.windowID }
    func hash(into hasher: inout Hasher) { hasher.combine(windowID) }
}
