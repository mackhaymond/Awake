import AppKit
import Darwin   // proc_pidpath

enum AppIdentityResolver {

    /// Icon cache keyed by bundleID or path (NOT pid — pids are reused). Capped.
    @MainActor private static var iconCache: [String: NSImage] = [:]
    @MainActor private static var iconCacheOrder: [String] = []   // FIFO eviction
    private static let iconCacheCap = 128

    /// caffeinate command-line cache, keyed by pid (stable for the proc's life).
    @MainActor private static var caffeinateCmdCache: [Int32: String] = [:]

    /// Drop caffeinate-command cache entries whose PID isn't in the current
    /// snapshot — PIDs are reused, so a stale entry could mislabel a new process.
    @MainActor static func pruneCaffeinateCache(livePIDs: Set<Int32>) {
        caffeinateCmdCache = caffeinateCmdCache.filter { livePIDs.contains($0.key) }
    }

    /// Friendly-name beautification for known bundle IDs / process names.
    private static let friendlyNames: [String: String] = [
        "com.apple.MobileSMS": "Messages",
        "com.apple.MobileSMS.MessagesViewService": "Messages",
        "com.apple.Music": "Music",
        "com.apple.Safari": "Safari",
        "com.apple.podcasts": "Podcasts",
        "com.apple.FaceTime": "FaceTime",
        "com.apple.QuickTimePlayerX": "QuickTime Player",
        "com.apple.finder": "Finder",
        "com.google.Chrome": "Google Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.openai.chat": "ChatGPT",
        "com.spotify.client": "Spotify",
        "com.tinyspeck.slackmacgap": "Slack",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
    ]

    /// Resolve identity for an assertion's effective holder. Layered fallback
    /// that degrades gracefully on dead PIDs.
    @MainActor static func identity(for a: PowerAssertion) -> AppIdentity {
        let pid = a.effectivePID

        // 0. caffeinate CLI — its IOKit BundlePath misleadingly points at
        //    powerd.bundle ("PowerManagement configd plugin"), so short-circuit
        //    with a clean, informative identity: the actual command line.
        if a.ownerProcName == "caffeinate" {
            return AppIdentity(
                displayName: caffeinateCommand(pid: a.ownerPID),
                bundleID: nil,
                iconBundleIDOrPath: nil,
                executablePath: nil,
                processNameForBucketing: "caffeinate"
            )
        }

        // 1. BundlePath from the dict — survives PID death.
        if let bundlePath = a.bundlePath,
           let bundle = Bundle(path: bundlePath) {
            let name = bundleDisplayName(bundle) ?? lastPathName(bundlePath)
            let bid = bundle.bundleIdentifier
            return AppIdentity(
                displayName: beautify(name: name, bundleID: bid),
                bundleID: bid,
                iconBundleIDOrPath: bid ?? bundlePath,
                executablePath: bundle.executablePath,
                processNameForBucketing: procName(forBundle: bundle, fallback: a.ownerProcName)
            )
        }

        // 2. NSRunningApplication for a live PID.
        if pid > 0,
           let running = NSRunningApplication(processIdentifier: pid) {
            let name = running.localizedName ?? running.bundleIdentifier ?? a.ownerProcName
            let bid = running.bundleIdentifier
            let execName = running.executableURL?.lastPathComponent ?? a.ownerProcName
            return AppIdentity(
                displayName: beautify(name: name, bundleID: bid),
                bundleID: bid,
                iconBundleIDOrPath: bid ?? running.bundleURL?.path,
                executablePath: running.executableURL?.path,
                processNameForBucketing: execName
            )
        }

        // 3. proc_pidpath → enclosing .app → Info.plist.
        if pid > 0, let execPath = executablePath(forPID: pid) {
            if let appURL = enclosingAppBundle(forExecutablePath: execPath),
               let bundle = Bundle(url: appURL) {
                let name = bundleDisplayName(bundle) ?? appURL.deletingPathExtension().lastPathComponent
                let bid = bundle.bundleIdentifier
                return AppIdentity(
                    displayName: beautify(name: name, bundleID: bid),
                    bundleID: bid,
                    iconBundleIDOrPath: bid ?? appURL.path,
                    executablePath: execPath,
                    processNameForBucketing: (execPath as NSString).lastPathComponent
                )
            }
            // Bare executable (e.g. CLI tool).
            let execName = (execPath as NSString).lastPathComponent
            return AppIdentity(
                displayName: beautify(name: execName, bundleID: nil),
                bundleID: nil,
                iconBundleIDOrPath: execPath,
                executablePath: execPath,
                processNameForBucketing: execName
            )
        }

        // 4. bundleID token from the assertion name.
        if let bid = bundleID(inNameToken: a.rawName) {
            let name = friendlyNames[bid] ?? appName(forBundleID: bid) ?? a.ownerProcName
            return AppIdentity(
                displayName: beautify(name: name, bundleID: bid),
                bundleID: bid,
                iconBundleIDOrPath: bid,
                executablePath: nil,
                processNameForBucketing: a.ownerProcName
            )
        }

        // 5. Graceful fallback.
        let fallbackName = a.ownerProcName.isEmpty ? "PID \(pid)" : a.ownerProcName
        return AppIdentity(
            displayName: fallbackName,
            bundleID: nil,
            iconBundleIDOrPath: nil,
            executablePath: nil,
            processNameForBucketing: a.ownerProcName
        )
    }

    // MARK: - Icon lookup

    @MainActor static func icon(forBundleID bundleID: String?, path: String?) -> NSImage? {
        let cacheKey = bundleID ?? path
        if let cacheKey, let cached = iconCache[cacheKey] {
            return cached
        }

        var image: NSImage?
        let workspace = NSWorkspace.shared

        if let bundleID,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            image = workspace.icon(forFile: url.path)
        } else if let path {
            if path.hasSuffix(".app") || FileManager.default.fileExists(atPath: path) {
                image = workspace.icon(forFile: path)
            }
        }

        if let image, let cacheKey {
            iconCache[cacheKey] = image
            iconCacheOrder.append(cacheKey)
            if iconCacheOrder.count > iconCacheCap {
                let evict = iconCacheOrder.removeFirst()
                iconCache.removeValue(forKey: evict)
            }
        }
        return image
    }

    // MARK: - Low-level helpers

    /// The caffeinate process's command line (e.g. "caffeinate -i -t 300"),
    /// fetched once per pid via `ps` and cached. Falls back to "caffeinate".
    ///
    /// In the LIVE app the cache is pre-warmed OFF the main actor (see
    /// `resolveCaffeinateCommands` / `seedCaffeinateCommands`) before classification
    /// runs, so this returns a cache hit and spawns nothing on the per-tick hot
    /// path. A miss only happens off the hot path (e.g. the one-shot `--dump`),
    /// where a synchronous `ps` spawn is acceptable to keep output faithful.
    @MainActor static func caffeinateCommand(pid: Int32) -> String {
        if let cached = caffeinateCmdCache[pid] { return cached }
        let command = runPS(forPID: pid)
        caffeinateCmdCache[pid] = command
        return command
    }

    /// Seed the caffeinate-command cache on the MainActor from a batch resolved
    /// off the main actor. Only fills missing/placeholder entries so a real
    /// command line never gets overwritten by a placeholder.
    @MainActor static func seedCaffeinateCommands(_ commands: [Int32: String]) {
        for (pid, command) in commands {
            caffeinateCmdCache[pid] = command
        }
    }

    /// PIDs already present in the cache (so the off-main pre-warm only spawns
    /// `ps` for genuinely new caffeinate PIDs).
    @MainActor static func cachedCaffeinatePIDs() -> Set<Int32> {
        Set(caffeinateCmdCache.keys)
    }

    /// Resolve caffeinate command lines for the given PIDs by spawning `ps`.
    /// `nonisolated` so it can run OFF the main actor (no shared mutable state is
    /// touched — the cache is seeded back on the MainActor by the caller).
    nonisolated static func resolveCaffeinateCommands(for pids: [Int32]) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for pid in pids where pid > 0 {
            out[pid] = runPS(forPID: pid)
        }
        return out
    }

    /// Spawn `ps` for one PID and extract its caffeinate command line. Pure /
    /// `nonisolated`; safe to call off the main actor.
    private nonisolated static func runPS(forPID pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "args=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr is unused; route it to /dev/null so an undrained Pipe can't
        // deadlock the child on large stderr.
        process.standardError = FileHandle.nullDevice

        var command = "caffeinate"
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !raw.isEmpty {
                // `ps -o args=` may prefix a full path; show from "caffeinate" on.
                if let r = raw.range(of: "caffeinate") {
                    command = String(raw[r.lowerBound...])
                } else {
                    command = raw
                }
            }
        }
        return command
    }

    static func executablePath(forPID pid: Int32) -> String? {
        let bufSize = Int(4 * MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: bufSize)
        let result = proc_pidpath(pid, &buffer, UInt32(bufSize))
        guard result > 0 else { return nil }
        let bytes = buffer.prefix(Int(result)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func enclosingAppBundle(forExecutablePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        // Walk up looking for a ".app" component.
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return nil
    }

    static func bundleID(inNameToken token: String) -> String? {
        // General reverse-DNS bundle id (>= 3 dot-separated components), not just
        // com.* — also matches org./net./io./dev./us./company. etc. Underscores
        // are permitted because some bundle ids use them.
        let pattern = #"[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+){2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let m = regex.firstMatch(in: token, range: range),
              let r = Range(m.range, in: token) else { return nil }
        // Strip a trailing dot that isn't part of the id.
        return String(token[r]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    // MARK: - Private name helpers

    private static func beautify(name: String, bundleID: String?) -> String {
        if let bundleID, let friendly = friendlyNames[bundleID] { return friendly }
        return name
    }

    private static func bundleDisplayName(_ bundle: Bundle) -> String? {
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    private static func lastPathName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func procName(forBundle bundle: Bundle, fallback: String) -> String {
        if let exec = bundle.executablePath {
            return (exec as NSString).lastPathComponent
        }
        return fallback
    }

    private static func appName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}
