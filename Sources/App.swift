// Mac Breather: two icons in the menu bar.
// The first follows the Mac's memory, the second the state of Claude and Codex sessions.
// No dependencies, built with swiftc (see build.sh).

import AppKit
import SwiftUI
import UserNotifications

let testingPanels = CommandLine.arguments.contains("--test-panels")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSPopoverDelegate {
    let model = Model()
    let memoryItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sessionsItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let memoryPopover = NSPopover()
    let sessionsPopover = NSPopover()
    var timer: Timer?
    var pulseTimer: Timer?
    var pulse = false
    var closedAt = Date.distantPast      // last time a panel closed

    func applicationDidFinishLaunching(_ n: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.checkNotificationSettings() }

        prepare(memoryPopover, NSHostingController(rootView: MemoryPanel(model: model)))
        prepare(sessionsPopover, NSHostingController(rootView: SessionsPanel(model: model) { [weak self] in
            self?.sessionsPopover.performClose(nil)
        }))
        for (item, action) in [(memoryItem, #selector(toggleMemory)), (sessionsItem, #selector(toggleSessions))] {
            item.button?.target = self
            item.button?.action = action
        }
        memoryItem.button?.imagePosition = .imageLeading
        sessionsItem.button?.imagePosition = .imageOnly

        model.onChange = { [weak self] in self?.drawIcons() }
        model.tick()
        // Start clean: a previous instance may have left sessions in low priority.
        model.resetAllPriorities()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.model.tick() }

        // Check: `--test-panels` opens each panel, logs its size to the system log, then quits.
        if testingPanels {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.toggleSessions() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.toggleMemory() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        model.snap.sessions.filter { model.lowered.contains($0.pid) }.forEach { model.setPriority($0.tree, low: false) }
    }

    func prepare<V: View>(_ p: NSPopover, _ vc: NSHostingController<V>) {
        vc.sizingOptions = .preferredContentSize
        p.contentViewController = vc
        p.behavior = .transient
        p.animates = true
        p.delegate = self
    }

    @objc func toggleMemory() { toggle(memoryPopover, from: memoryItem, other: sessionsPopover) }
    @objc func toggleSessions() { toggle(sessionsPopover, from: sessionsItem, other: memoryPopover) }

    func toggle(_ p: NSPopover, from item: NSStatusItem, other: NSPopover) {
        if p.isShown { p.performClose(nil); return }
        // Clicking the icon first closes the (transient) panel: don't reopen it right away.
        if Date().timeIntervalSince(closedAt) < 0.25 { return }
        show(p, from: item, other: other)
    }

    func show(_ p: NSPopover, from item: NSStatusItem, other: NSPopover) {
        other.performClose(nil)
        guard !p.isShown, let b = item.button else { return }
        model.tick(alerts: false)
        checkNotificationSettings()
        NSApp.activate()      // without this, Escape, Tab and VoiceOver don't get into the panel
        p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        b.highlight(true)
    }

    func popoverDidShow(_ n: Notification) {
        if testingPanels, let w = (n.object as? NSPopover)?.contentViewController?.view.window {
            NSLog("MacBreather panel opened %@", NSStringFromRect(w.frame))
        }
    }

    func popoverDidClose(_ n: Notification) {
        closedAt = Date()
        memoryItem.button?.highlight(memoryPopover.isShown)
        sessionsItem.button?.highlight(sessionsPopover.isShown)
    }

    func checkNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { self.model.notificationsDenied = s.authorizationStatus == .denied }
        }
    }

    // MARK: Menu bar icons

    func drawIcons() {
        let m = model.snap.mem
        let fraction = m.total > 0 ? Double(m.used) / Double(m.total) : 0
        let color: NSColor = m.health == .overloaded ? .systemRed : m.health == .strained ? .systemOrange : .systemGreen
        memoryItem.button?.image = ringIcon(fraction: fraction, color: color)
        memoryItem.button?.title = " \(Int(fraction * 100))%"
        memoryItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        memoryItem.button?.toolTip = "Mac Breather: \(formatBytes(m.used)) of \(formatBytes(m.total)), swap \(formatBytes(m.swapUsed))"
        memoryItem.button?.setAccessibilityLabel("Memory \(Int(fraction * 100)) percent, \(m.health.title)")

        let states = model.rows.map(\.reading.state)
        sessionsItem.button?.image = dotsIcon(states, pulse: pulse)
        let waiting = states.filter { $0 == .waiting }.count
        let working = states.filter { $0 == .working }.count
        let needs = waiting == 1 ? "needs you" : "need you"
        sessionsItem.button?.toolTip = "AI sessions: \(waiting) \(needs), \(working) working, \(states.count) in total"
        sessionsItem.button?.setAccessibilityLabel("AI sessions, \(waiting) \(needs), \(working) working")

        // "Working" dots breathe in the menu bar, unless Reduce Motion is on.
        let animate = working > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate && pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulse.toggle()
                self.sessionsItem.button?.image = dotsIcon(self.model.rows.map(\.reading.state), pulse: self.pulse)
            }
            pulseTimer?.tolerance = 0.5
        } else if !animate {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulse = false
        }
    }

    // MARK: Notifications

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.identifier
        DispatchQueue.main.async {
            // Open the right panel, never closing one that is already open.
            if id.hasPrefix("done-") || id.hasPrefix("waiting-") {
                self.show(self.sessionsPopover, from: self.sessionsItem, other: self.memoryPopover)
            } else {
                self.show(self.memoryPopover, from: self.memoryItem, other: self.sessionsPopover)
            }
        }
        done()
    }
}

/// Small gauge ring, in the Mac's health color.
func ringIcon(fraction: Double, color: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { r in
        let c = NSPoint(x: r.midX, y: r.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: 5.5, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.6
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: 5.5, startAngle: 90, endAngle: 90 - 360 * min(max(fraction, 0.02), 1), clockwise: true)
        arc.lineWidth = 2.6
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        return true
    }
    img.isTemplate = false
    return img
}

/// One dot per session, in its state's color; idle ones are a plain circle.
func dotsIcon(_ states: [SessionState], pulse: Bool) -> NSImage {
    guard !states.isEmpty else {
        let i = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI sessions") ?? NSImage()
        i.isTemplate = true
        return i
    }
    // At most 6 dots; beyond that, 5 dots and "+N" for the rest (sessions are sorted: what needs you comes first).
    let shown = Array(states.prefix(states.count > 6 ? 5 : 6))
    let rest = states.count - shown.count
    let plus = NSAttributedString(string: rest > 0 ? "+\(rest)" : "", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor])
    let d: CGFloat = 7, gap: CGFloat = 3.5
    let w = CGFloat(shown.count) * d + CGFloat(shown.count - 1) * gap + 2 + (rest > 0 ? plus.size().width + 3 : 0)
    let img = NSImage(size: NSSize(width: w, height: 16), flipped: false) { r in
        for (i, s) in shown.enumerated() {
            let rect = NSRect(x: 1 + CGFloat(i) * (d + gap), y: (r.height - d) / 2, width: d, height: d)
            let p = NSBezierPath(ovalIn: rect.insetBy(dx: s == .idle ? 0.75 : 0, dy: s == .idle ? 0.75 : 0))
            switch s {
            case .waiting: NSColor.systemOrange.setFill(); p.fill()
            case .working: NSColor.systemBlue.withAlphaComponent(pulse ? 0.45 : 1).setFill(); p.fill()
            case .done: NSColor.systemGreen.setFill(); p.fill()
            case .idle: p.lineWidth = 1.3; NSColor.labelColor.withAlphaComponent(0.6).setStroke(); p.stroke()
            }
        }
        if rest > 0 {
            let x = 1 + CGFloat(shown.count) * (d + gap)
            plus.draw(at: NSPoint(x: x, y: (r.height - plus.size().height) / 2))
        }
        return true
    }
    img.isTemplate = false
    return img
}

// MARK: - Launch

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") { dump(); return }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count { render(to: args[i + 1]); return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// `MacBreather --dump`: one sample printed to the terminal, to check without opening the panels.
    static func dump() {
        let m = Model()
        m.tick(alerts: false)
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        m.tick(alerts: false)
        let s = m.snap.mem
        print("memory \(formatBytes(s.used))/\(formatBytes(s.total)) free \(s.freePct)% swap \(formatBytes(s.swapUsed)) disk \(formatBytes(UInt64(max(s.diskFree, 0)))) \(s.health)")
        for g in m.snap.groups.prefix(8) { print("  app \(g.name): \(formatBytes(g.footprint))") }
        for r in m.rows { print("  \(r.tool) \"\(r.title)\" \(r.reading.state.title) \(ago(r)) \(r.memory.map(formatBytes) ?? "")") }
        for t in m.tips { print("  tip: \(t.text)") }
    }

    /// `MacBreather --render <folder>`: both panels as PNG, light and dark (without the glass, which only the screen draws).
    static func render(to folder: String) {
        _ = NSApplication.shared
        renderMode = true
        let m = Model()
        m.tick(alerts: false)
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        m.tick(alerts: false)
        MainActor.assumeIsolated {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let bg = Color(nsColor: scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1))
                let views: [(String, AnyView)] = [
                    ("memory", AnyView(MemoryPanel(model: m))),
                    ("sessions", AnyView(SessionsPanel(model: m) {})),
                ]
                for (panel, view) in views {
                    let r = ImageRenderer(content: view.background(bg).environment(\.colorScheme, scheme))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(folder)/\(panel)-\(name).png"))
                    }
                }
            }
        }
    }
}
