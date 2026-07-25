import SwiftUI
import GameCore

struct NotificationSettingsSection: View {
    let settings: SettingsStore
    @State private var service = NotificationService()
    @State private var expeditionEnabled: Bool
    @State private var dockingEnabled: Bool
    @State private var moraleEnabled: Bool
    @State private var akashiEnabled: Bool
    @State private var leadTime: Int

    init(settings: SettingsStore) {
        self.settings = settings
        _expeditionEnabled = State(initialValue: settings.expeditionNotificationsEnabled)
        _dockingEnabled = State(initialValue: settings.dockingNotificationsEnabled)
        _moraleEnabled = State(initialValue: settings.moraleNotificationsEnabled)
        _akashiEnabled = State(initialValue: settings.akashiNotificationsEnabled)
        _leadTime = State(initialValue: settings.notificationLeadTimeSeconds)
    }

    var body: some View {
        Section {
            authorizationControl
            Toggle("远征完成", isOn: $expeditionEnabled)
            Toggle("入渠完成", isOn: $dockingEnabled)
            Toggle("士气恢复", isOn: $moraleEnabled)
            Toggle("明石修理", isOn: $akashiEnabled)
            Stepper("提前 \(leadTime) 秒", value: $leadTime, in: 0...600, step: 10)
        } header: {
            Text("通知")
        } footer: {
            Text("通知由 iOS 调度，系统可能根据设备状态延迟送达。")
        }
        .task { await service.refreshAuthorizationState() }
        .onChange(of: expeditionEnabled) { _, value in update { $0.expeditionNotificationsEnabled = value } }
        .onChange(of: dockingEnabled) { _, value in update { $0.dockingNotificationsEnabled = value } }
        .onChange(of: moraleEnabled) { _, value in update { $0.moraleNotificationsEnabled = value } }
        .onChange(of: akashiEnabled) { _, value in update { $0.akashiNotificationsEnabled = value } }
        .onChange(of: leadTime) { _, value in update { $0.notificationLeadTimeSeconds = value } }
    }

    @ViewBuilder
    private var authorizationControl: some View {
        switch service.authorizationState {
        case .unknown:
            Button("启用系统通知") {
                Task { await service.requestAuthorization() }
            }
        case .allowed:
            Label("系统通知已启用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Button("前往系统设置启用通知") {
                service.openSystemSettings()
            }
        }
    }

    private func update(_ mutation: (inout SettingsStore) -> Void) {
        var store = settings
        mutation(&store)
    }
}
