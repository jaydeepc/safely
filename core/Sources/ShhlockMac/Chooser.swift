import AppKit
import SafelyCore
import SwiftUI

/// A small floating list under the login field, when more than one login matches. Never steals focus.
final class ChooserPanel {
    var onPick: ((WireItem) -> Void)?
    private var panel: NSPanel?
    private var trackingMouse = false

    var isVisible: Bool { panel?.isVisible ?? false }
    var mouseInside: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    func show(items: [WireItem], host: String, anchor: CGRect) {
        let content = ChooserView(items: items, host: host) { [weak self] item in self?.onPick?(item) }
        let hosting = NSHostingView(rootView: content)
        let width: CGFloat = 320
        let height = min(CGFloat(items.count) * 50 + 44, 320)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = self.panel ?? {
            let p = NSPanel(contentRect: hosting.frame, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            p.isMovableByWindowBackground = false
            return p
        }()
        panel.contentView = hosting
        panel.setContentSize(hosting.frame.size)

        // below the field, clamped to the screen it is on
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct ChooserView: View {
    let items: [WireItem]
    let host: String
    let pick: (WireItem) -> Void
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(MacTheme.accent)
                Text(host.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Text("\(items.count) logins").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button { pick(item) } label: {
                            HStack(spacing: 10) {
                                Text(String((item.title.isEmpty ? item.username : item.title).prefix(1)).uppercased())
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(MacTheme.avatar(for: item.username), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.username.isEmpty ? "(no username)" : item.username).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("Fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(MacTheme.accent)
                                    .opacity(hover == item.id ? 1 : 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(hover == item.id ? MacTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hover = $0 ? item.id : nil }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 0.5))
    }
}
