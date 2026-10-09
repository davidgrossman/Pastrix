import AppKit

/// Only installed during an explicitly started queue session. No keystrokes are stored.
@MainActor
final class QueuePasteMonitor {
    static let syntheticEventTag: Int64 = 0x50535452
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var shouldHandle: (() -> Bool)?
    var onPaste: (() -> Void)?

    func start() -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let consumed = MainActor.assumeIsolated {
                    let monitor = Unmanaged<QueuePasteMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return false
                    }
                    guard QueuePasteMonitor.isQueuePaste(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                        flags: event.flags, tag: event.getIntegerValueField(.eventSourceUserData)),
                        monitor.shouldHandle?() == true else { return false }
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { monitor.onPaste?() }
                    return true
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    nonisolated static func isQueuePaste(keyCode: Int64, flags: CGEventFlags, tag: Int64) -> Bool {
        keyCode == 9 && flags.contains(.maskCommand) &&
        flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty && tag != 0x50535452
    }
}
