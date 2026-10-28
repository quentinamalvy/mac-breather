// Mac Breather, AI session states.
// Claude: the official status Claude Code writes to ~/.claude/sessions/<pid>.json (busy, waiting, idle).
// Codex: task start and completion events, read incrementally from ~/.codex/sessions.

import Foundation

enum SessionState: Int, Comparable {
    case waiting = 0, working, done, seen, idle   // display order: what needs you comes first

    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .waiting: return "Needs you"
        case .working: return "Working"
        case .done: return "Your turn"
        case .seen: return "Seen"
        case .idle: return "Idle"
        }
    }
}

struct StateReading {
    var state: SessionState
    var since: Date
    var detail = ""        // extra detail: "Asked a question", "No news"...
    var certain = true     // false when the state is inferred rather than declared: no notification
}

/// A finished session with no news for this long, and no CPU, becomes idle:
/// still open, it holds its memory without working.
let idleDelay: TimeInterval = 30 * 60

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func modificationDate(_ file: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
}

// MARK: - Claude

func claudeState(_ s: Session, now: Date = Date()) -> StateReading {
    guard let r = s.registry else {
        // No registry entry (older version, terminal session): only the CPU tells.
        let quiet = now.timeIntervalSince(s.lastActive)
        return StateReading(state: s.cpu > 3 ? .working : quiet > idleDelay ? .idle : .done,
                            since: s.lastActive, certain: false)
    }
    switch r.status {
    case "busy":
        return StateReading(state: .working, since: r.since)
    case "waiting":
        return StateReading(state: .waiting, since: r.since, detail: r.waitingFor.map(describeWaiting) ?? "")
    default:
        // Idle for a long time, and its child processes (builds, background servers) are not working either.
        let idle = now.timeIntervalSince(r.since) > idleDelay && now.timeIntervalSince(s.lastActive) > idleDelay
        return StateReading(state: idle ? .idle : .done, since: r.since)
    }
}

private func describeWaiting(_ w: String) -> String {
    let l = w.lowercased()
    if l.contains("permission") || l.contains("approv") { return "Needs your permission" }
    if l.contains("question") || l.contains("input") || l.contains("answer") { return "Asked a question" }
    if l.contains("plan") { return "Plan to approve" }
    return ""
}

// MARK: - Codex

struct CodexThread {
    let id: String
    let title: String
    let reading: StateReading
}

/// Follows a Codex log without re-reading it: keeps the offset reached and the last task event seen.
private struct Tracker {
    var offset: UInt64 = 0
    var event: String?      // task_started, task_complete, turn_aborted, or an approval request
    var at: Date?
}

final class CodexReader {
    private var titles: [String: String] = [:]
    private var titlesReadAt: Date?
    private let root = NSHomeDirectory() + "/.codex"
    private var known: [String] = []
    private var lastScan = Date.distantPast
    private var trackers: [String: Tracker] = [:]

    /// Codex threads touched in the last 6 hours, with their state.
    func threads(now: Date = Date()) -> [CodexThread] {
        refreshTitles()
        // A thread started days ago can still be running: scan the whole tree, at most every 5 minutes.
        if now.timeIntervalSince(lastScan) > 300 {
            lastScan = now
            var list: [String] = []
            let base = root + "/sessions"
            if let e = FileManager.default.enumerator(atPath: base) {
                for case let f as String in e where f.hasSuffix(".jsonl") {
                    let p = base + "/" + f
                    if let m = modificationDate(p), now.timeIntervalSince(m) < 6 * 3600 { list.append(p) }
                }
            }
            known = list
            trackers = trackers.filter { list.contains($0.key) }
        }
        return known.compactMap { p in
            guard let m = modificationDate(p), now.timeIntervalSince(m) < 6 * 3600 else { return nil }
            let name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            // rollout-YYYY-MM-DDTHH-MM-SS-<id>
            let id = name.count > 28 ? String(name.dropFirst(28)) : name
            return CodexThread(id: id, title: titles[id] ?? "Codex thread", reading: state(p, modified: m, now: now))
        }
    }

    private func state(_ file: String, modified: Date, now: Date) -> StateReading {
        var t = trackers[file] ?? Tracker()
        readNew(file, &t)
        trackers[file] = t
        let at = t.at ?? modified
        var r: StateReading
        switch t.event {
        case "task_started"?:
            // Codex does not always log when it waits: silent for long, say so, without concluding it is done.
            r = now.timeIntervalSince(modified) > 600
                ? StateReading(state: .working, since: modified, detail: "No news", certain: false)
                : StateReading(state: .working, since: at)
        case "task_complete"?: r = StateReading(state: .done, since: at)
        case "turn_aborted"?: r = StateReading(state: .done, since: at, detail: "Interrupted")
        case nil: r = StateReading(state: .done, since: modified, certain: false)
        default: r = StateReading(state: .waiting, since: at, detail: "Approval requested")
        }
        if r.state == .done, now.timeIntervalSince(r.since) > idleDelay { r.state = .idle }
        return r
    }

    /// Reads what was appended since last time (first pass: the last 4 MB).
    private func readNew(_ file: String, _ t: inout Tracker) {
        guard let fh = FileHandle(forReadingAtPath: file) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < t.offset { t = Tracker() }                  // file rewritten
        let start = t.offset > 0 ? t.offset : (size > 4 << 20 ? size - (4 << 20) : 0)
        guard size > start else { return }
        try? fh.seek(toOffset: start)
        guard let data = try? fh.read(upToCount: Int(size - start)) else { return }
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }   // line not complete yet
        var lines = data[data.startIndex..<end].split(separator: UInt8(ascii: "\n"))
        if t.offset == 0, start > 0, !lines.isEmpty { lines.removeFirst() }    // first line is cut
        for l in lines {
            // Task event lines are short; big lines (tool outputs) are skipped without decoding.
            guard l.count < 64 << 10,
                  let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any],
                  o["type"] as? String == "event_msg",
                  let type = (o["payload"] as? [String: Any])?["type"] as? String else { continue }
            let at = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
            if ["task_started", "task_complete", "turn_aborted"].contains(type)
                || type.contains("approval") || type.contains("request_user_input") || type.contains("elicitation") {
                t.event = type
                t.at = at
            } else if let e = t.event, !["task_started", "task_complete", "turn_aborted"].contains(e) {
                t.event = "task_started"     // something happened after the approval: it is working again
                t.at = at
            }
        }
        t.offset = start + UInt64(end - data.startIndex) + 1
    }

    /// Thread names, from ~/.codex/session_index.jsonl (re-read when it changes).
    private func refreshTitles() {
        let f = root + "/session_index.jsonl"
        guard let m = modificationDate(f), m != titlesReadAt else { return }
        titlesReadAt = m
        guard let data = FileManager.default.contents(atPath: f) else { return }
        for l in data.split(separator: UInt8(ascii: "\n")) {
            if let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any],
               let id = o["id"] as? String, let n = o["thread_name"] as? String, !n.hasPrefix("<") {
                titles[id] = n
            }
        }
    }
}
