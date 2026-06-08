import SwiftUI
import AppKit

/// Entry point. Intercepts headless diagnostic flags, otherwise runs the
/// SwiftUI menu-bar app.
@main
enum AwakeMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        // --help / -h: print usage and exit.
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }
        if args.contains("--dump") {
            MainActor.assumeIsolated { DebugDump.run() }
            return
        }
        if args.contains("--selftest") {
            MainActor.assumeIsolated { DebugDump.selfTest() }
            return
        }
        if let i = args.firstIndex(of: "--icons") {
            guard let path = value(after: i, in: args) else {
                fail("--icons requires a path argument.")
                return
            }
            MainActor.assumeIsolated { DebugDump.renderIcons(to: path) }
            return
        }
        if let i = args.firstIndex(of: "--appicon") {
            guard let dir = value(after: i, in: args) else {
                fail("--appicon requires a directory argument.")
                return
            }
            MainActor.assumeIsolated { DebugDump.renderAppIcon(to: dir) }
            return
        }

        // Any unrecognized "--"-prefixed flag: print usage and exit rather than
        // silently launching the GUI from a terminal.
        let knownValueFlags: Set<String> = ["--icons", "--appicon"]
        for (idx, a) in args.enumerated() where a.hasPrefix("--") {
            // Skip a value that follows a known value-taking flag.
            if idx > 0, knownValueFlags.contains(args[idx - 1]) { continue }
            if !["--dump", "--selftest", "--icons", "--appicon", "--help"].contains(a) {
                FileHandle.standardError.write(Data("Unknown option: \(a)\n".utf8))
                printUsage()
                return
            }
        }

        AwakeApp.main()
    }

    /// The value following a value-taking flag at `index`, or nil when there is no
    /// next token or the next token is itself a flag (starts with "--"). Prevents
    /// silently defaulting to a relative path or consuming a following flag as the
    /// value.
    private static func value(after index: Int, in args: [String]) -> String? {
        let next = index + 1
        guard next < args.count else { return nil }
        let candidate = args[next]
        guard !candidate.hasPrefix("--") else { return nil }
        return candidate
    }

    /// Print an error + usage to stderr and exit non-zero.
    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        printUsage()
        exit(EXIT_FAILURE)
    }

    private static func printUsage() {
        print("""
        Awake — menu-bar caffeination utility

        Usage: Awake [option]

          (no option)        Launch the menu-bar app.
          --dump             Print the classified assertion buckets and exit.
          --selftest         Verify the native caffeination lifecycle and exit.
          --icons <path>     Render all icon states to a PNG at <path>.
          --appicon <dir>    Render an AppIcon.iconset into <dir> and exit.
          --help, -h         Show this help.
        """)
    }
}

struct AwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The model is owned by the app delegate so onLaunch() can run at launch
    // (applicationDidFinishLaunching) rather than waiting for the first menu open.
    private var model: AwakeModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                .onAppear { model.onLaunch() }   // idempotent fallback
        } label: {
            labelImage(state: model.iconState, holders: model.iconHolders)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    /// Menu-bar label icon. Reads prefs colors AND the icon layout *inside* the
    /// label closure's tracking scope so the glyph re-renders when the user
    /// changes a color or the layout in Settings (Observation invalidates the
    /// label on those changes). `holders` drives composition; `state` only the
    /// accessibility label.
    private func labelImage(state: IconState, holders: IconHolders) -> some View {
        Image(nsImage: StatusIconRenderer.image(holders: holders,
                                                palette: model.prefs.iconPalette,
                                                layout: model.prefs.iconLayout,
                                                appsIcon: model.appsSlotIcon))
            .accessibilityLabel(Self.accessibilityLabel(for: state))
    }

    private static func accessibilityLabel(for state: IconState) -> String {
        switch state {
        case .idle:                   return "Awake — idle, your Mac can sleep"
        case .selfOnly, .cliOnly:     return "Awake — you are keeping your Mac awake"
        case .appOnly:                return "Awake — an app is keeping your Mac awake"
        case .selfAndApp, .cliAndApp: return "Awake — you and an app are keeping your Mac awake"
        }
    }
}

/// App delegate: belt-and-suspenders teardown on quit (the kernel also cleans up
/// native holds), and restoring the accessory activation policy when Settings
/// closes so no Dock icon lingers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so setup runs at launch, not on first menu open.
    let model = AwakeModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Guarantee deterministic teardown. Info.plist enables sudden termination,
        // which lets AppKit exit() WITHOUT delivering applicationWillTerminate:, so
        // onQuit() (hotkey/timer/assertion release) might never run. Opt out so the
        // termination notification is always delivered and our explicit teardown
        // contract holds.
        ProcessInfo.processInfo.disableSuddenTermination()

        // Start the hotkey, login-item refresh, refresh timer, and seen-holder
        // recording immediately (onLaunch is idempotent).
        model.onLaunch()

        // When any Settings window closes, drop back to accessory (no Dock icon).
        // NSWindow notifications post on the main thread; the @objc selector
        // receives the Notification on the main actor.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        // The SwiftUI Settings window identifies as "Settings".
        let isSettings = (window.identifier?.rawValue.contains("Settings") ?? false)
            || window.title.localizedCaseInsensitiveContains("settings")
            || window.frameAutosaveName.contains("Settings")
        if isSettings {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.onQuit()
    }
}
