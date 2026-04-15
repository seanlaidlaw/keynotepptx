import SwiftUI

struct PatchOptionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = appState.pendingSummary
        VStack(alignment: .leading, spacing: 24) {
            Text("Choose output mode")
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(s.total) total images", systemImage: "photo.stack")
                    Label("\(s.skipped) skipped", systemImage: "minus.circle")
                    Label("\(s.vectors) vector replacements (SVG/PDF)", systemImage: "lasso")
                    Label("\(s.rasters) raster replacements", systemImage: "photo")
                }
                .font(.body)
            }

            Text("Vector mode affects SVG/PDF assets. Rasters are always copied as-is.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(PatchMode.allCases, id: \.self) { mode in
                    ModeRow(
                        mode: mode,
                        isSelected: appState.patchMode == mode,
                        onSelect: { appState.patchMode = mode }
                    )
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Apply") {
                    dismiss()
                    Task { await appState.applyPatching() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(s.total - s.skipped == 0)
            }
        }
        .padding(32)
        .frame(minWidth: 480, maxWidth: 600)
    }
}

private struct ModeRow: View {
    let mode: PatchMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.body)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.headline)
                    Text(mode.detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                        lineWidth: 1.5
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
