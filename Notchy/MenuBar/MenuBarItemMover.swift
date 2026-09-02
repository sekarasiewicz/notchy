import Cocoa
import os

/// Moves and clicks other apps' status items by synthesising the Cmd-drag a
/// user would do by hand.
///
/// Posting a plain event does not work: the item has to receive it through
/// its own process's tap. The relay ("scromble", as Ice calls it) bounces a
/// marker null event and the real event between a per-process tap and the
/// session tap until the item's process has seen the real event. All of it is
/// forbidden magic and may break with any macOS release.
enum MenuBarItemMover {
    private static let log = Logger(subsystem: "dev.karasiewicz.Notchy", category: "Mover")

    enum Destination {
        case leftOf(MenuBarItem)
        case rightOf(MenuBarItem)

        var target: MenuBarItem {
            switch self {
            case .leftOf(let item), .rightOf(let item): item
            }
        }
    }

    enum MoveError: Error {
        case noOwner(MenuBarItem)
        case eventCreationFailed
        case timeout(String)
        case boundsUnavailable
        case notMoved
    }

    // MARK: Public

    /// Moves `item` so it sits directly left or right of the destination
    /// target. Retries a few times; item ordering in the bar is flaky.
    static func move(_ item: MenuBarItem, to destination: Destination, attempts: Int = 5) async throws {
        if try isInPlace(item, destination) { return }
        var lastError: Error = MoveError.notMoved
        for attempt in 1...attempts {
            do {
                try await postMoveEvents(item, destination)
                if try await settledInPlace(item, destination) { return }
                lastError = MoveError.notMoved
            } catch {
                lastError = error
                log.warning("Move attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw lastError
    }

    /// Items slide into place over a few frames. Poll until adjacency holds
    /// or give up after a short while.
    private static func settledInPlace(_ item: MenuBarItem, _ destination: Destination) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < deadline {
            if try isInPlace(item, destination) { return true }
            try await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    static func click(_ item: MenuBarItem, button: CGMouseButton = .left) async throws {
        guard let pid = item.ownerPID else { throw MoveError.noOwner(item) }
        guard let bounds = WindowServer.frame(of: item.windowID) else { throw MoveError.boundsUnavailable }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        let source = try eventSource()
        let (downType, upType): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        guard let down = makeEvent(source, downType, button, point, item.windowID, isMove: false, clickState: 1),
              let up = makeEvent(source, upType, button, point, item.windowID, isMove: false, clickState: 0)
        else { throw MoveError.eventCreationFailed }
        try permitLocalEvents()
        try await relay(down, pid: pid, timeout: .milliseconds(250), repeating: 1, threeTaps: false)
        try await relay(up, pid: pid, timeout: .milliseconds(250), repeating: 2, threeTaps: false)
    }

    // MARK: Move mechanics

    private static func isInPlace(_ item: MenuBarItem, _ destination: Destination) throws -> Bool {
        guard let a = WindowServer.frame(of: item.windowID),
              let b = WindowServer.frame(of: destination.target.windowID)
        else { throw MoveError.boundsUnavailable }
        return switch destination {
        case .leftOf: a.maxX == b.minX
        case .rightOf: a.minX == b.maxX
        }
    }

    private static func targetPoints(_ item: MenuBarItem, _ destination: Destination) throws -> (start: CGPoint, end: CGPoint) {
        guard let itemBounds = WindowServer.frame(of: item.windowID),
              let targetBounds = WindowServer.frame(of: destination.target.windowID)
        else { throw MoveError.boundsUnavailable }
        switch destination {
        case .leftOf:
            var start = CGPoint(x: targetBounds.minX, y: targetBounds.minY)
            var end = start
            if itemBounds.maxX <= targetBounds.minX { end.x -= itemBounds.width } else { start.x -= 1 }
            return (start, end)
        case .rightOf:
            var start = CGPoint(x: targetBounds.maxX, y: targetBounds.minY)
            var end = start
            if itemBounds.minX <= targetBounds.maxX { end.x -= itemBounds.width } else { start.x += 1 }
            return (start, end)
        }
    }

    private static func postMoveEvents(_ item: MenuBarItem, _ destination: Destination) async throws {
        guard let pid = item.ownerPID else { throw MoveError.noOwner(item) }
        let points = try targetPoints(item, destination)
        guard var origin = WindowServer.frame(of: item.windowID)?.origin else { throw MoveError.boundsUnavailable }
        let mouseLocation = CGEvent(source: nil)?.location
        let source = try eventSource()
        try permitLocalEvents()

        guard let down = makeEvent(source, .leftMouseDown, .left, points.start, item.windowID, isMove: true, clickState: nil),
              let up = makeEvent(source, .leftMouseUp, .left, points.end, destination.target.windowID, isMove: true, clickState: nil)
        else { throw MoveError.eventCreationFailed }
        down.flags = .maskCommand

        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let mouseLocation { CGWarpMouseCursorPosition(mouseLocation) }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        let timeout: Duration = .milliseconds(100)
        do {
            try await relay(down, pid: pid, timeout: timeout, repeating: 1, threeTaps: true)
            origin = try await waitForOriginChange(item, from: origin, timeout: timeout)
            try await relay(up, pid: pid, timeout: timeout, repeating: 2, threeTaps: true)
            _ = try await waitForOriginChange(item, from: origin, timeout: timeout)
        } catch {
            // Never leave the item in a mid-drag state.
            try? await relay(up, pid: pid, timeout: .milliseconds(100), repeating: 2, threeTaps: true)
            throw error
        }
    }

    private static func waitForOriginChange(_ item: MenuBarItem, from origin: CGPoint, timeout: Duration) async throws -> CGPoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let now = WindowServer.frame(of: item.windowID)?.origin, now != origin { return now }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw MoveError.timeout("item did not move")
    }

    // MARK: Event relay

    /// Delivers `event` to the item's process `count` times and returns once
    /// the process has seen it. `threeTaps` is the move variant, where the real
    /// event has to be re-posted to the pid tap after the session tap saw it.
    private static func relay(_ event: CGEvent, pid: pid_t, timeout: Duration, repeating count: Int, threeTaps: Bool) async throws {
        guard let entry = uniqueNullEvent(), let exit = uniqueNullEvent() else { throw MoveError.eventCreationFailed }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        let first = EventTap.Location.pid(pid)
        let second = EventTap.Location.sessionEventTap
        let fields = CGEventField.menuBarItemEventFields

        final class State: @unchecked Sendable {
            var count: Int
            var taps: [EventTap] = []
            var resumed = false
            init(count: Int) { self.count = count }
        }
        let state = State(count: count)

        try await withTimeout(timeout * count) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let tap1 = EventTap(label: "entry/exit", types: [.null], location: first, placement: .headInsertEventTap, option: .defaultTap) { tap, received in
                    if received.matches(entry, byIntegerFields: [.eventSourceUserData]) {
                        state.count -= 1
                        event.post(to: second)
                        return nil
                    }
                    if received.matches(exit, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        if !state.resumed { state.resumed = true; continuation.resume() }
                        return nil
                    }
                    return received
                }
                let tap2 = EventTap(label: "session", types: [event.type], location: second, placement: .tailAppendEventTap, option: .listenOnly) { tap, received in
                    guard received.matches(event, byIntegerFields: fields) else { return received }
                    if threeTaps {
                        if state.count <= 0 { tap.disable() }
                        event.post(to: first)
                    } else {
                        if state.count <= 0 { tap.disable(); exit.post(to: first) } else { entry.post(to: first) }
                    }
                    received.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
                    return received
                }
                state.taps = [tap1, tap2]
                if threeTaps {
                    let tap3 = EventTap(label: "pid", types: [event.type], location: first, placement: .headInsertEventTap, option: .listenOnly) { tap, received in
                        guard received.matches(event, byIntegerFields: fields) else { return received }
                        if state.count <= 0 { tap.disable(); exit.post(to: first) } else { entry.post(to: first) }
                        received.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
                        return received
                    }
                    state.taps.append(tap3)
                }
                state.taps.forEach { $0.enable() }
                entry.post(to: first)
            }
        } onTimeout: {
            state.taps.forEach { $0.disable() }
        }
        state.taps.forEach { $0.disable() }
    }

    private static func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T, onTimeout: @escaping @Sendable () -> Void) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                onTimeout()
                throw MoveError.timeout("event relay")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: Event construction

    private static func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw MoveError.eventCreationFailed }
        return source
    }

    private static func permitLocalEvents() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw MoveError.eventCreationFailed }
        let all: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
    }

    private static func makeEvent(_ source: CGEventSource, _ type: CGEventType, _ button: CGMouseButton, _ location: CGPoint, _ windowID: CGWindowID, isMove: Bool, clickState: Int64?) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return nil }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Int64(Int(bitPattern: ObjectIdentifier(event))))
        let id = Int64(windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: id)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: id)
        if isMove { event.setIntegerValueField(.windowID, value: id) }
        if let clickState { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        return event
    }

    private static func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: Int64(Int(bitPattern: ObjectIdentifier(event))))
        return event
    }
}

private extension CGEventField {
    /// Undocumented field carrying the target window id of a mouse event.
    static let windowID = CGEventField(rawValue: 0x33)!

    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}
