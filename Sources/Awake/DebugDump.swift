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

        // Scoped to this process so a running Awake.app's own hold doesn't count.
        func ourHolds() -> [PowerAssertion] {
            AssertionReader.read().filter {
                $0.rawName.hasPrefix(CaffeinationController.namePrefix) && $0.ownerPID == pid
            }
        }

        print("Awake — caffeination self-test (pid \(pid))\n")
        print("before: our assertions = \(ourHolds().count)")

        let ok = controller.activate(reason: "self-test", seconds: nil)
        print("activate(indefinite) ok=\(ok) controller.isActive=\(controller.isActive)")

        let held = ourHolds()
        print("during: our assertions = \(held.count)")
        for h in held { print("  - \"\(h.rawName)\" type=\(h.rawType) ownerPID=\(h.ownerPID)") }

        // A hold must include PreventSystemSleep — the idle types alone don't
        // survive a lid close — and must still read as ONE This App row.
        let holdsLidClosed = held.contains { $0.type == .preventSystemSleep }
        print("PreventSystemSleep held: \(holdsLidClosed)")

        let buckets = AssertionClassifier.rows(from: AssertionReader.read(), ownPID: pid, showSystem: true)
        let selfRows = buckets[.thisApp] ?? []
        print("This App bucket: \(selfRows.map(\.title))")

        controller.release()
        print("release() controller.isActive=\(controller.isActive)")
        let after = ourHolds().count
        print("after: our assertions = \(after)")

        // Migration sanity: an older single-field {focus} blob must keep its focus.
        // (v2 added fields; a non-lenient decoder would throw and reset the choice.)
        let focusBlob = Data(#"{"focus":"otherAppsFirst"}"#.utf8)
        let migratedFocus = (try? JSONDecoder().decode(IconLayout.self, from: focusBlob))?.focus
        let migrationOK = (migratedFocus == .otherAppsFirst)
        print("migration: legacy {focus:otherAppsFirst} -> \(migratedFocus.map { "\($0)" } ?? "nil") \(migrationOK ? "OK" : "FAIL")")

        // Lid-closed override: the kernel accepts it, a watchdog is armed while
        // engaged, and both are gone after disengage.
        let lid = LidCloseOverride()
        let lidEngaged = lid.engage()
        let watchdogPID = lid.watchdogPID
        let watchdogAlive = watchdogPID.map { kill($0, 0) == 0 } ?? false
        lid.disengage()
        usleep(200_000)
        let watchdogGone = watchdogPID.map { kill($0, 0) != 0 } ?? false
        let lidOK = lidEngaged && watchdogAlive && watchdogGone && !lid.isEngaged
        print("lid override: engaged=\(lidEngaged) watchdog=\(watchdogPID.map(String.init) ?? "none") alive=\(watchdogAlive) gone-after=\(watchdogGone) \(lidOK ? "OK" : "FAIL")")

        let broadcastOK = broadcastSelfTest()

        let passed = ok && holdsLidClosed && selfRows.count == 1 && after == 0 && migrationOK && lidOK
            && broadcastOK
        print("\nSELF-TEST: \(passed ? "PASS ✅" : "FAIL ❌")")
    }

    /// State broadcast: the payload keeps to the v1 contract, and a post makes a
    /// real round trip through the distributed notification center.
    @MainActor
    private static func broadcastSelfTest() -> Bool {
        func state(active: Bool, start: Date? = nil, end: Date? = nil,
                   holders: [StateBroadcast.Holder]? = nil) -> StateBroadcast.State {
            .init(active: active, start: start, end: end, displayOn: active, lidOK: active,
                  preset: active ? 7200 : nil, lidPaused: false, prefDisplayAwake: true,
                  prefLidClosed: true, prefLidBatteryFloor: 20, iconHidden: false,
                  defaultDuration: -1, hotkey: "⌃⌥⌘A", onAC: true, battery: nil,
                  holders: holders, youCount: holders.map { _ in 1 })
        }
        let holder = StateBroadcast.Holder(bucket: "apps", title: "Claude Code", reason: "working",
                                           secsLeft: 280, bundleID: nil, count: 2, kind: "claudeCode")
        let timed = StateBroadcast.payload(.extended, state(active: true,
                                                            start: Date(timeIntervalSince1970: 1_000),
                                                            end: Date(timeIntervalSince1970: 8_200),
                                                            holders: [holder]),
                                           requestID: "r1")
        let idle = StateBroadcast.payload(.snapshot, state(active: false))
        let holders = timed["holders"] as? [[String: Any]]
        let shapeOK = timed["v"] as? Int == 1
            && timed["event"] as? String == "extended"
            && timed["active"] as? Bool == true
            && timed["start"] as? Double == 1_000
            && timed["end"] as? Double == 8_200
            && timed["preset"] as? Int == 7200
            && timed["requestId"] as? String == "r1"
            && timed["youCount"] as? Int == 1
            && holders?.first?["secsLeft"] as? Double == 280
            && holders?.first?["count"] as? Int == 2
            && holders?.first?["bundleID"] == nil
            && idle["start"] == nil && idle["end"] == nil && idle["preset"] == nil
            && idle["holders"] == nil && idle["youCount"] == nil && idle["requestId"] == nil
            && idle["hotkey"] as? String == "⌃⌥⌘A"
            && PropertyListSerialization.propertyList(timed, isValidFor: .binary)

        // Commands: what's accepted, and that malformed input is dropped.
        typealias Command = StateBroadcast.Command
        let now = Date(timeIntervalSince1970: 1_000_000)
        func parse(_ info: [String: Any]) -> Command.Action? {
            try? Command.parse(info, now: now).get().action
        }
        let base: [String: Any] = ["v": 1, "id": "x"]
        func cmd(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }
        let accepted: [(String, [String: Any], Command.Action)] = [
            ("start", cmd(["action": "start"]), .start(.indefinite)),
            ("start default", cmd(["action": "start", "default": true]), .start(.defaultDuration)),
            ("start 90m", cmd(["action": "start", "minutes": 90]), .start(.seconds(5400))),
            ("start until", cmd(["action": "start", "until": 1_003_600.0]),
             .start(.until(Date(timeIntervalSince1970: 1_003_600)))),
            ("extend", cmd(["action": "extend"]), .extend(seconds: 900)),
            ("stop", cmd(["action": "stop"]), .stop),
            ("set", cmd(["action": "set", "lidClosed": false]), .set(.init(lidClosed: false))),
            ("watch", cmd(["action": "watch", "on": true]), .watch(true)),
            ("stopCommands", cmd(["action": "stopCommands"]), .stopCommands),
            ("quit", cmd(["action": "quit"]), .quit),
            ("openSettings", cmd(["action": "openSettings"]), .openSettings),
        ]
        let rejected: [(String, [String: Any])] = [
            ("v2", cmd(["v": 2, "action": "stop"])),
            ("v as bool", cmd(["v": true, "action": "stop"])),
            ("no id", ["v": 1, "action": "stop"]),
            ("long id", cmd(["id": String(repeating: "a", count: 65), "action": "stop"])),
            ("unknown action", cmd(["action": "explode"])),
            ("minutes 0", cmd(["action": "start", "minutes": 0])),
            ("minutes 1441", cmd(["action": "start", "minutes": 1441])),
            ("minutes string", cmd(["action": "start", "minutes": "15"])),
            ("minutes + until", cmd(["action": "start", "minutes": 15, "until": 1_003_600.0])),
            ("default + minutes", cmd(["action": "start", "default": true, "minutes": 15])),
            ("until past", cmd(["action": "start", "until": 999_000.0])),
            ("until > 7d", cmd(["action": "start", "until": 1_000_000.0 + 8 * 86_400])),
            ("set empty", cmd(["action": "set"])),
            ("set number as bool", cmd(["action": "set", "lidClosed": 1])),
            ("watch missing on", cmd(["action": "watch"])),
        ]
        let badAccepts = accepted.filter { parse($0.1) != $0.2 }.map(\.0)
        let badRejects = rejected.filter { parse($0.1) != nil }.map(\.0)
        let commandsOK = badAccepts.isEmpty && badRejects.isEmpty
        if !commandsOK { print("commands: wrongly parsed \(badAccepts), wrongly accepted \(badRejects)") }

        // Only touched on the main queue (observer queue + this loop).
        final class Inbox: @unchecked Sendable { var info: [AnyHashable: Any]? }
        let inbox = Inbox()
        let center = DistributedNotificationCenter.default()
        // A private name: a real `state` post would tell listeners the hold is off.
        let testName = Notification.Name("\(StateBroadcast.stateName.rawValue).selftest.\(getpid())")
        let token = center.addObserver(forName: testName, object: nil, queue: .main) {
            inbox.info = $0.userInfo
        }
        StateBroadcast.post(.snapshot, state(active: false), name: testName)
        let deadline = Date().addingTimeInterval(2)
        while inbox.info == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(token)
        let roundTripOK = inbox.info?["event"] as? String == "snapshot"
            && inbox.info?["pid"] as? Int == Int(getpid())

        let passed = shapeOK && commandsOK && roundTripOK
        print("state broadcast: payload=\(shapeOK ? "OK" : "FAIL") commands=\(commandsOK ? "OK" : "FAIL") round-trip=\(roundTripOK ? "OK" : "FAIL")")
        return passed
    }

    /// Render representative holder combinations across both icon-focus modes
    /// (with and without the app-icon option) onto a dark sheet — verifies the
    /// real compositor (cup primary, apps dot, apps-primary, app-icon squircle,
    /// badge corner) end to end.
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
            ("self+you", IconHolders(thisApp: true, you: true)),
            ("all", IconHolders(thisApp: true, you: true, apps: true)),
        ]
        // A real, recognizable app icon to exercise the app-icon path honestly.
        let standIn = sampleAppIcon()
        let layouts: [(String, IconLayout, NSImage?)] = [
            ("Awake first",        IconLayout(focus: .awakeFirst),                              standIn),
            ("Apps first",         IconLayout(focus: .otherAppsFirst),                          standIn),
            ("Lone app icon",      IconLayout(focus: .awakeFirst, appIconMain: true),           standIn),
            ("Lone: cup+dot",      IconLayout(focus: .awakeFirst, loneApp: .cupWithDot),        standIn),
            ("Corner icon",        IconLayout(focus: .awakeFirst, appIconMain: true, appIconCorner: true), standIn),
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
                    img = StatusIconRenderer.image(holders: combo.1, palette: palette,
                                                   layout: layout.1, appsIcon: layout.2)
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

    /// A real, recognizable app icon for the --icons sanity sheet (so the app-icon
    /// path is exercised with a true multi-color icon, not a stand-in). Falls back
    /// to Awake's own icon, then a generic SF Symbol.
    @MainActor
    private static func sampleAppIcon() -> NSImage {
        let ws = NSWorkspace.shared
        for bid in ["com.apple.Safari", "com.apple.Music", "com.apple.finder", "com.apple.Notes"] {
            if let url = ws.urlForApplication(withBundleIdentifier: bid) {
                return ws.icon(forFile: url.path)
            }
        }
        return NSApp?.applicationIconImage
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage()
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

        // Cup-and-saucer, white, centered — ORIGINAL artwork drawn with
        // NSBezierPath, NOT an SF Symbol. Apple's SF Symbols license forbids
        // baking a symbol into an app icon; runtime SF Symbol use in the menu
        // bar / list rows is permitted and is unchanged. The silhouette echoes
        // the menu-bar cup for brand continuity without copying Apple's glyph.
        let boxW = tile.width * 0.60
        let boxH = tile.width * 0.46
        let box = NSRect(x: tile.midX - boxW / 2, y: tile.midY - boxH / 2,
                         width: boxW, height: boxH)
        drawCupAndSaucer(in: box, color: .white)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Draw an original filled cup-and-saucer silhouette inside `box`, in
    /// `color`. Used only for the generated app icon (AppIcon.icns) so that no
    /// Apple SF Symbol is redistributed in the icon asset. A wide shallow saucer
    /// ellipse, a slightly tapered cup body with a rounded base and a convex
    /// elliptical rim, and an open ring handle on the right.
    private static func drawCupAndSaucer(in box: NSRect, color: NSColor) {
        color.set()
        let w = box.width, h = box.height
        let cx = box.midX

        // Saucer: a wide, shallow ellipse along the bottom.
        let saucerH = h * 0.18
        NSBezierPath(ovalIn: NSRect(x: box.minX, y: box.minY, width: w, height: saucerH)).fill()

        // Cup body: tapers slightly toward the base, sits on the saucer.
        let cupTopW = w * 0.56
        let cupBotW = w * 0.44
        let bottomY = box.minY + saucerH * 0.55          // seated in the saucer
        let cupTop  = box.maxY - h * 0.04
        let corner  = cupBotW * 0.30                     // rounded base corners
        let rimH    = h * 0.12                           // convex rim bump

        let leftX  = cx - cupBotW / 2
        let rightX = cx + cupBotW / 2
        let topL = NSPoint(x: cx - cupTopW / 2, y: cupTop)
        let topR = NSPoint(x: cx + cupTopW / 2, y: cupTop)

        let body = NSBezierPath()
        body.move(to: topL)
        body.line(to: NSPoint(x: leftX, y: bottomY + corner))
        body.appendArc(from: NSPoint(x: leftX, y: bottomY),
                       to:   NSPoint(x: leftX + corner, y: bottomY), radius: corner)
        body.line(to: NSPoint(x: rightX - corner, y: bottomY))
        body.appendArc(from: NSPoint(x: rightX, y: bottomY),
                       to:   NSPoint(x: rightX, y: bottomY + corner), radius: corner)
        body.line(to: topR)
        body.curve(to: topL,                             // elliptical rim, seen from above
                   controlPoint1: NSPoint(x: cx + cupTopW * 0.32, y: cupTop + rimH),
                   controlPoint2: NSPoint(x: cx - cupTopW * 0.32, y: cupTop + rimH))
        body.close()
        body.fill()

        // Handle: a thick open ring whose ends tuck into the cup's right wall.
        let cupMidY = (bottomY + cupTop) / 2 + h * 0.04
        let handleR = h * 0.19
        let wallX = cx + cupTopW * 0.42                  // the wall at handle height
        let handle = NSBezierPath()
        handle.appendArc(withCenter: NSPoint(x: wallX, y: cupMidY),
                         radius: handleR, startAngle: -82, endAngle: 82)
        handle.lineWidth = h * 0.085
        handle.lineCapStyle = .round
        handle.stroke()
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
