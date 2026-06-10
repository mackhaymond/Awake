import SwiftUI
import AppKit

struct MenuContentView: View {
    @Bindable var model: AwakeModel
    @Environment(\.openSettings) private var openSettings
    @State private var showCustom = false
    @State private var customMinutes = 45
    @State private var untilTime = Date().addingTimeInterval(3600)
    @State private var confirmKill = false
    /// Measured intrinsic height of the holder list, used to give the bounded
    /// ScrollView a CONCRETE height (a plain ScrollView{}.frame(maxHeight:) reports
    /// an ideal height of ~0 inside the auto-sizing MenuBarExtra .window and so
    /// collapses to nothing). With a measured height we render normally
    /// for a few holders and cap + scroll for many.
    @State private var listContentHeight: CGFloat = 0

    /// Upper bound on the holder list's height before it starts scrolling.
    private let maxListHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            // Controls tier.
            VStack(alignment: .leading, spacing: 8) {
                masterToggle
                displayToggle
                countdown
                timedControls
            }
            Divider()
            killCaffeinateButton
            Divider()
            // Who's-holding tier. Bounded so a long holder list (Show System on:
            // powerd, WindowServer, sharingd, many app rows, per-bucket headers…)
            // can't overflow the popover and clip the footer/Settings/Quit. We
            // measure the list's intrinsic height and give the ScrollView a
            // CONCRETE height = min(measured, maxListHeight): renders normally for
            // a few holders, caps + scrolls for many. A plain ScrollView with only
            // .frame(maxHeight:) would collapse to ~0 in the .window MenuBarExtra.
            // Section title for the who's-keeping-awake list (Awake's headline
            // feature). Kept OUTSIDE the bounded ScrollView so it doesn't scroll
            // away — and so the measured-height list is untouched.
            VStack(alignment: .leading, spacing: 4) {
                if !isListEmpty {
                    Text("Keeping your Mac awake")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                boundedAssertionList
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .task {
            model.onLaunch()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("Awake")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Render the EXACT menu-bar glyph (same renderer + palette) so the header
    /// and the menu-bar icon are guaranteed identical marks.
    private var statusIcon: some View {
        Image(nsImage: StatusIconRenderer.image(holders: model.iconHolders,
                                                palette: model.prefs.iconPalette,
                                                layout: model.prefs.iconLayout,
                                                appsIcon: model.appsSlotIcon))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private var statusText: String {
        switch model.iconState {
        case .idle:       return "Your Mac can sleep"
        case .selfOnly:   return "You're keeping your Mac awake"
        case .cliOnly:    return "A command you ran is keeping your Mac awake"
        case .appOnly:    return "An app is keeping your Mac awake"
        case .selfAndApp: return "You and an app are keeping your Mac awake"
        case .cliAndApp:  return "A command you ran and an app are keeping your Mac awake"
        }
    }

    // MARK: - Master toggle

    private var masterToggle: some View {
        Toggle(isOn: Binding(
            get: { model.isActive },
            // Flip ON from idle starts a hold using the user's Default Duration
            // (Settings → General; ships as Indefinitely) rather than always
            // forcing indefinite — and never re-creates an already-running timed
            // hold. Flip OFF stops.
            set: { newValue in
                if newValue {
                    if !model.isActive { model.activate(duration: model.prefs.defaultDuration) }
                } else {
                    model.deactivate()
                }
            }
        )) {
            Text("Keep Awake")
                .font(.body)
        }
        .toggleStyle(.switch)
    }

    // MARK: - Display-awake toggle (per-caffeinate)

    /// Whether our hold also keeps the DISPLAY awake, toggleable right here in the
    /// menu (item 6) alongside Keep Awake and the timed controls — not buried in
    /// Settings. Bound to the same preference; flipping it while a hold is live
    /// re-creates the assertion with the new type immediately (display vs system).
    private var displayToggle: some View {
        Toggle(isOn: Binding(
            get: { model.prefs.ourHoldBlocksDisplay },
            set: { model.setDisplayHold($0) }
        )) {
            Text("Keep the display awake")
                .font(.subheadline)
        }
        // A checkbox, indented under the primary switch, so it reads as a
        // sub-condition of Keep Awake rather than a second equal toggle.
        .toggleStyle(.checkbox)
        .padding(.leading, 16)
        .help("Also keep the screen on while Awake is keeping your Mac awake.")
    }

    // MARK: - Countdown (active-state cluster)

    /// When a timed hold is running, show the countdown next to Stop and a
    /// "+15 min" extend affordance — co-located so there's no layout jump or a
    /// second "Stop" verb colliding with the kill button.
    @ViewBuilder
    private var countdown: some View {
        if let rem = model.remaining {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Label(hms(rem), systemImage: "timer")
                        .monospacedDigit()
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Time remaining: \(hms(rem))")
                    Button("+15 min") {
                        model.activateCustom(seconds: Int(rem) + 900)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Add 15 minutes")
                    Spacer()
                    Button("Stop") { model.deactivate() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                        .accessibilityLabel("Stop keeping your Mac awake")
                }
                if let end = model.endDate {
                    Text("Until \(end.formatted(.dateTime.hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else if model.isActive {
            // Indefinite hold: no countdown, but it still needs an inline Stop and
            // a cue that it's on with no end, so the active state never looks stuck.
            HStack(spacing: 8) {
                Label("On indefinitely", systemImage: "infinity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.deactivate() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .accessibilityLabel("Stop keeping your Mac awake")
            }
        }
    }

    // MARK: - Timed controls

    private var timedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep awake for…")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                durationButton(.fifteenMin, "15m")
                durationButton(.thirtyMin, "30m")
                durationButton(.oneHour, "1h")
                durationButton(.twoHours, "2h")
            }
            HStack(spacing: 6) {
                durationButton(.fourHours, "4h")
                durationButton(.eightHours, "8h")
                Button("Custom…") {
                    // Reset the "Until" picker to a sensible 1-hour-from-now each
                    // time the panel opens, so a stale value never shows.
                    if !showCustom { untilTime = Date().addingTimeInterval(3600) }
                    showCustom.toggle()
                }
                .buttonStyle(.bordered)
                if !model.isActive {
                    Button("Indefinitely") { model.activate(duration: .indefinite) }
                        .buttonStyle(.bordered)
                }
            }
            if showCustom {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Stepper(value: $customMinutes, in: 1...600, step: 5) {
                            Text("\(customMinutes) min")
                                .monospacedDigit()
                        }
                        Button("Start") { startCustom() }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Start, keep awake for \(customMinutes) minutes")
                    }
                    HStack {
                        DatePicker("Until", selection: $untilTime,
                                   displayedComponents: .hourAndMinute)
                        Spacer()
                        Button("Start") { startUntil() }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Start, keep awake until the chosen time")
                    }
                }
            }
        }
    }

    private func durationButton(_ duration: TimerDuration, _ label: String) -> some View {
        let selected = model.activeDuration == duration
        return Button(label) {
            model.activate(duration: duration)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : nil)
        .accessibilityLabel("Keep awake for \(duration.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func startCustom() {
        model.activateCustom(seconds: customMinutes * 60)
        showCustom = false
    }

    private func startUntil() {
        // Compute the NEXT occurrence of the picked wall-clock hour:minute from
        // now, via the calendar. This:
        //  • ignores the (possibly days-stale) DATE component of the @State Date,
        //    which the .hourAndMinute picker never updates (a stale base date
        //    would go strongly negative and become a forever INDEFINITE hold);
        //    and
        //  • is DST-correct: "tomorrow at HH:MM" across a DST boundary is 23h or
        //    25h away, not a literal 86,400s.
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: untilTime)
        guard let target = cal.nextDate(after: Date(),
                                        matching: DateComponents(hour: comps.hour,
                                                                 minute: comps.minute),
                                        matchingPolicy: .nextTime) else {
            showCustom = false
            return
        }
        let seconds = Int(target.timeIntervalSinceNow)
        if seconds > 0 { model.activateCustom(seconds: seconds) }
        showCustom = false
    }

    // MARK: - Kill caffeinate

    @ViewBuilder
    private var killCaffeinateButton: some View {
        // Count/enablement use the SAME predicate as the kill (model.killStray-
        // Caffeinate): the user's OWN caffeinate holds (isCaffeinate && natural
        // bucket == You), regardless of any manual category override. So the
        // displayed "Stop N" equals what gets killed and a caffeinate
        // overridden out of You is still counted + killable.
        let youCount = model.ownCaffeinateRows.count
        let hasYou = youCount > 0
        let label = "Stop \(youCount) Command\(youCount == 1 ? "" : "s")"
        // Inline confirmation rather than .confirmationDialog: a sheet/dialog
        // presented from a MenuBarExtra(.window) popover resigns the popover's key
        // window, which tears the popover down before the destructive action's
        // closure runs — so the dialog flashes, the menu closes, and nothing is
        // killed. Confirming inline keeps everything inside the popover.
        if confirmKill && hasYou {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stop \(youCount) command\(youCount == 1 ? "" : "s") you ran in Terminal? Apps keeping your Mac awake aren't affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(label, role: .destructive) {
                        _ = model.killStrayCaffeinate()
                        confirmKill = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Button("Cancel") { confirmKill = false }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }
        } else {
            Button {
                confirmKill = true
            } label: {
                Label("Stop Terminal Commands", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!hasYou)
            .help("Stops keep-awake commands you started in Terminal (the macOS caffeinate command). Apps keeping your Mac awake aren't affected.")
        }
    }

    // MARK: - Assertion list

    /// `assertionList` wrapped in a height-capped ScrollView. The list measures
    /// its own intrinsic height (via a background GeometryReader + preference) and
    /// we clamp the ScrollView's concrete height to `min(measured, maxListHeight)`,
    /// so it grows with the holder count up to the cap and then scrolls — without
    /// collapsing to ~0 the way a bare ScrollView does inside the .window
    /// MenuBarExtra.
    @ViewBuilder
    private var boundedAssertionList: some View {
        let height = listContentHeight > 0 ? min(listContentHeight, maxListHeight) : nil
        ScrollView(.vertical, showsIndicators: true) {
            assertionList
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self,
                                               value: proxy.size.height)
                    }
                )
        }
        .frame(height: height)
        .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
    }

    private var assertionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isListEmpty {
                Text(emptyStateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(sortedBuckets, id: \.self) { bucket in
                    if let rows = model.buckets[bucket], !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bucket.rawValue)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(rows.count)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(rows) { row in
                                assertionRow(row)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sortedBuckets: [Bucket] {
        Bucket.allCases.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// True when no buckets have any visible rows.
    private var isListEmpty: Bool {
        sortedBuckets.allSatisfy { (model.buckets[$0]?.isEmpty ?? true) }
    }

    private var emptyStateText: String {
        // If nothing visible but system is hidden, hint at the toggle.
        if !model.prefs.showSystemAssertions {
            return "Nothing is keeping your Mac awake. (System processes are hidden — turn on Show system processes in Settings.)"
        }
        return "Nothing is keeping your Mac awake."
    }

    private func assertionRow(_ row: AssertionRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            iconView(for: row)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = subtitle(for: row) {
                    Text(sub)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .foregroundStyle(row.isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
    }

    /// Combined VoiceOver label: title + reason + time-left.
    private func accessibilityLabel(for row: AssertionRow) -> String {
        var parts = [row.title]
        if !row.reason.isEmpty { parts.append(row.reason) }
        if let left = row.timeoutSecsLeft, left > 0 {
            parts.append("\(hms(TimeInterval(left))) left")
        }
        return parts.joined(separator: ", ")
    }

    /// Secondary line: reason descriptor and/or countdown, joined by " · ".
    private func subtitle(for row: AssertionRow) -> String? {
        var parts: [String] = []
        if !row.reason.isEmpty { parts.append(row.reason) }
        if let left = row.timeoutSecsLeft, left > 0 {
            parts.append("\(hms(TimeInterval(left))) left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func iconView(for row: AssertionRow) -> some View {
        if let nsImage = AppIdentityResolver.icon(forBundleID: row.bundleID, path: row.iconBundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Holder-specific SF Symbol if classification set one, else a generic
            // per-category fallback so the glyph still reads as its bucket (item 3).
            Image(systemName: row.sfFallback ?? row.bucket.fallbackSymbol)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                // Open Settings reliably from a .window MenuBarExtra (LSUIElement):
                // become a regular, frontmost app first, then open. The accessory
                // policy is restored when the Settings window closes (see the app
                // delegate). Teardown on quit is handled by the app delegate.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Spacer()
            Button("Quit Awake") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    // MARK: - Helpers

    private func hms(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Holder-list height measurement

/// Carries the holder list's measured intrinsic height up to the parent so the
/// bounded ScrollView can be given a concrete (non-collapsing) height.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
