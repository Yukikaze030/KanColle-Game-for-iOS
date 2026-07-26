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
        .navigationTitle("可选资源解密证书")
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

            if let detail = model.trustDetail {
                LabeledContent("检测详情") {
                    Text(detail)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }

            if let fingerprint = model.certificateFingerprint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前根证书 SHA-256")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("当前根证书 SHA-256 指纹")
                        .accessibilityValue(fingerprint)
                }
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
            Text("此证书仅供实验性资源缓存与脚本补丁使用，不是登录或舰队/战斗/任务数据解析的必要条件。DMM 黑屏时请关闭“实验性 HTTPS 资源解密”。根私钥仅保存在本机 Keychain。")
        }
    }

    private var installationStepsSection: some View {
        Section("安装与完全信任") {
            installationStep(1, "点击“分享或打开证书”，在分享菜单中选择打开或存储证书。")
            installationStep(2, "回到“设置”，进入“已下载描述文件”，完成证书描述文件安装。")
            installationStep(3, "进入“通用”→“关于本机”→“证书信任设置”。")
            installationStep(4, "为“KanColle Game Local CA”启用完全信任，并确认系统警告。")
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
                Text(
                    "若已启用完全信任仍检测失败，请比较本页 SHA-256 指纹与已安装证书；"
                        + "指纹不同表示系统中仍是旧证书。请删除旧描述文件，返回本页重新"
                        + "“分享或打开证书”并安装，再到“证书信任设置”为"
                        + "“KanColle Game Local CA”启用完全信任。"
                        + "未通过验证时代理只会使用普通盲隧道，不会绕过安全检查。"
                )
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
            return "正在刷新 trustd，并分别验证系统根证书完全信任和动态服务器证书链。"
        case .trusted:
            return "可以手动启用实验性 HTTPS 资源解密；正常游戏与数据解析无需启用。"
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
