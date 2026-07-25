import SwiftUI
import GameCore

struct ToolsOverlayView: View {
    let timers: [GameTimer]
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Label("工具", systemImage: "wrench.and.screwdriver.fill")
                        .font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Label("关闭", systemImage: "xmark.circle.fill")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                TimerOverlayView(timers: timers)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .preferredColorScheme(.dark)
    }
}
