import SwiftUI

enum GameMenuDestination: String, CaseIterable {
    case fleet = "舰队"
    case battle = "战斗"
    case quest = "任务"
    case tools = "工具"
    case settings = "设置"

    var symbol: String {
        switch self {
        case .fleet: "person.3.fill"
        case .battle: "scope"
        case .quest: "checklist"
        case .tools: "wrench.and.screwdriver.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct FloatingMenuView: View {
    let isMuted: Bool
    let onDestination: (GameMenuDestination) -> Void
    let onScreenshot: () -> Void
    let onToggleMute: () -> Void
    let onReload: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(GameMenuDestination.allCases, id: \.self) { destination in
                    menuButton(destination.rawValue, symbol: destination.symbol) {
                        onDestination(destination)
                    }
                }
            }
            Divider().overlay(.white.opacity(0.2))
            HStack(spacing: 10) {
                menuButton("截图", symbol: "camera.fill", action: onScreenshot)
                menuButton(isMuted ? "取消静音" : "静音",
                           symbol: isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill",
                           action: onToggleMute)
                menuButton("刷新", symbol: "arrow.clockwise", action: onReload)
                menuButton("退出", symbol: "rectangle.portrait.and.arrow.right",
                           role: .destructive, action: onExit)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private func menuButton(_ title: String,
                            symbol: String,
                            role: ButtonRole? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(minWidth: 48, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .accessibilityLabel(title)
    }
}
