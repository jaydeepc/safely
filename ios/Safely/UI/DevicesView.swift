import SafelyCore
import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var browsers: BrowserStore
    @State private var shown = false
    @State private var pairingOpen = false
    @State private var forgetting: PairedBrowser?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Devices").font(.rounded(34, .bold)).foregroundStyle(Theme.ink)
                    Text("Your key links this phone to your browsers").font(.rounded(14, .medium)).foregroundStyle(Theme.muted)
                }
                .staggered(0, shown: shown)

                keyCard.staggered(1, shown: shown)

                Text("PAIRED BROWSERS").font(.rounded(12)).foregroundStyle(Theme.muted).padding(.top, 4).staggered(2, shown: shown)

                if browsers.browsers.isEmpty {
                    Text("No browser yet. Install the Safely extension in Chrome, then pair it here.")
                        .font(.rounded(15, .medium)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        .staggered(3, shown: shown)
                }
                ForEach(Array(browsers.browsers.enumerated()), id: \.element.id) { index, browser in
                    browserRow(browser).staggered(index + 3, shown: shown)
                }

                Button {
                    model.beginPairing()
                    pairingOpen = true
                } label: {
                    Label("Pair a browser", systemImage: "plus.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .staggered(browsers.browsers.count + 4, shown: shown)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .onAppear { shown = true }
        .sheet(isPresented: $pairingOpen, onDismiss: { model.endPairing() }) {
            PairingSheet().presentationDetents([.large]).presentationCornerRadius(34)
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "")?", isPresented: .init(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Forget this browser", role: .destructive) {
                if let browser = forgetting { withAnimation(Theme.spring) { model.forget(browser) } }
            }
        } message: {
            Text("It can no longer ask for passwords until you pair it again.")
        }
    }

    private var keyCard: some View {
        VStack(spacing: 14) {
            LinkChain(state: model.linkState)
            LinkStatusPill(state: model.linkState)
            if model.linkState.keyConnected {
                HStack(spacing: 16) {
                    SignalBars(rssi: model.linkState.rssi)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Safely Key").font(.rounded(15)).foregroundStyle(Theme.ink)
                        Text(model.linkState.rssi.map { "Signal \($0) dBm · reconnects on its own" } ?? "Connected")
                            .font(.rounded(12, .medium)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.field.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Text("Power your Safely Key and keep it within a few metres. The phone finds it again by itself, even with this app closed.")
                    .font(.rounded(13, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 18)
    }

    private func browserRow(_ browser: PairedBrowser) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Theme.avatarGradient(for: browser.id), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name).font(.rounded(16)).foregroundStyle(Theme.ink)
                Text(browser.lastSeenAt.map { "Active \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                    .font(.rounded(13, .medium)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { forgetting = browser } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 32).background(Theme.field, in: Circle())
            }
        }
        .card(padding: 13)
    }
}

struct SignalBars: View {
    let rssi: Int?
    private var level: Int {
        guard let rssi else { return 0 }
        return rssi > -55 ? 4 : rssi > -67 ? 3 : rssi > -80 ? 2 : 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 2)
                    .fill(bar <= level ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.muted.opacity(0.2)))
                    .frame(width: 5, height: CGFloat(6 + bar * 5))
            }
        }
        .animation(Theme.spring, value: level)
    }
}

struct PairingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var radar = false

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 22) {
                Capsule().fill(Theme.muted.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)
                Spacer(minLength: 0)
                phase
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .animation(Theme.spring, value: model.pairing)
    }

    @ViewBuilder private var phase: some View {
        switch model.pairing {
        case .idle, .waiting:
            VStack(spacing: 22) {
                ZStack {
                    ForEach(0..<3) { ring in
                        Circle().stroke(Theme.indigo.opacity(0.35), lineWidth: 2)
                            .frame(width: 110, height: 110)
                            .scaleEffect(radar ? 2.3 : 1)
                            .opacity(radar ? 0 : 0.8)
                            .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(ring) * 0.8), value: radar)
                    }
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 110, height: 110)
                        .background(Theme.gradient, in: Circle())
                }
                .frame(height: 250)
                .onAppear { radar = true }
                Text("Waiting for your browser").font(.rounded(24, .bold)).foregroundStyle(Theme.ink)
                Text("In Chrome, click the Safely icon and choose **Pair with phone**. Keep your Safely Key close to both.")
                    .font(.rounded(15, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                if !model.linkState.keyConnected {
                    Label("Your key is not connected yet", systemImage: "exclamationmark.triangle.fill")
                        .font(.rounded(13)).foregroundStyle(Theme.amber)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))

        case .compare(let code, let browser):
            VStack(spacing: 20) {
                Text("Same code in the browser?").font(.rounded(24, .bold)).foregroundStyle(Theme.ink)
                Text(browser).font(.rounded(15, .medium)).foregroundStyle(Theme.muted)
                CodeDigits(code: code)
                Text("If the codes differ, someone may be interfering. Tap “They differ”.")
                    .font(.rounded(13, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("They differ") { model.answerPairing(matches: false) }.buttonStyle(SoftButtonStyle(color: Theme.rose))
                    Button("They match") { model.answerPairing(matches: true) }.buttonStyle(PrimaryButtonStyle())
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))

        case .paired(let browser):
            VStack(spacing: 18) {
                SuccessBurst()
                Text("Paired").font(.rounded(28, .bold)).foregroundStyle(Theme.ink)
                Text("\(browser) can now ask this phone for logins while your key is nearby.")
                    .font(.rounded(15, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 8)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .sensoryFeedback(.success, trigger: browser)

        case .failed(let reason):
            VStack(spacing: 18) {
                Image(systemName: "xmark.shield.fill").font(.system(size: 60)).foregroundStyle(Theme.rose).symbolEffect(.bounce, value: reason)
                Text("Pairing stopped").font(.rounded(24, .bold)).foregroundStyle(Theme.ink)
                Text(reason).font(.rounded(15, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Try again") { model.beginPairing() }.buttonStyle(PrimaryButtonStyle())
            }
            .transition(.opacity)
        }
    }
}

struct CodeDigits: View {
    let code: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.indigoDeep)
                    .frame(width: 46, height: 62)
                    .background(.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Theme.indigo.opacity(0.3), lineWidth: 1.5))
                    .shadow(color: Theme.indigo.opacity(0.15), radius: 8, y: 4)
                    .padding(.leading, index == 3 ? 10 : 0)
                    .rotation3DEffect(.degrees(shown ? 0 : 90), axis: (x: 1, y: 0, z: 0))
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(Double(index) * 0.08), value: shown)
            }
        }
        .padding(.vertical, 8)
        .onAppear { shown = true }
    }
}

/// A check mark that pops while particles fly outwards.
struct SuccessBurst: View {
    @State private var fire = false

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi
                Circle()
                    .fill([Theme.indigo, Theme.mint, Theme.amber, Theme.rose][i % 4])
                    .frame(width: i.isMultiple(of: 2) ? 9 : 6)
                    .offset(x: fire ? cos(angle) * 105 : 0, y: fire ? sin(angle) * 105 : 0)
                    .opacity(fire ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(0.15), value: fire)
            }
            Circle().fill(Theme.gradient).frame(width: 108, height: 108)
                .shadow(color: Theme.mint.opacity(0.5), radius: 22, y: 10)
                .scaleEffect(fire ? 1 : 0.2)
            Image(systemName: "checkmark").font(.system(size: 46, weight: .heavy)).foregroundStyle(.white)
                .scaleEffect(fire ? 1 : 0).rotationEffect(.degrees(fire ? 0 : -60))
        }
        .frame(height: 220)
        .animation(.spring(response: 0.5, dampingFraction: 0.55), value: fire)
        .onAppear { fire = true }
    }
}
