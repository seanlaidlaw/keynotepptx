import SwiftUI
import AppKit

struct ReviewRowView: View {
    @Environment(AppState.self) private var appState
    let rowIndex: Int

    private var row: MappingRow { appState.mappingRows[rowIndex] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left panel: PPTX image info (fixed width)
            VStack(alignment: .leading, spacing: 8) {
                ThumbnailView(data: row.pptxFingerprint.thumbnailData)
                    .frame(width: 200, height: 140)

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
            .frame(width: 240)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

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

// MARK: - Quality badge

struct QualityBadge: View {
    let quality: MatchQuality

    var body: some View {
        Text(quality.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(quality.color.opacity(0.15))
            .foregroundStyle(quality.color)
            .clipShape(Capsule())
    }
}

// MARK: - Thumbnail helper

struct ThumbnailView: View {
    let data: Data?

    var nsImage: NSImage? {
        data.flatMap { NSImage(data: $0) }
    }

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
