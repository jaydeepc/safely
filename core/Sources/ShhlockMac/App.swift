// Shhlock for Mac — a menu-bar app. No browser extension: it fills login forms in any app
// through Accessibility, with logins that live on your Shhlock Key.

import AppKit
import SafelyCore
import SwiftUI

enum MacTheme {
    static let accent = Color(red: 0.16, green: 0.42, blue: 0.96)   // calm blue
    static let ink = Color(red: 0.11, green: 0.13, blue: 0.18)
    static let good = Color(red: 0.13, green: 0.68, blue: 0.42)
    static let warn = Color(red: 0.93, green: 0.55, blue: 0.10)

    static func avatar(for text: String) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.16, green: 0.42, blue: 0.96), Color(red: 0.36, green: 0.66, blue: 1.0)],
            [Color(red: 0.42, green: 0.32, blue: 0.94), Color(red: 0.66, green: 0.52, blue: 1.0)],
            [Color(red: 0.05, green: 0.60, blue: 0.62), Color(red: 0.24, green: 0.80, blue: 0.72)],
            [Color(red: 0.87, green: 0.36, blue: 0.30), Color(red: 0.98, green: 0.56, blue: 0.36)],
            [Color(red: 0.13, green: 0.68, blue: 0.42), Color(red: 0.42, green: 0.84, blue: 0.48)],
        ]
        let seed = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return LinearGradient(colors: palettes[seed % palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

@main
struct ShhlockMacApp: App {
    @StateObject private var model = MacModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: menuSymbol)
        }

        Window("Shhlock", id: "setup") {
            SetupView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 520)
    }

    private var menuSymbol: String {
        if !model.link.keyConnected { return "lock.slash" }
        return model.paired && model.unlocked ? "lock.open.fill" : "lock.fill"
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if let last = model.lastFill { Text("Last filled: \(last)") }
        Divider()
        Button("Fill in the focused field…") { model.fillNow() }
            .disabled(!(model.paired && model.unlocked && model.link.keyConnected))
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Toggle("Fill automatically when one login matches", isOn: $model.autofill)
        Toggle("Sign in after filling", isOn: $model.autoSubmit)
        Divider()
        Button(model.paired ? "Shhlock settings…" : "Set up Shhlock…") {
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Shhlock") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        if !model.accessibilityGranted { return "Needs Accessibility permission" }
        switch model.link.bluetooth {
        case .off: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth not allowed for Shhlock"
        default: break
        }
        if !model.link.keyConnected { return "Looking for your Shhlock Key…" }
        if !model.paired { return "Key found — not paired with this Mac yet" }
        if !model.unlocked { return "Key connected — vault locked" }
        return "Ready · \(model.vaultCount ?? 0) logins on your key"
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: MacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.system(size: 26)).foregroundStyle(MacTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shhlock for Mac").font(.system(size: 20, weight: .semibold))
                    Text("Fills logins from your key in any browser or app.").foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    step(done: model.accessibilityGranted, title: "Allow Accessibility",
                         detail: "Lets Shhlock see the login field you clicked and fill it. System Settings → Privacy & Security → Accessibility.") {
                        if !model.accessibilityGranted { Button("Open System Settings") { model.requestAccessibility() } }
                    }
                    Divider()
                    step(done: model.link.keyConnected, title: "Shhlock Key nearby",
                         detail: model.link.keyConnected ? "Connected\(model.link.rssi.map { " · signal \($0) dBm" } ?? "")" : "Power the key and keep Bluetooth on. It connects on its own.") { EmptyView() }
                    Divider()
                    step(done: model.paired, title: "Paired with this Mac", detail: pairingDetail) {
                        pairingControls
                    }
                }
                .padding(6)
            }

            if model.paired {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Fill automatically when exactly one login matches", isOn: $model.autofill)
                        Toggle("Sign in after filling (presses Return)", isOn: $model.autoSubmit)
                        Text("With several matches, or when autofill is off, a small list appears under the field. You can also press ⌘⇧F.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }

            DisclosureGroup("Activity log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.suffix(40).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 440)
    }

    private var pairingDetail: String {
        switch model.pairingUI {
        case .idle: return model.paired ? "Your logins stay on the key; this Mac only borrows them to fill." : "Open Shhlock on your phone first — it approves new computers."
        case .waiting: return "Waiting for the key…"
        case .compare: return "Your phone shows a code. Confirm there, and here, if it is the same."
        case .paired: return "Paired. Your logins are ready."
        case .failed(let reason): return reason
        }
    }

    @ViewBuilder private var pairingControls: some View {
        switch model.pairingUI {
        case .compare(let code):
            HStack(spacing: 8) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit)).font(.system(size: 22, weight: .bold, design: .monospaced))
                        .frame(width: 32, height: 40)
                        .background(MacTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer()
                Button("Cancel") { model.cancelPairing() }
                Button("Same code") { model.confirmPairing() }.buttonStyle(.borderedProminent).tint(MacTheme.accent)
            }
        case .waiting:
            ProgressView().controlSize(.small)
        default:
            if model.paired {
                Button("Unpair this Mac", role: .destructive) { model.unpair() }
            } else {
                Button("Pair with my key") { model.startPairing() }
                    .buttonStyle(.borderedProminent).tint(MacTheme.accent)
                    .disabled(!model.link.keyConnected)
            }
        }
    }

    private func step<Content: View>(done: Bool, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? MacTheme.good : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}
