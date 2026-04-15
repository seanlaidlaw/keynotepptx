import SwiftUI

struct QualityBadge: View {
    let quality: MatchQuality

    var body: some View {
        Text(quality.label)
            .font(.callout.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(quality.color.opacity(0.15))
            .foregroundStyle(quality.color)
            .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 8) {
        QualityBadge(quality: .xmlExact)
        QualityBadge(quality: .exact)
        QualityBadge(quality: .strong)
        QualityBadge(quality: .review)
        QualityBadge(quality: .poor)
        QualityBadge(quality: .noMatch)
    }
    .padding()
}
