import Foundation

/// Pushes our own hold's state to other local apps (e.g. a notch HUD) the moment
/// it changes, so they needn't poll IOPM assertions and guess at transitions —
/// "+15 min" is a release + re-create there, here it's one `extended`.
///
/// Contract v1, on the distributed notification center:
/// - `com.mackhaymond.Awake.state`, object nil, userInfo of plist types (see
///   `payload`), posted after the assertions are actually created/released.
/// - `com.mackhaymond.Awake.query` (posted by a listener) is answered with a
///   `snapshot`, so a listener can sync at its own launch.
/// Nothing is posted while idle.
enum StateBroadcast {

    static let stateName = Notification.Name("com.mackhaymond.Awake.state")
    static let queryName = Notification.Name("com.mackhaymond.Awake.query")

    enum Event: String {
        case on         // a hold started from idle
        case extended   // a running hold's end changed (one post, never off+on)
        case off        // the user stopped the hold, or quit while holding
        case ended      // a timed hold reached its deadline
        case snapshot   // current state: a query reply, or display/lid change mid-hold
    }

    struct State: Equatable {
        var active: Bool
        /// Start of the current stretch, kept across extensions; on off/ended,
        /// the start of the stretch that just finished.
        var start: Date?
        /// Deadline of a timed hold; nil when indefinite or not active.
        var end: Date?
        var displayOn: Bool
        /// The clamshell override is actually engaged.
        var lidOK: Bool
    }

    static func payload(_ event: Event, _ state: State, pid: Int32 = getpid()) -> [String: Any] {
        var info: [String: Any] = [
            "v": 1,
            "event": event.rawValue,
            "active": state.active,
            "displayOn": state.displayOn,
            "lidOK": state.lidOK,
            "pid": Int(pid),
        ]
        if let start = state.start { info["start"] = start.timeIntervalSince1970 }
        if let end = state.end { info["end"] = end.timeIntervalSince1970 }
        return info
    }

    /// `name` is overridable only so --selftest can round-trip without
    /// telling real listeners the hold is off.
    static func post(_ event: Event, _ state: State, name: Notification.Name = stateName) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: payload(event, state), deliverImmediately: true)
    }

    /// Observe `name` with immediate delivery. The block-based observer API
    /// can't do that, and AppKit suspends distributed delivery while the app is
    /// inactive — which for a menu-bar app is nearly always — so a plain
    /// observer would sit on a query until the menu next opened.
    @MainActor
    final class Listener: NSObject {
        private let handler: () -> Void

        init(name: Notification.Name, handler: @escaping () -> Void) {
            self.handler = handler
            super.init()
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(fire(_:)), name: name, object: nil,
                suspensionBehavior: .deliverImmediately)
        }

        deinit { DistributedNotificationCenter.default().removeObserver(self) }

        // Distributed notifications are delivered on the main thread.
        @objc private func fire(_ note: Notification) { handler() }
    }
}
