import Foundation

/// UserDefaults-backed settings. Keys namespaced `awake.*`.
@MainActor
@Observable
final class AppPreferences {

    private enum Keys {
        static let defaultDuration = "awake.defaultDuration"
        static let showSystem      = "awake.showSystemAssertions"
        static let pmsetFallback   = "awake.usePMSetFallback"
        static let blocksDisplay   = "awake.ourHoldBlocksDisplay"
        static let colorSelf       = "awake.iconColor.self"
        static let colorCLI        = "awake.iconColor.cli"
        static let colorApp        = "awake.iconColor.app"
        static let colorIdle       = "awake.iconColor.idle"   // absent = nil = system dynamic
        static let overrides       = "awake.categoryOverrides"
        static let seenHolders     = "awake.seenHolders"
        static let settingsTab     = "awake.settingsTab"
        static let notifyOnExpiry  = "awake.notifyOnExpiry"
        static let activateOnLaunch = "awake.activateOnLaunch"
        static let iconLayout      = "awake.iconLayout"
        static let showAppIcon     = "awake.iconShowAppIcon"
    }

    /// Max remembered holders; oldest by lastSeen are evicted past this.
    private static let seenCap = 100

    var hotKey: KeyComboStore {
        didSet { hotKey.save() }
    }

    var defaultDuration: TimerDuration {
        didSet {
            UserDefaults.standard.set(defaultDuration.rawValue, forKey: Keys.defaultDuration)
        }
    }

    var showSystemAssertions: Bool {
        didSet {
            UserDefaults.standard.set(showSystemAssertions, forKey: Keys.showSystem)
        }
    }

    var usePMSetFallback: Bool {
        didSet {
            UserDefaults.standard.set(usePMSetFallback, forKey: Keys.pmsetFallback)
        }
    }

    var ourHoldBlocksDisplay: Bool {
        didSet {
            UserDefaults.standard.set(ourHoldBlocksDisplay, forKey: Keys.blocksDisplay)
        }
    }

    /// Menu-bar icon composition — now just the focus choice.
    var iconLayout: IconLayout {
        didSet {
            if let data = try? JSONEncoder().encode(iconLayout) {
                UserDefaults.standard.set(data, forKey: Keys.iconLayout)
            }
        }
    }


    var iconColorSelf: ColorStore { didSet { Self.saveColor(iconColorSelf, Keys.colorSelf) } }
    var iconColorCLI:  ColorStore { didSet { Self.saveColor(iconColorCLI,  Keys.colorCLI)  } }
    var iconColorApp:  ColorStore { didSet { Self.saveColor(iconColorApp,  Keys.colorApp)  } }
    /// nil = adaptive system color (recommended default).
    var iconColorIdle: ColorStore? {
        didSet {
            if let c = iconColorIdle { Self.saveColor(c, Keys.colorIdle) }
            else { UserDefaults.standard.removeObject(forKey: Keys.colorIdle) }
        }
    }

    // MARK: - Category overrides (identityKey -> Bucket)

    /// Manual per-holder bucket overrides. Persisted as [key: bucket.rawValue]
    /// JSON so `defaults read` stays human-readable.
    var categoryOverrides: [String: Bucket] {
        didSet { Self.saveOverrides(categoryOverrides) }
    }

    /// Holders Awake has seen (active or recently), so any can be overridden.
    var seenHolders: [String: SeenHolder] {
        didSet { Self.saveSeen(seenHolders) }
    }

    func setOverride(_ bucket: Bucket?, for key: String) {
        if let bucket { categoryOverrides[key] = bucket }
        else { categoryOverrides.removeValue(forKey: key) }
    }

    func clearAllOverrides() {
        categoryOverrides = [:]
    }

    /// How stale an unchanged entry's lastSeen may get before we bother
    /// re-persisting it. Coarse so the timestamp doesn't trigger a JSON encode +
    /// UserDefaults write (and a SwiftUI invalidation) on EVERY refresh tick.
    private static let seenTouchInterval: TimeInterval = 60

    /// Batched variant: record many holders with a SINGLE persist. refresh()
    /// would otherwise JSON-encode + write UserDefaults once per holder, every
    /// tick (1 Hz while a hold is active).
    ///
    /// Bug #20: only mutate/persist when something MATERIAL changed. An existing
    /// entry whose displayName and naturalBucket are unchanged is left untouched
    /// unless its lastSeen is older than `seenTouchInterval`, so a steady set of
    /// holders no longer rewrites the whole registry (and re-renders the Categories
    /// view) once per second.
    func recordSeen(batch: [SeenBatchItem]) {
        guard !batch.isEmpty else { return }
        var dict = seenHolders
        let now = Date()
        var changed = false
        let activeKeys = Set(batch.map { $0.key })   // bug #9: never evict these
        for item in batch {
            if let existing = dict[item.key],
               existing.displayName == item.displayName,
               existing.lastNaturalBucket == item.naturalBucket,
               existing.bundleID == item.bundleID,
               existing.iconPath == item.iconPath,
               existing.tokens == item.tokens,
               now.timeIntervalSince(existing.lastSeen) < Self.seenTouchInterval {
                continue   // nothing material changed and timestamp is still fresh
            }
            dict[item.key] = SeenHolder(displayName: item.displayName,
                                        lastSeen: now,
                                        lastNaturalBucket: item.naturalBucket,
                                        bundleID: item.bundleID,
                                        iconPath: item.iconPath,
                                        tokens: item.tokens)
            changed = true
        }
        if dict.count > Self.seenCap {
            // Evict oldest by lastSeen, but NEVER a currently-active holder (bug #9):
            // an active holder we just recorded must not be aged out from under its
            // override.
            let evictable = dict
                .filter { !activeKeys.contains($0.key) }
                .sorted { $0.value.lastSeen < $1.value.lastSeen }
            var toRemove = dict.count - Self.seenCap
            for (k, _) in evictable where toRemove > 0 {
                dict.removeValue(forKey: k)
                toRemove -= 1
                changed = true
            }
        }
        guard changed else { return }
        seenHolders = dict
    }

    func clearSeenHistory() {
        seenHolders = [:]
    }

    private static func saveOverrides(_ overrides: [String: Bucket]) {
        let raw = overrides.mapValues { $0.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Keys.overrides)
        }
    }
    private static func loadOverrides() -> [String: Bucket] {
        guard let data = UserDefaults.standard.data(forKey: Keys.overrides),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw.reduce(into: [String: Bucket]()) { acc, kv in
            if let b = Bucket(rawValue: kv.value) { acc[kv.key] = b }
        }
    }

    private static func saveSeen(_ seen: [String: SeenHolder]) {
        if let data = try? JSONEncoder().encode(seen) {
            UserDefaults.standard.set(data, forKey: Keys.seenHolders)
        }
    }
    private static func loadSeen() -> [String: SeenHolder] {
        guard let data = UserDefaults.standard.data(forKey: Keys.seenHolders),
              let seen = try? JSONDecoder().decode([String: SeenHolder].self, from: data)
        else { return [:] }
        return seen
    }

    // MARK: - Misc prefs

    /// Last-selected Settings tab index, restored on open.
    var settingsTab: Int {
        didSet { UserDefaults.standard.set(settingsTab, forKey: Keys.settingsTab) }
    }

    var notifyOnExpiry: Bool {
        didSet { UserDefaults.standard.set(notifyOnExpiry, forKey: Keys.notifyOnExpiry) }
    }

    var activateOnLaunch: Bool {
        didSet { UserDefaults.standard.set(activateOnLaunch, forKey: Keys.activateOnLaunch) }
    }

    private static func saveColor(_ color: ColorStore, _ key: String) {
        if let data = try? JSONEncoder().encode(color) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private static func loadColor(_ key: String, default fallback: ColorStore) -> ColorStore {
        guard let data = UserDefaults.standard.data(forKey: key),
              var color = try? JSONDecoder().decode(ColorStore.self, from: data)
        else { return fallback }
        color.alpha = 1   // icons are always opaque; the UI can't edit alpha
        return color
    }
    private static func loadOptionalColor(_ key: String) -> ColorStore? {
        guard let data = UserDefaults.standard.data(forKey: key),
              var color = try? JSONDecoder().decode(ColorStore.self, from: data)
        else { return nil }
        color.alpha = 1
        return color
    }

    func resetIconColors() {
        iconColorSelf = .defaultSelf
        iconColorCLI  = .defaultCLI
        iconColorApp  = .defaultApp
        iconColorIdle = nil          // back to adaptive system color
    }

    /// Restore the default icon composition (focus + lone-app + app-icon options).
    func resetIconStyle() {
        iconLayout = IconLayout()
    }

    /// Resolved palette for the renderer. A nil slot means "render that glyph as
    /// a template" (adapts to the bar). self/cli stay nil while the user hasn't
    /// customized them — the default white self color is invisible on light bars,
    /// so template rendering is the safe default. Color customization is opt-in.
    var iconPalette: StatusIconRenderer.Palette {
        StatusIconRenderer.Palette(
            idle: iconColorIdle?.nsColor,                                  // nil -> template/system
            selfColor: iconColorSelf == .defaultSelf ? nil : iconColorSelf.nsColor,
            // CLI defaults to a visible teal (not white), so always render it in
            // color — unlike self/idle whose defaults would be invisible.
            cli: iconColorCLI.nsColor,
            app: iconColorApp.nsColor
        )
    }

    init() {
        let defaults = UserDefaults.standard

        self.hotKey = KeyComboStore.load()

        if defaults.object(forKey: Keys.defaultDuration) != nil {
            let raw = defaults.integer(forKey: Keys.defaultDuration)
            self.defaultDuration = TimerDuration(rawValue: raw) ?? .indefinite
        } else {
            self.defaultDuration = .indefinite
        }

        self.showSystemAssertions = defaults.bool(forKey: Keys.showSystem)   // default false
        self.usePMSetFallback     = defaults.bool(forKey: Keys.pmsetFallback) // default false
        self.ourHoldBlocksDisplay = defaults.bool(forKey: Keys.blocksDisplay) // default false

        self.iconColorSelf = Self.loadColor(Keys.colorSelf, default: .defaultSelf)
        self.iconColorCLI  = Self.loadColor(Keys.colorCLI,  default: .defaultCLI)
        self.iconColorApp  = Self.loadColor(Keys.colorApp,  default: .defaultApp)
        self.iconColorIdle = Self.loadOptionalColor(Keys.colorIdle)   // nil default

        self.categoryOverrides = Self.loadOverrides()
        self.seenHolders       = Self.loadSeen()
        self.settingsTab       = defaults.integer(forKey: Keys.settingsTab)   // default 0
        self.notifyOnExpiry    = defaults.bool(forKey: Keys.notifyOnExpiry)   // default false
        self.activateOnLaunch  = defaults.bool(forKey: Keys.activateOnLaunch) // default false

        // IconLayout: decode the current shape; else migrate a pre-focus blob
        // (anchorCup == false → "other apps in front"). The newer fields are
        // Codable WITH defaults, so a {focus}-only blob decodes cleanly and the
        // new fields take their defaults. Colors live on separate keys, untouched.
        var layout: IconLayout
        if let data = defaults.data(forKey: Keys.iconLayout) {
            if let decoded = try? JSONDecoder().decode(IconLayout.self, from: data) {
                layout = decoded
            } else if let legacy = try? JSONDecoder().decode(LegacyIconLayout.self, from: data) {
                layout = IconLayout(focus: legacy.anchorCup == false ? .otherAppsFirst : .awakeFirst)
            } else {
                layout = IconLayout()
            }
        } else {
            layout = IconLayout()
        }
        // Fold the retired standalone "show app icon" toggle into the layout: it
        // only ever affected the full-size/main app mark. Then drop the old key.
        var migrated = false
        if defaults.object(forKey: Keys.showAppIcon) != nil {
            if defaults.bool(forKey: Keys.showAppIcon) && !layout.appIconMain {
                layout.appIconMain = true
            }
            defaults.removeObject(forKey: Keys.showAppIcon)
            migrated = true
        }
        self.iconLayout = layout
        // didSet doesn't fire for the initializing assignment, so persist the
        // upgraded blob explicitly when we migrated.
        if migrated, let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Keys.iconLayout)
        }
    }

}

/// Minimal decoder for the pre-focus IconLayout blob, used only to migrate an
/// existing install: a Holder-First layout (anchorCup == false) maps to
/// "other apps in front". All other old fields are intentionally ignored.
private struct LegacyIconLayout: Decodable {
    var anchorCup: Bool?
}
