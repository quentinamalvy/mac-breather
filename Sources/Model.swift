// Mac Breather, model: samples every 5 s, derives tips, session states and alerts.

import AppKit
import UserNotifications

let bundleId = Bundle.main.bundleIdentifier ?? "io.github.quentinamalvy.macbreather"

struct Tip: Identifiable {
    let id: String
    let icon: String         // SF Symbol
    let text: String
    let button: String?
    let run: (() -> Void)?
}

struct SessionRow: Identifiable {
    let id: String
    let tool: String             // "Claude" or "Codex"
    let title: String
    let reading: StateReading
    let memory: UInt64?
    let session: Session?        // the process, for Claude sessions
}

final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var rows: [SessionRow] = []
    @Published var tips: [Tip] = []
    @Published var lowered: Set<pid_t> = []          // sessions in low priority
    @Published var notificationsDenied = false

    let monitor = Monitor()
    let codex = CodexReader()
    var autoLowered: Set<pid_t> = []
    var lastStates: [String: SessionState] = [:]
    var lastAlert: [String: Date] = [:]
    var simWithoutXcodeSince: Date?
    let launchedAt = Date()
    var onChange: (() -> Void)?

    var autoPriority: Bool {
        get { UserDefaults.standard.object(forKey: "autoPriority") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPriority"); objectWillChange.send() }
    }

    var notifySessions: Bool {
        get { UserDefaults.standard.object(forKey: "notifySessions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifySessions"); objectWillChange.send() }
    }

    func tick(alerts: Bool = true) {
        snap = monitor.sample()
        let now = Date()
        var out: [SessionRow] = []
        for s in snap.sessions where s.kind == "Claude" && s.footprint > 20 << 20 {
            out.append(SessionRow(id: "claude-" + (s.registry?.sessionId ?? "\(s.pid)"), tool: "Claude", title: s.label,
                                  reading: claudeState(s, now: now), memory: s.footprint, session: s))
        }
        for t in codex.threads(now: now) {
            out.append(SessionRow(id: "codex-\(t.id)", tool: "Codex", title: t.title, reading: t.reading, memory: nil, session: nil))
        }
        out.sort { ($0.reading.state, -$0.reading.since.timeIntervalSince1970) < ($1.reading.state, -$1.reading.since.timeIntervalSince1970) }
        rows = out
        autoPriorityPass()
        tips = computeTips()
        if alerts { checkAlerts() }
        onChange?()
    }

    // MARK: Actions

    @discardableResult
    func setPriority(_ pids: [pid_t], low: Bool) -> Bool {
        var ok = true
        for p in pids where setpriority(PRIO_DARWIN_PROCESS, id_t(p), low ? PRIO_DARWIN_BG : 0) != 0 { ok = false }
        return ok
    }

    /// Is the process still the same session? (a freed pid can be reused by another program)
    func stillAlive(_ s: Session) -> Bool {
        guard let p = readProc(s.pid, uid: getuid()) else { return false }
        return p.start == s.start && (p.path.contains("/claude-code/") || p.path.contains("CodexCLI.app"))
    }

    /// The session's processes that still exist and were born after it.
    func liveTree(_ s: Session) -> [pid_t] {
        guard stillAlive(s) else { return [] }
        return s.tree.filter { pid in readProc(pid, uid: getuid()).map { $0.start >= s.start } ?? false }
    }

    func lower(_ s: Session, auto: Bool = false) {
        guard setPriority(liveTree(s), low: true) else { return }
        lowered.insert(s.pid)
        if auto { autoLowered.insert(s.pid) }
    }

    func restore(_ s: Session) {
        setPriority(liveTree(s), low: false)
        lowered.remove(s.pid)
        autoLowered.remove(s.pid)
    }

    /// Idle sessions go to low priority; they come back as soon as they get to work again.
    func autoPriorityPass() {
        guard Date().timeIntervalSince(launchedAt) > 60 else { return }   // measure for a minute first
        let states = Dictionary(rows.compactMap { r in r.session.map { ($0.pid, r.reading.state) } }, uniquingKeysWith: { a, _ in a })
        for s in snap.sessions {
            // Claude: status declared in its registry. Codex command line: 30 min without CPU.
            let idle = states[s.pid].map { $0 == .idle } ?? (Date().timeIntervalSince(s.lastActive) > idleDelay)
            if autoPriority, idle, !lowered.contains(s.pid) {
                lower(s, auto: true)
            } else if autoLowered.contains(s.pid), !autoPriority || !idle || s.cpu > 3 {
                restore(s)
            }
        }
        let alive = Set(snap.sessions.map(\.pid))
        lowered = lowered.filter { alive.contains($0) }
        autoLowered = autoLowered.filter { alive.contains($0) }
    }

    func resetAllPriorities() {
        snap.sessions.forEach { setPriority(liveTree($0), low: false) }
    }

    /// Closes sessions (already confirmed in the panel). Re-checks each one right before: still the same
    /// process, and for an "idle" close, still idle.
    func close(_ ss: [Session], onlyIdle: Bool = false) {
        tick(alerts: false)
        let idle = Set(idleSessions.map(\.pid))
        for s in ss where stillAlive(s) && (!onlyIdle || idle.contains(s.pid)) {
            kill(s.pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.tick(alerts: false) }
    }

    func quit(_ g: AppGroup) {
        guard let path = g.appPath else { return }
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }.forEach { $0.terminate() }
    }

    func shutDownSimulator() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "shutdown", "all"]
        try? p.run()
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.apple.iphonesimulator" }
            .forEach { $0.terminate() }
    }

    func open(_ r: SessionRow) {
        let app = r.tool == "Claude" ? "/Applications/Claude.app" : "/Applications/ChatGPT.app"
        NSWorkspace.shared.open(URL(fileURLWithPath: app))
    }

    // MARK: Tips

    func group(_ key: String) -> AppGroup? { snap.groups.first { $0.key == key } }

    func isRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    var idleSessions: [Session] {
        rows.filter { $0.reading.state == .idle }.compactMap(\.session)
    }

    func computeTips() -> [Tip] {
        var out: [Tip] = []
        let m = snap.mem
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path

        if let sim = group("sim"), sim.footprint > 200 << 20, !isRunning("com.apple.dt.Xcode") {
            out.append(Tip(id: "sim", icon: "iphone", text: "Simulator running without Xcode · \(formatBytes(sim.footprint))",
                           button: "Shut down", run: { [weak self] in self?.shutDownSimulator() }))
        }
        let idle = idleSessions
        if !idle.isEmpty {
            let total = idle.reduce(UInt64(0)) { $0 + $1.footprint }
            out.append(Tip(id: "idle", icon: "moon.zzz", text: "\(idle.count) idle Claude session\(idle.count > 1 ? "s" : "") · \(formatBytes(total))",
                           button: "Close", run: { [weak self] in self?.close(idle, onlyIdle: true) }))
        }
        if let c = group("Claude"), let x = group("codex"), c.footprint > 500 << 20, x.footprint > 500 << 20, m.health != .ok {
            out.append(Tip(id: "both", icon: "square.on.square", text: "Claude and Codex open together · \(formatBytes(c.footprint + x.footprint))",
                           button: "Quit Codex", run: { [weak self] in self?.quit(x) }))
        }
        let heavy = ["Microsoft Excel", "Microsoft Word", "Microsoft PowerPoint", "Microsoft Outlook", "Spotify",
                     "ChatGPT Classic", "WhatsApp", "Notion", "Discord", "Slack", "Microsoft Teams"]
        for g in snap.groups where heavy.contains(g.name) && g.footprint > 250 << 20 && g.appPath != front && g.cpu < 3 {
            out.append(Tip(id: "app-\(g.name)", icon: "xmark.app", text: "\(g.name) open in the background · \(formatBytes(g.footprint))",
                           button: "Quit", run: { [weak self] in self?.quit(g) }))
        }
        if let chrome = group("Google Chrome"), chrome.footprint > 2 << 30 {
            out.append(Tip(id: "chrome", icon: "safari", text: "Chrome · \(formatBytes(chrome.footprint)): close some tabs", button: nil, run: nil))
        }
        if m.swapUsed > 6 << 30 {
            out.append(Tip(id: "swap", icon: "arrow.clockwise", text: "Swap at \(formatBytes(m.swapUsed)): a restart clears it", button: nil, run: nil))
        }
        if m.diskFree > 0 && m.diskFree < 20 << 30 {
            out.append(Tip(id: "disk", icon: "internaldrive", text: "Disk: \(formatBytes(UInt64(m.diskFree))) free", button: nil, run: nil))
        }
        return out
    }

    // MARK: Alerts

    func notify(_ key: String, _ title: String, _ body: String, every: TimeInterval = 2700) {
        if let d = lastAlert[key], Date().timeIntervalSince(d) < every { return }
        lastAlert[key] = Date()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(key)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }

    func checkAlerts() {
        let m = snap.mem
        let now = Date()
        if m.health == .overloaded {
            notify("overloaded", "Mac overloaded", "\(m.freePct)% memory free, swap \(formatBytes(m.swapUsed)). \(tips.first?.text ?? "Quit a heavy app").")
        }
        for s in snap.sessions where s.kind == "Claude" && s.footprint > 3 << 29 {   // 1.5 GB
            notify("heavy-\(s.pid)", "Heavy Claude session", "\"\(s.label)\" is using \(formatBytes(s.footprint)).", every: 3600)
        }
        if let sim = group("sim"), sim.footprint > 200 << 20, !isRunning("com.apple.dt.Xcode") {
            if simWithoutXcodeSince == nil { simWithoutXcodeSince = now }
            if now.timeIntervalSince(simWithoutXcodeSince!) > 600 {
                notify("sim", "Simulator still running", "Xcode is closed but the simulator holds \(formatBytes(sim.footprint)).", every: 3 * 3600)
            }
        } else {
            simWithoutXcodeSince = nil
        }
        if m.diskFree > 0 && m.diskFree < 15 << 30 {
            notify("disk", "Disk almost full", "\(formatBytes(UInt64(m.diskFree))) free: the Mac has no room left to swap.", every: 6 * 3600)
        }

        // A session that goes from "working" to "done" or "needs you".
        let first = now.timeIntervalSince(launchedAt) < 15
        for r in rows {
            let before = lastStates[r.id]
            lastStates[r.id] = r.reading.state
            guard !first, notifySessions, before == .working, r.reading.certain else { continue }
            if r.reading.state == .done {
                notify("done-\(r.id)", "\(r.tool): your turn", "\"\(r.title)\" is done and waiting for your next message.", every: 60)
            } else if r.reading.state == .waiting {
                notify("waiting-\(r.id)", "\(r.tool) needs you", "\"\(r.title)\" is waiting: \(r.reading.detail.isEmpty ? "a question or an approval" : r.reading.detail.lowercased()).", every: 60)
            }
        }
        let ids = Set(rows.map(\.id))
        lastStates = lastStates.filter { ids.contains($0.key) }
    }

    // MARK: Launch at login

    let loginPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(bundleId).plist"

    var launchAtLogin: Bool {
        get { FileManager.default.fileExists(atPath: loginPlist) }
        set {
            let fm = FileManager.default
            if !newValue {
                try? fm.removeItem(atPath: loginPlist)
            } else {
                let plist: [String: Any] = [
                    "Label": bundleId,
                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                    "RunAtLoad": true,
                ]
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    fm.createFile(atPath: loginPlist, contents: data)
                }
            }
            objectWillChange.send()
        }
    }
}
