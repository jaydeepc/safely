import SafelyCore
import SwiftUI

/// A computer wants to use the key. The person compares the six digits and decides.
struct ApprovalSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: ApprovalRequest

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 16) {
                Capsule().fill(Theme.line).frame(width: 36, height: 5).padding(.top, 10)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.primary)
                    .frame(width: 72, height: 72)
                    .background(Theme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 8)
                VStack(spacing: 4) {
                    Text("Allow \(request.name)?").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                    Text("It wants to fill logins from your key. Approve only if it shows this code.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
                CodeDigits(code: request.code)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Button("Different code") { Task { await model.resolveApproval(false) } }.buttonStyle(SoftButtonStyle(color: Theme.rose))
                    Button { Task { await model.resolveApproval(true) } } label: { Label("Same code", systemImage: "faceid") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
        }
        .sensoryFeedback(.warning, trigger: request.id)
    }
}

struct CodeDigits: View {
    let code: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 58)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                    .padding(.leading, index == 3 ? 10 : 0)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(.easeOut(duration: 0.3).delay(Double(index) * 0.06), value: shown)
            }
        }
        .padding(.vertical, 8)
        .onAppear { shown = true }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var activity: ActivityLog
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Pairings, approvals and syncs").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                .staggered(0, shown: shown)

                if activity.events.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock").font(.system(size: 30)).foregroundStyle(Theme.faint)
                        Text("Nothing yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Pair your key to get started.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).card(padding: 28).staggered(1, shown: shown)
                }

                LazyVStack(spacing: 0) {
                    ForEach(Array(activity.events.enumerated()), id: \.element.id) { index, event in
                        ActivityRow(event: event, isLast: index == activity.events.count - 1).staggered(index + 1, shown: shown)
                    }
                }
                .animation(Theme.spring, value: activity.events)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 110)
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
        case .offered: return ("hand.raised.fill", Theme.amber, "Request from")
        case .denied: return ("xmark", Theme.rose, "Denied")
        case .saved: return ("tray.and.arrow.down.fill", Theme.primary, "Saved")
        case .imported: return ("arrow.down.circle.fill", Theme.primary, "Imported")
        case .synced: return ("arrow.triangle.2.circlepath", Theme.teal, "Synced")
        case .paired: return ("link", Theme.teal, "Paired")
        case .unpaired: return ("link.badge.plus", Theme.muted, "Removed")
        case .nothingFound: return ("questionmark", Theme.muted, "No login for")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: look.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(look.1)
                    .frame(width: 32, height: 32).background(look.1.opacity(0.12), in: Circle())
                if !isLast { Rectangle().fill(Theme.line).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(look.2) \(event.site)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Text(event.date.formatted(.relative(presentation: .named))).font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                Text(event.detail).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .padding(.bottom, 18)
        }
    }
}
