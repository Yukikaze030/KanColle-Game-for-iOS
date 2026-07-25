import SwiftUI
import UIKit

struct CertificateInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = CertificateTrustModel()

    var body: some View {
        List {
            statusSection
            exportSection
            installationStepsSection
            retrySection
        }
        .navigationTitle("安装游戏加速证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .task {
            guard model.state == .idle else { return }
            await model.prepareAndCheckTrust()
        }
        .onDisappear {
            model.cleanupTemporaryFile()
        }
    }

    private var statusSection: some View {
        Section("证书状态") {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var exportSection: some View {
        Section {
            if let certificateURL = model.certificateURL {
                ShareLink(
                    item: certificateURL,
                    preview: SharePreview("舰 C 游戏加速根证书")
                ) {
                    Label("分享或打开证书", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    Task { await model.prepareAndCheckTrust() }
                } label: {
                    Label("生成证书", systemImage: "key.fill")
                }
                .disabled(model.isBusy)
            }

            Button {
                openSystemSettings()
            } label: {
                Label("打开系统设置", systemImage: "gear")
            }
        } header: {
            Text("导出")
        } footer: {
            Text("根证书只用于解密舰 C 游戏服务器流量。根私钥保存在本机 Keychain，不会随 .cer 文件导出。")
        }
    }

    private var installationStepsSection: some View {
        Section("安装与完全信任") {
            installationStep(1, "点击“分享或打开证书”，在分享菜单中选择打开或存储证书。")
            installationStep(2, "回到“设置”，进入“已下载描述文件”，完成证书描述文件安装。")
            installationStep(3, "进入“通用”→“关于本机”→“证书信任设置”。")
            installationStep(4, "为“KanColle Game Local Root CA”启用完全信任，并确认系统警告。")
            installationStep(5, "返回本页，点击“重新检测信任状态”。")
        }
    }

    private var retrySection: some View {
        Section {
            Button {
                Task {
                    if model.certificateURL == nil {
                        await model.prepareAndCheckTrust()
                    } else {
                        await model.recheckTrust()
                    }
                }
            } label: {
                HStack {
                    Label("重新检测信任状态", systemImage: "arrow.clockwise")
                    if model.isBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isBusy)
        } footer: {
            if model.state == .untrusted {
                Text("未启用完全信任时，后续代理会对游戏域名回退为普通盲隧道，不会永久关闭此设置。")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.state {
        case .idle, .checking:
            ProgressView()
                .frame(width: 28, height: 28)
        case .trusted:
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .untrusted:
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(.red)
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .idle:
            return "等待检测"
        case .checking:
            return "正在检测…"
        case .trusted:
            return "已启用完全信任"
        case .untrusted:
            return "未启用完全信任"
        case .failed:
            return "检测失败"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .idle:
            return "将生成本机专用根证书。"
        case .checking:
            return "正在使用系统信任库验证游戏服务器证书。"
        case .trusted:
            return "游戏服务器 HTTPS 流量可以安全进入本地缓存与补丁流程。"
        case .untrusted:
            return "请按下方步骤安装证书并启用完全信任。"
        case .failed:
            return "错误不会被隐藏；可在修复后重新生成或检测。"
        }
    }

    private func installationStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }
}
