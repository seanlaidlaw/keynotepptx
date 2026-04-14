import SwiftUI

@main
struct KeynotePPTXApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

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
            ProcessingView(title: "Applying replacements…")
        case .done(let url):
            DoneView(outputURL: url)
        case .error(let msg):
            ErrorView(message: msg)
        }
    }
}

struct ErrorView: View {
    @Environment(AppState.self) private var appState
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("An error occurred")
                .font(.title2.bold())
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Start over") {
                appState.phase = .welcome
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
