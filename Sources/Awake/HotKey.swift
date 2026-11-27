import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey` — zero deps, no Accessibility
/// permission. Teardown happens in `invalidate()`, not `deinit` (the Carbon
/// handles aren't Sendable / main-actor-isolated).
@MainActor
final class GlobalHotKey {

    /// Active registry keyed by our hotkey id, so the C callback can find us.
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    /// Four-char signature ("AWKE").
    private static let signature: OSType = {
        let chars = Array("AWKE".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16)
             | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private let doubleTapHandler: (() -> Void)?
    private var taps = TapSequencer()

    /// With `onDoubleTap`, a single press waits `TapSequencer.window` for a
    /// second one before it runs `handler`; two quick presses run only
    /// `onDoubleTap`. Without it, a press runs `handler` at once.
    init?(keyCode: UInt32, carbonModifiers: UInt32,
          onDoubleTap: (() -> Void)? = nil,
          handler: @escaping () -> Void) {
        self.hotKeyID = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        self.handler = handler
        self.doubleTapHandler = onDoubleTap

        GlobalHotKey.installEventHandlerIfNeeded()

        let eventID = EventHotKeyID(signature: GlobalHotKey.signature, id: hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            eventID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }
        self.hotKeyRef = ref
        GlobalHotKey.registry[hotKeyID] = self
    }

    func invalidate() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        GlobalHotKey.registry[hotKeyID] = nil
    }

    /// `at`: when the key went down (the event's own time, seconds since
    /// boot), not when the main thread got to it - a stalled main thread
    /// must not squeeze two slow presses into a double tap.
    fileprivate func pressed(at time: TimeInterval) {
        switch taps.press(at: time) {
        case .ignore:
            return
        case .double:
            doubleTapHandler?()
        case .waitForSecond(let generation, let flushSingle):
            // The previous press's wait ran out but its timer hasn't run
            // yet (a busy main thread): it was a single, so it runs first.
            if flushSingle { handler() }
            guard doubleTapHandler != nil else {
                _ = taps.expire(generation: generation)
                handler()
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(TapSequencer.window))
                // Gone with the hotkey: a rebind or quit drops a pending tap.
                guard let self, self.hotKeyRef != nil,
                      self.taps.expire(generation: generation) else { return }
                self.handler()
            }
        }
    }

    fileprivate func released() {
        taps.release()
    }

    // MARK: - Shared Carbon event handler

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        // Releases too: a press only counts as a new tap after the key came
        // up, so a held key's auto-repeat never reads as a double tap.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard err == noErr else { return noErr }
            let id = hkID.id
            let isPress = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
            // Seconds since boot, the base of ProcessInfo.systemUptime.
            let eventTime = GetEventTime(eventRef)
            let time = eventTime > 0 ? eventTime : ProcessInfo.processInfo.systemUptime
            // @convention(c) context — hop to the main actor.
            DispatchQueue.main.async {
                if isPress {
                    GlobalHotKey.registry[id]?.pressed(at: time)
                } else {
                    GlobalHotKey.registry[id]?.released()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
    }
}

// MARK: - Single vs double tap

/// Tells a single press of the hotkey from a quick double tap, and drops a
/// held key's auto-repeat. Pure (times come in as arguments) so `--selftest`
/// can drive it.
struct TapSequencer {
    /// Press to press: a second press within this is a double tap. It is also
    /// how long a single press waits before it runs.
    static let window: TimeInterval = 0.3
    /// A press while the key is still down is auto-repeat, unless the last
    /// press was this long ago: then its release was lost (the first repeat
    /// comes after the system's key-repeat delay), and the key must not stay
    /// dead for longer than that.
    static var staleDown: TimeInterval { max(0.35, NSEvent.keyRepeatDelay + 0.15) }

    enum Step: Equatable {
        case ignore
        /// Wait `window` for a second press. `flushSingle`: the previous
        /// press's wait had already run out, so it is a single, due now.
        case waitForSecond(generation: Int, flushSingle: Bool)
        case double
    }

    private(set) var down = false
    private var lastPress: TimeInterval = -.infinity
    private var waitingSince: TimeInterval?
    private(set) var generation = 0
    private let staleDown: TimeInterval

    init(staleDown: TimeInterval = TapSequencer.staleDown) {
        self.staleDown = staleDown
    }

    mutating func press(at t: TimeInterval) -> Step {
        defer { lastPress = t }
        if down && t - lastPress < staleDown { return .ignore }
        down = true
        generation += 1   // any pending wait is settled here
        if let since = waitingSince, t - since <= Self.window {
            waitingSince = nil
            return .double
        }
        let flush = waitingSince != nil
        waitingSince = t
        return .waitForSecond(generation: generation, flushSingle: flush)
    }

    mutating func release() { down = false }

    /// The wait after press `generation` ran out: true when that press stands
    /// as a single tap (no second press came, nothing newer replaced it).
    mutating func expire(generation g: Int) -> Bool {
        guard g == generation, waitingSince != nil else { return false }
        waitingSince = nil
        return true
    }
}

// MARK: - NSEvent.ModifierFlags ↔ Carbon bridge

extension NSEvent.ModifierFlags {
    /// Convert Cocoa modifier flags into Carbon modifier bits.
    var carbonFlags: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command)  { carbon |= UInt32(cmdKey) }
        if contains(.option)   { carbon |= UInt32(optionKey) }
        if contains(.control)  { carbon |= UInt32(controlKey) }
        if contains(.shift)    { carbon |= UInt32(shiftKey) }
        return carbon
    }

    init(carbonFlags: UInt32) {
        var flags: NSEvent.ModifierFlags = []
        if carbonFlags & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        if carbonFlags & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if carbonFlags & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonFlags & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        self = flags
    }
}
