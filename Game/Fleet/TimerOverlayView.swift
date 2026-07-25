import SwiftUI
import GameCore

struct TimerOverlayView: View {
    let timers: [GameTimer]

    init(timers: [GameTimer]) {
        self.timers = timers
    }

    private var activeTimers: [GameTimer] {
        timers
            .filter { !$0.isCancelled }
            .sorted {
                if $0.completionDate != $1.completionDate { return $0.completionDate < $1.completionDate }
                return $0.id < $1.id
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("计时器", systemImage: "timer")
                .font(.headline)

            if activeTimers.isEmpty {
                Label("暂无远征、入渠、士气或明石计时", systemImage: "clock.badge.questionmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LazyVStack(spacing: 6) {
                        ForEach(activeTimers) { timer in
                            timerRow(timer, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private func timerRow(_ timer: GameTimer, now: Date) -> some View {
        let remaining = max(0, timer.completionDate.timeIntervalSince(now))
        let completed = timer.completionDate <= now

        return HStack(spacing: 10) {
            Image(systemName: symbol(for: timer.kind, completed: completed))
                .foregroundStyle(completed ? Color.green : tint(for: timer.kind))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(timer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(completed ? "已完成" : durationText(remaining))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(completed ? .green : .primary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(timer.title)，\(timer.detail)，\(completed ? "已完成" : "剩余 \(durationText(remaining))")")
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    private func symbol(for kind: GameTimer.Kind, completed: Bool) -> String {
        if completed { return "checkmark.circle.fill" }
        return switch kind {
        case .expedition: "paperplane.fill"
        case .docking: "wrench.and.screwdriver.fill"
        case .morale: "face.smiling.fill"
        case .akashi: "cross.case.fill"
        }
    }

    private func tint(for kind: GameTimer.Kind) -> Color {
        switch kind {
        case .expedition: .cyan
        case .docking: .blue
        case .morale: .yellow
        case .akashi: .mint
        }
    }
}
