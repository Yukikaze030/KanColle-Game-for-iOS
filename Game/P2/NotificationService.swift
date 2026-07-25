import UIKit
import UserNotifications
import Observation

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

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
