// Mac Breather, toasts: our own glass notifications, stacked under the menu bar, with a short chime.
// They replace macOS notifications, whose look an app cannot change.

import AppKit
import SwiftUI

struct Toast {
    let key: String
    let title: String
    let body: String
    let icon: NSImage
    let state: SessionState?     // session dot; nil for memory alerts
    let action: String           // "Open Claude", "Show Memory"...
    let open: () -> Void
}

struct ToastView: View {
    let t: Toast
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: t.icon).resizable().frame(width: 34, height: 34).accessibilityHidden(true)
                if let s = t.state { Dot(state: s).offset(x: 3, y: 3) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.headline).lineLimit(1)
                Text(t.body).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(t.action, action: open).buttonStyle(.borderedProminent)
                    Button("Dismiss", action: dismiss).buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .modifier(Glass())
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture(perform: open)     // the whole card opens
        .padding(10)          // room for the glass shadow
        .accessibilityElement(children: .contain)
    }
}

/// Liquid Glass on macOS 26; a frosted material before that, and in `--render` (ImageRenderer cannot draw glass).
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !renderMode {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 22))   // macOS 14-15, and --render
        }
    }
}

final class ToastCenter {
    private var shown: [(key: String, panel: NSPanel)] = []
    var sound = true
    private let chime = Bundle.main.url(forResource: "notify", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }

    func show(_ t: Toast) {
        if let old = shown.first(where: { $0.key == t.key }) { close(old.panel) }   // same subject: replace
        if shown.count >= 3, let oldest = shown.last { close(oldest.panel) }   // keep the corner usable

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]   // not over full-screen apps
        panel.hidesOnDeactivate = false
        panel.sharingType = .none        // session titles stay out of screen sharing and recordings
        let host = NSHostingView(rootView: ToastView(t: t,
            open: { [weak self, weak panel] in t.open(); if let panel { self?.close(panel) } },
            dismiss: { [weak self, weak panel] in if let panel { self?.close(panel) } }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        shown.insert((t.key, panel), at: 0)
        if let screen = NSScreen.screens.first?.visibleFrame {     // start slightly above its slot, then slide in
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 4, y: screen.maxY + 8))
        }
        layout(animated: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }

        if sound {
            chime?.stop()
            chime?.play()
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(t.title). \(t.body)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if testingPanels {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSLog("MacBreather toast %@ chime=%d", NSStringFromRect(panel.frame), self.chime == nil ? 0 : 1)
                // Snapshot of the real toast, as drawn in its window.
                if let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "macbreather-toast.png"))
                    NSLog("MacBreather toast snapshot %@", NSTemporaryDirectory() + "macbreather-toast.png")
                }
            }
        }
        // With VoiceOver, no timer: the buttons must stay reachable.
        if !NSWorkspace.shared.isVoiceOverEnabled { closeLater(panel, after: 6, budget: 15) }
    }

    /// Closes after a delay; the pointer resting on the toast holds it, up to `budget` seconds in all.
    private func closeLater(_ panel: NSPanel, after delay: TimeInterval, budget: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
            guard let self, let panel, self.shown.contains(where: { $0.panel === panel }) else { return }
            let left = budget - delay
            if left > 0, panel.frame.contains(NSEvent.mouseLocation) {
                self.closeLater(panel, after: 2, budget: left)
            } else {
                self.close(panel)
            }
        }
    }

    func close(_ panel: NSPanel) {
        shown.removeAll { $0.panel === panel }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
        layout(animated: true)
    }

    /// Stacks toasts from the top right corner, newest first.
    private func layout(animated: Bool) {
        guard let screen = NSScreen.screens.first?.visibleFrame else { return }   // the screen with the menu bar
        var top = screen.maxY - 4
        for (_, panel) in shown {
            let size = panel.frame.size
            let frame = NSRect(x: screen.maxX - size.width - 4, y: top - size.height, width: size.width, height: size.height)
            top -= size.height - 8                     // the 10 pt shadow margins overlap a little
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.animator().setFrame(frame, display: true)
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }
}
