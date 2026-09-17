import SafelyCore
import SwiftUI

/// Phone ─ Key ─ Browser, with light running along the wires that are live.
struct LinkChain: View {
    let state: RelayLink.State
    var compact = false

    private var keyOn: Bool { state.keyConnected }
    private var browserOn: Bool { state.keyConnected && state.peerPresent }

    var body: some View {
        HStack(spacing: 0) {
            node("iphone", "Phone", on: true)
            Wire(on: keyOn, seeking: state.bluetooth == .on && !keyOn)
            node("key.horizontal.fill", "Key", on: keyOn)
            Wire(on: browserOn, seeking: keyOn && !browserOn)
            node("laptopcomputer", "Browser", on: browserOn)
        }
    }

    private func node(_ symbol: String, _ label: String, on: Bool) -> some View {
        let size: CGFloat = compact ? 42 : 54
        return VStack(spacing: 7) {
            ZStack {
                if on {
                    PulseRing(size: size)
                }
                RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.field))
                    .frame(width: size, height: size)
                    .shadow(color: on ? Theme.indigo.opacity(0.3) : .clear, radius: 10, y: 5)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(on ? .white : Theme.muted.opacity(0.7))
                    .symbolEffect(.bounce, value: on)
            }
            .scaleEffect(on ? 1 : 0.92)
            if !compact {
                Text(label).font(.rounded(12)).foregroundStyle(on ? Theme.ink : Theme.muted)
            }
        }
        .animation(Theme.spring, value: on)
    }
}

private struct PulseRing: View {
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
            .stroke(Theme.indigo.opacity(0.35), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(pulse ? 1.45 : 1)
            .opacity(pulse ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
            }
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
                track.move(to: CGPoint(x: 4, y: y))
                track.addLine(to: CGPoint(x: size.width - 4, y: y))
                context.stroke(track, with: .color(on ? Theme.indigo.opacity(0.22) : Theme.muted.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: on ? [] : [2, 7]))

                guard on || seeking else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let count = on ? 3 : 1
                for i in 0..<count {
                    let speed = on ? 0.9 : 0.5
                    let phase = (t * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                    // when only seeking, the dot goes out and comes back
                    let progress = on ? phase : (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                    let x = 4 + (size.width - 8) * progress
                    let fade = on ? sin(phase * .pi) : 0.7
                    let dot = Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    context.fill(dot, with: .color((on ? Theme.mint : Theme.muted).opacity(fade)))
                    if on {
                        context.fill(Path(ellipseIn: CGRect(x: x - 8, y: y - 8, width: 16, height: 16)), with: .color(Theme.indigo.opacity(0.18 * fade)))
                    }
                }
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }
}

struct LinkStatusPill: View {
    let state: RelayLink.State

    private var info: (String, Color) {
        switch state.bluetooth {
        case .off: return ("Bluetooth is off", Theme.rose)
        case .unauthorized: return ("Bluetooth not allowed", Theme.rose)
        case .unsupported: return ("No Bluetooth here", Theme.muted)
        default: break
        }
        if !state.keyConnected { return ("Looking for your key", Theme.amber) }
        if !state.peerPresent { return ("Key connected", Theme.indigo) }
        return ("Ready to fill", Theme.green)
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(info.1).frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.35]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
            Text(info.0).font(.rounded(13)).foregroundStyle(info.1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(info.1.opacity(0.12), in: Capsule())
        .animation(Theme.spring, value: info.0)
    }
}
