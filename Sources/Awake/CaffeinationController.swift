import Foundation
import IOKit
import IOKit.pwr_mgt

/// Owns this app's native IOPMAssertion (indefinite or timed) and the
/// "kill stray caffeinate" action.
@MainActor
final class CaffeinationController {

    /// Must equal CFBundleIdentifier so our holds are self-detectable. Derived
    /// at runtime so self-detection stays correct even if a forker changes the
    /// bundle id. Falls back to the shipping reverse-DNS bundle id (NOT the plain
    /// word "Awake") when run unbundled (raw SPM binary used for --appicon /
    /// --dump / --selftest), so the fallback prefix stays unique and a third-party
    /// assertion merely named "Awake…" isn't misclassified as "This App".
    nonisolated static let namePrefix = Bundle.main.bundleIdentifier ?? "com.mackhaymond.Awake"

    private(set) var isActive: Bool = false

    /// The live assertion ids (non-Sendable handles held only on the main actor).
    private var assertionIDs: [IOPMAssertionID] = []

    /// Whether our hold should also keep the display awake.
    var blocksDisplay: Bool = false

    // MARK: - Activate

    /// Create our hold. `seconds == nil` → indefinite; otherwise timed with
    /// kernel auto-release. Returns true on success.
    ///
    /// A hold is TWO assertions sharing one name and timeout:
    /// - an idle assertion (display or system, per `blocksDisplay`), which is
    ///   what keeps the Mac and optionally the screen up on battery;
    /// - `PreventSystemSleep`, which is the only type powerd honors across a lid
    ///   close / maintenance sleep. The PreventUserIdle* types block idle sleep
    ///   only, so without it a closed lid slept the Mac mid-hold. Apple scopes it
    ///   to AC power, so on battery a closed lid still sleeps.
    /// The idle assertion is required; PreventSystemSleep is best-effort so a
    /// failure there never costs the user the hold itself.
    @discardableResult
    func activate(reason: String, seconds: Int?) -> Bool {
        // Release any existing hold first.
        if isActive { release() }

        let idleType = (blocksDisplay
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep) as String
        let name = "\(CaffeinationController.namePrefix): \(reason)"

        guard let idleID = Self.create(type: idleType, name: name, seconds: seconds) else {
            isActive = false
            return false
        }
        assertionIDs = [idleID]
        if let systemID = Self.create(type: kIOPMAssertionTypePreventSystemSleep as String,
                                      name: name, seconds: seconds) {
            assertionIDs.append(systemID)
        }
        isActive = true
        return true
    }

    /// Create one assertion; nil on failure.
    private static func create(type: String, name: String, seconds: Int?) -> IOPMAssertionID? {
        var newID = IOPMAssertionID(0)
        let rc: IOReturn

        if let seconds, seconds > 0 {
            // Timed: IOPMAssertionCreateWithProperties + timeout/auto-release.
            let properties: [String: Any] = [
                kIOPMAssertionTypeKey as String: type,
                kIOPMAssertionLevelKey as String: Int(kIOPMAssertionLevelOn),
                kIOPMAssertionNameKey as String: name,
                kIOPMAssertionTimeoutKey as String: Double(seconds),
                kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
            ]
            rc = IOPMAssertionCreateWithProperties(properties as CFDictionary, &newID)
        } else {
            // Indefinite.
            rc = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &newID
            )
        }
        return rc == kIOReturnSuccess ? newID : nil
    }

    // MARK: - Release

    func release() {
        guard isActive else { return }
        // Tolerate an id the kernel already auto-released (timed holds) — treat
        // kIOReturnNotFound / kIOReturnBadArgument as "already gone". Any other
        // failure still clears our state; the kernel handle is the source of
        // truth and we no longer track it.
        for id in assertionIDs {
            _ = IOPMAssertionRelease(id)
        }
        assertionIDs = []
        isActive = false
    }

    /// Release on quit. Done explicitly here (NOT in deinit — the handle is
    /// non-Sendable and deinit isn't main-actor-isolated).
    func invalidate() {
        release()
    }

    // MARK: - Terminate caffeinate processes

    /// SIGTERM the given caffeinate PIDs. The caller (AwakeModel.killStray-
    /// Caffeinate via ownCaffeinateRows) passes the PIDs of the user's OWN
    /// caffeinate holds — rows where isCaffeinate && naturalBucket == .you,
    /// regardless of any manual category override — which is the SAME predicate
    /// the menu uses for its "Stop N" count and enablement. So the count shown and
    /// what actually gets signalled are always identical. Returns the number
    /// signalled.
    @discardableResult
    static func terminate(pids: [pid_t]) -> Int {
        var killed = 0
        for pid in pids where pid > 0 {
            if kill(pid, SIGTERM) == 0 { killed += 1 }
        }
        return killed
    }
}
