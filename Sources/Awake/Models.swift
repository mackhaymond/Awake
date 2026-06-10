import Foundation
import Carbon.HIToolbox
import SwiftUI
import AppKit

// MARK: - AssertionType

/// The set of power-assertion types we care about. Raw strings match the
/// IOKit `AssertType` token (e.g. "PreventUserIdleSystemSleep").
enum AssertionType: String, Sendable {
    case preventUserIdleSystemSleep  = "PreventUserIdleSystemSleep"
    case preventSystemSleep          = "PreventSystemSleep"
    case noIdleSleep                 = "NoIdleSleepAssertion"
    case preventUserIdleDisplaySleep = "PreventUserIdleDisplaySleep"
    case noDisplaySleep              = "NoDisplaySleepAssertion"
    case networkClientActive         = "NetworkClientActive"
    case backgroundTask              = "BackgroundTask"
    case applePushServiceTask        = "ApplePushServiceTask"
    case userIsActive                = "UserIsActive"
    case preventDiskIdle             = "PreventDiskIdle"
    case other                       = "_other"

    init(rawType: String) {
        self = AssertionType(rawValue: rawType) ?? .other
    }

    /// True for assertions that actually prevent the *system* from sleeping
    /// (or that we surface as sleep-relevant).
    var blocksSystemSleep: Bool {
        switch self {
        case .preventUserIdleSystemSleep,
             .preventSystemSleep,
             .noIdleSleep,
             .preventUserIdleDisplaySleep,
             .noDisplaySleep,
             .networkClientActive,
             .backgroundTask,
             .applePushServiceTask:
            return true
        case .userIsActive, .preventDiskIdle, .other:
            return false
        }
    }

    /// True for assertions that keep the display awake.
    var blocksDisplaySleep: Bool {
        self == .preventUserIdleDisplaySleep || self == .noDisplaySleep
    }
}

// MARK: - Bucket

enum Bucket: String, CaseIterable, Codable, Sendable {
    case thisApp = "This App"
    case you     = "You"
    case apps    = "Apps"
    case system  = "System"

    var sortOrder: Int {
        switch self {
        case .thisApp: return 0
        case .you:     return 1
        case .apps:    return 2
        case .system:  return 3
        }
    }

    /// Generic SF Symbol shown for a holder in this category when no real app
    /// icon resolves — a per-category fallback so an unresolved holder still
    /// reads as belonging to its bucket instead of a uniform blank placeholder.
    var fallbackSymbol: String {
        switch self {
        case .thisApp: return "bolt.fill"
        case .you:     return "cup.and.saucer.fill"
        case .apps:    return "app.dashed"
        case .system:  return "gearshape"
        }
    }
}

// MARK: - Holder identity (stable keys, used for overrides + seen registry)

/// ALL candidate identity keys for a holder, in precedence order (most stable
/// first). Used so an override / seen-registry entry stored under ANY one of a
/// holder's tokens still matches the same holder on a later refresh even when a
/// different resolution path resolved it (multi-token match).
///
/// Why several keys, not one — the core matching defect this guards against:
/// `AppIdentityResolver`'s
/// layered fallback can resolve the SAME physical holder differently across
/// refreshes — with a live PID it yields a bundleID + executable path, but once
/// the PID dies and the assertion carries no BundlePath / no bundle-id token in
/// its name, bundleID flips to nil and only the process/display name survives.
/// A single bundleID-first key would then flip from `com.foo.bar` to `proc:foo`,
/// silently dropping any override stored under the bundleID. By matching on ANY
/// token we keep the override attached across that transition.
///
/// Precedence (most→least stable):
///  1. `path:` + executablePath — survives PID death whenever the assertion
///     carries a BundlePath (Bundle.executablePath) or the PID is still live;
///     identical whichever of those resolved it, so it's the most stable anchor.
///  2. bundleID (already lowercased) — stable while resolvable.
///  3. `name:` + displayName — survives when only the friendly name is known.
///  4. `proc:` + processName — last-resort, always present.
/// All variants are case-normalized (lowercased) so display-name/process-name
/// casing differences don't yield distinct keys.
func identityKeys(bundleID: String?,
                  executablePath: String?,
                  displayName: String,
                  processName: String) -> [String] {
    var keys: [String] = []
    if let p = executablePath, !p.isEmpty { keys.append("path:" + p.lowercased()) }
    if let b = bundleID, !b.isEmpty { keys.append(b.lowercased()) }
    if !displayName.isEmpty { keys.append("name:" + displayName.lowercased()) }
    if !processName.isEmpty { keys.append("proc:" + processName.lowercased()) }
    if keys.isEmpty { keys.append("proc:") }   // never empty
    return keys
}

/// The canonical (primary) identity key for a holder — the most stable candidate
/// from `identityKeys`. Used as the storage key when WRITING an override / seen
/// entry, and as the row's stable identity. Reads should prefer `matchOverride`
/// (multi-token) so a value stored under any token is still found.
func identityKey(bundleID: String?,
                 executablePath: String? = nil,
                 displayName: String,
                 processName: String) -> String {
    identityKeys(bundleID: bundleID, executablePath: executablePath,
                 displayName: displayName, processName: processName)[0]
}

/// Look up a holder's override across ALL its identity tokens: an
/// override stored under one token (e.g. the bundleID, captured while the PID was
/// live) still matches a later row that only resolves to another token (e.g.
/// `proc:` after the PID died). Returns the first token that has an override.
func matchOverride(_ overrides: [String: Bucket],
                   bundleID: String?,
                   executablePath: String?,
                   displayName: String,
                   processName: String) -> Bucket? {
    guard !overrides.isEmpty else { return nil }
    for key in identityKeys(bundleID: bundleID, executablePath: executablePath,
                            displayName: displayName, processName: processName) {
        if let b = overrides[key] { return b }
    }
    return nil
}

/// A holder Awake has seen, remembered so it can be overridden even when not
/// currently active. Capped (see AppPreferences.recordSeen).
///
/// `bundleID` / `iconPath` are remembered so the Categories view can resolve and
/// show a holder's REAL app icon even after it stops holding sleep (item 3 —
/// "remember icons for previously seen apps"). Both are optional and decoded
/// leniently so registries persisted before this field was added still load.
struct SeenHolder: Codable, Equatable, Sendable {
    var displayName: String
    var lastSeen: Date
    var lastNaturalBucket: Bucket
    var bundleID: String? = nil
    var iconPath: String? = nil
    /// ALL identity tokens this holder resolved to when last seen, so the
    /// Categories view can match an override stored under ANY token
    /// even after the holder goes inactive — mirroring how active rows match.
    /// Optional + defaulted so registries persisted before this field still load.
    var tokens: [String]? = nil
}

/// One holder in a refresh's seen-batch, recorded into the seen registry so it
/// stays overridable (and keeps its icon) after it stops holding sleep.
struct SeenBatchItem: Sendable {
    let key: String
    let displayName: String
    let naturalBucket: Bucket
    let bundleID: String?
    let iconPath: String?
    let tokens: [String]
}

// MARK: - PowerAssertion (source-agnostic snapshot)

struct PowerAssertion: Identifiable, Sendable {
    let id: String
    let ownerPID: Int32
    let ownerProcName: String
    let createdForPID: Int32?
    let isRunningboardd: Bool
    let bundlePath: String?
    let type: AssertionType
    let rawType: String
    let rawName: String
    var details: String?
    var localizedReason: String?
    var timeoutSecsLeft: Int?
    var timeoutAction: String?

    var effectivePID: Int32 { createdForPID ?? ownerPID }
}

// MARK: - AppIdentity

struct AppIdentity: Sendable {
    var displayName: String
    var bundleID: String?
    var iconBundleIDOrPath: String?   // key for NSWorkspace icon lookup
    var executablePath: String?
    var processNameForBucketing: String
}

// MARK: - AssertionRow (handed to the view)

struct AssertionRow: Identifiable, Sendable {
    let id: String
    let bucket: Bucket              // effective bucket (after any manual override)
    let naturalBucket: Bucket      // bucket Awake's automatic sorting chose
    let title: String
    let reason: String
    let bundleID: String?
    let iconBundleID: String?
    let timeoutSecsLeft: Int?
    let isMuted: Bool
    let rawName: String
    let rawType: String
    let ownerPID: Int32            // owning process pid (for targeted actions)
    let isCaffeinate: Bool         // true if this holder is a `caffeinate` process
    let executablePath: String?    // stable identity anchor (survives PID death via BundlePath)
    var sfFallback: String? = nil   // SF Symbol shown when no app icon resolves

    /// Canonical (primary) identity key — the most stable token. Used for storing
    /// an override / seen entry and for de-duplicating rows in the UI.
    var identityKey: String {
        Awake.identityKey(bundleID: bundleID, executablePath: executablePath,
                          displayName: title, processName: rawName)
    }

    /// All identity tokens for this holder, for multi-token override matching:
    /// a stored override under any token still matches the row.
    var identityKeys: [String] {
        Awake.identityKeys(bundleID: bundleID, executablePath: executablePath,
                           displayName: title, processName: rawName)
    }
}

// MARK: - IconState

enum IconState: Sendable, CaseIterable {
    case idle          // !S && !C && !A
    case selfOnly      // S && !A          (precedence: S wins over C)
    case cliOnly       // C && !S && !A
    case appOnly       // A && !S && !C
    case selfAndApp    // S && A           (precedence: S wins over C)
    case cliAndApp     // C && A && !S
}

// MARK: - TimerDuration

enum TimerDuration: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fifteenMin = 900
    case thirtyMin  = 1800
    case oneHour    = 3600
    case twoHours   = 7200
    case fourHours  = 14400
    case eightHours = 28800
    case indefinite = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fifteenMin: return "15 minutes"
        case .thirtyMin:  return "30 minutes"
        case .oneHour:    return "1 hour"
        case .twoHours:   return "2 hours"
        case .fourHours:  return "4 hours"
        case .eightHours: return "8 hours"
        case .indefinite: return "Indefinitely"
        }
    }

    /// nil for `.indefinite`.
    var seconds: Int? {
        self == .indefinite ? nil : rawValue
    }
}

// MARK: - KeyComboStore

struct KeyComboStore: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultsKey = "awake.hotkey"

    static let `default` = KeyComboStore(
        keyCode: UInt32(kVK_ANSI_A),                    // 0
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey) // ⌃⌥⌘ = 256|2048|4096
    )

    static func load() -> KeyComboStore {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let combo = try? JSONDecoder().decode(KeyComboStore.self, from: data)
        else { return .default }
        return combo
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: KeyComboStore.defaultsKey)
        }
    }

    /// e.g. "⌃⌥⌘A" — modifier glyphs + keycode glyph.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += KeyCodeGlyphs.glyph(for: keyCode)
        return s
    }
}

// MARK: - ColorStore

/// Codable, UserDefaults-friendly color: gamma-encoded sRGB RGBA components,
/// stored as JSON so it's legible in `defaults read`. Bridges SwiftUI.Color
/// (for ColorPicker/previews) and NSColor (for the rendered menu-bar glyph).
struct ColorStore: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// SwiftUI.Color -> ColorStore (gamma sRGB).
    @MainActor
    init(_ color: Color) {
        let r = color.resolve(in: EnvironmentValues())
        self.init(red: Double(r.red), green: Double(r.green),
                  blue: Double(r.blue), alpha: Double(r.opacity))
    }

    /// NSColor -> ColorStore (re-tag into sRGB first).
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    /// ColorStore -> NSColor (for the icon renderer).
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green),
                blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// ColorStore -> SwiftUI.Color (for ColorPicker / previews).
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    // MARK: Factory defaults (exact sRGB hex below)
    static let defaultSelf = ColorStore(red: 1.0,      green: 1.0,      blue: 1.0)      // #FFFFFF
    static let defaultCLI  = ColorStore(red: 0x34/255, green: 0xC7/255, blue: 0xC2/255) // #34C7C2 teal
    static let defaultApp  = ColorStore(red: 0xFF/255, green: 0x9F/255, blue: 0x0A/255) // #FF9F0A orange
    static let defaultIdle = ColorStore(red: 0x8E/255, green: 0x8E/255, blue: 0x93/255) // #8E8E93 gray
}

// MARK: - KeyCodeGlyphs

/// keyCode → human glyph table for `displayString`.
enum KeyCodeGlyphs {
    static func glyph(for keyCode: UInt32) -> String {
        if let named = special[Int(keyCode)] { return named }
        if let letter = letters[Int(keyCode)] { return letter }
        if let digit = digits[Int(keyCode)] { return digit }
        return "Key \(keyCode)"
    }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
    ]

    private static let digits: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    private static let special: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_ANSI_Equal: "=",
        kVK_ANSI_Minus: "-",
        kVK_ANSI_Slash: "/",
        kVK_ANSI_Period: ".",
        kVK_ANSI_Comma: ",",
        kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'",
        kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
