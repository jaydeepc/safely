import SwiftUI

enum AppTab: String, CaseIterable {
    case vault, devices, activity, settings

    var title: String { rawValue.capitalized }
    var gradient: LinearGradient {
        switch self {
        case .vault: return Theme.gradient
        case .devices: return Theme.skyGradient
        case .activity: return Theme.sunnyGradient
        case .settings: return Theme.grapeGradient
        }
    }
    var symbol: String {
        switch self {
        case .vault: return "lock.shield.fill"
        case .devices: return "dot.radiowaves.left.and.right"
        case .activity: return "bolt.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = Self.initialTab
    @Namespace private var tabSpace

    /// `-SafelyTab devices` opens a specific tab (used for screenshots).
    private static var initialTab: AppTab {
        UserDefaults.standard.string(forKey: "SafelyTab").flatMap(AppTab.init(rawValue:)) ?? .vault
    }

    /// `-SafelyScreen onboarding|lock|paired` shows one screen in demo mode (used for screenshots).
    private static let demoScreen = AppModel.isDemo ? UserDefaults.standard.string(forKey: "SafelyScreen") : nil

    var body: some View {
        ZStack {
            AuroraBackground()

            if Self.demoScreen == "onboarding" {
                OnboardingView()
            } else if Self.demoScreen == "lock" {
                LockView()
            } else if Self.demoScreen == "paired" {
                VStack(spacing: 18) {
                    SuccessBurst()
                    Text("Paired").font(.rounded(28, .bold)).foregroundStyle(Theme.ink)
                }
            } else if !settings.onboarded && !AppModel.isDemo {
                OnboardingView().transition(.opacity)
            } else {
                content
            }

            if model.isLocked {
                LockView().transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.15))))
            }

            // Hide the vault in the app switcher
            if scenePhase != .active && !model.isLocked {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().overlay(Mascot(size: 130))
            }
        }
        .sheet(item: $model.approval) { pending in
            ApprovalSheet(pending: pending)
                .presentationDetents([.medium])
                .presentationCornerRadius(34)
                .interactiveDismissDisabled()
        }
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .vault: VaultView()
                case .devices: DevicesView()
                case .activity: ActivityView()
                case .settings: SettingsView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.spring) { tab = item }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .symbolEffect(.bounce, value: tab == item)
                        if tab == item {
                            Text(item.title).font(.rounded(14)).transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .foregroundStyle(tab == item ? .white : Theme.muted)
                    .padding(.vertical, 12)
                    .padding(.horizontal, tab == item ? 18 : 14)
                    .background {
                        if tab == item {
                            Capsule().fill(item.gradient).matchedGeometryEffect(id: "tab", in: tabSpace)
                                .shadow(color: Theme.primaryDeep.opacity(0.28), radius: 10, y: 5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: tab)
            }
        }
        .padding(6)
        .background(.white.opacity(0.94), in: Capsule())
        .shadow(color: Theme.primaryDeep.opacity(0.14), radius: 22, y: 10)
        .padding(.bottom, 6)
    }
}

struct LockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var breathe = false

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    ForEach(0..<3) { ring in
                        Circle()
                            .stroke([Theme.primary, Theme.tangerine, Theme.grape][ring].opacity(0.30 - Double(ring) * 0.07), lineWidth: 2)
                            .frame(width: 230 + CGFloat(ring) * 56, height: 230 + CGFloat(ring) * 56)
                            .scaleEffect(breathe ? 1.06 : 0.94)
                            .animation(.easeInOut(duration: 2.4).repeatForever().delay(Double(ring) * 0.25), value: breathe)
                    }
                    BouncyMascot(size: 190)
                }
                VStack(spacing: 6) {
                    Text("Shlok").font(.rounded(34, .bold)).foregroundStyle(Theme.ink)
                    Text("Shh… your vault is locked").font(.rounded(16, .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    Task { await model.unlock() }
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 32)
                .padding(.bottom, 36)
            }
        }
        .onAppear { breathe = true }
        .task { await model.unlock() }
    }
}
