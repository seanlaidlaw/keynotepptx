import SwiftUI

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
