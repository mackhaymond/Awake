import Foundation
import AppKit

/// Headless diagnostics that run without the menu-bar UI:
///   `Awake --dump`     — print the classified assertion buckets and exit.
///   `Awake --selftest` — exercise the native caffeination lifecycle and exit.
enum DebugDump {

    @MainActor
    static func run() {
        let pid = ProcessInfo.processInfo.processIdentifier
        dump(assertions: AssertionReader.read(), ownPID: pid)
    }

    @MainActor
    private static func dump(assertions: [PowerAssertion], ownPID: Int32) {
        // Mirror the running app: apply the user's saved category overrides.
        let overrides = AppPreferences().categoryOverrides
        let buckets = AssertionClassifier.rows(from: assertions, ownPID: ownPID,
                                               showSystem: true, overrides: overrides)
        print("Awake — assertion dump (\(assertions.count) raw assertions)\n")
        for bucket in Bucket.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let rows = buckets[bucket] ?? []
            print("== \(bucket.rawValue) (\(rows.count)) ==")
            for r in rows {
                var detail = r.reason
                if let left = r.timeoutSecsLeft, left > 0 {
                    detail = detail.isEmpty ? "\(left)s left" : "\(detail) · \(left)s left"
                }
                print("  • \(r.title)\(detail.isEmpty ? "" : " — \(detail)")")
            }
            print("")
        }
    }

    /// Verifies that our native IOPMAssertion is created, is visible + classified
    /// as "This App", and is fully released (no leaked hold) afterwards.
    @MainActor
    static func selfTest() {
        let pid = getpid()
        let controller = CaffeinationController()

        func ourHolds() -> [PowerAssertion] {
            AssertionReader.read().filter {
                $0.rawName.hasPrefix(CaffeinationController.namePrefix)
            }
        }

        print("Awake — caffeination self-test (pid \(pid))\n")
        print("before: our assertions = \(ourHolds().count)")

        let ok = controller.activate(reason: "self-test", seconds: nil)
        print("activate(indefinite) ok=\(ok) controller.isActive=\(controller.isActive)")

        let held = ourHolds()
        print("during: our assertions = \(held.count)")
        for h in held { print("  - \"\(h.rawName)\" type=\(h.rawType) ownerPID=\(h.ownerPID)") }

        let buckets = AssertionClassifier.rows(from: AssertionReader.read(), ownPID: pid, showSystem: true)
        print("This App bucket: \((buckets[.thisApp] ?? []).map(\.title))")

        controller.release()
        print("release() controller.isActive=\(controller.isActive)")
        let after = ourHolds().count
        print("after: our assertions = \(after)")

        let passed = ok && !held.isEmpty && !(buckets[.thisApp] ?? []).isEmpty && after == 0
        print("\nSELF-TEST: \(passed ? "PASS ✅" : "FAIL ❌")")
    }

    /// Renders all 6 icon states (shipped default palette) onto dark + light
    /// rows and writes a PNG — verifies the real renderer incl. badge compositing.
    /// Render representative holder combinations across the live + a few alternate
    /// layouts onto a dark sheet — verifies the real compositor (primary glyph,
    /// apps shape, expand/holder-first, badge corner) end to end.
    @MainActor
    static func renderIcons(to path: String) {
        let palette = AppPreferences().iconPalette
        let combos: [(String, IconHolders)] = [
            ("idle", IconHolders()),
            ("self", IconHolders(thisApp: true)),
            ("you", IconHolders(you: true)),
            ("app", IconHolders(apps: true)),
            ("self+app", IconHolders(thisApp: true, apps: true)),
            ("you+app", IconHolders(you: true, apps: true)),
            ("all", IconHolders(thisApp: true, you: true, apps: true)),
        ]
        // The user's saved layout first, then a spread of alternates as a sanity sheet.
        var expandTri = IconLayout(); expandTri.expandLoneHolder = true; expandTri.appsShape = .triangle
        var holderTri = IconLayout(); holderTri.anchorCup = false; holderTri.appsShape = .triangle
        var appsFirst = IconLayout(); appsFirst.anchorCup = false; appsFirst.appsShape = .square
        appsFirst.priority = [.apps, .thisApp, .you]
        var boltDisc = IconLayout(); boltDisc.primaryGlyph = .bolt; boltDisc.appsShape = .disc
        let layouts: [(String, IconLayout)] = [
            ("Saved", AppPreferences().iconLayout),
            ("Expand+Tri", expandTri),
            ("HolderFirst+Tri", holderTri),
            ("AppsFirst+Sq", appsFirst),
            ("Bolt+Disc", boltDisc),
        ]
        let cell = 56, pad = 16, labelW = 130
        let w = labelW + combos.count * (cell + pad) + pad
        let rowH = cell + pad
        let h = rowH * layouts.count + pad
        let canvas = NSImage(size: NSSize(width: w, height: h))
        canvas.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        let dark = NSAppearance(named: .darkAqua)!
        for (r, layout) in layouts.enumerated() {
            let y = CGFloat(h - pad - (r + 1) * rowH)
            (layout.0 as NSString).draw(at: NSPoint(x: 8, y: y + CGFloat(cell) / 2 - 6),
                withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])
            for (c, combo) in combos.enumerated() {
                let x = CGFloat(labelW + pad + c * (cell + pad))
                var img = NSImage()
                dark.performAsCurrentDrawingAppearance {
                    img = StatusIconRenderer.image(holders: combo.1, palette: palette, layout: layout.1)
                }
                draw(img, in: NSRect(x: x, y: y, width: CGFloat(cell), height: CGFloat(cell)), templateTint: .white)
            }
        }
        canvas.unlockFocus()
        if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)  (cols: \(combos.map(\.0).joined(separator: ", ")))")
        }
    }

    // MARK: - App icon generation (.iconset)

    /// Render the filled-cup glyph on a rounded-rect ("squircle") app tile at the
    /// 10 standard sizes into an `AppIcon.iconset/` directory (build.sh then runs
    /// `iconutil` to produce AppIcon.icns). The cup silhouette matches the menu-
    /// bar glyph (same SF Symbol) for brand continuity.
    @MainActor
    static func renderAppIcon(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // (logical points, scale) -> file name, per Apple's AppIcon.iconset spec.
        let specs: [(pt: Int, scale: Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
        ]

        for spec in specs {
            let px = spec.pt * spec.scale
            guard let png = appTilePNG(pixels: px) else { continue }
            let suffix = spec.scale == 2 ? "@2x" : ""
            let name = "icon_\(spec.pt)x\(spec.pt)\(suffix).png"
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            try? png.write(to: url)
            print("wrote \(name) (\(px)px)")
        }
        print("iconset ready: \(dir)")
    }

    /// One square app-tile bitmap at the given pixel size.
    @MainActor
    private static func appTilePNG(pixels: Int) -> Data? {
        let size = NSSize(width: pixels, height: pixels)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let full = NSRect(origin: .zero, size: size)
        // macOS app-tile proportions: ~80% of the canvas, with a rounded-rect mask.
        let inset = CGFloat(pixels) * 0.10
        let tile = full.insetBy(dx: inset, dy: inset)
        let radius = tile.width * 0.225   // squircle-ish corner radius

        // Background tile: a soft vertical gradient (teal -> deeper teal) so the
        // white cup pops. Matches the brand teal used for the CLI state.
        let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        let top = ColorStore.defaultCLI.nsColor
        let bottom = NSColor(srgbRed: 0x1B/255.0, green: 0x8A/255.0, blue: 0x86/255.0, alpha: 1)
        let gradient = NSGradient(starting: top, ending: bottom)
        gradient?.draw(in: path, angle: -90)

        // Cup glyph, white, centered, ~52% of the tile.
        let glyphPt = tile.width * 0.52
        if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill",
                             accessibilityDescription: "Awake"),
           let tinted = cup.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: glyphPt, weight: .regular)
                   .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
            tinted.isTemplate = false
            let gw = tinted.size.width, gh = tinted.size.height
            let rect = NSRect(x: tile.midX - gw / 2,
                              y: tile.midY - gh / 2,
                              width: gw, height: gh)
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(_ image: NSImage, in cell: NSRect, templateTint: NSColor) {
        let img = image.isTemplate ? tinted(image, templateTint) : image
        let s = min(cell.width / img.size.width, cell.height / img.size.height)
        let dw = img.size.width * s, dh = img.size.height * s
        img.draw(in: NSRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}
