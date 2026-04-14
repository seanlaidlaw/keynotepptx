import SwiftUI

struct CandidateCardView: View {
    let candidate: CandidateMatch
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ThumbnailView(data: candidate.thumbnailData)
                    .frame(width: 160, height: 120)

                Text(candidate.keynoteFilename)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    KindBadge(kind: candidate.replacementKind, ext: candidate.fileExtension)
                    Spacer()
                    HashDistanceLabel(distance: candidate.aHashDistance)
                }

                Text(candidate.fileSizeBytes.formatted(.byteCount(style: .file)))
                    .font(.caption)
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

struct KindBadge: View {
    let kind: ReplacementKind
    let ext: String

    private var label: String {
        switch kind {
        case .svg: "SVG"
        case .pdf: "PDF"
        case .raster: ext.uppercased()
        }
    }

    private var color: Color {
        switch kind {
        case .svg: .green
        case .pdf: .orange
        case .raster: .blue
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct HashDistanceLabel: View {
    let distance: Int

    var body: some View {
        if distance < 64 {
            Text("Δ\(distance)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch distance {
        case 0:    return .green
        case 1...7: return .blue
        case 8...15: return .yellow
        default:   return .red
        }
    }
}
