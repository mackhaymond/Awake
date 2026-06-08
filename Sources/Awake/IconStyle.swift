import Foundation

// MARK: - Icon categories & active-holder set

/// The holder categories the menu-bar icon can represent.
enum IconCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case thisApp = "This App"
    case you     = "You"
    case apps    = "Apps"

    var id: String { rawValue }

    /// This App and You both render in the "cup" slot; Apps is the "shape" slot.
    var isCup: Bool { self != .apps }
}

/// Which categories are actively holding sleep right now — fed to the renderer
/// independent of any display precedence (so the layout, not a baked-in rule,
/// decides what's shown).
struct IconHolders: Sendable, Equatable {
    var thisApp: Bool = false
    var you: Bool = false
    var apps: Bool = false

    var any: Bool { thisApp || you || apps }
    var cupActive: Bool { thisApp || you }

    func isActive(_ c: IconCategory) -> Bool {
        switch c {
        case .thisApp: return thisApp
        case .you:     return you
        case .apps:    return apps
        }
    }
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
            return "Whatever else is keeping your Mac awake becomes the main icon; Awake's cup shrinks to the corner."
        }
    }
}

// MARK: - Layout

/// Menu-bar icon configuration, persisted as JSON in UserDefaults. The cup
/// glyph, the apps dot, and the top-right badge corner are all fixed; the only
/// user choice is `focus`. (Legacy multi-field layouts are migrated to a focus
/// value in AppPreferences.)
struct IconLayout: Codable, Equatable, Sendable {
    var focus: IconFocus = .awakeFirst
}
