import AuthenticationServices
import LocalAuthentication
import SafelyCore
import SwiftUI

/// iOS Password AutoFill: fills Shhlock logins into apps and Safari on the phone itself.
/// Enable under Settings → General → AutoFill & Passwords → Shhlock.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var host: UIHostingController<AutoFillList>?

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        show(for: serviceIdentifiers)
    }

    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        show(for: [credentialIdentity.serviceIdentifier])
    }

    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        // Every fill needs Face ID, so there is never a silent path.
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    private func show(for services: [ASCredentialServiceIdentifier]) {
        let list = AutoFillList(
            services: services.map(\.identifier),
            choose: { [weak self] item in
                self?.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: item.username, password: item.password))
            },
            cancel: { [weak self] in
                self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
            }
        )
        let controller = UIHostingController(rootView: list)
        controller.overrideUserInterfaceStyle = .light
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        host = controller
    }
}

struct AutoFillList: View {
    let services: [String]
    let choose: (VaultItem) -> Void
    let cancel: () -> Void

    @StateObject private var vault = VaultStore(readOnly: true)
    @State private var unlocked = false
    @State private var query = ""
    @State private var shown = false

    private var suggested: [VaultItem] {
        var seen = Set<UUID>()
        return services.flatMap { vault.matches(for: $0) }.filter { seen.insert($0.id).inserted }
    }

    private var others: [VaultItem] {
        let skip = Set(suggested.map(\.id))
        return vault.items.filter { item in
            !skip.contains(item.id) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
                || item.username.localizedCaseInsensitiveContains(query) || item.url.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground()
            if unlocked {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Shhlock").font(.rounded(28, .bold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Button("Cancel", action: cancel).font(.rounded(16)).foregroundStyle(Theme.primary)
                        }
                        .padding(.top, 18)

                        if !suggested.isEmpty {
                            Text("FOR THIS APP").font(.rounded(12)).foregroundStyle(Theme.muted)
                            ForEach(Array(suggested.enumerated()), id: \.element.id) { index, item in
                                row(item).staggered(index, shown: shown)
                            }
                        }

                        TextField("Search all logins", text: $query)
                            .font(.rounded(16, .medium))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        ForEach(Array(others.enumerated()), id: \.element.id) { index, item in
                            row(item).staggered(index + suggested.count, shown: shown)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
                .onAppear { shown = true }
            } else {
                VStack(spacing: 18) {
                    LockTile(size: 96)
                    Text("Unlock to fill").font(.rounded(20, .bold)).foregroundStyle(Theme.ink)
                    Button("Use Face ID") { authenticate() }.buttonStyle(PrimaryButtonStyle()).frame(width: 220)
                    Button("Cancel", action: cancel).font(.rounded(15)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onAppear { authenticate() }
    }

    private func row(_ item: VaultItem) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 14) {
                Avatar(text: item.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.rounded(16)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(item.username).font(.rounded(13, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.left.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.gradient)
            }
            .card(padding: 13)
        }
        .buttonStyle(.plain)
    }

    private func authenticate() {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            unlocked = true
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Fill a login from Shhlock") { ok, _ in
            DispatchQueue.main.async {
                if ok { withAnimation(Theme.spring) { unlocked = true } }
            }
        }
    }
}
