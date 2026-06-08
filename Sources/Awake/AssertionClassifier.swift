import Foundation

enum AssertionClassifier {

    private static let systemProcs: Set<String> = [
        "powerd", "WindowServer", "sharingd", "useractivityd",
        "apsd", "bluetoothd", "controlcenter", "loginwindow",
    ]

    private static let knownBrowsers: Set<String> = [
        "Arc", "Google Chrome", "Chrome", "Safari", "Microsoft Edge",
        "Firefox", "Brave Browser", "Opera", "Vivaldi",
    ]

    // MARK: - Public

    /// Result of classifying ONE assertion: the row plus its stable identity key.
    /// `row.naturalBucket` is the automatic bucket; `row.bucket` already reflects
    /// any manual override.
    private struct Classified {
        let key: String
        let row: AssertionRow
    }

    /// Classify a single assertion into its natural bucket, identity and row,
    /// applying any manual override to the EFFECTIVE bucket. No show-system gate —
    /// callers apply that. Returns nil for nothing here (kept for symmetry/future).
    @MainActor
    private static func classify(_ a: PowerAssertion,
                                 ownPID: Int32,
                                 overrides: [String: Bucket]) -> Classified {
        let identity = AppIdentityResolver.identity(for: a)

        let bucket: Bucket
        let title: String
        let reason: String
        let bundleID: String?
        let iconBundleID: String?
        let sfFallback: String?
        // Stable identity anchor (bug #21): survives PID death whenever the
        // assertion carried a BundlePath or the PID was live when resolved.
        // Caffeinate rows are identified by their command line, not an exec path.
        let executablePath: String? = a.ownerProcName == "caffeinate" ? nil : identity.executablePath

        if a.ownerProcName == "caffeinate" {
            // Attribute by WHO started it, via the process ancestry: your
            // manual holds stay under You, while a tool that spawns
            // caffeinate under the hood is credited to that tool under Apps.
            let origin = CaffeinateOrigin.classify(caffeinatePID: a.ownerPID,
                                                   command: identity.displayName)
            bucket = origin.bucket
            title = origin.title
            reason = origin.reason
            bundleID = origin.iconBundleID
            iconBundleID = origin.iconBundleID
            sfFallback = origin.sfFallback
        } else {
            var b = Self.bucket(for: a, ownPID: ownPID,
                                resolvedProcName: identity.processNameForBucketing)
            // Demote OS/daemon plumbing — a bare process with no .app bundle
            // (mds_stores, dataaccessd, nsurlsessiond, cloudd…) — from Apps to
            // System, so the Apps bucket (and the menu-bar icon's "an app is
            // keeping you awake" state) stays reserved for real, user-facing
            // applications (Claude, Arc/WebRTC, ChatGPT, Messages…).
            if b == .apps, identity.bundleID == nil { b = .system }
            bucket = b
            title = identity.displayName
            reason = friendlyReason(for: a, appName: identity.displayName)
            bundleID = identity.bundleID
            iconBundleID = identity.iconBundleIDOrPath
            sfFallback = nil
        }

        // Apply any manual override. `natural` is what the automatic sorting
        // chose; `effective` is what we actually display in. The override is
        // matched across ALL of the holder's identity tokens (bug #21), so a
        // value stored under the bundleID while the PID was live still matches a
        // later row that only resolves to its exec path / proc name once the PID
        // dies — instead of silently reverting to Auto.
        let natural = bucket
        let key = identityKey(bundleID: bundleID, executablePath: executablePath,
                              displayName: title, processName: a.rawName)
        var effective = matchOverride(overrides,
                                      bundleID: bundleID,
                                      executablePath: executablePath,
                                      displayName: title,
                                      processName: a.rawName) ?? natural
        // "This App" is locked (item 1): Awake's OWN hold is always This App and
        // can't be reassigned, and no foreign holder can be moved INTO This App.
        // Enforced here as defense-in-depth even if a stale override slipped
        // through (the Categories picker also won't offer/allow it).
        if natural == .thisApp {
            effective = .thisApp
        } else if effective == .thisApp {
            effective = natural
        }

        let row = AssertionRow(
            id: a.id,
            bucket: effective,
            naturalBucket: natural,
            title: title,
            reason: reason,
            bundleID: bundleID,
            iconBundleID: iconBundleID,
            timeoutSecsLeft: a.timeoutSecsLeft,
            isMuted: effective == .system,
            rawName: a.rawName,
            rawType: a.rawType,
            ownerPID: a.ownerPID,
            isCaffeinate: a.ownerProcName == "caffeinate",
            executablePath: executablePath,
            sfFallback: sfFallback
        )
        return Classified(key: key, row: row)
    }

    @MainActor
    static func rows(from assertions: [PowerAssertion],
                     ownPID: Int32,
                     showSystem: Bool,
                     overrides: [String: Bucket] = [:]) -> [Bucket: [AssertionRow]] {

        var buckets: [Bucket: [AssertionRow]] = [:]
        var seenIDs = Set<String>()

        for a in assertions {
            // Fast path: with NO overrides, a non-blocking holder (which would
            // land in System) can be dropped up-front while "Show system" is off.
            // When overrides exist we must do the full pass so an override OUT of
            // System still surfaces such a holder (gated below on EFFECTIVE bucket).
            if overrides.isEmpty && !a.type.blocksSystemSleep && !showSystem { continue }

            guard !seenIDs.contains(a.id) else { continue }
            seenIDs.insert(a.id)

            let c = classify(a, ownPID: ownPID, overrides: overrides)

            // The show-system gate tests the EFFECTIVE bucket: an override INTO
            // System respects showSystem, and an override OUT OF System reveals a
            // previously-hidden holder.
            if c.row.bucket == .system && !showSystem { continue }

            buckets[c.row.bucket, default: []].append(c.row)
        }

        // Sort within each bucket: timed rows first (shortest remaining), then by title.
        for key in buckets.keys {
            buckets[key]?.sort { lhs, rhs in
                switch (lhs.timeoutSecsLeft, rhs.timeoutSecsLeft) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        }

        return buckets
    }

    /// The seen-holders batch for the FULL classified set, computed BEFORE any
    /// show-system gate (bug #9). refresh() must record seen holders from this —
    /// not from the displayed `rows` buckets — because a holder whose EFFECTIVE
    /// bucket is System while "Show System" is off is dropped from `rows` and so
    /// would never have its lastSeen bumped, aging it out of the registry while
    /// it's actively holding and orphaning its override. Recording here keeps such
    /// holders fresh so their override stays revertable in the Categories UI.
    /// (key, displayName, naturalBucket) per unique assertion id.
    @MainActor
    static func seenBatch(from assertions: [PowerAssertion],
                          ownPID: Int32,
                          overrides: [String: Bucket] = [:])
        -> [SeenBatchItem] {

        var seenIDs = Set<String>()
        var out: [SeenBatchItem] = []
        for a in assertions {
            guard !seenIDs.contains(a.id) else { continue }
            seenIDs.insert(a.id)
            let c = classify(a, ownPID: ownPID, overrides: overrides)
            out.append(SeenBatchItem(key: c.key,
                                     displayName: c.row.title,
                                     naturalBucket: c.row.naturalBucket,
                                     bundleID: c.row.bundleID,
                                     iconPath: c.row.iconBundleID,
                                     tokens: c.row.identityKeys))
        }
        return out
    }

    // MARK: - Bucketing (spec §2.3)

    static func bucket(for a: PowerAssertion, ownPID: Int32, resolvedProcName: String) -> Bucket {
        // 1. THIS APP — our own native IOPMAssertion.
        if a.effectivePID == ownPID
            || a.rawName.hasPrefix(CaffeinationController.namePrefix) {
            return .thisApp
        }

        // 2. YOU (manual caffeinate) — a caffeinate process the user launched.
        if a.ownerProcName == "caffeinate"
            || a.rawName == "caffeinate command-line tool"
            || a.rawName.localizedCaseInsensitiveContains("caffeinate") {
            return .you
        }

        // 3. SYSTEM — Apple power/window/HID/sharing daemons & informational types.
        if !a.type.blocksSystemSleep { return .system }
        if systemProcs.contains(a.ownerProcName) || systemProcs.contains(resolvedProcName) {
            return .system
        }
        if a.rawName.localizedCaseInsensitiveContains("display is on") { return .system }

        // 4. APPS — everything else that blocks sleep.
        return .apps
    }

    // MARK: - Friendly reason (spec §2.4)

    /// A short descriptor of WHY sleep is held, WITHOUT the app name (the row's
    /// title already shows the app/command). e.g. "audio/WebRTC (call)",
    /// "FinishTask", "display is on". Empty for caffeinate (the title is the
    /// command and the countdown carries the time).
    static func friendlyReason(for a: PowerAssertion, appName: String) -> String {
        let haystack = (a.rawName + " " + (a.details ?? "") + " " + (a.localizedReason ?? ""))
            .lowercased()

        // caffeinate CLI (YOU bucket): title is the command, countdown shows time.
        if a.ownerProcName == "caffeinate" || haystack.contains("caffeinate") {
            return ""
        }
        // WebRTC / RTC audio (call).
        if haystack.contains("webrtc") || haystack.contains("rtcaudio") {
            return "audio or video call"
        }
        // Core audio / media device, or browser holding the display.
        if haystack.contains("coreaudio") || haystack.contains("audiodevice") || haystack.contains("ioaudio") {
            return "audio or media"
        }
        if a.type == .preventUserIdleDisplaySleep && knownBrowsers.contains(appName) {
            return "audio or media"
        }
        // Now-playing / media playback.
        if haystack.contains("nowplaying") || haystack.contains("avplayer") || haystack.contains("playing") {
            return "media playback"
        }
        // FinishTask.
        if haystack.contains("finishtask") {
            return "finishing a task"
        }
        // Network / download.
        if haystack.contains("cfnetwork") || haystack.contains("download") || a.type == .networkClientActive {
            return "network activity"
        }
        // Push notifications.
        if a.type == .applePushServiceTask || haystack.contains("apsd") {
            return "push notifications"
        }
        // Display is on.
        if haystack.contains("display is on") {
            return "display is on"
        }
        // Background task.
        if a.type == .backgroundTask || haystack.contains("runningboard") {
            return "background task"
        }
        // Fallback by type.
        if a.type.blocksDisplaySleep { return "keeping display awake" }
        if a.type.blocksSystemSleep { return "keeping system awake" }
        return a.rawType
    }

}
