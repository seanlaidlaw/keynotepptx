import SwiftUI

struct CandidateCardView: View {
    let candidate: CandidateMatch
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(data: candidate.thumbnailData)
                .frame(width: 160, height: 120)

            Text(candidate.keynoteFilename)
                .font(.caption2.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                kindBadge
                Spacer()
                distanceLabel
            }

            Text(formattedSize)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(width: 176)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.10)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2.5 : 1)
        )
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.keynoteFilename), \(candidate.replacementKind.rawValue.uppercased())")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var kindBadge: some View {
        let (label, color): (String, Color) = switch candidate.replacementKind {
        case .svg: ("SVG", .green)
        case .pdf: ("PDF", .orange)
        case .raster: (candidate.fileExtension.uppercased(), .blue)
        }
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var distanceLabel: some View {
        Group {
            if candidate.aHashDistance < 64 {
                Text("Δ\(candidate.aHashDistance)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(hashDistanceColor(candidate.aHashDistance))
            }
        }
    }

    private var formattedSize: String {
        let kb = candidate.fileSizeBytes / 1024
        return kb > 1024 ? String(format: "%.1f MB", Double(kb) / 1024) : "\(kb) KB"
    }

    private func hashDistanceColor(_ d: Int) -> Color {
        switch d {
        case 0: return .green
        case 1...7: return .blue
        case 8...15: return .yellow
        default: return .red
        }
    }
}
