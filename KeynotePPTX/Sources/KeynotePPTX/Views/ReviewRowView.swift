import SwiftUI
import AppKit

struct ReviewRowView: View {
    @Environment(AppState.self) private var appState
    let rowIndex: Int

    private var row: MappingRow { appState.mappingRows[rowIndex] }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left: floating "Low quality image" box — taller, self-contained card
            VStack(alignment: .leading, spacing: 0) {
                // Header strip — 50% more vertical padding than before (top: 9→14, bottom: 6→9)
                Label("Low quality image", systemImage: "photo")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(EdgeInsets(top: 14, leading: 10, bottom: 9, trailing: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor)

                VStack(alignment: .leading, spacing: 8) {
                    ThumbnailView(data: row.pptxFingerprint.thumbnailData)
                        .frame(width: 200, height: 145)

                    Text(row.pptxItem.filename)
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        QualityBadge(quality: row.quality)
                        if !row.pptxItem.slideNumbers.isEmpty {
                            Text("Slide \(row.pptxItem.slideNumbers.map(String.init).joined(separator: ", "))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 240)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            }

            // Right: candidates + actions — shorter cards, no divider
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
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 140, height: 100)
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
            .frame(maxWidth: .infinity)
        }
        .padding(16)
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
