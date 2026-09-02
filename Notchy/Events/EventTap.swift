import Cocoa
import os

/// Small wrapper over `CGEvent.tapCreate` / `tapCreateForPid`.
/// Callback returns the event to pass on, or nil to swallow it.
final class EventTap: @unchecked Sendable {
    enum Location {
        case hidEventTap
        case sessionEventTap
        case annotatedSessionEventTap
        case pid(pid_t)
    }

    private static let log = Logger(subsystem: "dev.karasiewicz.Notchy", category: "EventTap")

    private static let sharedCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let tap: EventTap = Unmanaged.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            tap.enable()
            return nil
        }
        guard tap.isEnabled else { return Unmanaged.passUnretained(event) }
        return tap.callback(tap, event).map { Unmanaged.passUnretained($0) }
    }

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private let runLoop = CFRunLoopGetMain()!
    private let callback: (EventTap, CGEvent) -> CGEvent?
    let label: String

    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    init(
        label: String,
        types: [CGEventType],
        location: Location,
        placement: CGEventTapPlacement,
        option: CGEventTapOptions,
        callback: @escaping (_ tap: EventTap, _ event: CGEvent) -> CGEvent?
    ) {
        self.label = label
        self.callback = callback
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let port: CFMachPort? = switch location {
        case .hidEventTap:
            CGEvent.tapCreate(tap: .cghidEventTap, place: placement, options: option, eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo)
        case .sessionEventTap:
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: placement, options: option, eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo)
        case .annotatedSessionEventTap:
            CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: placement, options: option, eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo)
        case .pid(let pid):
            CGEvent.tapCreateForPid(pid: pid, place: placement, options: option, eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo)
        }
        guard let port, let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            Self.log.error("Could not create event tap \(label, privacy: .public)")
            return
        }
        self.machPort = port
        self.source = source
    }

    deinit {
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
    }

    func enable() {
        guard let source, let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: true)
        CFRunLoopAddSource(runLoop, source, .commonModes)
    }

    func disable() {
        guard let source, let machPort else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: false)
    }
}

extension CGEvent {
    func post(to location: EventTap.Location) {
        switch location {
        case .hidEventTap: post(tap: .cghidEventTap)
        case .sessionEventTap: post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid): postToPid(pid)
        }
    }

    func matches(_ other: CGEvent, byIntegerFields fields: [CGEventField]) -> Bool {
        fields.allSatisfy { getIntegerValueField($0) == other.getIntegerValueField($0) }
    }
}
