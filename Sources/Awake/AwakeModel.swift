import Foundation
import AppKit
import UserNotifications

/// Central coordinator. Owns caffeination, hotkey, login item, timers, and the
/// bucketed assertion snapshot the views render.
@MainActor
@Observable
final class AwakeModel {

    // MARK: - Observable state

    var isActive: Bool = false
    var remaining: TimeInterval?            // nil = indefinite; drives countdown + icon
    /// The preset duration the current hold was started from (15m…8h or
    /// indefinite), so the menu can highlight which duration button is active.
    /// nil for custom / "until time" / extended holds and when idle.
    var activeDuration: TimerDuration?
    var buckets: [Bucket: [AssertionRow]] = [:]

    /// True when the last hotkey registration failed (combo already in use).
    var hotKeyUnavailable: Bool = false

    var prefs = AppPreferences()
    var loginItem = LoginItem()

    var iconState: IconState {
        // Reads post-override buckets, so manual category overrides change which
        // axis (S/C/A) a holder contributes to, and the icon reflects them.
        // S = our own native Awake hold. isActive flips synchronously on toggle;
        // ownNativeHoldPresent is the async IOKit read-back of OUR OWN assertion
        // specifically (NOT any foreign holder a user overrode INTO "This App").
        // OR covers both windows.
        let s = isActive || ownNativeHoldPresent
        // C = a caffeinate the user launched manually (CLI) — the "You" bucket.
        let c = !(buckets[.you]?.isEmpty ?? true)
        // A = a real, user-facing app holding sleep — the "Apps" bucket.
        let a = !(buckets[.apps]?.isEmpty ?? true)

        switch (s, c, a) {
        case (false, false, false): return .idle
        case (true,  _,     false): return .selfOnly      // S precedence over C
        case (false, true,  false): return .cliOnly
        case (false, false, true):  return .appOnly
        case (true,  _,     true):  return .selfAndApp    // S precedence over C
        case (false, true,  true):  return .cliAndApp
        }
    }

    /// The independent active-holder booleans feeding the menu-bar renderer — the
    /// layout (not a baked-in precedence) decides what's shown. Unlike `iconState`
    /// this does NOT collapse self over cli, so a custom priority can pick either.
    var iconHolders: IconHolders {
        IconHolders(
            thisApp: isActive || ownNativeHoldPresent,
            you: !(buckets[.you]?.isEmpty ?? true),
            apps: !(buckets[.apps]?.isEmpty ?? true)
        )
    }

    /// The least-transient (most persistent) app currently holding sleep — the
    /// one whose real icon represents the Apps slot when "Show the app's icon"
    /// is on. An indefinite hold (no kernel timeout) beats any timed one; among
    /// timed holds the longest remaining wins; ties break on the stable
    /// identityKey so the choice doesn't flicker between 1 Hz refreshes.
    /// (Computed fresh — NOT buckets[.apps].first, which is sorted shortest-
    /// remaining-first, i.e. the MOST transient row.)
    var leastTransientAppRow: AssertionRow? {
        (buckets[.apps] ?? []).min { l, r in
            switch (l.timeoutSecsLeft, r.timeoutSecsLeft) {
            case (nil, nil):          return l.identityKey < r.identityKey
            case (nil, _?):           return true     // indefinite precedes timed
            case (_?, nil):           return false
            case let (a?, b?):
                if a != b { return a > b }            // longer remaining precedes
                return l.identityKey < r.identityKey
            }
        }
    }

    /// The resolved icon for the Apps slot when "Show the app's icon" is on,
    /// else nil (→ the renderer draws the colored dot). The guard makes this
    /// cost nothing when the option is off; icon resolution is FIFO-cached in
    /// AppIdentityResolver, so steady state is a dictionary hit (no NSWorkspace
    /// call per render). nil when no app holds or no icon resolves → dot.
    var appsSlotIcon: NSImage? {
        guard prefs.showAppIconForApps, let row = leastTransientAppRow else { return nil }
        return AppIdentityResolver.icon(forBundleID: row.bundleID, path: row.iconBundleID)
    }

    /// True when OUR OWN native IOPMAssertion is present in the latest read-back.
    /// Tests our assertion specifically — a row whose rawName carries our
    /// namePrefix AND whose NATURAL bucket is "This App" — rather than trusting
    /// the post-override buckets[.thisApp], which a user can pollute by overriding
    /// any foreign holder INTO "This App". Scans all buckets, since an override
    /// could also have moved our own row OUT of "This App".
    var ownNativeHoldPresent: Bool {
        for rows in buckets.values {
            for row in rows where row.naturalBucket == .thisApp
                && row.rawName.hasPrefix(CaffeinationController.namePrefix) {
                return true
            }
        }
        return false
    }

    // MARK: - Collaborators

    private let controller = CaffeinationController()
    private var hotKey: GlobalHotKey?
    private var timer: Timer?
    private let ownPID = getpid()
    private var hasLaunched = false

    /// Absolute wall-clock deadline for a timed hold (nil = indefinite / idle).
    /// `remaining` is derived from this each tick so the displayed countdown
    /// tracks the real kernel deadline regardless of timer jitter/coalescing,
    /// instead of drifting by counting ticks.
    private var deadline: Date?

    /// Wall-clock instant the current timed hold ends (nil = indefinite / idle).
    /// Exposed so the menu can show the absolute end time ("Until 3:45 PM")
    /// without re-deriving it from `remaining` each tick.
    var endDate: Date? { deadline }

    // MARK: - Lifecycle

    func onLaunch() {
        guard !hasLaunched else { return }
        hasLaunched = true

        controller.blocksDisplay = prefs.ourHoldBlocksDisplay
        installHotKey(from: prefs.hotKey)
        loginItem.refresh()
        refresh()
        startTicking()   // slow idle cadence to keep the bucket list fresh

        // Opt-in: start a hold immediately on launch (pairs with Launch at Login).
        if prefs.activateOnLaunch && !isActive {
            activate(duration: prefs.defaultDuration)
        }
    }

    func onQuit() {
        controller.invalidate()
        hotKey?.invalidate()
        hotKey = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Caffeination

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(duration: prefs.defaultDuration)
        }
    }

    func activate(duration: TimerDuration) {
        controller.blocksDisplay = prefs.ourHoldBlocksDisplay
        let seconds = duration.seconds
        let reason = duration == .indefinite ? "Manual hold" : "Timed hold (\(duration.label))"
        let ok = controller.activate(reason: reason, seconds: seconds)
        guard ok else { return }

        isActive = true
        activeDuration = duration
        if let seconds {
            remaining = TimeInterval(seconds)
            deadline = Date().addingTimeInterval(TimeInterval(seconds))
        } else {
            remaining = nil
            deadline = nil
        }
        refresh()
        startTicking()
    }

    /// Activate with an arbitrary number of seconds (custom timer from the UI).
    func activateCustom(seconds: Int) {
        controller.blocksDisplay = prefs.ourHoldBlocksDisplay
        guard seconds > 0 else { activate(duration: .indefinite); return }
        let label = seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
        let ok = controller.activate(reason: "Timed hold (\(label))", seconds: seconds)
        guard ok else { return }
        isActive = true
        activeDuration = nil   // custom / "until time" / extended: no preset selected
        remaining = TimeInterval(seconds)
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        refresh()
        startTicking()
    }

    func deactivate() {
        controller.release()
        isActive = false
        activeDuration = nil
        remaining = nil
        deadline = nil
        refresh()
        startTicking()   // drop back to slow cadence
    }

    /// Set the "keep display awake" preference and apply it to any live hold in
    /// ONE place, so the menu toggle and the Settings toggle share a single side
    /// effect (no double re-creation of the assertion when both are on screen).
    func setDisplayHold(_ value: Bool) {
        guard prefs.ourHoldBlocksDisplay != value else { return }
        prefs.ourHoldBlocksDisplay = value
        applyDisplayHoldPreference()
    }

    /// Re-create the live assertion with the current `blocksDisplay` preference.
    /// The display-vs-system assertion TYPE is only chosen at activate() time, so
    /// flipping "Keep the Display Awake" while a hold is active would otherwise
    /// leave the kernel assertion unchanged. Preserves the remaining time
    /// (indefinite stays indefinite; a timed hold keeps its countdown) by
    /// releasing and re-creating with the new type. No-op when idle.
    func applyDisplayHoldPreference() {
        guard isActive else { return }
        controller.blocksDisplay = prefs.ourHoldBlocksDisplay
        if let rem = remaining {
            let seconds = max(1, Int(rem.rounded()))
            // Re-creating via activateCustom() nils activeDuration, but the chosen
            // preset is unchanged here — only the assertion TYPE (display vs system)
            // is swapped — so preserve the duration-button highlight across it.
            let saved = activeDuration
            activateCustom(seconds: seconds)
            activeDuration = saved
        } else {
            activate(duration: .indefinite)
        }
    }

    // MARK: - Hotkey

    func installHotKey(from combo: KeyComboStore) {
        // Register the NEW combo FIRST. Only tear down the old hotkey and swap if
        // the new registration succeeds, so a failed registration (combo already
        // claimed) leaves the previously-working shortcut intact instead of
        // disabling the hotkey entirely.
        let candidate = GlobalHotKey(
            keyCode: combo.keyCode,
            carbonModifiers: combo.carbonModifiers
        ) { [weak self] in
            self?.toggle()
        }
        if let candidate {
            hotKey?.invalidate()
            hotKey = candidate
            hotKeyUnavailable = false
        } else {
            // Keep the existing hotKey in place; just flag the failure.
            hotKeyUnavailable = true
        }
    }

    // MARK: - Reading

    /// True while an off-main read is in flight, so overlapping refresh() calls
    /// (e.g. activate() immediately followed by the next timer tick) coalesce
    /// instead of spawning redundant subprocess reads.
    private var isRefreshing = false

    /// Refresh the bucket snapshot. The blocking I/O — the IOKit/pmset assertion
    /// READ (which may spawn pmset) and the per-PID caffeinate `ps` lookups — runs
    /// OFF the main actor in a detached Task so the run loop (menu/label) never
    /// stalls. Classification, cache seeding, persistence, and reconcile then run
    /// back on the MainActor, so Observation and the identity caches stay free of
    /// data races.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let source: AssertionSource = prefs.usePMSetFallback ? .pmset : .ioKit
        // Snapshot the PIDs already resolved so the off-main pre-warm only spawns
        // `ps` for genuinely new caffeinate PIDs.
        let alreadyCached = AppIdentityResolver.cachedCaffeinatePIDs()

        Task.detached { [weak self] in
            // --- Off the main actor: blocking subprocess + IOKit work. ---
            let assertions = AssertionReader.read(preferring: source)
            let caffeinatePIDs = assertions
                .filter { $0.ownerProcName == "caffeinate" }
                .map { $0.ownerPID }
            let newPIDs = caffeinatePIDs.filter { !alreadyCached.contains($0) }
            let resolvedCommands = AppIdentityResolver.resolveCaffeinateCommands(for: newPIDs)

            // --- Back on the MainActor: classify, persist, assign, reconcile. ---
            await self?.applyRefresh(assertions: assertions,
                                     resolvedCommands: resolvedCommands)
        }
    }

    /// MainActor tail of refresh(): seed caches, classify, persist, assign, and
    /// reconcile from the off-main read result.
    private func applyRefresh(assertions: [PowerAssertion],
                              resolvedCommands: [Int32: String]) {
        defer { isRefreshing = false }

        // Invalidate stale caffeinate-command cache entries (PIDs get reused),
        // then seed the freshly-resolved command lines so classification's
        // synchronous lookups hit the cache (no `ps` on the main actor).
        AppIdentityResolver.pruneCaffeinateCache(
            livePIDs: Set(assertions.map(\.ownerPID))
        )
        AppIdentityResolver.seedCaffeinateCommands(resolvedCommands)

        let newBuckets = AssertionClassifier.rows(
            from: assertions,
            ownPID: ownPID,
            showSystem: prefs.showSystemAssertions,
            overrides: prefs.categoryOverrides
        )

        // Remember every holder we saw (by its NATURAL bucket) so it can be
        // overridden later even when it's no longer active. Built from the FULL
        // classified set (BEFORE the show-system gate), so a holder whose
        // effective bucket is System while "Show System" is off still has its
        // lastSeen bumped and isn't aged out of the registry while active (bug #9).
        // Batched into a single persist instead of one UserDefaults write per tick.
        let seenBatch = AssertionClassifier.seenBatch(
            from: assertions,
            ownPID: ownPID,
            overrides: prefs.categoryOverrides
        )
        prefs.recordSeen(batch: seenBatch)

        buckets = newBuckets

        // Reconcile our own hold against IOKit truth: timed holds auto-release in
        // the kernel, which can leave isActive/remaining stale.
        reconcileSelfHold()
    }

    /// Number of consecutive refreshes where we believed we held sleep but the
    /// IOKit read-back showed no "This App" assertion. Requires two in a row to
    /// avoid the brief async window right after activation.
    private var missingSelfHoldStreak = 0

    /// If we believe we hold sleep but IOKit consistently shows no assertion of
    /// OURS, the kernel auto-released a timed hold — mirror that in our state.
    ///
    /// Truth is `ownNativeHoldPresent` — our OWN assertion (namePrefix +
    /// naturalBucket==.thisApp), never a foreign holder a user overrode INTO
    /// "This App" (bug #1). We only ever auto-release a TIMED hold, because that
    /// is the only kind the kernel auto-releases; an indefinite hold is never
    /// inferred-released from an empty read-back (bug #6) — a transient pmset/IOKit
    /// miss must not tear down a live forever-hold. We also require the read-back
    /// to be non-empty before counting a miss, so a wholesale empty snapshot
    /// (subprocess/parse hiccup) doesn't masquerade as "our hold vanished".
    private func reconcileSelfHold() {
        guard isActive, remaining != nil else { missingSelfHoldStreak = 0; return }
        if ownNativeHoldPresent {
            missingSelfHoldStreak = 0
            return
        }
        // Don't count a miss against a completely empty read-back (a failed/empty
        // snapshot), only against one that returned holders yet not ours.
        let readBackHadHolders = buckets.values.contains { !$0.isEmpty }
        guard readBackHadHolders else { return }
        missingSelfHoldStreak += 1
        if missingSelfHoldStreak >= 2 {
            missingSelfHoldStreak = 0
            controller.release()   // tolerant of an already-gone id
            isActive = false
            activeDuration = nil
            remaining = nil
            deadline = nil
        }
    }

    // MARK: - Timer

    /// 1 Hz while caffeinating (countdown + live list); 5 s while idle.
    private func startTicking() {
        timer?.invalidate()
        let interval: TimeInterval = isActive ? 1.0 : 5.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        refresh()

        guard isActive else { return }

        // Drive the countdown from the absolute deadline, not a per-tick -1, so a
        // late/coalesced/throttled timer fire doesn't make the displayed time-left
        // lag the real kernel deadline.
        if let deadline {
            let rem = deadline.timeIntervalSinceNow
            if rem <= 0 {
                // Kernel will also auto-release; mirror that in UI.
                deactivate()
                if prefs.notifyOnExpiry { Self.notifyExpiry() }
            } else {
                remaining = rem
            }
        }
    }

    // MARK: - Notifications (opt-in, lazy auth)

    /// Post a local notification that the timed session ended. Authorization is
    /// requested lazily here (never at launch).
    private static func notifyExpiry() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Awake session ended"
            content.body = "Your timed session ended. Your Mac can sleep again."
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    // MARK: - Actions

    /// The user's OWN caffeinate holds: rows that are genuinely a `caffeinate`
    /// process (isCaffeinate, fixed at classification) AND whose NATURAL bucket is
    /// "You" — regardless of any manual category override. This is the SINGLE
    /// predicate that drives BOTH the menu's count/enablement AND the kill set, so:
    ///  • the displayed "Stop N" count always equals what actually gets killed
    ///    (bug #10 — a non-caffeinate row overridden INTO You no longer inflates
    ///    the count, and would no-op the kill); and
    ///  • a genuine caffeinate the user re-categorized for display (overridden OUT
    ///    of You into Apps/System) stays killable (bug #11).
    /// Scans all buckets because an override leaves buckets[.you].
    var ownCaffeinateRows: [AssertionRow] {
        var out: [AssertionRow] = []
        for rows in buckets.values {
            for row in rows where row.isCaffeinate && row.naturalBucket == .you {
                out.append(row)
            }
        }
        return out
    }

    @discardableResult
    func killStrayCaffeinate() -> Int {
        // Kill exactly the rows the menu counts (see ownCaffeinateRows).
        let pids = ownCaffeinateRows.map { $0.ownerPID }
        let n = CaffeinationController.terminate(pids: pids)
        refresh()
        return n
    }
}
