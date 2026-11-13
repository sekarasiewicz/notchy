import AppKit
import CoreGraphics

/// Clicks and ⌘-drags menu bar items on macOS 27 by posting ordinary mouse
/// events, the same ones a hand on the trackpad would produce.
///
/// The per-process relay in `MenuBarItemMover` aims events at an item's own
/// window, and macOS 27 has no such window. Accessibility presses are not a
/// substitute either: on 27.2 they fail or open nothing for most third-party
/// items. Real events work for everything, at the price of the pointer
/// visiting the menu bar for a moment before it is put back.
enum PointerDriver {
    static func click(at point: CGPoint) async throws {
        let home = CGEvent(source: nil)?.location
        defer { if let home { CGWarpMouseCursorPosition(home) } }
        try post(.mouseMoved, at: point)
        try await Task.sleep(for: .milliseconds(40))
        try post(.leftMouseDown, at: point)
        try await Task.sleep(for: .milliseconds(40))
        try post(.leftMouseUp, at: point)
        try await Task.sleep(for: .milliseconds(40))
    }

    /// The bar only starts a drag after the pointer has travelled, and only
    /// reorders while it sees intermediate positions, so walk there.
    static func commandDrag(from start: CGPoint, to end: CGPoint) async throws {
        let home = CGEvent(source: nil)?.location
        defer { if let home { CGWarpMouseCursorPosition(home) } }
        try post(.mouseMoved, at: start)
        try await Task.sleep(for: .milliseconds(50))
        try post(.leftMouseDown, at: start, flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(80))
        do {
            let steps = 12
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                try post(.leftMouseDragged, at: point, flags: .maskCommand)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            // Never leave the button down.
            try? post(.leftMouseUp, at: end, flags: .maskCommand)
            throw error
        }
        try post(.leftMouseUp, at: end, flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(50))
    }

    private static func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else { throw MenuBarItemMover.MoveError.eventCreationFailed }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
