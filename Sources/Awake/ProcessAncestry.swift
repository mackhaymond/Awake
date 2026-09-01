import Foundation
import Darwin

/// Walks a process's parent chain (via sysctl KERN_PROC + proc_pidpath) so we
/// can attribute a `caffeinate` process to whoever *started* it.
enum ProcessAncestry {

    struct Proc: Sendable {
        let pid: Int32
        let ppid: Int32
        let name: String      // p_comm (≤16 chars)
        let path: String?     // full executable path (proc_pidpath)
    }

    /// (ppid, comm) for a pid, or nil if it no longer exists.
    static func info(pid: Int32) -> (ppid: Int32, comm: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0)
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let ppid = Int32(kp.kp_eproc.e_ppid)
        var comm = kp.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (ppid, name)
    }

    /// A process's argument vector, read straight from the kernel — no `ps`
    /// spawn. Used to fingerprint a parent whose `p_comm` is only a runtime name
    /// (a `python3` that is really the cua MCP shim). Empty when the process is
    /// gone or owned by another user.
    ///
    /// KERN_PROCARGS2 lays out: `int argc`, the NUL-terminated exec path, NUL
    /// padding, then `argc` NUL-separated arguments, then the environment.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0 else { return [] }

        let header = MemoryLayout<Int32>.size
        guard size > header else { return [] }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<header]) }
        guard argc > 0 else { return [] }

        var i = header
        while i < size && buf[i] != 0 { i += 1 }        // skip the exec path
        while i < size && buf[i] == 0 { i += 1 }        // skip its NUL padding

        var args: [String] = []
        var start = i
        while i < size && args.count < Int(argc) {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    /// Ancestors from the immediate parent up toward launchd (caffeinate itself
    /// is NOT included). Ordered nearest-first.
    static func ancestry(of pid: Int32, maxDepth: Int = 16) -> [Proc] {
        guard let first = info(pid: pid) else { return [] }
        var result: [Proc] = []
        var current = first.ppid
        var seen = Set<Int32>()
        var depth = 0
        while current >= 1 && !seen.contains(current) && depth < maxDepth {
            seen.insert(current)
            if current == 1 {
                result.append(Proc(pid: 1, ppid: 0, name: "launchd", path: nil))
                break
            }
            guard let m = info(pid: current) else { break }
            let path = AppIdentityResolver.executablePath(forPID: current)
            result.append(Proc(pid: current, ppid: m.ppid, name: m.comm, path: path))
            current = m.ppid
            depth += 1
        }
        return result
    }
}

/// Decides which bucket a `caffeinate` process belongs to based on its
/// originating ancestor, and how to label it.
///
///  - a known agent-stack keepalive        →  APPS, named by the STATE it
///    represents (see `AgentCaffeinate`) rather than by its command line
///  - a terminal emulator or a bare shell  →  YOU (you started it)
///  - any other tool or app (Claude Code, build scripts, Electron apps…)
///    that spawned `caffeinate` under the hood        →  APPS ("Tool · via caffeinate")
@MainActor
enum CaffeinateOrigin {

    struct Resolved: Sendable {
        let bucket: Bucket
        let title: String
        let reason: String
        let iconBundleID: String?
        let sfFallback: String?
        /// Non-nil for holders that represent ONE ongoing state rather than one
        /// process: rows sharing a key collapse into a single row (a working
        /// Claude Code session re-spawns its keepalive every few minutes, so the
        /// same state otherwise stacks up several identical rows).
        var groupKey: String? = nil
        /// What one member of the group is called, for the collapsed row's
        /// count ("working · 3 sessions").
        var groupNoun: String? = nil
        /// The distinct thing holding this — the owning agent process. Several
        /// overlapping caffeinates from ONE session share a sessionID, so the
        /// collapsed row counts sessions rather than processes.
        var sessionID: Int32? = nil
        /// Longer explanation, shown as the row's tooltip.
        var note: String? = nil
    }

    /// Shells / multiplexers / wrappers that are "pass-through" — they don't own
    /// the caffeinate, they just relayed it. Compared after stripping a leading
    /// "-" (login shells appear as "-zsh") and lowercasing.
    private static let passThrough: Set<String> = [
        "zsh", "bash", "sh", "dash", "fish", "ksh", "tcsh", "csh", "ash",
        "login", "tmux", "tmux: server", "screen", "env", "sudo", "doas",
        "nice", "setsid", "script", "time", "xargs", "stdbuf", "caffeinate",
        "reattach-to-user-namespace",
    ]

    /// Language runtimes that are usually a thin host for the *real* app
    /// (Electron helpers, etc.). When the originator is one of these we
    /// climb to the owning .app above it, if any.
    private static let genericRuntime: Set<String> = [
        "node", "deno", "bun", "electron", "python", "python3", "ruby", "perl",
    ]

    /// comm → friendly terminal name.
    private static let terminalComms: [String: String] = [
        "Terminal": "Terminal", "iTerm2": "iTerm", "wezterm-gui": "WezTerm",
        "wezterm": "WezTerm", "alacritty": "Alacritty", "kitty": "kitty",
        "ghostty": "Ghostty", "Warp": "Warp", "Hyper": "Hyper", "tabby": "Tabby",
        "rio": "Rio",
    ]

    /// bundle id → friendly terminal name (when comm is ambiguous, e.g. "stable").
    private static let terminalBundleIDs: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
        "com.github.wez.wezterm": "WezTerm", "org.alacritty": "Alacritty",
        "net.kovidgoyal.kitty": "kitty", "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp", "co.zeit.hyper": "Hyper",
    ]

    /// comm/bundle → nicer tool name.
    private static let friendlyTool: [String: String] = [
        "claude": "Claude Code",
        "com.anthropic.claude": "Claude",
    ]

    // MARK: - Entry point

    static func classify(caffeinatePID pid: Int32, command: String) -> Resolved {
        let chain = ProcessAncestry.ancestry(of: pid)

        // A caffeinate the local agent stack spawned means something specific;
        // name that state instead of the command line. Checked first, and
        // before the empty-chain fallback, because an orphaned keepalive whose
        // parent already exited is exactly the case that used to read as a bare
        // "caffeinate -i -t 300" command the user supposedly ran.
        if let agent = AgentCaffeinate.match(command: command, chain: chain) {
            return agent
        }

        // Couldn't read the ancestry at all (transient/dead pid): don't assume
        // it's the user's manual hold — treat as an unattributed tool under Apps.
        if chain.isEmpty {
            return Resolved(bucket: .apps,
                            title: command.isEmpty ? "caffeinate" : command,
                            reason: "via caffeinate",
                            iconBundleID: nil, sfFallback: "bolt.badge.clock")
        }

        var originator = chain.first { !isPassThrough($0) }

        // Bridge a generic runtime up to the owning non-terminal .app.
        if let o = originator, isGenericRuntime(o),
           let owner = chain.drop(while: { $0.pid != o.pid }).dropFirst()
               .first(where: { appBundleURL(for: $0) != nil && terminalName(for: $0) == nil }) {
            originator = owner
        }

        guard let o = originator else { return you(command, source: "CLI") }

        if let term = terminalName(for: o)  { return you(command, source: term) }
        if o.pid == 1 || o.name == "launchd" { return you(command, source: "CLI") }

        // A tool/app spawned caffeinate under the hood → attribute it.
        let (name, bundleID) = appIdentity(for: o)
        return Resolved(bucket: .apps, title: name, reason: "via caffeinate",
                        iconBundleID: bundleID, sfFallback: "bolt.badge.clock")
    }

    // MARK: - Helpers

    private static func you(_ command: String, source: String) -> Resolved {
        Resolved(bucket: .you, title: command, reason: source,
                 iconBundleID: nil, sfFallback: "cup.and.saucer")
    }

    /// Candidate names to match a process against: the (≤16-char truncated)
    /// p_comm AND, when a full path is known, its basename — so long names like
    /// `reattach-to-user-namespace` (which p_comm truncates) still match.
    private static func names(of p: ProcessAncestry.Proc) -> [String] {
        var names = [p.name]
        if let path = p.path {
            let base = (path as NSString).lastPathComponent
            if base != p.name { names.append(base) }
        }
        return names
    }

    private static func isPassThrough(_ p: ProcessAncestry.Proc) -> Bool {
        names(of: p).contains { isPassThroughName($0) }
    }

    private static func isPassThroughName(_ comm: String) -> Bool {
        var n = comm
        if n.hasPrefix("-") { n.removeFirst() }
        let lower = n.lowercased()
        if passThrough.contains(lower) || passThrough.contains(n) { return true }
        // p_comm truncates at 16 chars; match known long names by prefix too.
        return passThrough.contains { $0.count > 15 && lower.hasPrefix(String($0.prefix(15))) }
    }

    private static func isGenericRuntime(_ p: ProcessAncestry.Proc) -> Bool {
        names(of: p).contains { genericRuntime.contains($0.lowercased()) }
    }

    private static func appBundleURL(for p: ProcessAncestry.Proc) -> URL? {
        guard let path = p.path else { return nil }
        return AppIdentityResolver.enclosingAppBundle(forExecutablePath: path)
    }

    private static func terminalName(for p: ProcessAncestry.Proc) -> String? {
        for n in names(of: p) {
            if let t = terminalComms[n] { return t }
        }
        if let url = appBundleURL(for: p), let b = Bundle(url: url),
           let id = b.bundleIdentifier, let n = terminalBundleIDs[id] {
            return n
        }
        return nil
    }

    private static func appIdentity(for p: ProcessAncestry.Proc) -> (name: String, bundleID: String?) {
        if let url = appBundleURL(for: p), let b = Bundle(url: url) {
            let raw = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let bid = b.bundleIdentifier
            let nice = friendlyTool[bid ?? ""] ?? friendlyTool[raw] ?? raw
            return (nice, bid)
        }
        return (friendlyToolName(comm: p.name, path: p.path), nil)
    }

    /// Friendly name for a bare (non-.app) tool. Detects Claude Code by its
    /// install path, since its executable is named by version (e.g. "2.1.168")
    /// so `p_comm` isn't "claude".
    private static func friendlyToolName(comm: String, path: String?) -> String {
        if let p = path?.lowercased(),
           p.contains("/claude/") || p.contains("/.claude/") {
            return "Claude Code"
        }
        return friendlyTool[comm] ?? comm
    }
}
