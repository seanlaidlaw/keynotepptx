import SwiftUI

struct ProcessingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            ProgressView(value: appState.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 480)

            Text(appState.progressDetail)
                .font(.body)
                .foregroundStyle(.secondary)
                .animation(.default, value: appState.progressDetail)

            Text(appState.progress, format: .percent.precision(.fractionLength(0)))
                .font(.largeTitle.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
