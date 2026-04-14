import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .welcome:
            WelcomeView()
        case .processing:
            ProcessingView()
        case .review:
            ReviewView()
        case .patchOptions:
            PatchOptionsView()
        case .patching:
            ProcessingView()
        case .done(let url):
            DoneView(outputURL: url)
        case .error(let msg):
            ErrorView(message: msg)
        }
    }
}
