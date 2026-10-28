// Mac Breather, measurements: Mac memory, processes grouped by app, Claude and Codex command-line sessions.

import AppKit
import Darwin

// MARK: - System measurements

let timebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()

func tupleString<T>(_ t: T) -> String {
    withUnsafeBytes(of: t) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

func sysInt32(_ name: String) -> Int {
    var v: Int32 = 0
    var s = MemoryLayout<Int32>.size
    return sysctlbyname(name, &v, &s, nil, 0) == 0 ? Int(v) : -1
}

struct MemStats {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var freePct = 100      // kern.memorystatus_level, what `memory_pressure` prints
    var level = 1          // 1 normal, 2 warning, 4 critical
    var diskFree: Int64 = 0

    enum Health { case ok, strained, overloaded }
    var health: Health {
        if level >= 4 || freePct < 12 { return .overloaded }
        if level >= 2 || freePct < 25 || swapUsed > 6 << 30 { return .strained }
        return .ok
    }
}

func readMemStats() -> MemStats {
    var m = MemStats()
    var memsize: UInt64 = 0
    var s = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &memsize, &s, nil, 0)
    m.total = memsize

    var st = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &st) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        // Same formula as Activity Monitor: app memory + wired + compressed.
        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(st.internal_page_count)
        let purgeable = UInt64(st.purgeable_count)
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        m.used = (app + UInt64(st.wire_count) + UInt64(st.compressor_page_count)) * page
    }

    var xs = xsw_usage()
    var xsz = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &xs, &xsz, nil, 0) == 0 {
        m.swapUsed = xs.xsu_used
        m.swapTotal = xs.xsu_total
    }
    m.freePct = sysInt32("kern.memorystatus_level")
    m.level = sysInt32("kern.memorystatus_vm_pressure_level")
    if let v = try? URL(fileURLWithPath: NSHomeDirectory())
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage {
        m.diskFree = v
    }
    return m
}

// MARK: - Processes

struct Proc {
    let pid: pid_t
    let ppid: pid_t
    let path: String
    let start: Date
    let footprint: UInt64
    let cpuNs: UInt64
    var cpu: Double = 0   // % of one core since the previous sample
}

func listPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var buf = [pid_t](repeating: 0, count: Int(n) + 128)
    let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return buf.prefix(Int(max(got, 0))).filter { $0 > 0 }
}

func readProc(_ pid: pid_t, uid: uid_t) -> Proc? {
    var info = proc_bsdinfo()
    let isz = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, isz) == isz, info.pbi_uid == uid else { return nil }

    var ru = rusage_info_v2()
    let rr = withUnsafeMutablePointer(to: &ru) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard rr == 0 else { return nil }

    var pbuf = [CChar](repeating: 0, count: 4096)
    let plen = proc_pidpath(pid, &pbuf, 4096)
    let path = plen > 0 ? String(cString: pbuf) : tupleString(info.pbi_name)

    let ticks = ru.ri_user_time + ru.ri_system_time
    return Proc(pid: pid, ppid: pid_t(info.pbi_ppid), path: path,
                start: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
                footprint: ru.ri_phys_footprint,
                cpuNs: ticks * timebase.numer / timebase.denom)
}

func procCwd(_ pid: pid_t) -> String {
    var vp = proc_vnodepathinfo()
    let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, sz) == sz else { return "" }
    return tupleString(vp.pvi_cdir.vip_path)
}

/// Maps an executable path to a readable app.
func groupFor(_ path: String) -> (key: String, name: String, appPath: String?)? {
    if path.contains("CoreSimulator") { return ("sim", "Simulator", nil) }
    if path.contains("Codex Framework.framework") || path.contains("CodexCLI.app") || path.hasSuffix("/codex") {
        return ("codex", "Codex", "/Applications/ChatGPT.app")
    }
    if path.contains("/claude-code/") || path.hasSuffix("/claude") {
        return ("Claude", "Claude", "/Applications/Claude.app")
    }
    if let r = path.range(of: ".app/") {
        let appPath = String(path[..<r.lowerBound]) + ".app"
        let name = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        return (name, name, appPath)
    }
    return nil
}

// MARK: - Model

struct AppGroup {
    let key: String
    let name: String
    let appPath: String?
    var pids: [pid_t] = []
    var footprint: UInt64 = 0
    var cpu: Double = 0
}

struct Session {
    let pid: pid_t
    let kind: String          // "Claude" or "Codex"
    var label: String
    let start: Date
    var footprint: UInt64
    var cpu: Double
    var tree: [pid_t]
    var lastActive: Date
    var registry: Registry? = nil   // what Claude Code itself declares about the session
}

/// Entry kept by Claude Code in ~/.claude/sessions/<pid>.json: the session's title and official status.
struct Registry {
    let sessionId: String
    let name: String?
    let status: String          // "busy", "waiting" or "idle"
    let waitingFor: String?     // detail when status == "waiting"
    let since: Date             // last status change
}

/// Reads a claude process's registry entry, only if it really is its own (same start time).
func readRegistry(pid: pid_t, start: Date) -> Registry? {
    let f = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
    guard let data = FileManager.default.contents(atPath: f),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (o["pid"] as? Int).map({ pid_t($0) }) == pid,
          let id = o["sessionId"] as? String,
          let launched = o["startedAt"] as? Double,
          abs(launched / 1000 - start.timeIntervalSince1970) < 600 else { return nil }   // reused pid: stale entry
    let updated = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? launched
    let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return Registry(sessionId: id, name: name, status: o["status"] as? String ?? "idle",
                    waitingFor: o["waitingFor"] as? String, since: Date(timeIntervalSince1970: updated / 1000))
}

struct Snapshot {
    var mem = MemStats()
    var groups: [AppGroup] = []
    var sessions: [Session] = []
    var date = Date()
}

final class Monitor {
    private var prevCpu: [pid_t: UInt64] = [:]
    private var prevDate = Date()
    private var cwdCache: [pid_t: (start: Date, cwd: String)] = [:]
    private var lastBusy: [pid_t: Date] = [:]
    private let uid = getuid()

    func sample() -> Snapshot {
        var snap = Snapshot()
        snap.mem = readMemStats()
        let now = Date()
        let dt = max(now.timeIntervalSince(prevDate), 0.5)

        var procs: [pid_t: Proc] = [:]
        var newCpu: [pid_t: UInt64] = [:]
        for pid in listPids() {
            guard var p = readProc(pid, uid: uid) else { continue }
            if let old = prevCpu[pid], p.cpuNs >= old {
                p.cpu = Double(p.cpuNs - old) / 1e9 / dt * 100
            }
            newCpu[pid] = p.cpuNs
            procs[pid] = p
        }
        prevCpu = newCpu
        prevDate = now

        var children: [pid_t: [pid_t]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }

        // App of each process; a tool without an app (node, MCP server) follows its parent.
        var groupOf: [pid_t: (key: String, name: String, appPath: String?)] = [:]
        func resolve(_ pid: pid_t, depth: Int = 0) -> (key: String, name: String, appPath: String?)? {
            if let g = groupOf[pid] { return g }
            guard let p = procs[pid] else { return nil }
            var g = groupFor(p.path)
            if g == nil, depth < 12, p.ppid > 1 { g = resolve(p.ppid, depth: depth + 1) }
            if g == nil {
                let n = (p.path as NSString).lastPathComponent
                g = (n, n, nil)
            }
            groupOf[pid] = g
            return g
        }
        var groups: [String: AppGroup] = [:]
        for p in procs.values {
            guard let g = resolve(p.pid) else { continue }
            var grp = groups[g.key] ?? AppGroup(key: g.key, name: g.name, appPath: g.appPath)
            grp.pids.append(p.pid)
            grp.footprint += p.footprint
            grp.cpu += p.cpu
            groups[g.key] = grp
        }
        snap.groups = groups.values.sorted { $0.footprint > $1.footprint }

        // Sessions: every claude / codex command-line process, with its children.
        for p in procs.values {
            let exe = (p.path as NSString).lastPathComponent
            let isClaude = exe == "claude" && p.path.contains("/claude-code/")
            let isCodex = exe == "codex" && p.path.contains("CodexCLI.app")
            guard isClaude || isCodex else { continue }

            var tree: [pid_t] = []
            var stack = [p.pid]
            while let x = stack.popLast() {
                tree.append(x)
                stack.append(contentsOf: children[x] ?? [])
            }
            let fp = tree.reduce(UInt64(0)) { $0 + (procs[$1]?.footprint ?? 0) }
            let cpu = tree.reduce(0.0) { $0 + (procs[$1]?.cpu ?? 0) }

            // Only the working directory is read (Codex label); never the arguments or the environment.
            if cwdCache[p.pid]?.start != p.start {
                cwdCache[p.pid] = (p.start, isCodex ? procCwd(p.pid) : "")
            }
            let cwd = cwdCache[p.pid]!.cwd
            if cpu > 3 { lastBusy[p.pid] = now }

            let last = lastBusy[p.pid] ?? p.start
            var label: String
            var registry: Registry? = nil
            if isClaude {
                registry = readRegistry(pid: p.pid, start: p.start)
                label = registry?.name ?? "Untitled session"
            } else {
                label = (cwd.isEmpty || cwd == "/" || cwd.contains(".app/")) ? "inside the ChatGPT app"
                    : (cwd as NSString).lastPathComponent
            }
            snap.sessions.append(Session(pid: p.pid, kind: isClaude ? "Claude" : "Codex", label: label,
                                         start: p.start, footprint: fp, cpu: cpu, tree: tree, lastActive: last, registry: registry))
        }
        snap.sessions.sort { $0.footprint > $1.footprint }
        let alive = Set(procs.keys)
        lastBusy = lastBusy.filter { alive.contains($0.key) }
        cwdCache = cwdCache.filter { alive.contains($0.key) }
        snap.date = now
        return snap
    }
}

// MARK: - Formatting

func formatBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb < 1 { return "\(Int(Double(b) / 1_048_576)) MB" }
    return String(format: "%.1f GB", gb)
}

func formatDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    if m < 60 { return "\(max(m, 1)) min" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    return "\(h / 24)d \(h % 24)h"
}
