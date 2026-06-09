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
    /// A real app icon in the corner is drawn larger than the dot badge and with
    /// no separation rim — it needs the extra size to stay recognizable.
    private static let appCornerIconScale: CGFloat = 0.72
    private static let fixedCorner: IconCorner = .topRight

    // MARK: - Primary entry point (holders + layout)

    /// The menu-bar glyph for the current holders, composed per the layout.
    /// `appsIcon`, when provided, is the real icon of the least-transient app; the
    /// layout's appIconMain / appIconCorner decide whether it's used in the main
    /// or corner position (else a colored dot). One grammar in both focus modes:
    /// a primary mark + a small corner mark tinted by whoever is in the corner.
    static func image(holders: IconHolders, palette p: Palette, layout: IconLayout,
                      appsIcon: NSImage? = nil) -> NSImage {
        nudgedUp(composeImage(holders: holders, palette: p, layout: layout, appsIcon: appsIcon))
    }

    /// Points the finished glyph is raised within the menu bar. We add transparent
    /// space at the BOTTOM of the image; because the bar vertically centers it,
    /// that lifts the visible mark up by ~half this amount.
    private static let verticalNudge: CGFloat = 3

    private static func nudgedUp(_ img: NSImage) -> NSImage {
        guard verticalNudge > 0, img.size.width > 0, img.size.height > 0 else { return img }
        let isTemplate = img.isTemplate
        let out = NSImage(size: NSSize(width: img.size.width, height: img.size.height + verticalNudge),
                          flipped: false) { _ in
            img.draw(in: NSRect(x: 0, y: verticalNudge, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        out.isTemplate = isTemplate
        return out
    }

    private static func composeImage(holders: IconHolders, palette p: Palette, layout: IconLayout,
                                     appsIcon: NSImage? = nil) -> NSImage {
        // Idle: outline cup, adaptive/idle color.
        guard holders.any else {
            if let idle = p.idle { return symbolImage(cupOutline, color: idle) }
            return templateSymbol(cupOutline)
        }

        // Cup slot: tinted by its active holder; This App wins the tie over You.
        let cupActive = holders.cupActive
        let cupColor: NSColor? = holders.thisApp ? p.selfColor : (holders.you ? p.cli : nil)

        // Lone app (an app holds, no cup holder) — the one state `focus` is silent
        // on; `loneApp` decides it.
        if !cupActive {
            switch layout.loneApp {
            case .cupWithDot:
                // Idle OUTLINE cup (never reads as an active filled cup) carrying
                // the app as a small corner mark.
                let primary = Mark(symbol: cupOutline, color: p.idle, filled: false)
                return composeAppCorner(primary: primary, appsIcon: appsIcon,
                                        layout: layout, app: p.app)
            case .appFull:
                return appPrimary(appsIcon: appsIcon, layout: layout, app: p.app, secondary: nil)
            }
        }

        // A cup holder is active (maybe an app too). Focus decides the primary in
        // combined states; pure-cup states are focus-invariant.
        let cupIsPrimary: Bool
        switch layout.focus {
        case .awakeFirst:     cupIsPrimary = true
        case .otherAppsFirst: cupIsPrimary = !holders.apps   // apps win the spotlight
        }

        if cupIsPrimary {
            let primary = Mark(symbol: cupFilled, color: cupColor, filled: true)
            guard holders.apps else { return compose(primary: primary, badge: nil, corner: fixedCorner) }
            // Cup primary; app is the corner mark (dot, or mini icon).
            return composeAppCorner(primary: primary, appsIcon: appsIcon,
                                    layout: layout, app: p.app)
        } else {
            // App primary; the cup holder is the secondary — a corner pip (dot
            // main) or an accent ring (icon main), tinted by the cup holder, or
            // dropped entirely when showSecondary is off.
            let secondary: NSColor? = layout.showSecondary
                ? (cupColor ?? labelColorForCurrentAppearance())
                : nil
            return appPrimary(appsIcon: appsIcon, layout: layout, app: p.app, secondary: secondary)
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
    private static func composeAppIcon(_ icon: NSImage, accentRing: NSColor? = nil,
                                       badge: BadgeMark?, corner: IconCorner) -> NSImage {
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
            // No grey separation border — the app icon sits clean. When a cup
            // holder is also active, frame the icon with a colored ring at the edge
            // — the "you're also holding" mark (frames without occluding it).
            if let accentRing {
                accentRing.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            return true
        }
        iconImage.isTemplate = false
        guard let badge else { return iconImage }
        return overlayBadge(on: iconImage, badge: badge, corner: corner)
    }

    // MARK: - Slot composition (one grammar: primary + optional corner mark)

    /// Render a primary symbol Mark to an opaque (non-template) image, resolving a
    /// nil color to the bar's label color — for composites that carry a corner.
    private static func renderPrimaryGlyph(_ primary: Mark) -> NSImage {
        symbolImage(primary.symbol, color: primary.color ?? labelColorForCurrentAppearance())
    }

    /// A cup (or idle outline cup) primary with the app as the small corner mark:
    /// a colored dot, or — when appIconCorner is on — a mini real-app icon.
    private static func composeAppCorner(primary: Mark, appsIcon: NSImage?,
                                         layout: IconLayout, app: NSColor) -> NSImage {
        if layout.appIconCorner, let appsIcon {
            return overlayIconBadge(on: renderPrimaryGlyph(primary), icon: appsIcon,
                                    scale: appCornerIconScale, corner: fixedCorner)
        }
        let badge = BadgeMark(symbol: appsDot, color: app, scale: badgeScale)
        return compose(primary: primary, badge: badge, corner: fixedCorner)
    }

    /// The app as the full-size primary mark — a colored dot, or its real icon.
    /// `secondary`, when non-nil, is the cup holder's color shown as a corner pip
    /// (dot main) or an accent ring around the icon (icon main).
    private static func appPrimary(appsIcon: NSImage?, layout: IconLayout,
                                   app: NSColor, secondary: NSColor?) -> NSImage {
        // "Show other apps in front" mandates the real app icon as the primary
        // mark — a generic dot defeats the point of foregrounding the app. (Falls
        // back to the dot only if no icon resolves.)
        let useIcon = layout.appIconMain || layout.focus == .otherAppsFirst
        if useIcon, let appsIcon {
            return composeAppIcon(appsIcon, accentRing: secondary, badge: nil, corner: fixedCorner)
        }
        let primary = Mark(symbol: appsDot, color: app, filled: true)
        let badge: BadgeMark? = secondary.map { BadgeMark(symbol: appsDot, color: $0, scale: badgeScale) }
        return compose(primary: primary, badge: badge, corner: fixedCorner)
    }

    /// Like overlayBadge, but the corner mark is a squircle-masked real app icon
    /// (used when appIconCorner is on and the APP occupies the corner).
    private static func overlayIconBadge(on primaryImage: NSImage, icon: NSImage,
                                         scale: CGFloat, corner: IconCorner) -> NSImage {
        let canvas = primaryImage.size
        let badgePt = pointSize * scale
        let iconSize = NSSize(width: badgePt, height: badgePt)
        let composed = NSImage(size: canvas, flipped: false) { _ in
            primaryImage.draw(in: NSRect(origin: .zero, size: canvas),
                              from: .zero, operation: .sourceOver, fraction: 1)
            let iconRect = cornerRect(canvas: canvas, glyph: iconSize,
                                      inset: max(1, badgePt * 0.15), corner: corner)
            let radius = iconRect.width * 0.225
            // No separation rim — the app icon sits clean in the corner.
            let path = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
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
