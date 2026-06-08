import AppKit

@MainActor
enum StatusIconRenderer {

    /// Resolved colors for one render pass. A `nil` slot means "render that glyph
    /// as a template" so the OS tints it per menu-bar appearance (keeps the most
    /// common active states legible on BOTH light and dark bars). The app/badge
    /// color is always concrete (it's the distinctive "an app is involved" mark).
    struct Palette {
        var idle: NSColor?        // nil -> adaptive system color (template)
        var selfColor: NSColor?   // nil -> template (default white is invisible on light bars)
        var cli: NSColor?         // nil -> template
        var app: NSColor          // always concrete
    }

    static let pointSize: CGFloat = 15

    // MARK: - Primary entry point (holders + layout)

    /// The menu-bar glyph for the current holders, composed per the layout.
    static func image(holders: IconHolders, palette p: Palette, layout: IconLayout) -> NSImage {
        let order = layout.normalizedPriority

        // Idle: outline primary glyph, adaptive/idle color.
        guard holders.any else {
            let name = layout.primaryGlyph.symbol(active: false)
            if let idle = p.idle { return symbolImage(name, color: idle) }
            return templateSymbol(name)
        }

        // --- Cup slot: tinted by the highest-priority active cup holder. ---
        let cupCat = order.first { $0.isCup && holders.isActive($0) }   // nil if only apps
        let cupActive = holders.cupActive
        let cupColor: NSColor? = {
            switch cupCat {
            case .thisApp: return p.selfColor
            case .you:     return p.cli
            default:       return nil   // no cup holder -> neutral frame
            }
        }()

        // --- Decide which slot is the full-size primary. ---
        let cupIsPrimary: Bool
        if layout.anchorCup {
            // Cup is the anchor unless a LONE app holder is allowed to expand.
            if cupActive { cupIsPrimary = true }
            else { cupIsPrimary = !layout.expandLoneHolder }
        } else {
            // Holder-First: compare priority rank of the cup holder vs apps.
            if cupActive && holders.apps {
                let cupRank = order.firstIndex(of: cupCat ?? .thisApp) ?? Int.max
                let appsRank = order.firstIndex(of: .apps) ?? Int.max
                cupIsPrimary = cupRank < appsRank
            } else {
                cupIsPrimary = cupActive   // whichever single slot is active
            }
        }

        // --- Build primary + (optional) badge marks. ---
        let cupSymbol = layout.primaryGlyph.symbol(active: cupActive)
        let appsBadge = layout.appsShape

        if cupIsPrimary {
            // Cup primary; apps (if active) is the corner badge.
            let primary = Mark(symbol: cupSymbol, color: cupColor, filled: cupActive)
            let badge: BadgeMark? = holders.apps
                ? BadgeMark(symbol: appsBadge.symbol, color: p.app, scale: appsBadge.badgeScale)
                : nil
            return compose(primary: primary, badge: badge, corner: layout.corner)
        } else {
            // Apps primary (full-size shape); cup (if active) is the corner badge.
            let primary = Mark(symbol: appsBadge.symbol, color: p.app, filled: true)
            let badge: BadgeMark? = cupActive
                ? BadgeMark(symbol: layout.primaryGlyph.filled, color: cupColor, scale: 0.50)
                : nil
            return compose(primary: primary, badge: badge, corner: layout.corner)
        }
    }

    /// Back-compat shim for the semantic IconState (used by `--icons` rendering
    /// and anywhere a coarse state is handy). Maps to holders + the Classic
    /// layout so the shipped preview/tooling keeps working.
    static func image(for state: IconState, palette p: Palette) -> NSImage {
        image(holders: holders(for: state), palette: p, layout: IconLayout())
    }

    /// IconState -> the independent holder booleans (Classic precedence baked in:
    /// selfOnly/selfAndApp imply the cup; cliOnly/cliAndApp imply You).
    static func holders(for state: IconState) -> IconHolders {
        switch state {
        case .idle:       return IconHolders()
        case .selfOnly:   return IconHolders(thisApp: true)
        case .cliOnly:    return IconHolders(you: true)
        case .appOnly:    return IconHolders(apps: true)
        case .selfAndApp: return IconHolders(thisApp: true, apps: true)
        case .cliAndApp:  return IconHolders(you: true, apps: true)
        }
    }

    // MARK: - Mark types

    private struct Mark {
        let symbol: String
        let color: NSColor?   // nil -> template
        let filled: Bool      // (informational; symbol already carries fill)
    }

    private struct BadgeMark {
        let symbol: String
        let color: NSColor?
        let scale: CGFloat
    }

    // MARK: - Single-symbol images

    /// Palette-colored, NON-template symbol (the colored states). Falls back to
    /// the coffee cup if the requested symbol isn't available on this OS.
    static func symbolImage(_ name: String,
                            color: NSColor,
                            pointSize: CGFloat = pointSize,
                            weight: NSFont.Weight = .regular) -> NSImage {
        let sizing  = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        let config  = sizing.applying(palette)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Awake status")
            ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Awake status")
        guard let base, let img = base.withSymbolConfiguration(config) else {
            return base ?? NSImage()
        }
        img.isTemplate = false   // keep our color; do not let the menu bar tint it
        return img
    }

    /// Template symbol (idle / nil color) — the menu bar tints it for the current
    /// appearance. Falls back to the cup if the symbol is unavailable.
    static func templateSymbol(_ name: String, pointSize: CGFloat = pointSize) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Awake status")
            ?? NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Awake status")
        guard let base, let img = base.withSymbolConfiguration(config) else {
            return base ?? NSImage()
        }
        img.isTemplate = true
        return img
    }

    private static func glyph(_ name: String, color: NSColor?, pointSize: CGFloat = pointSize) -> NSImage {
        if let color { return symbolImage(name, color: color, pointSize: pointSize) }
        return templateSymbol(name, pointSize: pointSize)
    }

    // MARK: - Compositor (primary + optional corner badge)

    /// Compose a full-size primary mark with an optional corner badge. With no
    /// badge the primary is returned as-is (so it stays a clean template when its
    /// color is nil). With a badge, the result is a pre-tinted composite.
    private static func compose(primary: Mark, badge: BadgeMark?, corner: IconCorner) -> NSImage {
        guard let badge else {
            return glyph(primary.symbol, color: primary.color)
        }

        // Primary cup uses the bar's label color when it has no explicit color, so
        // a non-template composite still reads on both light and dark bars.
        let resolvedPrimary = primary.color ?? labelColorForCurrentAppearance()
        let primaryGlyph = symbolImage(primary.symbol, color: resolvedPrimary)
        let canvas = primaryGlyph.size

        let badgePt = pointSize * badge.scale
        let badgeColor = badge.color ?? labelColorForCurrentAppearance()
        let badgeImg = symbolImage(badge.symbol, color: badgeColor, pointSize: badgePt)
        // Appearance-invariant separation rim under the badge.
        let rimColor = NSColor(white: 0.5, alpha: 1)
        let rim = symbolImage(badge.symbol, color: rimColor, pointSize: badgePt * 1.30)

        let composed = NSImage(size: canvas, flipped: false) { _ in
            primaryGlyph.draw(in: NSRect(origin: .zero, size: canvas),
                              from: .zero, operation: .sourceOver, fraction: 1)
            let ring = max(1, (rim.size.height - badgeImg.size.height) / 2)
            let badgeRect = cornerRect(canvas: canvas, glyph: badgeImg.size, inset: ring, corner: corner)
            let rimRect = NSRect(x: badgeRect.midX - rim.size.width / 2,
                                 y: badgeRect.midY - rim.size.height / 2,
                                 width: rim.size.width, height: rim.size.height)
            rim.draw(in: rimRect, from: .zero, operation: .sourceOver, fraction: 1)
            badgeImg.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        composed.isTemplate = false
        return composed
    }

    /// The effective label color for the menu bar's current appearance, so a
    /// non-template glyph stays legible on light and dark bars.
    private static func labelColorForCurrentAppearance() -> NSColor {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.0, alpha: 1)
    }

    /// Anchor a badge glyph into the chosen corner, flush to the edge minus `inset`.
    private static func cornerRect(canvas: NSSize, glyph: NSSize,
                                   inset: CGFloat, corner: IconCorner) -> NSRect {
        let xRight = canvas.width - glyph.width - inset
        let xLeft  = inset
        let yTop   = canvas.height - glyph.height - inset
        let yBot   = inset
        switch corner {
        case .topRight:    return NSRect(x: xRight, y: yTop, width: glyph.width, height: glyph.height)
        case .topLeft:     return NSRect(x: xLeft,  y: yTop, width: glyph.width, height: glyph.height)
        case .bottomRight: return NSRect(x: xRight, y: yBot, width: glyph.width, height: glyph.height)
        case .bottomLeft:  return NSRect(x: xLeft,  y: yBot, width: glyph.width, height: glyph.height)
        }
    }
}
