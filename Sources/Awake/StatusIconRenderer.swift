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

    // Fixed marks. The glyph / apps-shape / corner choosers were removed; the
    // icon is always a coffee cup for the cup slot and a dot for the apps slot,
    // with the badge in the top-right corner.
    private static let cupOutline = "cup.and.saucer"
    private static let cupFilled  = "cup.and.saucer.fill"
    private static let appsDot    = "circle.fill"
    private static let badgeScale: CGFloat = 0.50
    private static let fixedCorner: IconCorner = .topRight

    // MARK: - Primary entry point (holders + layout)

    /// The menu-bar glyph for the current holders, composed per the layout's
    /// focus. `appsIcon`, when provided, is the real icon of the least-transient
    /// app and is drawn (squircle-masked) instead of the colored dot WHENEVER
    /// the apps slot is the full-size primary; everywhere it's a small corner
    /// badge it stays the dot. Nil → always the dot (the default).
    static func image(holders: IconHolders, palette p: Palette, layout: IconLayout,
                      appsIcon: NSImage? = nil) -> NSImage {
        // Idle: outline cup, adaptive/idle color.
        guard holders.any else {
            if let idle = p.idle { return symbolImage(cupOutline, color: idle) }
            return templateSymbol(cupOutline)
        }

        // Cup slot: tinted by its active holder; This App wins the tie over You.
        let cupActive = holders.cupActive
        let cupColor: NSColor? = holders.thisApp ? p.selfColor : (holders.you ? p.cli : nil)

        // Which slot is the full-size primary?
        let cupIsPrimary: Bool
        switch layout.focus {
        case .awakeFirst:
            // Cup is the brand mark whenever a cup holder is active. A lone app
            // (no cup holder) expands to the full-size apps mark instead of an
            // empty outline cup + dot (which reads as idle).
            cupIsPrimary = cupActive
        case .otherAppsFirst:
            // Apps take the spotlight when present. LOAD-BEARING: this MUST make
            // apps primary in the combined states, or .otherAppsFirst renders
            // identically to .awakeFirst in every state.
            cupIsPrimary = cupActive && !holders.apps
        }

        if cupIsPrimary {
            // Cup primary; apps (if also holding) is the corner dot.
            let primary = Mark(symbol: cupFilled, color: cupColor, filled: true)
            let badge: BadgeMark? = holders.apps
                ? BadgeMark(symbol: appsDot, color: p.app, scale: badgeScale)
                : nil
            return compose(primary: primary, badge: badge, corner: fixedCorner)
        } else {
            // Apps primary (full-size); cup (if active) becomes the corner badge.
            let cupBadge: BadgeMark? = cupActive
                ? BadgeMark(symbol: cupFilled, color: cupColor, scale: badgeScale)
                : nil
            // Real app icon when supplied + resolvable, else the colored dot.
            if let appsIcon {
                return composeAppIcon(appsIcon, badge: cupBadge, corner: fixedCorner)
            }
            let primary = Mark(symbol: appsDot, color: p.app, filled: true)
            return compose(primary: primary, badge: cupBadge, corner: fixedCorner)
        }
    }

    /// Back-compat shim for the semantic IconState (used by `--icons` rendering
    /// and anywhere a coarse state is handy). Maps to holders + the default
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
        return overlayBadge(on: primaryGlyph, badge: badge, corner: corner)
    }

    /// Draw a corner badge (with its separation rim) over an already-rendered
    /// full-size primary image. Shared by the symbol-primary and app-icon paths.
    private static func overlayBadge(on primaryImage: NSImage, badge: BadgeMark,
                                     corner: IconCorner) -> NSImage {
        let canvas = primaryImage.size
        let badgePt = pointSize * badge.scale
        let badgeColor = badge.color ?? labelColorForCurrentAppearance()
        let badgeImg = symbolImage(badge.symbol, color: badgeColor, pointSize: badgePt)
        // Appearance-invariant separation rim under the badge.
        let rimColor = NSColor(white: 0.5, alpha: 1)
        let rim = symbolImage(badge.symbol, color: rimColor, pointSize: badgePt * 1.30)

        let composed = NSImage(size: canvas, flipped: false) { _ in
            primaryImage.draw(in: NSRect(origin: .zero, size: canvas),
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

    /// Compose a full-size REAL app icon (squircle-masked, full color) as the
    /// primary mark, with an optional corner cup badge. The canvas matches the
    /// symbol states (so the bar baseline / width don't jump), but the icon is
    /// drawn into a centered SQUARE the height of the canvas — the cup symbol's
    /// canvas is ~1.4:1, and filling its full width would stretch a square app
    /// icon into a pill. Retina-safe: drawn via the NSImage block form so the
    /// icon's @2x rep is preserved.
    private static func composeAppIcon(_ icon: NSImage, badge: BadgeMark?,
                                       corner: IconCorner) -> NSImage {
        let canvas = symbolImage(cupFilled, color: .black).size
        let side = canvas.height
        let square = NSRect(x: (canvas.width - side) / 2, y: 0, width: side, height: side)
            .insetBy(dx: 0.5, dy: 0.5)
        let radius = square.width * 0.225   // squircle-ish, matches the app tile
        let iconImage = NSImage(size: canvas, flipped: false) { _ in
            let path = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            icon.draw(in: square, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
            // Subtle separation edge so a dark/busy icon still reads on the bar.
            NSColor(white: 0.5, alpha: 1).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        iconImage.isTemplate = false
        guard let badge else { return iconImage }
        return overlayBadge(on: iconImage, badge: badge, corner: corner)
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
