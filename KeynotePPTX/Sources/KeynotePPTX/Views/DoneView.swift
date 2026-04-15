import SwiftUI
import UniformTypeIdentifiers

struct DoneView: View {
    @Environment(AppState.self) private var appState
    let outputURL: URL
    @State private var showingExporter = false
    @State private var saved = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: saved ? "checkmark.circle.fill" : "arrow.down.doc.fill")
                .font(.system(size: 64))
                .foregroundStyle(saved ? .green : .accentColor)

            Text(saved ? "Saved!" : "Patching complete")
                .font(.title2.bold())

            Text(outputURL.lastPathComponent)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Save as…") { showingExporter = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button("Start over") {
                appState.pptxURL = nil
                appState.keynoteURL = nil
                appState.mappingRows = []
                appState.phase = .welcome
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.body)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileExporter(
            isPresented: $showingExporter,
            document: PPTXFile(url: outputURL),
            contentType: .pptx,
            defaultFilename: outputURL.lastPathComponent
        ) { result in
            switch result {
            case .success:
                saved = true
            case .failure(let error):
                saveError = error.localizedDescription
            }
        }
        .alert(
            "Save failed",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
            presenting: saveError
        ) { _ in
            Button("OK") { saveError = nil }
        } message: { msg in
            Text(msg)
        }
    }
}

// MARK: - FileDocument wrapper for export

private struct PPTXFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pptx] }
    let sourceURL: URL

    init(url: URL) { sourceURL = url }

    init(configuration: ReadConfiguration) throws {
        sourceURL = URL(fileURLWithPath: "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: [])
    }
}

private extension UTType {
    static let pptx = UTType(filenameExtension: "pptx") ?? .data
}
