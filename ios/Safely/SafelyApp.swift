import SwiftUI

@main
struct SafelyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.vault)
                .environmentObject(model.activity)
                .environmentObject(model.settings)
                .preferredColorScheme(.light)
                .tint(Theme.primary)
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}
