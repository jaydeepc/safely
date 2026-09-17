import SafelyCore
import SwiftUI

enum AppTab: String, CaseIterable {
    case vault, key, activity, settings

    var title: String { rawValue.capitalized }
    var gradient: LinearGradient {
        switch self {
        case .vault: return Theme.gradient
        case .key: return Theme.skyGradient
        case .activity: return Theme.sunnyGradient
        case .settings: return Theme.grapeGradient
        }
    }
    var symbol: String {
        switch self {
        case .vault: return "lock.fill"
        case .key: return "key.horizontal"
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
            } else if Self.demoScreen == "approve" {
                ApprovalSheet(request: ApprovalRequest(id: "demo", code: "482913", name: "Jaydeep's MacBook Pro"))
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
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().overlay(LockTile(size: 96))
            }
        }
        .sheet(item: $model.approval) { request in
            ApprovalSheet(request: request)
                .presentationDetents([.medium])
                .presentationCornerRadius(28)
                .interactiveDismissDisabled()
        }
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .vault: VaultView()
                case .key: KeyView()
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
                            Capsule().fill(Theme.navy).matchedGeometryEffect(id: "tab", in: tabSpace)
                        }
                    }
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: tab)
            }
        }
        .padding(6)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: Theme.navy.opacity(0.10), radius: 18, y: 8)
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
                LockTile(size: 120)
                    .scaleEffect(breathe ? 1.02 : 0.98)
                    .animation(.easeInOut(duration: 2.6).repeatForever(), value: breathe)
                VStack(spacing: 6) {
                    Text("Shhlock").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Your vault is locked").font(.system(size: 15)).foregroundStyle(Theme.muted)
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
