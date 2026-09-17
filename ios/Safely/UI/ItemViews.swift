import SafelyCore
import SwiftUI
import UIKit

enum PasswordGenerator {
    static func make(length: Int = 20, symbols: Bool = true) -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ")
        let digits = Array("23456789")
        let marks = Array("!@#$%&*-_+?")
        var pool = letters + digits + (symbols ? marks : [])
        var generator = SystemRandomNumberGenerator()
        var result = [letters.randomElement(using: &generator)!, digits.randomElement(using: &generator)!]
        if symbols { result.append(marks.randomElement(using: &generator)!) }
        while result.count < length { result.append(pool.randomElement(using: &generator)!) }
        pool.removeAll()
        return String(result.shuffled(using: &generator))
    }

    /// 0 (terrible) … 4 (excellent). A rough guide, not an audit.
    static func strength(of password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var classes = 0
        if password.contains(where: \.isLowercase) { classes += 1 }
        if password.contains(where: \.isUppercase) { classes += 1 }
        if password.contains(where: \.isNumber) { classes += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        let lengthScore = password.count >= 16 ? 2 : password.count >= 11 ? 1 : 0
        let unique = Set(password).count
        if unique < 5 { return 1 }
        return max(1, min(4, classes - 1 + lengthScore))
    }
}

/// Copies a secret that other devices never see and that expires from the clipboard after a minute.
func copySecret(_ value: String) {
    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]],
                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
}

/// Characters settle into place one by one when a password is revealed.
struct ScrambleText: View {
    let text: String
    let revealed: Bool
    @State private var progress = 0
    @State private var noise = ""
    private let glyphs = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789#$%&@")

    var body: some View {
        Text(display)
            .font(.system(size: 19, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .task(id: revealed) { await run() }
    }

    private var display: String {
        guard revealed else { return String(repeating: "•", count: min(max(text.count, 8), 16)) }
        return String(text.prefix(progress)) + noise
    }

    private func run() async {
        guard revealed else {
            progress = 0
            noise = ""
            return
        }
        let count = text.count
        for step in 0...count {
            progress = step
            noise = String((0..<(count - step)).map { _ in glyphs.randomElement()! })
            try? await Task.sleep(for: .milliseconds(max(14, 360 / max(count, 1))))
        }
    }
}

struct ItemDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    let item: VaultItem

    @State private var revealed = false
    @State private var copied: String?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var shown = false

    private var current: VaultItem { vault.items.first { $0.id == item.id } ?? item }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 16) {
                    Capsule().fill(Theme.muted.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)

                    VStack(spacing: 10) {
                        Avatar(text: current.title, size: 84)
                            .scaleEffect(shown ? 1 : 0.4)
                            .rotationEffect(.degrees(shown ? 0 : -18))
                        Text(current.title).font(.rounded(26, .bold)).foregroundStyle(Theme.ink)
                        Text(current.host).font(.rounded(15, .medium)).foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 6)

                    field("Username", symbol: "person.fill", index: 1) {
                        Text(current.username.isEmpty ? "—" : current.username).font(.rounded(17, .medium)).foregroundStyle(Theme.ink)
                    } action: {
                        copyButton("username") { UIPasteboard.general.string = current.username }
                    }

                    field("Password", symbol: "key.fill", index: 2) {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrambleText(text: current.password, revealed: revealed)
                            PasswordStrengthDots(score: PasswordGenerator.strength(of: current.password))
                        }
                    } action: {
                        HStack(spacing: 8) {
                            iconButton(revealed ? "eye.slash.fill" : "eye.fill") {
                                if revealed {
                                    revealed = false
                                } else {
                                    Task { if await model.authenticate("Reveal this password") { revealed = true } }
                                }
                            }
                            copyButton("password") { copySecret(current.password) }
                        }
                    }

                    if !current.notes.isEmpty {
                        field("Notes", symbol: "note.text", index: 3) {
                            Text(current.notes).font(.rounded(15, .medium)).foregroundStyle(Theme.ink)
                        } action: { EmptyView() }
                    }

                    HStack(spacing: 10) {
                        stat("Filled", "\(current.useCount)×")
                        stat("Last used", current.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
                        stat("Changed", current.updatedAt.formatted(.relative(presentation: .named)))
                    }
                    .staggered(4, shown: shown)

                    HStack(spacing: 12) {
                        Button("Edit") { editing = true }.buttonStyle(SoftButtonStyle())
                        Button("Delete") { confirmDelete = true }.buttonStyle(SoftButtonStyle(color: Theme.rose))
                    }
                    .staggered(5, shown: shown)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { shown = true } }
        .sheet(isPresented: $editing) { ItemEditor(item: current).presentationCornerRadius(34) }
        .confirmationDialog("Delete \(current.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete login", role: .destructive) {
                vault.delete(current)
                dismiss()
            }
        }
    }

    private func field<Content: View, Action: View>(_ label: String, symbol: String, index: Int,
                                                     @ViewBuilder content: () -> Content, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol).font(.rounded(12)).foregroundStyle(Theme.muted)
                content()
            }
            Spacer(minLength: 6)
            action()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .staggered(index, shown: shown)
    }

    private func copyButton(_ what: String, perform: @escaping () -> Void) -> some View {
        iconButton(copied == what ? "checkmark" : "doc.on.doc.fill", tint: copied == what ? Theme.green : Theme.primary) {
            perform()
            withAnimation(Theme.spring) { copied = what }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(Theme.spring) { if copied == what { copied = nil } }
            }
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    private func iconButton(_ symbol: String, tint: Color = Theme.primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableRowStyle())
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.rounded(14)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.rounded(11, .medium)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 12)
    }
}

struct ItemEditor: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    let item: VaultItem?

    @State private var title = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var notes = ""
    @State private var spin = 0.0

    private var canSave: Bool { !password.isEmpty && !(title.isEmpty && url.isEmpty) }

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 14) {
                    Capsule().fill(Theme.muted.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)
                    Text(item == nil ? "New login" : "Edit login").font(.rounded(24, .bold)).foregroundStyle(Theme.ink).padding(.vertical, 4)

                    input("Name", text: $title, prompt: "GitHub")
                    input("Website", text: $url, prompt: "https://github.com", keyboard: .URL)
                    input("Username", text: $username, prompt: "you@example.com", keyboard: .emailAddress)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password").font(.rounded(12)).foregroundStyle(Theme.muted)
                        HStack {
                            TextField("Password", text: $password)
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                                    spin += 360
                                    password = PasswordGenerator.make()
                                }
                            } label: {
                                Image(systemName: "dice.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 42, height: 42)
                                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .rotationEffect(.degrees(spin))
                            }
                            .sensoryFeedback(.impact, trigger: spin)
                        }
                        StrengthBar(score: PasswordGenerator.strength(of: password))
                    }
                    .card()

                    input("Notes", text: $notes, prompt: "Optional")

                    Button(item == nil ? "Save to vault" : "Save changes") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.5)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            guard let item else { return }
            title = item.title
            url = item.url
            username = item.username
            password = item.password
            notes = item.notes
        }
    }

    private func input(_ label: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.rounded(12)).foregroundStyle(Theme.muted)
            TextField(prompt, text: text)
                .font(.rounded(17, .medium))
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
                .autocorrectionDisabled()
        }
        .card()
    }

    private func save() {
        var updated = item ?? VaultItem(title: "", url: "", username: "", password: "")
        updated.title = title.isEmpty ? DomainMatcher.host(of: url) : title
        updated.url = url
        updated.username = username
        updated.password = password
        updated.notes = notes
        vault.upsert(updated)
        dismiss()
    }
}

struct StrengthBar: View {
    let score: Int
    private let labels = ["", "Weak", "Fair", "Strong", "Excellent"]

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.field)
                    Capsule().fill(color.gradient).frame(width: geo.size.width * CGFloat(score) / 4)
                }
            }
            .frame(height: 7)
            Text(labels[min(max(score, 0), 4)]).font(.rounded(12)).foregroundStyle(color).frame(width: 64, alignment: .trailing)
                .contentTransition(.opacity)
        }
        .animation(Theme.spring, value: score)
    }

    private var color: Color { score <= 1 ? Theme.rose : score == 2 ? Theme.amber : Theme.green }
}
