import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Keeps the Mac running with the lid closed — on battery too — by turning off
/// the kernel's clamshell sleep, the same switch Amphetamine's closed-display
/// mode flips. Assertions can't do this: PreventSystemSleep covers a lid close
/// on AC only.
///
/// The switch is kernel state that OUTLIVES this process (verified: closing the
/// IOKit connection or exiting does not reset it), so a crash while engaged
/// would leave the Mac unable to sleep on lid close until reboot. Three layers
/// guard against that:
/// - normal teardown: `disengage()` on hold end and on quit;
/// - a watchdog child (this same binary run as `--lid-watchdog <pid>`) that
///   resets the switch when Awake exits for any reason, SIGKILL included;
/// - a persisted flag, so the next launch resets a switch left on when both
///   processes died together.
@MainActor
final class LidCloseOverride {

    private(set) var isEngaged = false
    private var watchdog: Process?

    private static let engagedKey = "awake.lidOverrideEngaged"

    /// Turn clamshell sleep off and arm the watchdog. Idempotent. Returns false
    /// if the kernel refused, in which case nothing is left engaged.
    @discardableResult
    func engage() -> Bool {
        guard !isEngaged else { return true }
        guard Self.setClamshellSleepDisabled(true) else { return false }
        isEngaged = true
        UserDefaults.standard.set(true, forKey: Self.engagedKey)
        startWatchdog()
        return true
    }

    /// Restore clamshell sleep and stand the watchdog down. Idempotent.
    func disengage() {
        guard isEngaged else { return }
        _ = Self.setClamshellSleepDisabled(false)
        isEngaged = false
        UserDefaults.standard.set(false, forKey: Self.engagedKey)
        // SIGTERM: the watchdog only resets on its PARENT's exit, so stopping it
        // can't race a later engage().
        watchdog?.terminate()
        watchdog = nil
    }

    /// Launch-time cleanup: reset a switch a previous run left on. Keyed on our
    /// own flag so another tool's override (e.g. Amphetamine) is left alone.
    static func resetIfLeftEngaged() {
        guard UserDefaults.standard.bool(forKey: engagedKey) else { return }
        _ = setClamshellSleepDisabled(false)
        UserDefaults.standard.set(false, forKey: engagedKey)
    }

    var watchdogPID: pid_t? { watchdog?.isRunning == true ? watchdog?.processIdentifier : nil }

    private func startWatchdog() {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--lid-watchdog", String(getpid())]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            watchdog = p
        } catch {
            watchdog = nil   // the launch-time reset still covers a crash
        }
    }

    // MARK: - Kernel switch

    /// `kPMSetClamshellSleepState` (IOPMLibDefs.h) on the IOPMrootDomain user
    /// client. No root required. The kernel logs each change as
    /// `PMRD: setClamShellSleepDisable(old->new)`.
    nonisolated static func setClamshellSleepDisabled(_ disabled: Bool) -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(root, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return false }
        defer { IOServiceClose(connection) }

        var input: [UInt64] = [disabled ? 1 : 0]
        var outputCount: UInt32 = 0
        let rc = IOConnectCallScalarMethod(connection, UInt32(kPMSetClamshellSleepState),
                                           &input, 1, nil, &outputCount)
        return rc == kIOReturnSuccess
    }

    // MARK: - Watchdog mode

    /// Entry point for `Awake --lid-watchdog <pid>`: block until `pid` exits,
    /// reset clamshell sleep, exit. Never returns.
    nonisolated static func runWatchdog(parent: pid_t) -> Never {
        // Outlive the parent's terminal/process group; only SIGTERM (a clean
        // stand-down from disengage()) should stop us without a reset.
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            _ = setClamshellSleepDisabled(false)
            exit(EXIT_SUCCESS)
        }
        source.resume()

        // The parent may already be gone before the source was armed.
        if kill(parent, 0) != 0 && errno == ESRCH {
            _ = setClamshellSleepDisabled(false)
            exit(EXIT_SUCCESS)
        }
        dispatchMain()
    }
}

/// Snapshot of the providing power source, for the lid override's battery floor.
struct PowerStatus {
    var onAC: Bool
    /// Internal battery charge 0–100, or nil when there's no battery (desktops).
    var batteryPercent: Int?

    static func current() -> PowerStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerStatus(onAC: true, batteryPercent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing != kIOPSBatteryPowerValue

        var percent: Int?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            percent = current * 100 / max
        }
        return PowerStatus(onAC: onAC, batteryPercent: percent)
    }
}
