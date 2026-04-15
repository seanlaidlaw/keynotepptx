import SwiftUI

struct ReviewOnboardingView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("How to review matches")
                .font(.title2.bold())

            Text("The algorithm has already selected the most likely high-quality replacement from your Keynote file for each low-quality image in the PowerPoint. Your job is to verify the pre-selection looks correct — or pick a better option.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            // Mini diagram
            HStack(alignment: .top, spacing: 16) {
                // Left: blurry PPTX image
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.08))
                            .frame(width: 100, height: 70)
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(Color.accentColor.opacity(0.5))
                            .blur(radius: 1.5)
                    }
                    Text("Low quality\n(from PPTX)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Image(systemName: "arrow.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)

                // Right: three candidate cards
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(i == 0 ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                                    .frame(width: 72, height: 52)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(i == 0 ? Color.accentColor : Color.clear, lineWidth: 2)
                                    }
                                Image(systemName: "photo.fill")
                                    .font(i == 0 ? .title2 : .title3)
                                    .foregroundStyle(i == 0 ? Color.accentColor : Color.secondary.opacity(0.4))
                            }
                            Text(i == 0 ? "Best match" : "Alt \(i)")
                                .font(.callout)
                                .foregroundStyle(i == 0 ? Color.accentColor : .secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                OnboardingBullet(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: "The highlighted card is the algorithm's best guess — confirm it if it looks right."
                )
                OnboardingBullet(
                    icon: "hand.tap.fill",
                    color: .accentColor,
                    text: "Tap a different card to choose an alternative from the Keynote file."
                )
                OnboardingBullet(
                    icon: "folder.fill",
                    color: .secondary,
                    text: "Use Browse… to pick any file from your Mac, or Skip to leave an image unchanged."
                )
            }
            .frame(maxWidth: 440, alignment: .leading)

            Button("Start reviewing") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(minWidth: 520)
    }
}

private struct OnboardingBullet: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}
