import SwiftUI
import AppKit

struct ThumbnailView: View {
    let data: Data?

    var nsImage: NSImage? {
        data.flatMap { NSImage(data: $0) }
    }

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    VStack(spacing: 20) {
        ThumbnailView(data: nil)
            .frame(width: 200, height: 150)
        ThumbnailView(data: Data())
            .frame(width: 200, height: 150)
    }
    .padding()
}
