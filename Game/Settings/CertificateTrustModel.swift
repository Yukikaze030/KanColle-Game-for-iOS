import Foundation
import GameCore
import Security

/// Prepares the local root certificate for export and checks whether iOS
/// currently trusts it. Trust evaluation deliberately uses the system trust
/// store; it never installs a custom anchor for the check.
@MainActor
@Observable
final class CertificateTrustModel {
    enum TrustState: Equatable {
        case idle
        case checking
        case trusted
        case untrusted
        case failed(String)
    }

    private struct PreparationResult: @unchecked Sendable {
        let certificateURL: URL
        let isTrusted: Bool
    }

    nonisolated private static let probeHost = "w00g.kancolle-server.com"

    private(set) var state: TrustState = .idle
    private(set) var certificateURL: URL?

    private let certificateAuthority: MitmCA
    private var temporaryDirectory: URL?

    init(certificateAuthority: MitmCA = MitmCA()) {
        self.certificateAuthority = certificateAuthority
    }

    var isBusy: Bool {
        state == .checking
    }

    var errorMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    func prepareAndCheckTrust() async {
        guard !isBusy else { return }
        state = .checking

        let certificateAuthority = certificateAuthority
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(certificateAuthority: certificateAuthority)
            }.value

            replaceTemporaryFile(with: result.certificateURL)
            state = result.isTrusted ? .trusted : .untrusted
        } catch {
            state = .failed(Self.userFacingMessage(for: error))
        }
    }

    func recheckTrust() async {
        guard !isBusy else { return }
        state = .checking

        let certificateAuthority = certificateAuthority
        do {
            let isTrusted = try await Task.detached(priority: .userInitiated) {
                try Self.evaluateSystemTrust(
                    certificateAuthority: certificateAuthority
                )
            }.value
            state = isTrusted ? .trusted : .untrusted
        } catch {
            state = .failed(Self.userFacingMessage(for: error))
        }
    }

    func cleanupTemporaryFile() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        self.temporaryDirectory = nil
        certificateURL = nil
    }

    private func replaceTemporaryFile(with url: URL) {
        if let oldDirectory = temporaryDirectory,
           oldDirectory != url.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: oldDirectory)
        }
        certificateURL = url
        temporaryDirectory = url.deletingLastPathComponent()
    }

    nonisolated private static func prepare(
        certificateAuthority: MitmCA
    ) throws -> PreparationResult {
        let certificateDER = try certificateAuthority.rootCertificateDER()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KanColle-Root-CA-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(resourceValues)

            let certificateURL = directory
                .appendingPathComponent("KanColle-Game-Root-CA")
                .appendingPathExtension("cer")
            try certificateDER.write(
                to: certificateURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )

            return PreparationResult(
                certificateURL: certificateURL,
                isTrusted: try evaluateSystemTrust(
                    certificateAuthority: certificateAuthority
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Evaluates a freshly issued game-host leaf with the default system
    /// anchors. Supplying the root as an intermediate does not make it trusted;
    /// iOS must already have the same root installed with full trust enabled.
    nonisolated private static func evaluateSystemTrust(
        certificateAuthority: MitmCA
    ) throws -> Bool {
        let issued = try certificateAuthority.issueCertificate(
            forHost: probeHost
        )
        let rootDER = try certificateAuthority.rootCertificateDER()

        guard let leaf = SecCertificateCreateWithData(
            nil,
            issued.certificateDER as CFData
        ), let root = SecCertificateCreateWithData(
            nil,
            rootDER as CFData
        ) else {
            throw TrustCheckError.invalidCertificate
        }

        let policy = SecPolicyCreateSSL(true, probeHost as CFString)
        var optionalTrust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            [leaf, root] as CFArray,
            policy,
            &optionalTrust
        )
        guard status == errSecSuccess, let trust = optionalTrust else {
            throw TrustCheckError.createTrust(status)
        }

        var trustError: CFError?
        return SecTrustEvaluateWithError(trust, &trustError)
    }

    nonisolated private static func userFacingMessage(for error: Error) -> String {
        if let caError = error as? MitmCA.CAError {
            return "生成本机根证书失败：\(caError)"
        }
        if let trustError = error as? TrustCheckError {
            return "检查证书信任状态失败：\(trustError.description)"
        }
        return "证书操作失败：\(error.localizedDescription)"
    }

    private enum TrustCheckError: Error {
        case invalidCertificate
        case createTrust(OSStatus)

        var description: String {
            switch self {
            case .invalidCertificate:
                return "证书数据无效"
            case .createTrust(let status):
                return "无法创建系统信任检查（\(status)）"
            }
        }
    }

}
