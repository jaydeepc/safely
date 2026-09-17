import SafelyCore
import SwiftUI

struct VaultView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vault: VaultStore
    @State private var query = ""
    @State private var shown = false
    @State private var selected: VaultItem?
    @State private var adding = false

    private var filtered: [VaultItem] {
        guard !query.isEmpty else { return vault.items }
        return vault.items.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                linkCard
                searchField

                if vault.items.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            Button { selected = item } label: { VaultRow(item: item) }
                                .buttonStyle(PressableRowStyle())
                                .staggered(index + 3, shown: shown)
                        }
                    }
                    .animation(Theme.spring, value: filtered.map(\.id))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.immediately)
        .onAppear { shown = true }
        .sheet(item: $selected) { item in
            ItemDetailView(item: item).presentationCornerRadius(34)
        }
        .sheet(isPresented: $adding) {
            ItemEditor(item: nil).presentationCornerRadius(34)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vault").font(.rounded(34, .bold)).foregroundStyle(Theme.ink)
                Text("\(vault.items.count) logins, only on this phone")
                    .font(.rounded(14, .medium)).foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
            }
            Spacer()
            BouncyMascot(size: 58)
            Button { adding = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Theme.grapeGradient, in: Circle())
                    .shadow(color: Theme.grape.opacity(0.35), radius: 10, y: 5)
            }
            .buttonStyle(PressableRowStyle())
        }
        .staggered(0, shown: shown)
    }

    private var linkCard: some View {
        VStack(spacing: 12) {
            LinkChain(state: model.linkState)
            LinkStatusPill(state: model.linkState)
            if let fill = model.lastFill {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
                    Text("Just filled \(fill.site)").font(.rounded(13, .medium)).foregroundStyle(Theme.muted)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 18)
        .staggered(1, shown: shown)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Search logins", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { withAnimation { query = "" } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted.opacity(0.6)) }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.rounded(16, .medium))
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .staggered(2, shown: shown)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            BouncyMascot(pose: .empty, size: 190)
            Text("Nothing here yet").font(.rounded(20, .bold)).foregroundStyle(Theme.ink)
            Text("Tap + to add a login, or import everything from Chrome or Safari in Settings.")
                .font(.rounded(15, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 28)
        .staggered(3, shown: shown)
    }
}

struct VaultRow: View {
    let item: VaultItem

    var body: some View {
        HStack(spacing: 14) {
            Avatar(text: item.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.rounded(16)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(item.username.isEmpty ? item.host : item.username).font(.rounded(13, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            PasswordStrengthDots(score: PasswordGenerator.strength(of: item.password))
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted.opacity(0.5))
        }
        .card(padding: 13)
    }
}

struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct PasswordStrengthDots: View {
    let score: Int  // 0...4

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i < score ? color : Theme.field).frame(width: 5, height: 14)
            }
        }
    }

    private var color: Color { score <= 1 ? Theme.rose : score == 2 ? Theme.amber : Theme.green }
}
