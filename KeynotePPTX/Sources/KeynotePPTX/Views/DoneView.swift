import SwiftUI

struct DoneView: View {
    @Environment(AppState.self) private var appState
    let outputURL: URL
    @State private var saved = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: saved ? "checkmark.circle.fill" : "doc.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(saved ? .green : .accentColor)

            Text(saved ? "Saved!" : "Patching complete")
                .font(.title2.bold())

            Text(outputURL.lastPathComponent)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Save as…") {
                    Task { await saveFile() }
                }
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
            .font(.subheadline)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveFile() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = outputURL.lastPathComponent
        panel.allowedContentTypes = [.init(filenameExtension: "pptx")!]
        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
        guard response == .OK, let dest = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: outputURL, to: dest)
            saved = true
        } catch {
            // Show alert
            let alert = NSAlert()
            alert.messageText = "Save failed"
            alert.informativeText = error.localizedDescription
            await alert.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
        }
    }
}
