import SwiftUI

struct HashDistanceLabel: View {
    let distance: Int

    var body: some View {
        if distance < 64 {
            Text("Δ\(distance)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch distance {
        case 0:      return .green
        case 1...7:  return .blue
        case 8...15: return .yellow
        default:     return .red
        }
    }
}
