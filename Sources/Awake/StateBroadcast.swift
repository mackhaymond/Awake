import Foundation
import os

/// Pushes our own hold's state to other local apps (e.g. a notch HUD) the moment
/// it changes, so they needn't poll IOPM assertions and guess at transitions —
/// "+15 min" is a release + re-create there, here it's one `extended`.
///
/// Contract v1, on the distributed notification center:
/// - `com.mackhaymond.Awake.state`, object nil, userInfo of plist types (see
///   `payload`), posted after the assertions are actually created/released.
/// - `com.mackhaymond.Awake.query` (posted by a listener) is answered with a
///   `snapshot`, so a listener can sync at its own launch.
/// - `com.mackhaymond.Awake.command` drives Awake (see `Command`); the state
///   post it causes carries the command's id as `requestId`.
/// Nothing is posted while idle, except replies and the user changing one of
/// the settings the payload carries.
enum StateBroadcast {

    static let stateName = Notification.Name("com.mackhaymond.Awake.state")
    static let queryName = Notification.Name("com.mackhaymond.Awake.query")
    static let commandName = Notification.Name("com.mackhaymond.Awake.command")

    static let log = Logger(subsystem: "com.mackhaymond.Awake", category: "command")

    enum Event: String {
        case on         // a hold started from idle
        case extended   // a running hold's end changed (one post, never off+on)
        case off        // the user stopped the hold, or quit while holding
        case ended      // a timed hold reached its deadline
        case snapshot   // current state: a query/no-op reply, or a change mid-hold
    }

    struct State: Equatable {
        var active: Bool
        /// Start of the current stretch, kept across extensions; on off/ended,
        /// the start of the stretch that just finished.
        var start: Date?
        /// Deadline of a timed hold; nil when indefinite or not active.
        var end: Date?
        /// The hold is keeping the display awake (what's engaged).
        var displayOn: Bool
        /// The clamshell override is actually engaged.
        var lidOK: Bool
        /// Seconds of the preset that started the current hold (-1 = indefinitely);
        /// nil for custom/until, after an extend, and when idle.
        var preset: Int?
        /// The lid preference is on but disengaged (battery floor).
        var lidPaused: Bool
        /// The settings, independent of whether a hold is running.
        var prefDisplayAwake: Bool
        var prefLidClosed: Bool
        var prefLidBatteryFloor: Int
        var iconHidden: Bool
        /// Default Duration in seconds, -1 = indefinitely.
        var defaultDuration: Int
        var hotkey: String
        var onAC: Bool
        var battery: Int?
        /// Present only while a listener is watching (and on query replies).
        var holders: [Holder]?
        /// The menu's "Stop N Commands" count; sent alongside `holders`.
        var youCount: Int?
        /// When the Mac went to sleep with the lid closed despite the lid
        /// override (powerd turned it off with the lid already shut). Present
        /// until the next hold starts or the user dismisses it.
        var lidSleptAt: Date? = nil
    }

    /// One row of the menu's "Keeping your Mac awake" list, minus our own hold.
    struct Holder: Equatable {
        var bucket: String          // "you" | "apps" | "system"
        var title: String
        var reason: String
        var secsLeft: Int?
        var bundleID: String?
        var count: Int
        var kind: String            // claudeCode | agentGUI | terminal | caffeinate | app | system

        /// The fields that make a change worth a push. `secsLeft` counts down
        /// every second, so it alone never triggers one.
        var identity: [String] { [bucket, title, reason, bundleID ?? "", String(count), kind] }

        /// The list's identity, order-insensitive: timed rows sort by secsLeft,
        /// so near-equal timeouts can swap places from one second to the next.
        static func signature(_ holders: [Holder]) -> [[String]] {
            holders.map(\.identity).sorted { $0.lexicographicallyPrecedes($1) }
        }

        var plist: [String: Any] {
            var d: [String: Any] = ["bucket": bucket, "title": title, "reason": reason,
                                    "count": count, "kind": kind]
            if let secsLeft { d["secsLeft"] = Double(secsLeft) }
            if let bundleID { d["bundleID"] = bundleID }
            return d
        }

        /// The menu's rows, in its order (bucket order, then the bucket's sort).
        static func from(_ buckets: [Bucket: [AssertionRow]]) -> [Holder] {
            Bucket.allCases.sorted { $0.sortOrder < $1.sortOrder }
                .filter { $0 != .thisApp }
                .flatMap { buckets[$0] ?? [] }
                .map { row in
                    Holder(bucket: row.bucket.rawValue.lowercased(),
                           title: row.title,
                           reason: row.reason,
                           secsLeft: row.timeoutSecsLeft.flatMap { $0 > 0 ? $0 : nil },
                           bundleID: row.bundleID,
                           count: row.sessionCount,
                           kind: kind(of: row))
                }
        }

        static func kind(of row: AssertionRow) -> String {
            switch row.groupKey {
            case "agent.claude-code": return "claudeCode"
            case "agent.cua-display": return "agentGUI"
            default: break
            }
            if row.isCaffeinate { return row.naturalBucket == .you ? "terminal" : "caffeinate" }
            return row.naturalBucket == .system ? "system" : "app"
        }
    }

    static func payload(_ event: Event, _ state: State, requestID: String? = nil,
                        pid: Int32 = getpid()) -> [String: Any] {
        var info: [String: Any] = [
            "v": 1,
            "event": event.rawValue,
            "active": state.active,
            "displayOn": state.displayOn,
            "lidOK": state.lidOK,
            "lidPaused": state.lidPaused,
            "prefDisplayAwake": state.prefDisplayAwake,
            "prefLidClosed": state.prefLidClosed,
            "prefLidBatteryFloor": state.prefLidBatteryFloor,
            "iconHidden": state.iconHidden,
            "defaultDuration": state.defaultDuration,
            "hotkey": state.hotkey,
            "onAC": state.onAC,
            "pid": Int(pid),
        ]
        if let start = state.start { info["start"] = start.timeIntervalSince1970 }
        if let end = state.end { info["end"] = end.timeIntervalSince1970 }
        if let preset = state.preset { info["preset"] = preset }
        if let battery = state.battery { info["battery"] = battery }
        if let holders = state.holders { info["holders"] = holders.map(\.plist) }
        if let youCount = state.youCount { info["youCount"] = youCount }
        if let lidSleptAt = state.lidSleptAt { info["lidSleptAt"] = lidSleptAt.timeIntervalSince1970 }
        if let requestID { info["requestId"] = requestID }
        return info
    }

    /// `name` is overridable only so --selftest can round-trip without
    /// telling real listeners the hold is off.
    static func post(_ event: Event, _ state: State, requestID: String? = nil,
                     name: Notification.Name = stateName) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: payload(event, state, requestID: requestID),
            deliverImmediately: true)
    }

    /// Observe `name` with immediate delivery. The block-based observer API
    /// can't do that, and AppKit suspends distributed delivery while the app is
    /// inactive — which for a menu-bar app is nearly always — so a plain
    /// observer would sit on a query until the menu next opened.
    @MainActor
    final class Listener: NSObject {
        private let handler: ([AnyHashable: Any]?) -> Void

        init(name: Notification.Name, handler: @escaping ([AnyHashable: Any]?) -> Void) {
            self.handler = handler
            super.init()
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(fire(_:)), name: name, object: nil,
                suspensionBehavior: .deliverImmediately)
        }

        deinit { DistributedNotificationCenter.default().removeObserver(self) }

        // Distributed notifications are delivered on the main thread.
        @objc private func fire(_ note: Notification) { handler(note.userInfo) }
    }

    // MARK: - Commands

    /// A validated `com.mackhaymond.Awake.command`. Any local process can post
    /// one; the worst it can do is toggle a hold, so there's no auth — but
    /// every field is checked and anything malformed is dropped.
    struct Command: Equatable {
        enum Start: Equatable {
            case indefinite
            case defaultDuration
            case seconds(Int)
            case until(Date)
        }
        struct Settings: Equatable {
            var displayAwake: Bool?
            var lidClosed: Bool?
            var iconHidden: Bool?
        }
        enum Action: Equatable {
            case start(Start)
            case extend(seconds: Int)
            case stop
            case set(Settings)
            case openSettings
            case watch(Bool)
            case stopCommands
            case quit

            var name: String {
                switch self {
                case .start: "start"
                case .extend: "extend"
                case .stop: "stop"
                case .set: "set"
                case .openSettings: "openSettings"
                case .watch: "watch"
                case .stopCommands: "stopCommands"
                case .quit: "quit"
                }
            }
        }

        let id: String
        let action: Action

        static let minuteRange: ClosedRange<Double> = 1...1440
        static let maxUntil: TimeInterval = 7 * 24 * 3600

        /// The command, or why it was rejected.
        static func parse(_ info: [AnyHashable: Any]?, now: Date = Date()) -> Result<Command, Rejection> {
            guard let info else { return .failure("no userInfo") }
            guard let id = info["id"] as? String, (1...64).contains(id.count) else {
                return .failure("bad id")
            }
            func fail(_ reason: String) -> Result<Command, Rejection> {
                .failure(Rejection(reason: reason, id: id))
            }
            guard let v = number(info["v"]), v == 1 else { return fail("unsupported v") }
            let actionName = info["action"] as? String

            switch actionName {
            case "start":
                var useDefault = false
                if info["default"] != nil {
                    guard let d = bool(info["default"]) else { return fail("bad default") }
                    useDefault = d
                }
                if useDefault {
                    guard info["minutes"] == nil, info["until"] == nil else {
                        return fail("default with minutes/until")
                    }
                    return .success(Command(id: id, action: .start(.defaultDuration)))
                }
                switch (info["minutes"], info["until"]) {
                case (nil, nil):
                    return .success(Command(id: id, action: .start(.indefinite)))
                case (let m?, nil):
                    guard let seconds = minutesToSeconds(m) else { return fail("bad minutes") }
                    return .success(Command(id: id, action: .start(.seconds(seconds))))
                case (nil, let u?):
                    guard let epoch = number(u) else { return fail("bad until") }
                    let until = Date(timeIntervalSince1970: epoch)
                    let lead = until.timeIntervalSince(now)
                    guard lead >= 1, lead <= maxUntil else { return fail("until out of range") }
                    return .success(Command(id: id, action: .start(.until(until))))
                default:
                    return fail("both minutes and until")
                }
            case "extend":
                let seconds = info["minutes"] == nil ? 900 : minutesToSeconds(info["minutes"])
                guard let seconds else { return fail("bad minutes") }
                return .success(Command(id: id, action: .extend(seconds: seconds)))
            case "stop":
                return .success(Command(id: id, action: .stop))
            case "set":
                var settings = Settings()
                for key in ["displayAwake", "lidClosed", "iconHidden"] where info[key] != nil {
                    guard let value = bool(info[key]) else { return fail("bad \(key)") }
                    switch key {
                    case "displayAwake": settings.displayAwake = value
                    case "lidClosed": settings.lidClosed = value
                    default: settings.iconHidden = value
                    }
                }
                guard settings != Settings() else { return fail("set with no settings") }
                return .success(Command(id: id, action: .set(settings)))
            case "openSettings":
                return .success(Command(id: id, action: .openSettings))
            case "watch":
                guard let on = bool(info["on"]) else { return fail("bad on") }
                return .success(Command(id: id, action: .watch(on)))
            case "stopCommands":
                return .success(Command(id: id, action: .stopCommands))
            case "quit":
                return .success(Command(id: id, action: .quit))
            default:
                return fail("unknown action")
            }
        }

        struct Rejection: Error, ExpressibleByStringLiteral {
            var reason: String
            var id: String?
            init(reason: String, id: String?) { self.reason = reason; self.id = id }
            init(stringLiteral reason: String) { self.init(reason: reason, id: nil) }
        }

        /// A real boolean only: an NSNumber 0/1 isn't accepted as a Bool.
        private static func bool(_ value: Any?) -> Bool? {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }

        /// A finite number that isn't a boolean.
        private static func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }

        private static func minutesToSeconds(_ value: Any?) -> Int? {
            guard let m = number(value), minuteRange.contains(m) else { return nil }
            return Int((m * 60).rounded())
        }
    }
}
