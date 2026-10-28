// Mac Breather, views: the two panels that open from the menu bar.
// The glass comes from the popover itself (macOS 26); inside, quiet fills, and color is kept for states.

import AppKit
import SwiftUI

extension MemStats.Health {
    var color: Color { self == .overloaded ? .red : self == .strained ? .orange : .green }
    var title: String { self == .overloaded ? "Mac overloaded" : self == .strained ? "Mac under strain" : "Mac breathing fine" }
}

extension SessionState {
    var color: Color {
        switch self {
        case .waiting: return .orange
        case .working: return .blue
        case .done: return .green
        case .idle: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

func icon(for g: AppGroup) -> NSImage {
    if g.key == "sim" { return NSImage(systemSymbolName: "iphone", accessibilityDescription: nil) ?? NSImage() }
    if let p = g.appPath { return NSWorkspace.shared.icon(forFile: p) }
    return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
}

func toolIcon(_ tool: String) -> NSImage {
    NSWorkspace.shared.icon(forFile: tool == "Claude" ? "/Applications/Claude.app" : "/Applications/ChatGPT.app")
}

/// Card background: a fill tint, not glass (glass stays on the popover).
struct Card: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var opaque
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(opaque ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - Memory panel

struct Ring: View {
    let fraction: Double
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(fraction * 100))%")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 78, height: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory used: \(Int(fraction * 100)) percent")
    }
}

/// Two-step button: the first click arms it ("Confirm?"), the second acts. No alert window.
struct ConfirmButton: View {
    let title: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button(armed ? "Confirm?" : title) {
            if armed {
                armed = false
                action()
            } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(armed ? .red : nil)
        .accessibilityHint(armed ? "Click again to confirm" : "Asks for confirmation")
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Takes the height of its content and only scrolls past the cap (the popover never runs off screen).
struct BoundedScroll<Content: View>: View {
    let cap: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        if renderMode {
            content      // ImageRenderer does not draw ScrollViews
        } else {
            scroll
        }
    }

    var scroll: some View {
        ScrollView(.vertical) {
            content.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(height: min(max(height, 1), cap))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

/// True during `--render`, when the panels are drawn to images.
var renderMode = false

func screenHeight() -> CGFloat { NSScreen.main?.visibleFrame.height ?? 800 }

struct AppRow: View {
    let g: AppGroup
    let total: UInt64
    let model: Model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: icon(for: g)).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                Text(g.name).lineLimit(1)
                Spacer(minLength: 4)
                // The button keeps its space even when hidden: the row does not change height on hover.
                Group {
                    if g.key == "sim" {
                        Button("Shut down") { model.shutDownSimulator() }.buttonStyle(.bordered).controlSize(.small)
                    } else if g.appPath != nil {
                        ConfirmButton(title: "Quit") { model.quit(g) }
                    }
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(true)
                Text(formatBytes(g.footprint)).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.55))
                            .frame(width: geo.size.width * min(Double(g.footprint) / Double(max(total, 1)), 1))
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(g.name), \(formatBytes(g.footprint))")
        .accessibilityActions {
            if g.key == "sim" { Button("Shut down the simulator") { model.shutDownSimulator() } }
            if g.appPath != nil { Button("Quit \(g.name)") { model.quit(g) } }
        }
        .contextMenu {
            if g.key == "sim" { Button("Shut down the simulator") { model.shutDownSimulator() } }
            if g.appPath != nil { Button("Quit \(g.name)") { model.quit(g) } }
        }
    }
}

struct MemoryPanel: View {
    @ObservedObject var model: Model

    var body: some View {
        let m = model.snap.mem
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Ring(fraction: m.total > 0 ? Double(m.used) / Double(m.total) : 0, color: m.health.color)
                VStack(alignment: .leading, spacing: 5) {
                    Text(m.health.title).font(.title3.weight(.semibold))
                    Text("\(formatBytes(m.used)) used of \(formatBytes(m.total))").foregroundStyle(.secondary)
                    Label("Swap \(formatBytes(m.swapUsed))", systemImage: "arrow.left.arrow.right").foregroundStyle(.secondary)
                    Label("Disk \(formatBytes(UInt64(max(m.diskFree, 0)))) free", systemImage: "internaldrive").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            BoundedScroll(cap: screenHeight() - 300) {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.tips.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(text: "Give your Mac a breather")
                            ForEach(model.tips) { t in
                                HStack(spacing: 10) {
                                    Image(systemName: t.icon).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
                                    Text(t.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 6)
                                    if let b = t.button, let run = t.run {
                                        ConfirmButton(title: b, action: run)
                                    }
                                }
                                .modifier(Card())
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        SectionTitle(text: "Apps")
                        ForEach(model.snap.groups.prefix(6).filter { $0.footprint > 100 << 20 }, id: \.key) { g in
                            AppRow(g: g, total: m.total, model: model)
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Run idle sessions at low priority", isOn: Binding(get: { model.autoPriority }, set: { model.autoPriority = $0 }))
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            .toggleStyle(.switch).controlSize(.mini).font(.callout)
            HStack {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit Mac Breather") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }
}

// MARK: - Sessions panel

struct Dot: View {
    let state: SessionState
    @Environment(\.accessibilityReduceMotion) var calm
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .working && !calm {
                Circle().fill(state.color.opacity(0.35))
                    .scaleEffect(pulse ? 1.9 : 1)
                    .opacity(pulse ? 0 : 1)
                    .animation(pulse ? .easeOut(duration: 1.4).repeatForever(autoreverses: false) : .default, value: pulse)
            }
            if state == .idle {
                Circle().strokeBorder(state.color, lineWidth: 1.5)
            } else {
                Circle().fill(state.color)
            }
        }
        .frame(width: 10, height: 10)
        .onAppear { pulse = true }
        .onDisappear { pulse = false }      // the halo does not run while the popover is closed
        .accessibilityHidden(true)
    }
}

/// "5 min ago", "for 3 min"...: the section already says the state, the row says since when.
func ago(_ r: SessionRow) -> String {
    let t = Date().timeIntervalSince(r.reading.since)
    let now = t < 60
    var text: String
    switch r.reading.state {
    case .working: text = now ? "Just now" : "For \(formatDuration(t))"
    default: text = now ? "Just now" : "\(formatDuration(t)) ago"
    }
    if !r.reading.detail.isEmpty { text = r.reading.detail + " · " + text.lowercased() }
    return text
}

struct SessionRowView: View {
    let r: SessionRow
    let model: Model
    let closePanel: () -> Void
    @State private var hovering = false

    var subtitle: String {
        var t = ago(r)
        if let m = r.memory { t += " · \(formatBytes(m))" }
        if let s = r.session, model.lowered.contains(s.pid) { t += " · low priority" }
        return t
    }

    var body: some View {
        Button {
            model.open(r)
            closePanel()
        } label: {
            HStack(spacing: 10) {
                Dot(state: r.reading.state)
                Image(nsImage: toolIcon(r.tool)).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption)
                        .foregroundStyle(r.reading.state == .waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(r.reading.state == .idle ? 0.7 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(r.title), \(r.tool), \(r.reading.state.title), \(subtitle)")
        .accessibilityHint("Opens \(r.tool)")
        .accessibilityActions {
            if let s = r.session {
                Button("Close the session") { model.close([s]) }
                if model.lowered.contains(s.pid) {
                    Button("Normal priority") { model.restore(s) }
                } else {
                    Button("Low priority") { model.lower(s) }
                }
            }
        }
        .contextMenu {
            Button("Open \(r.tool)") { model.open(r) }
            if let s = r.session {
                if model.lowered.contains(s.pid) {
                    Button("Normal priority") { model.restore(s) }
                } else {
                    Button("Low priority") { model.lower(s) }
                }
                Button("Close the session") { model.close([s]) }
            }
        }
    }
}

struct SessionsPanel: View {
    @ObservedObject var model: Model
    let closePanel: () -> Void

    func count(_ s: SessionState) -> Int { model.rows.filter { $0.reading.state == s }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI sessions").font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 10) {
                    ForEach([SessionState.waiting, .working, .done], id: \.self) { s in
                        if count(s) > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(s.color).frame(width: 7, height: 7)
                                Text("\(count(s))").monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(s.title): \(count(s))")
                        }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            if model.rows.isEmpty {
                Text("No Claude or Codex sessions open.").foregroundStyle(.secondary).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }

            BoundedScroll(cap: screenHeight() - 260) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach([SessionState.waiting, .working, .done, .idle], id: \.self) { s in
                        let rs = model.rows.filter { $0.reading.state == s }
                        if !rs.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    SectionTitle(text: s.title)
                                    Spacer()
                                    let idle = model.idleSessions
                                    if s == .idle, !idle.isEmpty {
                                        ConfirmButton(title: idle.count == 1 ? "Close Claude session"
                                                                             : "Close all \(idle.count) Claude sessions") {
                                            model.close(idle, onlyIdle: true)
                                        }
                                    }
                                }
                                .padding(.horizontal, 8)
                                ForEach(rs) { r in SessionRowView(r: r, model: model, closePanel: closePanel) }
                            }
                        }
                    }
                }
            }

            Divider()
            Text("Idle: done for more than 30 min, with nothing running. The session still holds its memory; you can close it, the thread stays in the app.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Notify me when a session finishes or needs me",
                   isOn: Binding(get: { model.notifySessions }, set: { model.notifySessions = $0 }))
                .toggleStyle(.switch).controlSize(.mini).font(.callout)
            if model.notificationsDenied {
                HStack(spacing: 6) {
                    Text("Notifications are off for Mac Breather.").foregroundStyle(.orange)
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
