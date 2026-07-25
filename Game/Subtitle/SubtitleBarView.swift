import SwiftUI
import GameCore

struct SubtitleBarView: View {
    let match: SubtitleMatch?
    let fontSize: Int

    @State private var displayedText = ""
    @State private var isVisible = false

    var body: some View {
        Text(displayedText)
            .font(.system(size: CGFloat(max(12, min(fontSize, 48))),
                          weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.62))
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isVisible)
            .allowsHitTesting(false)
            .task(id: match) {
                isVisible = false
                guard let match else { return }
                let totalDelay = max(
                    0,
                    Int64(match.delayMilliseconds) + match.extraDelayMilliseconds
                )
                if totalDelay > 0 {
                    try? await Task.sleep(
                        for: .milliseconds(Double(totalDelay))
                    )
                }
                guard !Task.isCancelled else { return }
                displayedText = match.text
                isVisible = true
                try? await Task.sleep(
                    for: .milliseconds(Double(max(500, match.durationMilliseconds)))
                )
                guard !Task.isCancelled else { return }
                isVisible = false
            }
    }
}
