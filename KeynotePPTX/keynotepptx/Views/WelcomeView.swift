import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("KeynotePPTX")
                    .font(.largeTitle.bold())
                Text("Restore high-quality Keynote assets into PPTX exports")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            HStack(spacing: 24) {
                DropZone(
                    label: "PowerPoint file",
                    icon: "doc.richtext",
                    filename: appState.pptxURL?.lastPathComponent,
                    accepted: ["pptx"],
                    onDrop: { appState.pptxURL = $0 },
                    onBrowse: { Task { appState.pptxURL = await pickFile(types: [.pptx]) } }
                )

                DropZone(
                    label: "Keynote file",
                    icon: "doc.text",
                    filename: appState.keynoteURL?.lastPathComponent,
                    accepted: ["key"],
                    onDrop: { appState.keynoteURL = $0 },
                    onBrowse: { Task { appState.keynoteURL = await pickFile(types: [.keynote]) } }
                )
            }
            .frame(maxWidth: 720)

            Button("Process") {
                Task { await appState.startProcessing() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(width: 200)
            .disabled(appState.pptxURL == nil || appState.keynoteURL == nil)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickFile(types: [UTType]) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = types
            panel.allowsMultipleSelection = false
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

// MARK: - UTType constants

private extension UTType {
    static let pptx = UTType(filenameExtension: "pptx") ?? .data
    static let keynote = UTType(filenameExtension: "key") ?? .package
}

// MARK: - Drop zone component

private struct DropZone: View {
    let label: String
    let icon: String
    let filename: String?
    let accepted: [String]
    let onDrop: (URL) -> Void
    let onBrowse: () -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: filename != nil ? "checkmark.circle.fill" : icon)
                .font(.system(.largeTitle))
                .foregroundStyle(filename != nil ? Color.green : Color.secondary)

            Text(label)
                .font(.headline)

            if let name = filename {
                Text(name)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Drop here or browse")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }

            Button("Browse…", action: onBrowse)
                .controlSize(.small)
        }
        .frame(width: 280, height: 180)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted
                      ? Color.accentColor.opacity(0.1)
                      : Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [6, 4])
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let typeID = UTType.fileURL.identifier
        let cb = onDrop
        let exts = accepted
        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
            guard let data = item as? Data else { return }
            let urlStr = String(data: data, encoding: .utf8) ?? ""
            guard let url = URL(string: urlStr),
                  exts.contains(url.pathExtension.lowercased()) else { return }
            Task { @MainActor in cb(url) }
        }
        return true
    }
}

#Preview {
    WelcomeView()
        .environment(AppState())
}
