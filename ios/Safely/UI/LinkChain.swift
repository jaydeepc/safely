import SafelyCore
import SwiftUI

/// Phone ─ Key ─ Computers. Solid wire when live, dotted while looking.
struct LinkChain: View {
    let state: RelayLink.State
    let key: KeyStatus
    let paired: Bool
    let computers: Int

    private var keyOn: Bool { state.keyConnected && paired && key.unlocked }
    private var keyFound: Bool { state.keyConnected }

    var body: some View {
        HStack(spacing: 0) {
            node("iphone", "Phone", on: true)
            Wire(on: keyOn, seeking: state.bluetooth == .on && !keyOn)
            node("key.horizontal", "Key", on: keyFound, highlight: keyOn)
            Wire(on: keyOn && computers > 0, seeking: keyOn && computers == 0)
            node("laptopcomputer", computers == 1 ? "1 computer" : "\(computers) computers", on: keyOn && computers > 0)
        }
    }

    private func node(_ symbol: String, _ label: String, on: Bool, highlight: Bool? = nil) -> some View {
        let strong = highlight ?? on
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(strong ? AnyShapeStyle(Theme.navyGradient) : on ? AnyShapeStyle(Theme.primary.opacity(0.12)) : AnyShapeStyle(Theme.field))
                    .frame(width: 52, height: 52)
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(strong ? .white : on ? Theme.primary : Theme.faint)
            }
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Theme.ink : Theme.muted).lineLimit(1)
        }
        .frame(width: 84)
        .animation(Theme.spring, value: on)
        .animation(Theme.spring, value: strong)
    }
}

private struct Wire: View {
    let on: Bool
    let seeking: Bool

    var body: some View {
        TimelineView(.animation(paused: !(on || seeking))) { timeline in
            Canvas { context, size in
                let y = size.height / 2
                var track = Path()
                track.move(to: CGPoint(x: 2, y: y))
                track.addLine(to: CGPoint(x: size.width - 2, y: y))
                context.stroke(track, with: .color(on ? Theme.primary.opacity(0.5) : Theme.line),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: on ? [] : [3, 5]))
                guard on || seeking else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t * (on ? 0.6 : 0.4)).truncatingRemainder(dividingBy: 1)
                let progress = on ? phase : (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                let x = 2 + (size.width - 4) * progress
                let fade = on ? sin(phase * .pi) : 0.6
                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                             with: .color((on ? Theme.primary : Theme.muted).opacity(fade)))
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }
}
