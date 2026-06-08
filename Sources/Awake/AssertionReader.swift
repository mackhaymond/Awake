import Foundation
import IOKit
import IOKit.pwr_mgt

enum AssertionSource: Sendable {
    case ioKit
    case pmset
}

enum AssertionReader {

    /// Primary entry. Tries IOKit; if it returns empty AND pmset shows holders,
    /// falls back. When `source == .pmset`, reads via pmset directly.
    static func read(preferring source: AssertionSource = .ioKit) -> [PowerAssertion] {
        switch source {
        case .pmset:
            return readPMSet()
        case .ioKit:
            let ioKit = readIOKit()
            if !ioKit.isEmpty { return ioKit }
            // IOKit empty: check the aggregate status; if anything blocking is
            // asserted, fall back to the text parser.
            if aggregateBlockingCount() > 0 {
                return readPMSet()
            }
            return ioKit
        }
    }

    // MARK: - IOKit path

    static func readIOKit() -> [PowerAssertion] {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let rc = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard rc == kIOReturnSuccess,
              let dict = assertionsByProcess?.takeRetainedValue() as? [Int: [[String: Any]]]
        else { return [] }

        var results: [PowerAssertion] = []
        for (pid, perProcess) in dict {
            for entry in perProcess {
                results.append(makeAssertion(ownerPID: Int32(pid), entry: entry))
            }
        }
        return results
    }

    private static func makeAssertion(ownerPID: Int32, entry: [String: Any]) -> PowerAssertion {
        let rawType = (entry["AssertType"] as? String)
            ?? (entry["AssertionTrueType"] as? String)
            ?? "_other"

        let ownerProcName = (entry["Process Name"] as? String) ?? "pid \(ownerPID)"

        var createdForPID: Int32?
        if let onBehalf = entry["AssertionOnBehalfOfPID"] as? Int, onBehalf > 0 {
            createdForPID = Int32(onBehalf)
        }

        let isRunningboardd = (entry["_IsRunningboardd"] as? Int) == 1
            || ownerProcName == "runningboardd"

        let bundlePath = entry["BundlePath"] as? String

        let id: String
        if let gid = entry["GlobalUniqueID"] as? Int {
            id = String(format: "0x%016llx", Int64(gid))
        } else if let aid = entry["AssertionId"] as? Int {
            id = "id\(aid)-pid\(ownerPID)"
        } else {
            id = "\(rawType)-pid\(ownerPID)-\(UUID().uuidString)"
        }

        let rawName = (entry["AssertName"] as? String) ?? ""
        let details = entry["Details"] as? String
        let localizedReason = entry["HumanReadableReason"] as? String

        // Compute the LIVE time remaining. Despite its name,
        // `AssertTimeoutTimeLeft` reports the ORIGINAL configured timeout and
        // never decrements, so a timed third-party holder would show a frozen
        // countdown. When IOKit also supplies `AssertTimeoutUpdateTime` (the
        // Date the timeout was last (re)armed), derive the true remaining as
        // configured - elapsed. Fall back to the raw value only when no update
        // time is present.
        var timeoutSecsLeft: Int?
        let configuredTimeout = (entry["AssertTimeoutTimeLeft"] as? Int)
            ?? (entry["TimeoutSeconds"] as? Int)
        if let configured = configuredTimeout {
            if let updateTime = entry["AssertTimeoutUpdateTime"] as? Date {
                let elapsed = Date().timeIntervalSince(updateTime)
                timeoutSecsLeft = max(0, configured - Int(elapsed))
            } else {
                timeoutSecsLeft = configured
            }
        }

        let timeoutAction = entry["TimeoutAction"] as? String

        return PowerAssertion(
            id: id,
            ownerPID: ownerPID,
            ownerProcName: ownerProcName,
            createdForPID: createdForPID,
            isRunningboardd: isRunningboardd,
            bundlePath: bundlePath,
            type: AssertionType(rawType: rawType),
            rawType: rawType,
            rawName: rawName,
            details: details,
            localizedReason: localizedReason,
            timeoutSecsLeft: timeoutSecsLeft,
            timeoutAction: timeoutAction
        )
    }

    /// Sum of blocking-type assertion levels reported by the aggregate status.
    /// Used solely to decide whether the pmset fallback is worth running.
    private static func aggregateBlockingCount() -> Int {
        var statusDict: Unmanaged<CFDictionary>?
        let rc = IOPMCopyAssertionsStatus(&statusDict)
        guard rc == kIOReturnSuccess,
              let status = statusDict?.takeRetainedValue() as? [String: Int]
        else { return 0 }

        let blockingKeys = [
            kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionTypePreventSystemSleep as String,
            kIOPMAssertionTypeNoIdleSleep as String,
            kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            kIOPMAssertionTypeNoDisplaySleep as String,
        ]
        return blockingKeys.reduce(0) { $0 + (status[$1] ?? 0) }
    }

    // MARK: - pmset fallback path

    static func readPMSet() -> [PowerAssertion] {
        guard let output = runPMSet() else { return [] }
        return parsePMSet(output)
    }

    private static func runPMSet() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr is unused; route it to /dev/null. An undrained Pipe here could
        // deadlock if the child wrote more than the pipe buffer to stderr while
        // we block in readDataToEndOfFile() on stdout.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Parses `pmset -g assertions` "Listed by owning process" section.
    static func parsePMSet(_ output: String) -> [PowerAssertion] {
        // Header line:  pid 721(Messages): [0x...] 00:01:23 PreventUserIdleSystemSleep named: "..."
        // pmset can append a trailing status marker after the quoted name, e.g.
        //   ... named: "x" (timed out)   /   ... named: "x" (Suspended)
        // so the name capture is non-greedy and an optional parenthesized marker
        // is tolerated after it; otherwise such whole assertions are dropped.
        let headerPattern = #"^\s*pid (\d+)\(([^)]*)\): \[(0x[0-9a-fA-F]+)\] (\d+:\d+:\d+) (\S+) named: "(.*?)"\s*(?:\(.*\))?\s*$"#
        guard let headerRegex = try? NSRegularExpression(pattern: headerPattern) else { return [] }

        var results: [PowerAssertion] = []
        var current: PendingAssertion?

        func flush() {
            if let p = current { results.append(p.build()) }
            current = nil
        }

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = headerRegex.firstMatch(in: line, range: range) {
                flush()
                func cap(_ i: Int) -> String {
                    guard let r = Range(m.range(at: i), in: line) else { return "" }
                    return String(line[r])
                }
                let pid = Int32(cap(1)) ?? -1
                let proc = cap(2)
                let gid = cap(3)
                // cap(4) = age string (unused); cap(5) = type; cap(6) = name.
                let type = cap(5)
                let name = cap(6)
                current = PendingAssertion(
                    id: gid,
                    ownerPID: pid,
                    ownerProcName: proc,
                    rawType: type,
                    rawName: name
                )
                continue
            }

            guard current != nil else { continue }
            // Tab-indented follow-on attributes.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let v = valueAfterPrefix("Created for PID:", in: trimmed) {
                // pmset formats this as "Created for PID: %d. " (period + space,
                // no trailing newline), so the rest of the assertion's
                // attributes ("Resources: ...", "Localized=...") are
                // concatenated onto the SAME physical line. Take only the
                // leading digits before parsing, and still scan the remainder
                // of the line for a "Localized=" reason (not gated by else-if).
                let leadingDigits = v.prefix { $0.isNumber }
                if !leadingDigits.isEmpty {
                    current?.createdForPID = Int32(leadingDigits)
                }
                if let reason = value(after: "Localized=", in: trimmed) {
                    current?.localizedReason = reason
                }
            } else if let v = valueAfterPrefix("Details:", in: trimmed) {
                current?.details = v
            } else if let v = value(after: "Localized=", in: trimmed) {
                current?.localizedReason = v
            } else if trimmed.hasPrefix("Timeout will fire in") {
                if let secs = timeoutSecs(in: trimmed) {
                    current?.timeoutSecsLeft = secs
                }
                if let action = value(after: "Action=", in: trimmed) {
                    current?.timeoutAction = action
                }
            }
        }
        flush()
        return results
    }

    // MARK: - pmset parse helpers

    private struct PendingAssertion {
        let id: String
        let ownerPID: Int32
        let ownerProcName: String
        let rawType: String
        let rawName: String
        var createdForPID: Int32?
        var details: String?
        var localizedReason: String?
        var timeoutSecsLeft: Int?
        var timeoutAction: String?

        func build() -> PowerAssertion {
            PowerAssertion(
                id: id,
                ownerPID: ownerPID,
                ownerProcName: ownerProcName,
                createdForPID: createdForPID,
                isRunningboardd: ownerProcName == "runningboardd",
                bundlePath: nil,
                type: AssertionType(rawType: rawType),
                rawType: rawType,
                rawName: rawName,
                details: details,
                localizedReason: localizedReason,
                timeoutSecsLeft: timeoutSecsLeft,
                timeoutAction: timeoutAction
            )
        }
    }

    /// Value after a leading prefix label (e.g. "Details: foo"). Anchored to the
    /// start of the trimmed line so a value containing the label can't false-match.
    private static func valueAfterPrefix(_ prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Value after an inline token (e.g. "Action=Release") that can appear
    /// anywhere on the line.
    private static func value(after prefix: String, in line: String) -> String? {
        guard let r = line.range(of: prefix) else { return nil }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Seconds from a "Timeout will fire in N secs (Action=...)" line via an
    /// explicit capture, so 0 stays distinguishable from "no match" (nil).
    private static func timeoutSecs(in line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"fire in (\d+) secs"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = regex.firstMatch(in: line, range: range),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return Int(line[r])
    }
}
