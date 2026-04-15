import SwiftUI
import AppKit

struct ReviewRowView: View {
    @Environment(AppState.self) private var appState
    let rowIndex: Int

    private var row: MappingRow { appState.mappingRows[rowIndex] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left panel: PPTX source image (fixed width, visually distinct)
            VStack(alignment: .leading, spacing: 0) {
                // Header strip
                Label("Low quality image", systemImage: "photo")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(EdgeInsets(top: 9, leading: 10, bottom: 6, trailing: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor)

                VStack(alignment: .leading, spacing: 8) {
                    ThumbnailView(data: row.pptxFingerprint.thumbnailData)
                        .frame(width: 200, height: 110)

                    Text(row.pptxItem.filename)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        QualityBadge(quality: row.quality)
                        if !row.pptxItem.slideNumbers.isEmpty {
                            Text("Slide \(row.pptxItem.slideNumbers.map(String.init).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 240)
            .background(Color.accentColor.opacity(0.06))

            Divider()

            // Right panel: candidates + actions
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row.topCandidates) { candidate in
                        CandidateCardView(
                            candidate: candidate,
                            isSelected: row.selectedChoice == .keynoteFile(filename: candidate.keynoteFilename),
                            onSelect: {
                                appState.mappingRows[rowIndex].selectedChoice =
                                    .keynoteFile(filename: candidate.keynoteFilename)
                            }
                        )
                    }

                    if row.topCandidates.isEmpty {
                        Text("No candidates found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 160, height: 140)
                    }

                    VStack(spacing: 8) {
                        // Skip button
                        Button {
                            appState.mappingRows[rowIndex].selectedChoice = .skip
                        } label: {
                            Label("Skip", systemImage: "minus.circle")
                                .frame(width: 90)
                        }
                        .buttonStyle(.bordered)
                        .tint(row.selectedChoice == .skip ? .red : nil)

                        // Browse button
                        Button {
                            Task {
                                if let url = await pickFile() {
                                    appState.mappingRows[rowIndex].selectedChoice = .customFile(url: url)
                                }
                            }
                        } label: {
                            Label("Browse…", systemImage: "folder")
                                .frame(width: 90)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
                .padding(12)
            }
        }
        .frame(height: 200)
    }

    private func pickFile() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
