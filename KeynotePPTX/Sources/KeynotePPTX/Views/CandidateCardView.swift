import SwiftUI

struct CandidateCardView: View {
    let candidate: CandidateMatch
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ThumbnailView(data: candidate.thumbnailData)
                    .frame(width: 160, height: 110)

                Text(candidate.keynoteFilename)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    KindBadge(kind: candidate.replacementKind, ext: candidate.fileExtension)
                    Spacer()
                    HashDistanceLabel(distance: candidate.aHashDistance)
                }

                Text(candidate.fileSizeBytes.formatted(.byteCount(style: .file)))
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .frame(width: 176)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.10)
                      : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: isSelected ? 2.5 : 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.keynoteFilename), \(candidate.replacementKind.rawValue.uppercased()), \(isSelected ? "selected" : "unselected")")
    }
}
