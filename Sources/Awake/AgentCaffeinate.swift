import Foundation
import AppKit

/// Recognizes the `caffeinate` processes that the local *agent stack* spawns and
/// names the STATE each one represents, instead of showing its raw command line
/// as one more anonymous "command you ran".
///
/// Two distinct producers, both short-lived and self-expiring:
///
///  1. **Claude Code keepalive** — `caffeinate -i -t 300`, re-spawned by each
///     actively-working session roughly every 5 minutes. Definitive tell: the
///     caffeinate's DIRECT parent is the `claude` process itself.
///  2. **Agent GUI display hold** — `caffeinate -d -t 600`, held by the cua MCP
///     shim only while an agent is driving the GUI, so the idle screen-lock
///     can't close the accessibility doors mid-run. Definitive tell: the direct
///     parent is a python process whose argv names `cua-mcp-shim`.
///
/// Near the end of its life either one can outlive its parent and reparent to
/// launchd; the argv fingerprint is then the only thing left to go on, so an
/// orphan is matched on its EXACT argv (plus, for the GUI hold, the feature's
/// flag file) and labelled as expiring rather than as live work.
///
/// Deliberately NOT matched here: Claude Desktop's own `NoIdleSleepAssertion
/// named "Electron"`. That's a native assertion under the app's pid, not a
/// caffeinate, so it never reaches this code and keeps showing as the app.
@MainActor
enum AgentCaffeinate {

    /// Marker for the caffeinate the cua MCP shim holds. The whole feature only
    /// exists while this flag file does, so an orphaned `-d -t 600` is only
    /// attributed to it when the flag is present.
    /// Overridable via `AWAKE_CUA_STATE_DIR` purely so the recognizer can be
    /// exercised against a fixture directory (`--dump`) without writing to the
    /// live shim state the notch and monitor read.
    private static let stateDir: URL = {
        if let override = ProcessInfo.processInfo.environment["AWAKE_CUA_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CuaNotch", isDirectory: true)
    }()
    private static var assertFlagURL: URL { stateDir.appendingPathComponent("display-assertion.enabled") }
    private static var activityURL: URL { stateDir.appendingPathComponent("activity.json") }

    /// A session record is only worth naming while it's recent: the shim drops
    /// the assertion ~120 s after the last GUI action, so anything older than
    /// this is a leftover record, not the run that's holding the display.
    private static let activityFreshness: TimeInterval = 180

    // MARK: - Entry point

    /// A named agent state for this caffeinate, or nil if it isn't one of ours
    /// (the caller then falls back to generic ancestry attribution).
    static func match(command: String,
                      chain: [ProcessAncestry.Proc]) -> CaffeinateOrigin.Resolved? {
        let args = flags(in: command)
        // Only the DIRECT parent counts: a caffeinate reached through a shell or
        // any other hop is something the agent ran on the user's behalf, not the
        // stack's own keepalive, and belongs in the generic attribution below.
        let parent = chain.first
        let orphaned = parent == nil || parent?.pid == 1 || parent?.name == "launchd"

        if let parent, isClaude(parent), args.contains("-i") {
            return claudeCode(sessionID: parent.pid, expiring: false)
        }
        if let parent, isCuaShim(parent), args.contains("-d") {
            return guiDisplayHold(sessionID: parent.pid, expiring: false)
        }

        // Reparented to launchd: the argv fingerprint is all that's left.
        guard orphaned else { return nil }
        if args == ["-i", "-t", "300"] {
            return claudeCode(sessionID: nil, expiring: true)
        }
        if args == ["-d", "-t", "600"],
           FileManager.default.fileExists(atPath: assertFlagURL.path) {
            return guiDisplayHold(sessionID: nil, expiring: true)
        }
        return nil
    }

    // MARK: - The states

    private static func claudeCode(sessionID: Int32?, expiring: Bool) -> CaffeinateOrigin.Resolved {
        CaffeinateOrigin.Resolved(
            bucket: .apps,
            title: "Claude Code",
            reason: expiring ? "keepalive expiring" : "working",
            iconBundleID: nil,
            sfFallback: "chevron.left.forwardslash.chevron.right",
            groupKey: "agent.claude-code",
            groupNoun: "session",
            sessionID: sessionID,
            note: """
                Claude Code keeps your Mac awake for 5 minutes at a time while a \
                session is actively working, renewing it as long as work continues. \
                Each hold expires on its own — there's nothing to stop.
                """
        )
    }

    private static func guiDisplayHold(sessionID: Int32?, expiring: Bool) -> CaffeinateOrigin.Resolved {
        let driving = drivenAppNames()
        var reason = expiring ? "display hold expiring" : "holding the display"
        if !expiring, !driving.isEmpty {
            reason += " · " + driving.joined(separator: ", ")
        }
        return CaffeinateOrigin.Resolved(
            bucket: .apps,
            title: "Agent GUI run",
            reason: reason,
            iconBundleID: nil,
            sfFallback: "display",
            groupKey: "agent.cua-display",
            groupNoun: "run",
            sessionID: sessionID,
            note: """
                An agent is driving an app on screen and is holding the display \
                awake so the idle lock can't interrupt it. It's released about \
                2 minutes after the last action and expires on its own after 10. \
                Sleeping the displays yourself still works — this doesn't block it.
                """
        )
    }

    // MARK: - Parent fingerprints

    private static func isClaude(_ p: ProcessAncestry.Proc) -> Bool {
        if p.name == "claude" { return true }
        // Claude Code's executable is named by version (e.g. "2.1.168"), so match
        // its install directory too.
        guard let path = p.path?.lowercased() else { return false }
        return path.contains("/.claude/") || path.contains("/claude/")
    }

    /// A python process whose argv names the cua MCP shim. The argv read is
    /// gated on a python-looking parent so the extra sysctl only happens for the
    /// handful of processes that could possibly be the shim.
    private static func isCuaShim(_ p: ProcessAncestry.Proc) -> Bool {
        let base = (p.path as NSString?)?.lastPathComponent ?? p.name
        guard p.name.lowercased().hasPrefix("python") || base.lowercased().hasPrefix("python")
        else { return false }
        return ProcessAncestry.arguments(of: p.pid)
            .contains { $0.contains("cua-mcp-shim") }
    }

    // MARK: - Command line

    /// The caffeinate flags from a command line like "caffeinate -i -t 300",
    /// i.e. everything after the executable name.
    private static func flags(in command: String) -> [String] {
        var parts = command.split(separator: " ").map(String.init)
        if let first = parts.first, first.hasSuffix("caffeinate") { parts.removeFirst() }
        return parts
    }

    // MARK: - Which app is being driven (activity.json enrichment)

    private static var activityCache: (modified: Date, size: Int, names: [String])?

    /// Friendly names of the apps agents are currently driving, from the cua
    /// shim's `activity.json` (atomically replaced, so a plain read is safe).
    /// Empty when the file is missing, unparseable, or holds only stale records.
    private static func drivenAppNames() -> [String] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: activityURL.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return [] }
        if let c = activityCache, c.modified == modified, c.size == size { return c.names }

        var names: [String] = []
        if let data = try? Data(contentsOf: activityURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessions = root["sessions"] as? [String: Any] {
            let now = Date().timeIntervalSince1970
            let fresh = sessions.values
                .compactMap { $0 as? [String: Any] }
                .filter { now - (($0["ts"] as? Double) ?? 0) <= activityFreshness }
                .sorted { (($0["ts"] as? Double) ?? 0) > (($1["ts"] as? Double) ?? 0) }
            for entry in fresh {
                guard let name = appName(pid: entry["pid"] as? Int,
                                         bundleID: entry["bundle_id"] as? String),
                      !names.contains(name) else { continue }
                names.append(name)
            }
        }
        activityCache = (modified, size, names)
        return names
    }

    /// Friendly name for a driven app: the live process first (cheapest and most
    /// accurate), then its bundle id.
    private static func appName(pid: Int?, bundleID: String?) -> String? {
        if let pid, pid > 0,
           let running = NSRunningApplication(processIdentifier: Int32(pid)),
           let name = running.localizedName { return name }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return AppIdentityResolver.appName(forBundleID: bundleID) ?? bundleID
    }
}
