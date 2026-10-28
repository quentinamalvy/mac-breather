// Mac Breather, model: samples every 5 s, derives tips, session states and alerts.

import AppKit

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

/// What the menu bar shows: the memory ring, the AI session dots, or both.
enum Display: String, CaseIterable {
    case both, memory, ai
    var title: String { self == .both ? "Memory and Sessions" : self == .memory ? "Memory Only" : "Sessions Only" }
}

final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var rows: [SessionRow] = []
    @Published var tips: [Tip] = []
    @Published var lowered: Set<pid_t> = []          // sessions in low priority

    let monitor = Monitor()
    let codex = CodexReader()
    var history: [Double] = []                       // share of memory used, last 30 min (one sample per 5 s)
    var autoLowered: Set<pid_t> = []
    var lastStates: [String: SessionState] = [:]
    var workingSince: [String: Date] = [:]
    var seenAt: [String: Date] = [:]                 // when you last looked at a finished session
    var reminded: Set<String> = []                   // "still waiting" reminder already shown
    var lastAlert: [String: Date] = [:]
    var swapHistory: [(at: Date, swap: UInt64)] = []
    var highSince: Date?
    var memoryArmed = true                           // re-armed once memory drops under 80%
    var simWithoutXcodeSince: Date?
    var simNotified = false
    let launchedAt = Date()
    var onChange: (() -> Void)?
    var onToast: ((Toast) -> Void)?
    var showMemoryPanel: (() -> Void)?
    var onDisplayChange: (() -> Void)?

    private func flag(_ key: String, _ fallback: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    private func set(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        objectWillChange.send()
    }

    var autoPriority: Bool { get { flag("autoPriority") } set { set("autoPriority", newValue) } }
    var notifySessions: Bool { get { flag("notifySessions") } set { set("notifySessions", newValue) } }
    var notifyMemory: Bool { get { flag("notifyMemory") } set { set("notifyMemory", newValue) } }
    var alertSound: Bool { get { flag("alertSound") } set { set("alertSound", newValue) } }

    var display: Display {
        get { Display(rawValue: UserDefaults.standard.string(forKey: "display") ?? "") ?? .both }
        set { set("display", newValue.rawValue); onDisplayChange?() }
    }
    var showsMemory: Bool { display != .ai || !aiInstalled }
    var showsAI: Bool { display != .memory }

    var pausedUntil: Date? {
        get { (UserDefaults.standard.object(forKey: "pausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil } }
        set {
            if let d = newValue { set("pausedUntil", d) } else { UserDefaults.standard.removeObject(forKey: "pausedUntil"); objectWillChange.send() }
        }
    }

    func tick(alerts: Bool = true) {
        snap = monitor.sample()
        let now = Date()
        let m = snap.mem
        history.append(m.total > 0 ? Double(m.used) / Double(m.total) : 0)
        if history.count > 360 { history.removeFirst(history.count - 360) }
        swapHistory.append((now, m.swapUsed))
        swapHistory.removeAll { now.timeIntervalSince($0.at) > 600 }

        var out: [SessionRow] = []
        for s in snap.sessions where s.kind == "Claude" && s.footprint > 20 << 20 {
            out.append(SessionRow(id: "claude-" + (s.registry?.sessionId ?? "\(s.pid)"), tool: "Claude", title: s.label,
                                  reading: claudeState(s, now: now), memory: s.footprint, session: s))
        }
        for t in codex.threads(now: now) {
            out.append(SessionRow(id: "codex-\(t.id)", tool: "Codex", title: t.title, reading: t.reading, memory: nil, session: nil))
        }
        // Looking at the tool's app after a session finished counts as having seen it.
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        for r in out where r.reading.state == .done && front == appOf(r) && now.timeIntervalSince(r.reading.since) > 3 {
            seenAt[r.id] = now
        }
        out = out.map { r in
            guard r.reading.state == .done, let seen = seenAt[r.id], seen > r.reading.since else { return r }
            var reading = r.reading
            reading.state = .seen
            return SessionRow(id: r.id, tool: r.tool, title: r.title, reading: reading, memory: r.memory, session: r.session)
        }
        out.sort { ($0.reading.state, -$0.reading.since.timeIntervalSince1970) < ($1.reading.state, -$1.reading.since.timeIntervalSince1970) }
        rows = out
        let ids = Set(out.map(\.id))
        seenAt = seenAt.filter { ids.contains($0.key) }

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

    func appOf(_ r: SessionRow) -> String { r.tool == "Claude" ? claudeApp : codexApp }

    func open(_ r: SessionRow) {
        seenAt[r.id] = Date()
        if FileManager.default.fileExists(atPath: appOf(r)) { NSWorkspace.shared.open(URL(fileURLWithPath: appOf(r))) }
    }

    func pauseNotifications() { pausedUntil = Date().addingTimeInterval(3600) }
    func resumeNotifications() { pausedUntil = nil }

    // MARK: Tips

    func group(_ key: String) -> AppGroup? { snap.groups.first { $0.key == key } }

    func isRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    var idleSessions: [Session] {
        rows.filter { $0.reading.state == .idle }.compactMap(\.session)
    }

    /// Thresholds scale with the Mac's memory: what is heavy on 8 GB is fine on 32 GB.
    func computeTips() -> [Tip] {
        var out: [Tip] = []
        let m = snap.mem
        let ram = m.total
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path

        if let sim = group("sim"), sim.footprint > 200 << 20, !isRunning("com.apple.dt.Xcode") {
            out.append(Tip(id: "sim", icon: "iphone", text: "Simulator running without Xcode · \(formatBytes(sim.footprint))",
                           button: "Shut down", run: { [weak self] in self?.shutDownSimulator() }))
        }
        let idle = idleSessions
        if showsAI, !idle.isEmpty {
            let total = idle.reduce(UInt64(0)) { $0 + $1.footprint }
            out.append(Tip(id: "idle", icon: "moon.zzz", text: "\(idle.count) idle Claude session\(idle.count > 1 ? "s" : "") · \(formatBytes(total))",
                           button: "Close", run: { [weak self] in self?.close(idle, onlyIdle: true) }))
        }
        if let c = group("Claude"), let x = group("codex"), c.footprint > ram / 16, x.footprint > ram / 16, m.health != .ok {
            out.append(Tip(id: "both", icon: "square.on.square", text: "Claude and Codex open together · \(formatBytes(c.footprint + x.footprint))",
                           button: "Quit Codex", run: { [weak self] in self?.quit(x) }))
        }
        let heavy = ["Microsoft Excel", "Microsoft Word", "Microsoft PowerPoint", "Microsoft Outlook", "Spotify",
                     "ChatGPT Classic", "WhatsApp", "Notion", "Discord", "Slack", "Microsoft Teams"]
        for g in snap.groups where heavy.contains(g.name) && g.footprint > ram / 32 && g.appPath != front && g.cpu < 3 {
            out.append(Tip(id: "app-\(g.name)", icon: "xmark.app", text: "\(g.name) open in the background · \(formatBytes(g.footprint))",
                           button: "Quit", run: { [weak self] in self?.quit(g) }))
        }
        if let chrome = group("Google Chrome"), chrome.footprint > ram / 4 {
            out.append(Tip(id: "chrome", icon: "safari", text: "Chrome · \(formatBytes(chrome.footprint)): close some tabs", button: nil, run: nil))
        }
        if m.swapUsed > min(ram / 4 * 3, 6 << 30) {
            out.append(Tip(id: "swap", icon: "arrow.clockwise", text: "Swap at \(formatBytes(m.swapUsed)): a restart clears it", button: nil, run: nil))
        }
        if m.diskFree > 0 && m.diskFree < 20 << 30 {
            out.append(Tip(id: "disk", icon: "internaldrive", text: "Disk: \(formatBytes(UInt64(m.diskFree))) free", button: nil, run: nil))
        }
        return out
    }

    // MARK: Alerts

    /// Shows a toast, at most once per `every` seconds for the same key. Opens the memory panel by default.
    func notify(_ key: String, _ title: String, _ body: String, icon: NSImage, state: SessionState? = nil,
                every: TimeInterval = 2700, action: String = "Show Memory", open: (() -> Void)? = nil) {
        if let d = lastAlert[key], Date().timeIntervalSince(d) < every { return }
        lastAlert[key] = Date()
        onToast?(Toast(key: key, title: title, body: body, icon: icon, state: state, action: action,
                       open: open ?? { [weak self] in self?.showMemoryPanel?() }))
    }

    /// Few, useful alerts: sustained high memory, swap climbing fast, and sessions that need you
    /// while you are not already looking at them.
    func checkAlerts() {
        let m = snap.mem
        let now = Date()
        let frac = m.total > 0 ? Double(m.used) / Double(m.total) : 0
        let canMemory = showsMemory && notifyMemory && pausedUntil == nil
        let canSessions = showsAI && notifySessions && pausedUntil == nil

        // Memory at 90% or more for a full minute; then silent until it drops under 80%.
        highSince = frac >= 0.9 ? (highSince ?? now) : nil
        if frac < 0.8 { memoryArmed = true }
        if canMemory, memoryArmed, let h = highSince, now.timeIntervalSince(h) >= 60 {
            memoryArmed = false
            notify("memory", "Memory at \(Int(frac * 100))%", tips.first.map { $0.text } ?? "Quit an app you are not using.",
                   icon: ringIcon(fraction: frac, color: .systemRed), every: 0)
        }
        // Swap climbing by more than 2 GB within 10 minutes: this is when everything starts to lag.
        if canMemory, let oldest = swapHistory.first, m.swapUsed > oldest.swap + (2 << 30) {
            let mins = max(Int(now.timeIntervalSince(oldest.at) / 60), 1)
            notify("swap", "Your Mac is swapping hard", "Swap grew by \(formatBytes(m.swapUsed - oldest.swap)) in \(mins) min. \(tips.first?.text ?? "Quit an app you are not using.")",
                   icon: ringIcon(fraction: frac, color: .systemOrange), every: 1800)
        }
        for s in snap.sessions where canMemory && s.kind == "Claude" && s.footprint > m.total / 5 {
            notify("heavy-\(s.pid)", "Heavy Claude session", "\"\(s.label)\" is using \(formatBytes(s.footprint)), a fifth of your memory.",
                   icon: toolIcon("Claude"), every: 3 * 3600)
        }
        if let sim = group("sim"), sim.footprint > 200 << 20, !isRunning("com.apple.dt.Xcode") {
            if simWithoutXcodeSince == nil { simWithoutXcodeSince = now }
            if canMemory, !simNotified, now.timeIntervalSince(simWithoutXcodeSince!) > 600 {
                simNotified = true          // once per simulator run
                notify("sim", "Simulator still running", "Xcode is closed but the simulator holds \(formatBytes(sim.footprint)).",
                       icon: icon(for: sim), every: 0)
            }
        } else {
            simWithoutXcodeSince = nil
            simNotified = false
        }
        if canMemory, m.diskFree > 0 && m.diskFree < 15 << 30 {
            notify("disk", "Disk almost full", "\(formatBytes(UInt64(m.diskFree))) free: the Mac has no room left to swap.",
                   icon: NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil) ?? NSImage(), every: 24 * 3600)
        }

        // Sessions: done after more than a minute of work, or needing you, while you are not in that app.
        let first = now.timeIntervalSince(launchedAt) < 15
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        for r in rows {
            let before = lastStates[r.id]
            let state = r.reading.state
            lastStates[r.id] = state
            // A permission prompt pauses the work, it does not restart the clock.
            if state == .working, before != .working, before != .waiting { workingSince[r.id] = now }
            if state != .waiting { reminded.remove(r.id) }
            guard !first, canSessions, r.reading.certain, front != appOf(r) else { continue }
            let open: () -> Void = { [weak self] in self?.open(r) }
            let action = "Open " + (appOf(r) as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            if state == .done, before == .working, now.timeIntervalSince(workingSince[r.id] ?? now) >= 60 {
                notify("done-\(r.id)", r.title, "\(r.tool) is done, your turn.",
                       icon: toolIcon(r.tool), state: .done, every: 60, action: action, open: open)
            } else if state == .waiting, before == .working {
                notify("waiting-\(r.id)", r.title, "\(r.tool) needs you: \(r.reading.detail.isEmpty ? "a question or an approval" : r.reading.detail.lowercased()).",
                       icon: toolIcon(r.tool), state: .waiting, every: 60, action: action, open: open)
            } else if state == .waiting, r.reading.since > launchedAt, now.timeIntervalSince(r.reading.since) > 600, !reminded.contains(r.id) {
                reminded.insert(r.id)
                notify("waiting-\(r.id)", r.title, "Still waiting for you, for \(formatDuration(now.timeIntervalSince(r.reading.since))).",
                       icon: toolIcon(r.tool), state: .waiting, every: 0, action: action, open: open)
            }
        }
        let ids = Set(rows.map(\.id))
        lastStates = lastStates.filter { ids.contains($0.key) }
        workingSince = workingSince.filter { ids.contains($0.key) }
        reminded = reminded.filter { ids.contains($0) }
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
