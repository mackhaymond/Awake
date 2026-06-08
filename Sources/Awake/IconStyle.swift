import Foundation

// MARK: - Icon categories & active-holder set

/// The holder categories the menu-bar icon can represent. Ordering in
/// `IconLayout.priority` decides cup-tint precedence and which slot wins the
/// full-size primary position.
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

// MARK: - Primary glyph (themed)

/// The main mark used for the cup slot (This App / You) and the idle state.
/// Each maps to an SF Symbol pair: an outline for idle/frame use and a filled
/// variant when a holder is active. The renderer falls back to the cup if a
/// symbol isn't available on the running OS.
enum PrimaryGlyph: String, Codable, CaseIterable, Sendable, Identifiable {
    case cup, mug, espresso, bolt, eye, sun

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cup:      return "Coffee Cup"
        case .mug:      return "Mug"
        case .espresso: return "Hot Cup"
        case .bolt:     return "Bolt"
        case .eye:      return "Eye"
        case .sun:      return "Sun"
        }
    }

    var outline: String {
        switch self {
        case .cup:      return "cup.and.saucer"
        case .mug:      return "mug"
        case .espresso: return "cup.and.heat.waves"
        case .bolt:     return "bolt"
        case .eye:      return "eye"
        case .sun:      return "sun.max"
        }
    }

    var filled: String {
        switch self {
        case .cup:      return "cup.and.saucer.fill"
        case .mug:      return "mug.fill"
        case .espresso: return "cup.and.heat.waves.fill"
        case .bolt:     return "bolt.fill"
        case .eye:      return "eye.fill"
        case .sun:      return "sun.max.fill"
        }
    }

    func symbol(active: Bool) -> String { active ? filled : outline }
}

// MARK: - Badge / apps shape

/// The shape used for the apps indicator (a corner badge, or full-size when the
/// apps slot is primary). Also used for a small cup badge when a cup holder is
/// secondary.
enum BadgeShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case dot, disc, ring, triangle, square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dot:      return "Dot"
        case .disc:     return "Disc"
        case .ring:     return "Ring"
        case .triangle: return "Triangle"
        case .square:   return "Square"
        }
    }

    var symbol: String {
        switch self {
        case .dot, .disc: return "circle.fill"
        case .ring:       return "circle"
        case .triangle:   return "triangle.fill"
        case .square:     return "square.fill"
        }
    }

    /// Badge diameter as a fraction of the primary point size.
    var badgeScale: CGFloat {
        switch self {
        case .dot:      return 0.50
        case .disc:     return 0.62
        case .ring:     return 0.58
        case .triangle: return 0.64
        case .square:   return 0.54
        }
    }
}

// MARK: - Corner

enum IconCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case topRight, topLeft, bottomRight, bottomLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topRight:    return "Top Right"
        case .topLeft:     return "Top Left"
        case .bottomRight: return "Bottom Right"
        case .bottomLeft:  return "Bottom Left"
        }
    }
}

// MARK: - Composition preset

enum CompositionPreset: String, CaseIterable, Identifiable {
    case classic, expandLoneApp, holderFirst, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:       return "Classic"
        case .expandLoneApp: return "Expand Lone App"
        case .holderFirst:   return "Holder-First"
        case .custom:        return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .classic:       return "Cup is always the main mark; apps show as a corner badge."
        case .expandLoneApp: return "Like Classic, but when only an app is holding it goes full-size."
        case .holderFirst:   return "The highest-priority active holder becomes the full-size mark."
        case .custom:        return "Tune priority, lone-holder expansion, and badge corner yourself."
        }
    }
}

// MARK: - Layout

/// Full menu-bar icon configuration. Persisted as JSON in UserDefaults.
///
/// Two-slot model: a CUP slot (This App / You, tinted by `priority`) and an
/// APPS slot (`appsShape`). `anchorCup` + `expandLoneHolder` + `priority` decide
/// which slot is the full-size primary and which is the corner badge.
struct IconLayout: Codable, Equatable, Sendable {
    var primaryGlyph: PrimaryGlyph = .cup
    var appsShape: BadgeShape = .dot
    /// When true the cup slot is always the primary mark (apps badge onto it).
    /// When false the highest-priority active holder wins the primary slot.
    var anchorCup: Bool = true
    /// Anchored-only: a lone apps holder (no cup holder) expands to full size
    /// instead of showing an empty cup frame + badge.
    var expandLoneHolder: Bool = false
    /// Precedence order across categories. Decides cup tint when both This App &
    /// You hold, and (in Holder-First) which slot is primary.
    var priority: [IconCategory] = [.thisApp, .you, .apps]
    var corner: IconCorner = .topRight

    /// All categories present exactly once, in the stored order, missing ones
    /// appended in canonical order — so a malformed/partial array still works.
    var normalizedPriority: [IconCategory] {
        var seen = Set<IconCategory>()
        var out: [IconCategory] = []
        for c in priority where !seen.contains(c) { seen.insert(c); out.append(c) }
        for c in IconCategory.allCases where !seen.contains(c) { out.append(c) }
        return out
    }

    /// The preset the current knobs correspond to (for the settings selector).
    var preset: CompositionPreset {
        let defaultOrder = priority == [.thisApp, .you, .apps]
        let defaultCorner = corner == .topRight
        if anchorCup && !expandLoneHolder && defaultOrder && defaultCorner { return .classic }
        if anchorCup && expandLoneHolder && defaultOrder && defaultCorner { return .expandLoneApp }
        if !anchorCup && defaultOrder && defaultCorner { return .holderFirst }
        return .custom
    }

    /// Apply a preset's knob bundle (Custom leaves knobs as-is).
    mutating func apply(preset: CompositionPreset) {
        switch preset {
        case .classic:
            anchorCup = true;  expandLoneHolder = false
            priority = [.thisApp, .you, .apps]; corner = .topRight
        case .expandLoneApp:
            anchorCup = true;  expandLoneHolder = true
            priority = [.thisApp, .you, .apps]; corner = .topRight
        case .holderFirst:
            anchorCup = false; expandLoneHolder = false
            priority = [.thisApp, .you, .apps]; corner = .topRight
        case .custom:
            break
        }
    }
}
