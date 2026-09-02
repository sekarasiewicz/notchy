import AppKit

/// AppKit persists each status item's slot as
/// "NSStatusItem Preferred Position <autosaveName>" in the app's defaults.
/// Removing an item or setting `isVisible = false` deletes that key, so anything
/// that wants a stable slot has to snapshot and restore it around those calls.
enum StatusItemDefaults {
    private static func key(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    static func preferredPosition(_ autosaveName: String) -> CGFloat? {
        UserDefaults.standard.object(forKey: key(autosaveName)) as? CGFloat
    }

    static func setPreferredPosition(_ position: CGFloat?, _ autosaveName: String) {
        if let position {
            UserDefaults.standard.set(position, forKey: key(autosaveName))
        } else {
            UserDefaults.standard.removeObject(forKey: key(autosaveName))
        }
    }
}
