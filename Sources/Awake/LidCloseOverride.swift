import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import notify
import os

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
///
/// The switch is also powerd's: the kernel bit we set (kClamshellSleepDisablePowerd)
/// is the one powerd writes whenever its own "desktop mode with AC" verdict
/// flips — a display appearing/disappearing (a virtual display counts), a power
/// source change, ~5 s after wake. Its write clears ours silently, and there's
/// no reliable way to read the bit back (`AppleClamshellCausesSleep` goes
/// stale), so while engaged we re-assert: a short burst after each of those
/// triggers, landing after powerd's write, plus a backstop from `engage()`.
/// What this can't cover: powerd clearing the bit while the lid is ALREADY
/// closed (e.g. AC or an external display unplugged in clamshell mode) — the
/// kernel re-evaluates on that write and sleeps before we can answer.
@MainActor
final class LidCloseOverride {

    private(set) var isEngaged = false
    private var watchdog: Process?

    private static let engagedKey = "awake.lidOverrideEngaged"
    private static let log = Logger(subsystem: "com.mackhaymond.Awake", category: "lid")

    /// The kernel switch. Injectable so --selftest can play powerd.
    private let setDisabled: (Bool) -> Bool
    /// The watchdog and the persisted flag; off only for a fake kernel.
    private let guardsCrashes: Bool
    /// Backstop: `engage()` while engaged re-asserts at most this often.
    private let reassertInterval: TimeInterval
    /// Re-asserts after a trigger. powerd writes ~0.3 s after a display or
    /// power change and ~5 s after wake (kClamshellEvaluateDelay).
    private let burstDelays: [TimeInterval]

    private var lastAsserted: Date?
    private var burst = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerToken: Int32 = NOTIFY_TOKEN_INVALID

    init(setDisabled: @escaping (Bool) -> Bool = LidCloseOverride.setClamshellSleepDisabled,
         guardsCrashes: Bool = true,
         reassertInterval: TimeInterval = 5,
         burstDelays: [TimeInterval] = [1, 3, 6, 10]) {
        self.setDisabled = setDisabled
        self.guardsCrashes = guardsCrashes
        self.reassertInterval = reassertInterval
        self.burstDelays = burstDelays
    }

    /// Turn clamshell sleep off and arm the watchdog. Idempotent, except that
    /// while engaged it re-asserts the switch every `reassertInterval` (powerd
    /// may have cleared it). Returns false if the kernel refused, in which case
    /// nothing is left engaged.
    @discardableResult
    func engage(now: Date = Date()) -> Bool {
        // A dead watchdog means the switch may have been reset under us (the
        // watchdog resets on SIGTERM, e.g. `killall Awake`) and nothing guards
        // it — re-assert both.
        if isEngaged, guardsCrashes, watchdog?.isRunning != true {
            isEngaged = false
            watchdog = nil
        }
        if isEngaged {
            if lastAsserted.map({ now.timeIntervalSince($0) >= reassertInterval }) ?? true {
                reassert(now: now)
            }
            return true
        }
        guard setDisabled(true) else {
            stopWatching()   // left armed if this was a dead-watchdog re-engage
            return false
        }
        isEngaged = true
        lastAsserted = now
        if guardsCrashes {
            UserDefaults.standard.set(true, forKey: Self.engagedKey)
            startWatchdog()
        }
        startWatching()
        return true
    }

    /// Restore clamshell sleep and stand the watchdog down. Idempotent.
    func disengage() {
        guard isEngaged else { return }
        stopWatching()
        _ = setDisabled(false)
        isEngaged = false
        lastAsserted = nil
        if guardsCrashes { UserDefaults.standard.set(false, forKey: Self.engagedKey) }
        // SIGUSR1 is the stand-down signal: its default action exits WITHOUT a
        // reset, so stopping the watchdog can't race a later engage(). Any other
        // signal makes it reset (see runWatchdog).
        if let pid = watchdogPID { kill(pid, SIGUSR1) }
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

    // MARK: - Re-asserting over powerd

    /// Something that makes powerd re-evaluate happened: re-assert a few times
    /// over the next seconds, after its write lands. A newer trigger supersedes
    /// the rest of an older burst.
    func systemChanged(_ reason: String) {
        guard isEngaged else { return }
        Self.log.notice("re-asserting after \(reason, privacy: .public)")
        burst += 1
        let current = burst
        for delay in burstDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.burst == current else { return }
                    self.reassert(now: Date())
                }
            }
        }
    }

    private func reassert(now: Date) {
        guard isEngaged else { return }
        if setDisabled(true) {
            lastAsserted = now
        } else {
            Self.log.error("re-assert refused by the kernel")
        }
    }

    /// The triggers powerd evaluates clamshell sleep on, as far as we can see
    /// them: display set changes (powerd's "DesktopMode update"), display and
    /// system wake, and power source changes.
    private func startWatching() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let watched: [(NotificationCenter, Notification.Name, String)] = [
            (.default, NSApplication.didChangeScreenParametersNotification, "display change"),
            (workspace, NSWorkspace.screensDidSleepNotification, "display sleep"),
            (workspace, NSWorkspace.screensDidWakeNotification, "display wake"),
            (workspace, NSWorkspace.didWakeNotification, "system wake"),
        ]
        for (center, name, reason) in watched {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemChanged(reason) }
            }
            observers.append((center, token))
        }
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemChanged("power source change") }
        }
    }

    private func stopWatching() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if powerToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(powerToken)
            powerToken = NOTIFY_TOKEN_INVALID
        }
        burst += 1   // drop any pending re-asserts
    }

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
    ///
    /// The watchdog shares the app's process name, so `killall Awake` /
    /// `pkill -x Awake` signal both at once — SIGTERM, SIGINT and SIGHUP
    /// therefore reset before exiting, same as the parent dying. Only SIGUSR1
    /// (disengage()'s stand-down) exits without a reset.
    nonisolated static func runWatchdog(parent: pid_t) -> Never {
        func resetAndExit() -> Never {
            _ = setClamshellSleepDisabled(false)
            exit(EXIT_SUCCESS)
        }

        var sources: [DispatchSourceProtocol] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // deliver via the dispatch source instead
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { resetAndExit() }
            s.resume()
            sources.append(s)
        }

        let exitSource = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { resetAndExit() }
        exitSource.resume()
        sources.append(exitSource)

        // The parent may already be gone before the source was armed.
        if kill(parent, 0) != 0 && errno == ESRCH { resetAndExit() }
        withExtendedLifetime(sources) { dispatchMain() }
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
