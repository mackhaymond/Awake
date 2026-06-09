import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @Bindable var model: AwakeModel
    @State private var isRecording = false

    var body: some View {
        TabView(selection: $model.prefs.settingsTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(1)
            categoriesTab
                .tabItem { Label("Categories", systemImage: "square.stack.3d.up") }
                .tag(2)
            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(3)
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(4)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear {
            // The Shortcut tab was folded into General; clamp a persisted index
            // that pointed past the now-shorter tab list so a valid tab shows.
            if model.prefs.settingsTab > 4 { model.prefs.settingsTab = 0 }
        }
    }

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    // Show "on" for a successful registration that is still pending
                    // approval (.requiresApproval), so the toggle doesn't snap back
                    // off after the user enables it — the Approve button below then
                    // guides them to finish.
                    get: { model.loginItem.isOnOrPending },
                    set: { model.loginItem.set($0) }
                ))
                if model.loginItem.needsApproval {
                    Button("Approve Awake in Login Items & Extensions…") {
                        model.loginItem.openSystemSettingsLoginItems()
                    }
                    .font(.caption)
                }
                Picker("Default Duration", selection: $model.prefs.defaultDuration) {
                    ForEach(TimerDuration.allCases) { duration in
                        Text(duration.label).tag(duration)
                    }
                }
                .help("The timer length used when you turn on Keep Awake, and for Start active on launch.")
                Toggle("Start active on launch", isOn: $model.prefs.activateOnLaunch)
                    .help("Begin a session (using the default duration) as soon as Awake launches.")
            }
            Section("While Active") {
                // Routed through the model so the live assertion is re-created with
                // the new type immediately — and exactly once even if the menu's
                // matching toggle is also on screen (shared single side effect).
                Toggle("Keep the display awake", isOn: Binding(
                    get: { model.prefs.ourHoldBlocksDisplay },
                    set: { model.setDisplayHold($0) }
                ))
                Toggle("Notify when a timed session ends", isOn: $model.prefs.notifyOnExpiry)
                    .help("Post a notification when a timed session ends.")
            }
            // Shortcut folded in from its former standalone tab (item 4).
            Section {
                HStack {
                    Text("Toggle Awake")
                    Spacer()
                    KeyRecorder(
                        combo: $model.prefs.hotKey,
                        isRecording: $isRecording,
                        onChange: { combo in
                            model.installHotKey(from: combo)
                        }
                    )
                    .frame(width: 140, height: 24)
                }
                if model.hotKeyUnavailable {
                    Text("Shortcut unavailable — try another combo.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Reset to Default (⌃⌥⌘A)") {
                        model.prefs.hotKey = .default
                        model.installHotKey(from: .default)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Works from any app; no Accessibility permission required.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loginItem.refresh() }
    }

    // MARK: - Appearance tab

    private var appearanceTab: some View {
        Form {
            Section("Icon Style") {
                focusControl
                iconStylePreview
            }
            Section {
                colorRow("This App", binding: bindSelf)
                colorRow("You", binding: bindCLI)
                    .help("Commands you ran in Terminal via the macOS caffeinate command.")
                colorRow("Apps", binding: bindApp)
                    .help("The colored dot shown for other apps — and the fallback when an app's icon can't load.")
                Toggle("Show the app's icon instead of a dot", isOn: $model.prefs.showAppIconForApps)
                    .help("When another app is the main icon, show that app's real icon — the app that has been keeping your Mac awake the longest. A colored dot is still used for the small corner badge and as a fallback.")
                idleColorRow
                HStack {
                    Spacer()
                    Button("Reset Colors") { model.prefs.resetIconColors() }
                        .buttonStyle(.borderless)
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("Idle uses your Mac's menu-bar color automatically so it stays readable on light and dark backgrounds.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Icon-style helpers

    private var layout: IconLayout { model.prefs.iconLayout }

    /// The single composition choice — what the icon emphasizes when more than
    /// one thing is holding sleep. Captions explain each; the live preview below
    /// shows the effect for the selected focus.
    private var focusControl: some View {
        Picker(selection: Binding(
            get: { model.prefs.iconLayout.focus },
            set: { newValue in
                var l = model.prefs.iconLayout
                l.focus = newValue
                model.prefs.iconLayout = l
            }
        )) {
            ForEach(IconFocus.allCases) { f in
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label)
                    Text(f.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(f)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    /// Representative holder combinations rendered through the REAL renderer with
    /// the current focus + palette, so the preview reflects the choice live.
    private static let previewCombos: [(label: String, holders: IconHolders)] = [
        ("Idle", IconHolders()),
        ("This app", IconHolders(thisApp: true)),
        ("You", IconHolders(you: true)),
        ("An app", IconHolders(apps: true)),
        ("This app + an app", IconHolders(thisApp: true, apps: true)),
        ("You + an app", IconHolders(you: true, apps: true)),
    ]

    private var iconStylePreview: some View {
        // When "Show the app's icon" is on, pass a stand-in (Awake's own icon)
        // for the apps cells so the preview honestly shows icon mode — the static
        // preview has no real third-party app to resolve.
        let standIn: NSImage? = model.prefs.showAppIconForApps ? NSApp.applicationIconImage : nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                ForEach(Self.previewCombos, id: \.label) { combo in
                    VStack(spacing: 3) {
                        Image(nsImage: StatusIconRenderer.image(
                            holders: combo.holders,
                            palette: model.prefs.iconPalette,
                            layout: layout,
                            appsIcon: combo.holders.apps ? standIn : nil))
                            .frame(width: 22, height: 22)
                        Text(combo.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .help("Menu-bar icon when: \(combo.label)")
                }
            }
            Text(model.prefs.showAppIconForApps
                 ? "A coffee cup means Awake or you are holding sleep; an app icon means another app is. The preview uses Awake's own icon as a stand-in — the menu bar shows each app's real icon."
                 : "A coffee cup means Awake or you are holding sleep; a colored dot means another app is.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func colorRow(_ title: String, binding: Binding<Color>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// Idle row: nil prefs == adaptive system color. Toggling "Custom" off restores nil.
    private var idleColorRow: some View {
        HStack {
            Text("Idle (Adaptive)")
            Spacer()
            if model.prefs.iconColorIdle == nil {
                Button("Customize…") { model.prefs.iconColorIdle = .defaultIdle }
                    .buttonStyle(.borderless)
            } else {
                ColorPicker("", selection: bindIdle, supportsOpacity: false)
                    .labelsHidden()
                Button { model.prefs.iconColorIdle = nil } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Use adaptive system color")
            }
        }
    }

    // Explicit Binding<Color> bridges (most reliable form per the research report).
    private var bindSelf: Binding<Color> {
        Binding(get: { model.prefs.iconColorSelf.swiftUIColor },
                set: { model.prefs.iconColorSelf = ColorStore($0) })
    }
    private var bindCLI: Binding<Color> {
        Binding(get: { model.prefs.iconColorCLI.swiftUIColor },
                set: { model.prefs.iconColorCLI = ColorStore($0) })
    }
    private var bindApp: Binding<Color> {
        Binding(get: { model.prefs.iconColorApp.swiftUIColor },
                set: { model.prefs.iconColorApp = ColorStore($0) })
    }
    private var bindIdle: Binding<Color> {
        Binding(get: { (model.prefs.iconColorIdle ?? .defaultIdle).swiftUIColor },
                set: { model.prefs.iconColorIdle = ColorStore($0) })
    }

    // MARK: - Categories tab

    private var categoriesTab: some View {
        CategoriesSettingsView(model: model)
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        Form {
            Section {
                Toggle("Show system processes", isOn: $model.prefs.showSystemAssertions)
                    .help("Include macOS background processes (powerd, WindowServer, daemons) in the list.")
                    .onChange(of: model.prefs.showSystemAssertions) { _, _ in
                        model.refresh()
                    }
                Toggle("Use pmset reader", isOn: $model.prefs.usePMSetFallback)
                    .help("Read assertions via pmset instead of IOKit. For troubleshooting only.")
                    .onChange(of: model.prefs.usePMSetFallback) { _, _ in
                        model.refresh()
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About tab

    private var aboutTab: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    } else {
                        Image(nsImage: StatusIconRenderer.image(
                            for: .selfOnly, palette: model.prefs.iconPalette))
                            .frame(width: 48, height: 48)
                    }
                    Text("Awake")
                        .font(.title2.bold())
                    Text("Version \(Self.versionString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Shows who is keeping your Mac awake — and lets you keep it awake yourself.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Link("View Source on GitHub",
                             destination: URL(string: "https://github.com/mackhaymond/Awake")!)
                        Text("MIT License")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
    }

    private static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}

// MARK: - Categories settings (grouped by category; This App pinned + locked)

struct CategoriesSettingsView: View {
    @Bindable var model: AwakeModel

    /// A holder shown in the Categories list (active or remembered).
    private struct HolderEntry: Identifiable {
        let key: String
        let tokens: [String]        // all identity tokens (multi-token override match)
        let name: String
        let effective: Bucket       // section it's grouped under (after any override)
        let auto: Bucket?           // natural bucket Awake chose (for the "Auto:" hint)
        let bundleID: String?
        let iconPath: String?
        let active: Bool
        let lastSeen: Date?
        var id: String { key }
    }

    /// Buckets a non-self holder may be assigned to — This App is locked out
    /// (item 1: nothing but Awake can be This App), in display order.
    private static let assignable: [Bucket] =
        Bucket.allCases.filter { $0 != .thisApp }.sorted { $0.sortOrder < $1.sortOrder }

    /// ALL identity tokens of holders present in the current snapshot — not just
    /// each row's canonical key. A remembered holder is filtered out of the
    /// "remembered" list if ANY of its tokens is active, so a holder whose
    /// canonical key shifted across a PID death (e.g. path: → name:) isn't shown
    /// twice (once active, once remembered).
    private var activeKeys: Set<String> {
        var keys = Set<String>()
        for rows in model.buckets.values {
            for row in rows { keys.formUnion(row.identityKeys) }
        }
        return keys
    }

    /// All non-self holders (active + remembered), de-duplicated by identity key.
    /// Self ("This App") holders are excluded — Awake is shown by the pinned,
    /// locked row at the top instead.
    private var entries: [HolderEntry] {
        var seen = Set<String>()
        var out: [HolderEntry] = []

        // Active holders, in bucket order.
        for bucket in Bucket.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            for row in model.buckets[bucket] ?? [] where !seen.contains(row.identityKey) {
                if row.naturalBucket == .thisApp { continue }   // pinned separately
                seen.insert(row.identityKey)
                out.append(HolderEntry(
                    key: row.identityKey, tokens: row.identityKeys, name: row.title,
                    effective: row.bucket, auto: row.naturalBucket,
                    bundleID: row.bundleID, iconPath: row.iconBundleID,
                    active: true, lastSeen: nil))
            }
        }

        // Remembered holders not currently active, newest first.
        let remembered = model.prefs.seenHolders
            .filter { !seen.contains($0.key) && !activeKeys.contains($0.key) }
            .sorted { $0.value.lastSeen > $1.value.lastSeen }
        for (key, holder) in remembered where holder.lastNaturalBucket != .thisApp {
            // The remembered registry is keyed by canonical key (one entry per
            // holder), and the filter above already dropped anything active under
            // any of its tokens — so no extra cross-token dedup is needed here
            // (and would be unsafe: distinct caffeinate holds share `proc:caffeinate`).
            let tokens = holder.tokens ?? [key]
            // Multi-token override match (bug #21): an override stored under ANY of
            // the holder's tokens applies. Locked: a stored override INTO This App
            // can never take effect, so ignore one.
            let stored = tokens.lazy.compactMap { model.prefs.categoryOverrides[$0] }.first
            let effective = (stored == .thisApp ? nil : stored) ?? holder.lastNaturalBucket
            out.append(HolderEntry(
                key: key, tokens: tokens, name: holder.displayName,
                effective: effective, auto: holder.lastNaturalBucket,
                bundleID: holder.bundleID, iconPath: holder.iconPath,
                active: false, lastSeen: holder.lastSeen))
        }
        return out
    }

    /// Whether Awake itself currently holds sleep (drives the pinned row's status).
    private var selfActive: Bool { model.isActive || model.ownNativeHoldPresent }

    var body: some View {
        let grouped = Dictionary(grouping: entries, by: { $0.effective })
        return Form {
            Section {
                Text("Awake automatically sorts what's keeping your Mac awake into This App, You, Apps, and System. Holders are grouped by their category below — override any one to move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // This App — pinned at the top and locked (item 1).
            Section(Bucket.thisApp.rawValue) {
                pinnedSelfRow
            }

            // One section per remaining category that has holders (item 2).
            ForEach(Self.assignable, id: \.self) { bucket in
                if let rows = grouped[bucket], !rows.isEmpty {
                    Section(bucket.rawValue) {
                        ForEach(sortRows(rows)) { holderRow($0) }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Clear All Overrides") {
                        model.prefs.clearAllOverrides()
                        model.refresh()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.prefs.categoryOverrides.isEmpty)
                    Button("Clear History") {
                        model.prefs.clearSeenHistory()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.prefs.seenHolders.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Active first, then alphabetical — stable order within a category section.
    private func sortRows(_ rows: [HolderEntry]) -> [HolderEntry] {
        rows.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The locked Awake row. Always shown, no picker — This App can't be
    /// reassigned and nothing else can become This App (item 1).
    private var pinnedSelfRow: some View {
        HStack(spacing: 8) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: Bucket.thisApp.fallbackSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Awake").lineLimit(1)
                if selfActive {
                    Label("Active", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text("This is Awake")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Label("Locked", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .help("Awake is always This App and can't be recategorized.")
        }
    }

    @ViewBuilder
    private func holderRow(_ e: HolderEntry) -> some View {
        HStack(spacing: 8) {
            // Try the real app icon; fall back to a per-category SF Symbol (item 3).
            if let img = AppIdentityResolver.icon(forBundleID: e.bundleID, path: e.iconPath) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: e.effective.fallbackSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if e.active {
                        Label("Active", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else if let lastSeen = e.lastSeen {
                        Text("Last seen \(Self.relative(lastSeen))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let auto = e.auto {
                        Text((e.active || e.lastSeen != nil ? "· " : "") + "Auto: \(auto.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Picker("", selection: overrideBinding(canonical: e.key, tokens: e.tokens)) {
                Text("Auto").tag(Optional<Bucket>.none)
                ForEach(Self.assignable, id: \.self) { b in
                    Text(b.rawValue).tag(Optional(b))
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    /// Multi-token override binding (bug #21): READS the override across all of a
    /// holder's identity tokens (so a value stored under any token shows up), and
    /// WRITES under the canonical key after clearing any value stored under the
    /// holder's OTHER tokens — so changing/clearing the override never leaves a
    /// stale duplicate under a different token.
    private func overrideBinding(canonical: String, tokens: [String]) -> Binding<Bucket?> {
        Binding(
            get: {
                for t in tokens {
                    if let b = model.prefs.categoryOverrides[t] { return b }
                }
                return nil
            },
            set: { newValue in
                for t in tokens where t != canonical {
                    model.prefs.setOverride(nil, for: t)
                }
                model.prefs.setOverride(newValue, for: canonical)
                model.refresh()
            }
        )
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - KeyRecorder (NSViewRepresentable)

struct KeyRecorder: NSViewRepresentable {
    @Binding var combo: KeyComboStore
    @Binding var isRecording: Bool
    var onChange: (KeyComboStore) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { keyCode, carbonMods in
            let newCombo = KeyComboStore(keyCode: keyCode, carbonModifiers: carbonMods)
            combo = newCombo
            onChange(newCombo)
            isRecording = false
        }
        view.onRecordingChange = { recording in
            isRecording = recording
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.displayString = combo.displayString
        nsView.needsDisplay = true
    }
}

// MARK: - RecorderView (focusable chord capture)

final class RecorderView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var displayString: String = "" {
        didSet { needsDisplay = true }
    }

    private var isRecording = false {
        didSet {
            onRecordingChange?(isRecording)
            needsDisplay = true
            // Tell VoiceOver the value changed so it re-reads "Recording…" / the combo.
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Accessibility
    // A custom NSView is otherwise invisible to VoiceOver (WCAG 4.1.2). Expose it
    // as a button whose value is the current shortcut / recording state, and let
    // an accessibility press start recording (mirroring mouseDown).

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Keyboard shortcut for Toggle Awake" }
    override func accessibilityValue() -> Any? {
        if isRecording { return "Recording — type a shortcut" }
        return displayString.isEmpty ? "No shortcut set" : displayString
    }
    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        isRecording = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let cocoaMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonMods = cocoaMods.carbonFlags

        // Require at least one non-shift modifier.
        let hasNonShift = carbonMods & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0
        guard hasNonShift else {
            NSSound.beep()
            return
        }

        let keyCode = UInt32(event.keyCode)
        isRecording = false
        window?.makeFirstResponder(nil)
        onCapture?(keyCode, carbonMods)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgColor = isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.2)
                                  : NSColor.controlBackgroundColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        bgColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let text = isRecording ? "Type a shortcut…" : (displayString.isEmpty ? "Record shortcut" : displayString)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        attributed.draw(at: origin)
    }
}
