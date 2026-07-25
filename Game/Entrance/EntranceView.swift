import SwiftUI
import GameCore

struct EntranceView: View {
    let onStart: (BrowserConstants.Connector, KeychainStore.Credentials?) -> Void
    let onOpenSettings: () -> Void

    private let keychain: KeychainStore
    private let settings: SettingsStore

    @State private var connector: BrowserConstants.Connector
    @State private var accountID = ""
    @State private var password = ""
    @State private var saveCredentials = false
    @State private var silentStart: Bool
    @State private var hasSavedCredentials = false
    @State private var errorMessage: String?

    init(settings: SettingsStore = SettingsStore(),
         keychain: KeychainStore = KeychainStore(),
         onStart: @escaping (
            BrowserConstants.Connector,
            KeychainStore.Credentials?
         ) -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.settings = settings
        self.keychain = keychain
        self.onStart = onStart
        self.onOpenSettings = onOpenSettings
        _connector = State(initialValue: settings.connector)
        _silentStart = State(initialValue: settings.silentStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接方式") {
                    Picker("连接器", selection: $connector) {
                        ForEach(BrowserConstants.Connector.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("账号", text: $accountID)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                    Toggle("保存到钥匙串", isOn: $saveCredentials)
                    if hasSavedCredentials {
                        Label("已保存", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("登录信息")
                } footer: {
                    Text("凭证仅保存在系统钥匙串，不会写入 UserDefaults 或普通文件。")
                }

                Section("启动选项") {
                    Toggle("静音启动", isOn: $silentStart)
                }

                Section {
                    Button(action: startGame) {
                        Label("开始游戏", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("舰队浏览器")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
        }
        .task(id: connector) { loadCredentials() }
        .alert("无法继续", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func loadCredentials() {
        do {
            if let credentials = try keychain.load(for: connector) {
                accountID = credentials.id
                password = credentials.password
                saveCredentials = true
                hasSavedCredentials = true
            } else {
                accountID = ""
                password = ""
                saveCredentials = false
                hasSavedCredentials = false
            }
        } catch {
            errorMessage = error.localizedDescription
            hasSavedCredentials = false
        }
    }

    private func startGame() {
        do {
            let sessionCredentials: KeychainStore.Credentials?
            if accountID.isEmpty && password.isEmpty {
                sessionCredentials = nil
            } else {
                guard !accountID.isEmpty, !password.isEmpty else {
                    throw KeychainStore.StoreError.invalidCredentials
                }
                sessionCredentials = .init(id: accountID, password: password)
            }

            if saveCredentials {
                guard let sessionCredentials else {
                    throw KeychainStore.StoreError.invalidCredentials
                }
                try keychain.save(sessionCredentials, for: connector)
                hasSavedCredentials = true
            } else {
                try keychain.delete(for: connector)
                hasSavedCredentials = false
            }
            var updatedSettings = settings
            updatedSettings.connector = connector
            updatedSettings.silentStart = silentStart
            // Persistence and this launch are deliberately independent: even
            // when the user declines Keychain storage, the credentials remain
            // available in memory until the game session exits.
            onStart(connector, sessionCredentials)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
