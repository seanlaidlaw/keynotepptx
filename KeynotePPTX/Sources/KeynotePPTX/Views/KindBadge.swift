import SwiftUI

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
