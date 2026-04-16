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
            .font(.callout.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 8) {
        KindBadge(kind: .svg, ext: "svg")
        KindBadge(kind: .pdf, ext: "pdf")
        KindBadge(kind: .raster, ext: "png")
        KindBadge(kind: .raster, ext: "jpg")
    }
    .padding()
}
