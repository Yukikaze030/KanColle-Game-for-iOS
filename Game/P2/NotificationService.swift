import UIKit
import UserNotifications
import Observation
import GameCore

@MainActor
@Observable
final class NotificationService {
    enum AuthorizationState: Equatable {
        case unknown
        case allowed
        case denied
    }

    private(set) var authorizationState: AuthorizationState = .unknown
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func refreshAuthorizationState() async {
        let settings = await center.notificationSettings()
        authorizationState = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    /// Called only from an explicit user action; cold start never prompts.
    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // The subsequent settings query remains the source of truth.
        }
        await refreshAuthorizationState()
    }

    func reconcile(
        timers: [GameTimer],
        plannerSettings: NotificationPlanner.Settings
    ) async {
        await refreshAuthorizationState()
        let pending = await center.pendingNotificationRequests()
        let p2Pending = pending.compactMap { request -> NotificationPlanner.PendingRequest? in
            guard request.identifier.hasPrefix(NotificationPlanner.identifierPrefix),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let fireDate = trigger.nextTriggerDate() else { return nil }
            return .init(
                id: request.identifier,
                title: request.content.title,
                body: request.content.body,
                fireDate: fireDate
            )
        }
        let foreignCount = pending.count - pending.filter {
            $0.identifier.hasPrefix(NotificationPlanner.identifierPrefix)
        }.count
        var plan = NotificationPlanner().plan(
            timers: timers,
            pendingRequests: p2Pending,
            foreignPendingCount: foreignCount,
            settings: plannerSettings,
            now: Date()
        )

        // Without authorization we still remove obsolete requests but never
        // create new ones or trigger an unsolicited permission prompt.
        if authorizationState != .allowed {
            plan = .init(toAdd: [], toRemove: plan.toRemove)
        }
        if !plan.toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: plan.toRemove)
        }
        for request in plan.toAdd {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: request.fireDate
            )
            components.calendar = calendar
            components.timeZone = calendar.timeZone

            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default
            content.userInfo = ["destination": "fleet", "timerID": request.timerID]
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
            do {
                try await center.add(
                    UNNotificationRequest(
                        identifier: request.id,
                        content: content,
                        trigger: trigger
                    )
                )
            } catch {
                // A later successful snapshot retries reconciliation.
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
