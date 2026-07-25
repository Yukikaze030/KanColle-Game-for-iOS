import UIKit

final class GameAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.supportedOrientations
    }
}

@MainActor
enum OrientationLock {
    static var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func lockLandscape() {
        supportedOrientations = .landscape
        request(.landscape)
    }

    static func releaseLandscape(preferPortrait: Bool = true) {
        supportedOrientations = .allButUpsideDown
        if preferPortrait {
            request(.portrait)
        } else {
            refreshSupportedOrientations()
        }
    }

    private static func request(_ orientations: UIInterfaceOrientationMask) {
        refreshSupportedOrientations()
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            DiagnosticsStore.shared.recordNavigationError(
                "屏幕方向切换失败：\(error.localizedDescription)"
            )
        }
    }

    private static func refreshSupportedOrientations() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
            .forEach { $0.setNeedsUpdateOfSupportedInterfaceOrientations() }
    }
}
