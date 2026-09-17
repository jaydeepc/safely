import SafelyCore
import SwiftUI

/// The Key tab: the link to the key, what is on it, and the computers allowed to use it.
struct KeyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var shown = false
    @State private var pairingOpen = false
    @State private var removing: PeerInfo?
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Key").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Your logins live on the key. This phone manages them.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                .staggered(0, shown: shown)

                keyCard.staggered(1, shown: shown)

                if model.paired {
                    sectionTitle("COMPUTERS").staggered(2, shown: shown)
                    if model.peers.isEmpty {
                        Text("No computer yet. Install Shhlock for Mac, click “Pair with my key” there, and approve it here.")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).card()
                            .staggered(3, shown: shown)
                    }
                    ForEach(Array(model.peers.enumerated()), id: \.element.id) { index, peer in
                        peerRow(peer).staggered(index + 3, shown: shown)
                    }

                    sectionTitle("MANAGE").staggered(model.peers.count + 4, shown: shown)
                    VStack(spacing: 0) {
                        actionRow("Sync now", detail: model.key.syncing ? "Syncing…" : "Push this phone's vault, pull new logins", symbol: "arrow.triangle.2.circlepath") {
                            Task { await model.sync() }
                        }
                        Divider().padding(.leading, 52)
                        actionRow("Forget this key", detail: "Keeps the vault on this phone", symbol: "minus.circle", tint: Theme.rose) { model.forgetKey() }
                        Divider().padding(.leading, 52)
                        actionRow("Reset the key", detail: "Erases the key completely", symbol: "exclamationmark.triangle", tint: Theme.rose) { confirmReset = true }
                    }
                    .card(padding: 6)
                    .staggered(model.peers.count + 5, shown: shown)
                } else {
                    Button {
                        model.beginPairing()
                        pairingOpen = true
                    } label: { Label("Pair this phone with the key", systemImage: "link") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.linkState.keyConnected)
                    .opacity(model.linkState.keyConnected ? 1 : 0.5)
                    .staggered(2, shown: shown)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 110)
        }
        .onAppear {
            shown = true
            if model.paired, model.key.unlocked { Task { await model.refreshPeers() } }
        }
        .sheet(isPresented: $pairingOpen, onDismiss: { model.endPairing() }) {
            KeyPairingSheet().presentationDetents([.large]).presentationCornerRadius(28)
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let peer = removing { Task { await model.remove(peer) } } }
        } message: { Text("It can no longer read logins from the key until you approve it again.") }
        .confirmationDialog("Reset the key?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase the key", role: .destructive) { Task { if await model.authenticate("Reset the key") { await model.resetKey() } } }
        } message: { Text("Every login and pairing on the key is erased. This phone keeps its own copy and can load it again.") }
    }

    private var keyCard: some View {
        VStack(spacing: 16) {
            LinkChain(state: model.linkState, key: model.key, paired: model.paired, computers: model.peers.count)
            HStack {
                StatusPill(text: statusText, color: statusColor)
                Spacer()
                if let rssi = model.linkState.rssi, model.linkState.keyConnected { SignalBars(rssi: rssi) }
            }
            if model.paired && model.key.unlocked {
                Divider()
                HStack(spacing: 0) {
                    stat("\(model.key.vaultCount ?? 0)", "logins on key")
                    stat(model.key.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "—", "last sync")
                    stat("\(model.peers.count)", model.peers.count == 1 ? "computer" : "computers")
                }
            } else if !model.linkState.keyConnected {
                Text("Power the key and keep it within a few metres. The phone finds it by itself, even with this app closed.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 18)
    }

    private var statusText: String {
        switch model.linkState.bluetooth {
        case .off: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth not allowed"
        case .unsupported: return "No Bluetooth here"
        default: break
        }
        if !model.linkState.keyConnected { return "Looking for the key" }
        if !model.paired { return "Key found — not paired" }
        if model.key.syncing { return "Syncing" }
        return model.key.unlocked ? "Connected and unlocked" : "Connected — unlocking"
    }

    private var statusColor: Color {
        if !model.linkState.keyConnected { return Theme.amber }
        return model.paired && model.key.unlocked ? Theme.green : Theme.primary
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).tracking(0.6).padding(.top, 6).padding(.leading, 4)
    }

    private func peerRow(_ peer: PeerInfo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 42, height: 42)
                .background(Theme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Can fill logins from the key").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { removing = peer } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30).background(Theme.field, in: Circle())
            }
        }
        .card(padding: 12)
    }

    private func actionRow(_ title: String, detail: String, symbol: String, tint: Color = Theme.primary, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 34, height: 34).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint == Theme.rose ? Theme.rose : Theme.ink)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(10)
        }
        .buttonStyle(.plain)
    }
}

struct SignalBars: View {
    let rssi: Int
    private var level: Int { rssi > -55 ? 4 : rssi > -67 ? 3 : rssi > -80 ? 2 : 1 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(bar <= level ? Theme.primary : Theme.line)
                    .frame(width: 4, height: CGFloat(5 + bar * 4))
            }
        }
    }
}

/// Pairing this phone with a key: press the button on the key to prove you hold it.
struct KeyPairingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 20) {
                Capsule().fill(Theme.line).frame(width: 36, height: 5).padding(.top, 10)
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .animation(Theme.spring, value: model.pairing)
    }

    @ViewBuilder private var content: some View {
        switch model.pairing {
        case .idle, .connecting:
            VStack(spacing: 16) {
                LockTile(size: 110)
                Text("Reaching the key…").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                ProgressView().tint(Theme.primary)
            }
        case .pressButton:
            VStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.primary.opacity(0.35), lineWidth: 2).frame(width: 130, height: 130)
                        .scaleEffect(pulse ? 1.5 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                    Image(systemName: "button.programmable")
                        .font(.system(size: 52, weight: .medium)).foregroundStyle(Theme.primary)
                        .frame(width: 130, height: 130)
                        .background(Theme.primary.opacity(0.10), in: Circle())
                }
                .onAppear { pulse = true }
                Text("Press the button on the key").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                Text("The small button on the XIAO board, next to the USB-C port. That proves the key is in your hand, not someone else's.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
        case .paired(let name):
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.green)
                    .symbolEffect(.bounce, value: name)
                Text("Paired with \(name)").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                Text("Your vault is being loaded onto the key. From now on, computers you approve can fill logins from it — with or without this phone nearby.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
            .sensoryFeedback(.success, trigger: name)
        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.rose)
                Text("Pairing stopped").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                Text(reason).font(.system(size: 15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Try again") { model.beginPairing() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
