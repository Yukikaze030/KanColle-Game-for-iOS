import GameCore
import SwiftUI
import WidgetKit

struct FleetTimerWidget: Widget {
    static let kind = "GameTimersWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FleetTimerProvider()) { entry in
            FleetTimerWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.12, blue: 0.20), Color(red: 0.10, green: 0.24, blue: 0.32)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("舰队计时")
        .description("显示最近的远征、入渠、士气与明石计时。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FleetTimerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FleetTimerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.projection.timers.isEmpty {
                emptyState
            } else if family == .systemSmall {
                timerRow(entry.projection.timers[0], prominent: true)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.projection.timers.prefix(4)) { timer in
                    timerRow(timer, prominent: false)
                }
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.cyan)
            Text("舰队计时")
                .font(.headline)
            Spacer(minLength: 4)
            if entry.projection.isStale {
                Text("可能已过期")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: entry.loadFailed ? "exclamationmark.icloud" : "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(entry.loadFailed ? .yellow : .cyan)
            Text(entry.loadFailed ? "暂时无法读取计时" : "进入游戏后同步")
                .font(.subheadline.weight(.semibold))
            Text("主 App 保存舰队状态后会自动显示。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func timerRow(_ timer: WidgetTimerItem, prominent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: timer.kind))
                .frame(width: 18)
                .foregroundStyle(color(for: timer.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(timer.title)
                    .font(prominent ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(1)
                Text(timer.detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(timer.completionDate, style: .timer)
                .font(prominent ? .title3.monospacedDigit().weight(.bold) : .caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private func symbol(for kind: GameTimer.Kind) -> String {
        switch kind {
        case .expedition: "ferry"
        case .docking: "wrench.and.screwdriver"
        case .morale: "face.smiling"
        case .akashi: "cross.case"
        }
    }

    private func color(for kind: GameTimer.Kind) -> Color {
        switch kind {
        case .expedition: .cyan
        case .docking: .orange
        case .morale: .green
        case .akashi: .pink
        }
    }
}

#Preview(as: .systemMedium) {
    FleetTimerWidget()
} timeline: {
    let now = Date()
    FleetTimerEntry(
        date: now,
        projection: WidgetProjection(
            timers: [
                WidgetTimerItem(
                    id: "expedition.2",
                    kind: .expedition,
                    title: "第二舰队远征",
                    detail: "海上护卫任务",
                    completionDate: now.addingTimeInterval(900)
                ),
                WidgetTimerItem(
                    id: "docking.1",
                    kind: .docking,
                    title: "第一入渠",
                    detail: "雪风",
                    completionDate: now.addingTimeInterval(2_100)
                )
            ],
            updatedAt: now,
            isStale: false
        ),
        loadFailed: false
    )
}
