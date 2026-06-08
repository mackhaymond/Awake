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

    /// The live assertion id (non-Sendable handle held only on the main actor).
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    /// Whether our hold should also keep the display awake.
    var blocksDisplay: Bool = false

    // MARK: - Activate

    /// Create our assertion. `seconds == nil` → indefinite; otherwise timed
    /// with kernel auto-release. Returns true on success.
    @discardableResult
    func activate(reason: String, seconds: Int?) -> Bool {
        // Release any existing hold first.
        if isActive { release() }

        let typeName = (blocksDisplay
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep) as String
        let name = "\(CaffeinationController.namePrefix): \(reason)" as CFString

        var newID = IOPMAssertionID(0)
        let rc: IOReturn

        if let seconds, seconds > 0 {
            // Timed: IOPMAssertionCreateWithProperties + timeout/auto-release.
            let properties: [String: Any] = [
                kIOPMAssertionTypeKey as String: typeName,
                kIOPMAssertionLevelKey as String: Int(kIOPMAssertionLevelOn),
                kIOPMAssertionNameKey as String: name as String,
                kIOPMAssertionTimeoutKey as String: Double(seconds),
                kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
            ]
            rc = IOPMAssertionCreateWithProperties(properties as CFDictionary, &newID)
        } else {
            // Indefinite.
            rc = IOPMAssertionCreateWithName(
                typeName as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name,
                &newID
            )
        }

        guard rc == kIOReturnSuccess else {
            isActive = false
            return false
        }

        assertionID = newID
        isActive = true
        return true
    }

    // MARK: - Release

    func release() {
        guard isActive else { return }
        // Tolerate an id the kernel already auto-released (timed holds) — treat
        // kIOReturnNotFound / kIOReturnBadArgument as "already gone".
        let rc = IOPMAssertionRelease(assertionID)
        if rc != kIOReturnSuccess
            && rc != kIOReturnNotFound
            && rc != kIOReturnBadArgument {
            // Unexpected failure — still clear our state; the kernel handle is
            // the source of truth and we no longer track it.
        }
        assertionID = IOPMAssertionID(0)
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
