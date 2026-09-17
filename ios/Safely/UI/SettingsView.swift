import SafelyCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var activity: ActivityLog

    @State private var shown = false
    @State private var importing = false
    @State private var importResult: ImportSummary?
    @State private var exportFile: ExportedCSV?
    @State private var confirmErase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.rounded(34, .bold)).foregroundStyle(Theme.ink).staggered(0, shown: shown)

                section("WHEN A BROWSER ASKS", index: 1) {
                    ForEach(FillPolicy.allCases) { policy in
                        Button {
                            withAnimation(Theme.spring) { settings.fillPolicy = policy }
                            if policy == .ask { model.requestNotificationPermission() }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: settings.fillPolicy == policy ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(settings.fillPolicy == policy ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.muted.opacity(0.4)))
                                    .contentTransition(.symbolEffect(.replace))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(policy.title).font(.rounded(16)).foregroundStyle(Theme.ink)
                                    Text(policy.blurb).font(.rounded(13, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.selection, trigger: settings.fillPolicyRaw)
                    }
                }

                section("SECURITY", index: 2) {
                    toggle("Lock with Face ID", "Ask when the app opens and after 45 s away", symbol: "faceid", isOn: $settings.appLock)
                    Divider()
                    toggle("Tell me about every fill", "A quiet notification while the app is closed", symbol: "bell.badge.fill", isOn: $settings.notifyOnFill)
                        .onChange(of: settings.notifyOnFill) { _, on in if on { model.requestNotificationPermission() } }
                }

                section("YOUR PASSWORDS", index: 3) {
                    action("Import from Chrome or Safari", "Pick the exported .csv file", symbol: "square.and.arrow.down.fill") { importing = true }
                    Divider()
                    action("Export a backup", "A plain .csv — store it somewhere safe", symbol: "square.and.arrow.up.fill") {
                        Task {
                            if await model.authenticate("Export every password") { exportFile = ExportedCSV(text: model.exportCSV()) }
                        }
                    }
                    Divider()
                    action("Fill in apps and Safari", "Settings → General → AutoFill & Passwords → Safely", symbol: "rectangle.and.pencil.and.ellipsis") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                section("DANGER ZONE", index: 4) {
                    action("Erase the vault", "Deletes all \(vault.items.count) logins from this phone", symbol: "trash.fill", tint: Theme.rose) { confirmErase = true }
                    Divider()
                    action("Clear activity", "Forget the history shown on the Activity tab", symbol: "clock.arrow.circlepath", tint: Theme.rose) { activity.clear() }
                }

                Text("Safely 1.0 · Passwords are encrypted with AES-256 and the key never leaves this iPhone. The Safely Key only relays sealed messages.")
                    .font(.rounded(12, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.top, 6)
                    .staggered(5, shown: shown)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .onAppear { shown = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            withAnimation(Theme.spring) { importResult = model.importCSV(text) }
        }
        .fileExporter(isPresented: .init(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      document: exportFile, contentType: .commaSeparatedText, defaultFilename: "Safely backup") { _ in exportFile = nil }
        .alert("Import finished", isPresented: .init(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK") {}
        } message: {
            Text("\(importResult?.imported ?? 0) new, \(importResult?.updated ?? 0) updated, \(importResult?.skipped ?? 0) already there.\n\nNow delete the .csv file — it holds your passwords in plain text.")
        }
        .confirmationDialog("Erase every login?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase the vault", role: .destructive) {
                Task { if await model.authenticate("Erase the vault") { withAnimation { vault.deleteAll() } } }
            }
        } message: {
            Text("There is no copy anywhere else. This cannot be undone.")
        }
    }

    private func section<Content: View>(_ title: String, index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.rounded(12)).foregroundStyle(Theme.muted).padding(.leading, 6)
            VStack(alignment: .leading, spacing: 10) { content() }.card()
        }
        .staggered(index, shown: shown)
    }

    private func toggle(_ title: String, _ detail: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                icon(symbol, tint: Theme.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(16)).foregroundStyle(Theme.ink)
                    Text(detail).font(.rounded(13, .medium)).foregroundStyle(Theme.muted)
                }
            }
        }
        .tint(Theme.indigo)
    }

    private func action(_ title: String, _ detail: String, symbol: String, tint: Color = Theme.indigo, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                icon(symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(16)).foregroundStyle(tint == Theme.rose ? Theme.rose : Theme.ink)
                    Text(detail).font(.rounded(13, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted.opacity(0.5))
            }
        }
        .buttonStyle(PressableRowStyle())
    }

    private func icon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ExportedCSV: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var page = 0
    @State private var shown = false

    private let pages: [(String, String, String)] = [
        ("lock.shield.fill", "Your passwords,\nonly on your phone", "Not in Chrome. Not in a cloud. Encrypted on this iPhone and nowhere else."),
        ("key.horizontal.fill", "A key in your pocket", "Your Safely Key links this phone to your browser over Bluetooth. It carries sealed messages and can read none of them."),
        ("bolt.fill", "Walk up. It fills.\nWalk away. It's gone.", "Open a login page with your key nearby and the form fills itself. Leave, and the browser knows nothing."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: pages[index].0)
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 132, height: 132)
                            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
                            .shadow(color: Theme.indigo.opacity(0.35), radius: 26, y: 14)
                            .symbolEffect(.bounce, value: page)
                            .scaleEffect(page == index && shown ? 1 : 0.7)
                            .animation(.spring(response: 0.6, dampingFraction: 0.6), value: page)
                        Text(pages[index].1).font(.rounded(30, .bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        Text(pages[index].2).font(.rounded(16, .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 12)
                        Spacer()
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule().fill(index == page ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.muted.opacity(0.25)))
                        .frame(width: index == page ? 26 : 8, height: 8)
                }
            }
            .animation(Theme.spring, value: page)
            .padding(.bottom, 26)

            Button(page == pages.count - 1 ? "Get started" : "Continue") {
                if page < pages.count - 1 {
                    withAnimation(Theme.spring) { page += 1 }
                } else {
                    model.requestNotificationPermission()
                    withAnimation(.easeInOut(duration: 0.4)) { settings.onboarded = true }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
        .onAppear { shown = true }
    }
}
