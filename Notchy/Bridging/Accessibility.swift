import AppKit
import ApplicationServices

/// Accessibility view of status items. Every app exposes its own items under
/// the undocumented-but-stable `AXExtrasMenuBar` attribute. On macOS 26 this is
/// the only way to learn which app owns a status item window, because the
/// window server reports all of them as owned by Control Center.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    struct Extra {
        let ownerPID: pid_t
        let bundleID: String?
        let appName: String?
        /// Position among the owning app's extras, left to right.
        let index: Int
        let title: String?
        let description: String?
        let identifier: String?
        /// Screen coordinates, origin top-left. Reported even for items the
        /// window server is not drawing.
        let frame: CGRect
        let element: AXUIElement
    }

    /// All status items of all running apps. Needs Accessibility permission;
    /// returns an empty array without it.
    static func allExtras() -> [Extra] {
        guard isTrusted else { return [] }
        var out: [Extra] = []
        for app in NSWorkspace.shared.runningApplications {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            guard let bar: AXUIElement = attribute(ax, "AXExtrasMenuBar"),
                  let children: [AXUIElement] = attribute(bar, kAXChildrenAttribute)
            else { continue }
            let sorted = children
                .map { ($0, frame(of: $0)) }
                .sorted { $0.1.minX < $1.1.minX }
            for (index, (element, frame)) in sorted.enumerated() {
                out.append(Extra(
                    ownerPID: app.processIdentifier,
                    bundleID: app.bundleIdentifier,
                    appName: app.localizedName,
                    index: index,
                    title: attribute(element, kAXTitleAttribute),
                    description: attribute(element, kAXDescriptionAttribute),
                    identifier: attribute(element, kAXIdentifierAttribute),
                    frame: frame,
                    element: element
                ))
            }
        }
        return out
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let value: AXValue = attribute(element, kAXPositionAttribute) {
            AXValueGetValue(value, .cgPoint, &origin)
        }
        if let value: AXValue = attribute(element, kAXSizeAttribute) {
            AXValueGetValue(value, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
