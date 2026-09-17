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
                Text("Settings").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink).staggered(0, shown: shown)

                section("SECURITY", index: 2) {
                    toggle("Lock with Face ID", "Ask when the app opens and after 45 s away", symbol: "faceid", tint: Theme.primary, isOn: $settings.appLock)
                }

                section("YOUR PASSWORDS", index: 3) {
                    action("Import from Chrome or Safari", "Pick the exported .csv file", symbol: "square.and.arrow.down.fill", tint: Theme.sky) { importing = true }
                    Divider()
                    action("Export a backup", "A plain .csv — store it somewhere safe", symbol: "square.and.arrow.up.fill", tint: Theme.green) {
                        Task {
                            if await model.authenticate("Export every password") { exportFile = ExportedCSV(text: model.exportCSV()) }
                        }
                    }
                    Divider()
                    action("Fill in apps and Safari", "Settings → General → AutoFill & Passwords → Shhlock", symbol: "rectangle.and.pencil.and.ellipsis", tint: Theme.teal) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                section("DANGER ZONE", index: 4) {
                    action("Erase the vault", "Deletes all \(vault.items.count) logins from this phone", symbol: "trash.fill", tint: Theme.rose) { confirmErase = true }
                    Divider()
                    action("Clear activity", "Forget the history shown on the Activity tab", symbol: "clock.arrow.circlepath", tint: Theme.rose) { activity.clear() }
                }

                Text("Shhlock 2.0 · Your vault is AES-256 encrypted on this iPhone and on the key. The key only opens for devices you paired.")
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
                      document: exportFile, contentType: .commaSeparatedText, defaultFilename: "Shhlock backup") { _ in exportFile = nil }
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

    private func toggle(_ title: String, _ detail: String, symbol: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                icon(symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(16)).foregroundStyle(Theme.ink)
                    Text(detail).font(.rounded(13, .medium)).foregroundStyle(Theme.muted)
                }
            }
        }
        .tint(tint)
    }

    private func action(_ title: String, _ detail: String, symbol: String, tint: Color = Theme.primary, perform: @escaping () -> Void) -> some View {
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
        ("key.horizontal", "Your passwords,\non a key you carry", "Encrypted on the Shhlock Key in your pocket and on this iPhone. Not in a browser, not in a cloud."),
        ("laptopcomputer.and.iphone", "Walk up to any computer", "Shhlock for Mac fills logins in any browser while the key is near. No phone needed — this app just manages the vault."),
        ("checkmark.shield", "You decide who may use it", "New computers need your approval here, with a code you compare. Lose the key, and it is unreadable without a paired device."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 22) {
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Theme.navyGradient).frame(width: 150, height: 150)
                                .shadow(color: Theme.navy.opacity(0.25), radius: 24, y: 12)
                            if index == 0 { LockGlyph(size: 96) } else {
                                Image(systemName: pages[index].0).font(.system(size: 60, weight: .medium)).foregroundStyle(.white)
                            }
                        }
                        .scaleEffect(page == index && shown ? 1 : 0.8)
                            .animation(.spring(response: 0.6, dampingFraction: 0.6), value: page)
                        Text(pages[index].1).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        Text(pages[index].2).font(.system(size: 16)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 12)
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
                    Capsule().fill(index == page ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.line))
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
