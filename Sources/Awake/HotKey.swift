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

    init?(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) {
        self.hotKeyID = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        self.handler = handler

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

    fileprivate func fire() {
        handler()
    }

    // MARK: - Shared Carbon event handler

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

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
            // @convention(c) context — hop to the main actor.
            DispatchQueue.main.async {
                GlobalHotKey.registry[id]?.fire()
            }
            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
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
