import SafelyCore
import SwiftUI

/// "Ask me every time": a browser wants a login, the person decides.
struct ApprovalSheet: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingApproval
    @State private var pulse = false

    private var site: String { DomainMatcher.host(of: pending.request.origin) }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.indigo.opacity(0.3), lineWidth: 2).frame(width: 84, height: 84)
                        .scaleEffect(pulse ? 1.7 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                    Avatar(text: pending.matches.first?.title ?? site, size: 84)
                }
                .padding(.top, 26)

                VStack(spacing: 4) {
                    Text("Sign in to \(site)?").font(.rounded(23, .bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                    Text("\(pending.request.browser.name) is asking").font(.rounded(15, .medium)).foregroundStyle(Theme.muted)
                }

                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.indigo)
                    Text(pending.matches.count == 1 ? pending.matches[0].username : "\(pending.matches.count) matching logins")
                        .font(.rounded(15)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white.opacity(0.9), in: Capsule())

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Deny") { Task { await model.resolveApproval(false) } }.buttonStyle(SoftButtonStyle(color: Theme.rose))
                    Button { Task { await model.resolveApproval(true) } } label: { Label("Approve", systemImage: "faceid") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
        }
        .onAppear { pulse = true }
        .sensoryFeedback(.warning, trigger: pending.id)
    }
}

struct ActivityView: View {
    @EnvironmentObject private var activity: ActivityLog
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(.rounded(34, .bold)).foregroundStyle(Theme.ink)
                    Text("Every time a password left this phone").font(.rounded(14, .medium)).foregroundStyle(Theme.muted)
                }
                .staggered(0, shown: shown)

                if activity.events.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 36)).foregroundStyle(Theme.gradient)
                        Text("All quiet").font(.rounded(19, .bold)).foregroundStyle(Theme.ink)
                        Text("Fills, saves and pairings will show up here.").font(.rounded(14, .medium)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .card(padding: 28)
                    .staggered(1, shown: shown)
                }

                LazyVStack(spacing: 0) {
                    ForEach(Array(activity.events.enumerated()), id: \.element.id) { index, event in
                        ActivityRow(event: event, isLast: index == activity.events.count - 1)
                            .staggered(index + 1, shown: shown)
                    }
                }
                .animation(Theme.spring, value: activity.events)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .onAppear { shown = true }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let isLast: Bool

    private var look: (String, Color, String) {
        switch event.kind {
        case .filled: return ("bolt.fill", Theme.green, "Filled")
        case .offered: return ("hand.raised.fill", Theme.amber, "Asked")
        case .denied: return ("xmark", Theme.rose, "Denied")
        case .saved: return ("tray.and.arrow.down.fill", Theme.indigo, "Saved")
        case .imported: return ("square.and.arrow.down.on.square.fill", Theme.indigo, "Imported")
        case .paired: return ("link", Theme.mint, "Paired")
        case .unpaired: return ("link.badge.plus", Theme.muted, "Unpaired")
        case .nothingFound: return ("questionmark", Theme.muted, "No login for")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: look.0)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(look.1.gradient, in: Circle())
                if !isLast {
                    Rectangle().fill(Theme.muted.opacity(0.18)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(look.2) \(event.site)").font(.rounded(15)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Text(event.date.formatted(.relative(presentation: .named))).font(.rounded(12, .medium)).foregroundStyle(Theme.muted)
                }
                Text(event.detail).font(.rounded(13, .medium)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .padding(.bottom, 20)
        }
    }
}
