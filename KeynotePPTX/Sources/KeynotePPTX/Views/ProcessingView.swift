import SwiftUI

struct ProcessingView: View {
    @Environment(AppState.self) private var appState
    var title: String = "Processing…"

    var body: some View {
        VStack(spacing: 24) {
            ProgressView(value: appState.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 480)

            Text(appState.progressDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .animation(.default, value: appState.progressDetail)

            Text(String(format: "%.0f%%", appState.progress * 100))
                .font(.largeTitle.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
