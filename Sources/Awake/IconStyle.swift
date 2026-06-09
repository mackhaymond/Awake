import Foundation

// MARK: - Active-holder set

/// Which holders are actively keeping the Mac awake right now — fed to the
/// renderer. (`thisApp`/`you` map to the cup slot; `apps` to the dot/icon slot.)
struct IconHolders: Sendable, Equatable {
    var thisApp: Bool = false
    var you: Bool = false
    var apps: Bool = false

    var any: Bool { thisApp || you || apps }
    var cupActive: Bool { thisApp || you }
}

// MARK: - Badge corner (internal — fixed top-right, no longer user-chosen)

enum IconCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft

    var id: String { rawValue }
}

// MARK: - Icon focus (the single user-facing composition choice)

/// What the menu-bar icon emphasizes when more than one thing is keeping the
/// Mac awake — the ONE composition choice exposed in Settings → Appearance.
/// Everything else about the icon (a coffee-cup glyph, a dot for apps, the
/// top-right badge corner) is fixed.
enum IconFocus: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Awake's cup stays the main mark; other apps show as a small corner dot.
    case awakeFirst
    /// The app keeping the Mac awake becomes the main mark; the cup shrinks to
    /// a corner badge.
    case otherAppsFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .awakeFirst:     return "Show Awake in front"
        case .otherAppsFirst: return "Show other apps in front"
        }
    }

    var caption: String {
        switch self {
        case .awakeFirst:
            return "The coffee cup stays the main icon; other apps appear as a small dot in the corner."
        case .otherAppsFirst:
            return "Whatever else is keeping your Mac awake becomes the main icon; Awake shows as a small dot — or a thin ring around the app's icon — in the corner."
        }
    }
}

// MARK: - Lone-app style

/// What the icon shows when ONLY another app is keeping the Mac awake (no cup
/// holder). Either the app stands on its own, or an idle cup carries the app as
/// a small corner mark.
enum LoneAppStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The app is the full-size mark (a dot, or its real icon). Default.
    case appFull
    /// An idle (outline) cup with the app shown as a small corner mark.
    case cupWithDot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appFull:    return "Show the app on its own"
        case .cupWithDot: return "Show a cup with the app in the corner"
        }
    }
}

// MARK: - Layout

/// Menu-bar icon configuration, persisted as JSON in UserDefaults. The cup
/// glyph and the top-right badge corner are fixed; the apps mark is a colored
/// dot unless an app-icon option is on. New fields are Codable WITH defaults so
/// older single-field blobs decode cleanly. (Pre-focus layouts are migrated in
/// AppPreferences.)
struct IconLayout: Codable, Equatable, Sendable {
    /// Which slot is the full-size mark when a cup holder AND an app both hold.
    var focus: IconFocus = .awakeFirst
    /// What to show when ONLY an app holds (no cup holder).
    var loneApp: LoneAppStyle = .appFull
    /// Show the app's real icon (vs a colored dot) when the app is the MAIN mark.
    var appIconMain: Bool = false
    /// Show the app's real icon (vs a colored dot) when the app is the small
    /// CORNER mark. (A real icon at ~8px can be hard to read.)
    var appIconCorner: Bool = false
    /// In apps-first combined states, draw the cup holder as a small corner mark
    /// (a colored dot, or a ring around a real app icon). Off = clean app-only.
    var showSecondary: Bool = true
}
