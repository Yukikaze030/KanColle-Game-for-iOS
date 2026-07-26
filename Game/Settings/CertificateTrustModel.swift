import CryptoKit
import Foundation
import GameCore
import Security

/// Prepares the local root certificate for export and checks whether iOS
/// currently trusts it.
///
/// Trust is checked in two independent stages:
/// 1. The self-signed root must pass Basic X.509 evaluation with the system's
///    anchors. This is the signal that the installed profile has Full Trust.
/// 2. A freshly issued host leaf must form a valid chain when that exact root is
///    supplied as an explicit anchor. This verifies the local CA material and
///    dynamic leaf generation, but cannot make an untrusted root trusted because
///    stage 1 must already have succeeded.
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
        let fingerprint: String
    }

    private struct TrustEvaluation: Sendable {
        let isTrusted: Bool
        let detail: String
    }

    nonisolated private static let probeHost = "w00g.kancolle-server.com"
    nonisolated private static let trustRetryDelays: [TimeInterval] = [
        0,
        0.5,
        1,
        2
    ]

    private(set) var state: TrustState = .idle
    private(set) var certificateURL: URL?
    private(set) var certificateFingerprint: String?
    private(set) var trustDetail: String?

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
            certificateFingerprint = result.fingerprint
            let evaluation = try await Self.evaluateSystemTrustWithRetry(
                certificateAuthority: certificateAuthority
            )
            trustDetail = evaluation.detail
            state = evaluation.isTrusted ? .trusted : .untrusted
        } catch {
            let message = Self.userFacingMessage(for: error)
            trustDetail = message
            state = .failed(message)
        }
    }

    func recheckTrust() async {
        guard !isBusy else { return }
        state = .checking

        let certificateAuthority = certificateAuthority
        do {
            if certificateFingerprint == nil {
                let rootDER = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try certificateAuthority.rootCertificateDER()
                }.value
                certificateFingerprint = Self.sha256Fingerprint(of: rootDER)
            }
            let evaluation = try await Self.evaluateSystemTrustWithRetry(
                certificateAuthority: certificateAuthority
            )
            trustDetail = evaluation.detail
            state = evaluation.isTrusted ? .trusted : .untrusted
        } catch {
            let message = Self.userFacingMessage(for: error)
            trustDetail = message
            state = .failed(message)
        }
    }

    func cleanupTemporaryFile() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        self.temporaryDirectory = nil
        certificateURL = nil
        certificateFingerprint = nil
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
                .appendingPathComponent("KanColle-Game-Local-CA")
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
                fingerprint: sha256Fingerprint(of: certificateDER)
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// trustd can briefly retain the pre-installation result after the user
    /// returns from Settings. Retry only a small, bounded number of times. A
    /// retry never changes policy or anchors, so an untrusted root cannot become
    /// a false positive.
    nonisolated private static func evaluateSystemTrustWithRetry(
        certificateAuthority: MitmCA
    ) async throws -> TrustEvaluation {
        let rootDER = try certificateAuthority.rootCertificateDER()
        guard let root = SecCertificateCreateWithData(
            nil,
            rootDER as CFData
        ) else {
            throw TrustCheckError.invalidCertificate
        }

        var finalRootFailure = "系统未返回详细原因"
        for (index, delay) in trustRetryDelays.enumerated() {
            if delay > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            try Task.checkCancellation()

            let rootResult = try evaluateRootWithSystemAnchors(root)
            guard rootResult.isTrusted else {
                finalRootFailure = rootResult.detail
                continue
            }

            let leafResult = try evaluateDynamicLeaf(
                certificateAuthority: certificateAuthority,
                root: root
            )
            guard leafResult.isTrusted else {
                return TrustEvaluation(
                    isTrusted: false,
                    detail: "根证书已通过系统完全信任检查，但动态服务器证书链校验失败："
                        + leafResult.detail
                )
            }

            let attempts = index + 1
            let retryText = attempts > 1
                ? "（trustd 缓存刷新后，第 \(attempts) 次检测通过）"
                : ""
            return TrustEvaluation(
                isTrusted: true,
                detail: "系统根证书完全信任与动态服务器证书链均验证通过\(retryText)。"
            )
        }

        return TrustEvaluation(
            isTrusted: false,
            detail: "系统根证书 Basic X.509 完全信任检查未通过："
                + finalRootFailure
                + "。请核对下方 SHA-256 指纹，确认启用的是本 App 当前导出的证书。"
        )
    }

    /// Uses only the default system/user anchor store. The root is input
    /// material, not an explicit anchor. Therefore success requires iOS to know
    /// and fully trust the exact installed root.
    nonisolated private static func evaluateRootWithSystemAnchors(
        _ root: SecCertificate
    ) throws -> TrustEvaluation {
        let policy = SecPolicyCreateBasicX509()
        var optionalTrust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            root,
            policy,
            &optionalTrust
        )
        guard status == errSecSuccess, let trust = optionalTrust else {
            throw TrustCheckError.createTrust(status)
        }

        var trustError: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &trustError)
        return TrustEvaluation(
            isTrusted: trusted,
            detail: trusted
                ? "系统根证书 Basic X.509 检查通过"
                : describeTrustFailure(trustError)
        )
    }

    /// Verifies the generated leaf against the same root that was exported.
    /// This stage checks CA/leaf consistency only; it is never used as evidence
    /// of system Full Trust.
    nonisolated private static func evaluateDynamicLeaf(
        certificateAuthority: MitmCA,
        root: SecCertificate
    ) throws -> TrustEvaluation {
        let issued = try certificateAuthority.issueCertificate(
            forHost: probeHost
        )
        guard let leaf = SecCertificateCreateWithData(
            nil,
            issued.certificateDER as CFData
        ) else {
            throw TrustCheckError.invalidCertificate
        }

        let policy = SecPolicyCreateSSL(true, probeHost as CFString)
        var optionalTrust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            leaf,
            policy,
            &optionalTrust
        )
        guard status == errSecSuccess, let trust = optionalTrust else {
            throw TrustCheckError.createTrust(status)
        }
        let anchorStatus = SecTrustSetAnchorCertificates(
            trust,
            [root] as CFArray
        )
        guard anchorStatus == errSecSuccess else {
            throw TrustCheckError.configureAnchor(anchorStatus)
        }
        let anchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard anchorsOnlyStatus == errSecSuccess else {
            throw TrustCheckError.configureAnchor(anchorsOnlyStatus)
        }

        var trustError: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &trustError)
        return TrustEvaluation(
            isTrusted: trusted,
            detail: trusted
                ? "动态服务器证书链检查通过"
                : describeTrustFailure(trustError)
        )
    }

    nonisolated private static func sha256Fingerprint(
        of certificateDER: Data
    ) -> String {
        SHA256.hash(data: certificateDER)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    nonisolated private static func describeTrustFailure(
        _ error: CFError?
    ) -> String {
        guard let error else {
            return "SecTrustEvaluateWithError 返回失败，但没有错误详情"
        }
        let nsError = error as Error as NSError
        var message = "\(nsError.domain)（\(nsError.code)）："
            + nsError.localizedDescription
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += "；底层错误 \(underlying.domain)（\(underlying.code)）："
                + underlying.localizedDescription
        }
        return message
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
        case configureAnchor(OSStatus)

        var description: String {
            switch self {
            case .invalidCertificate:
                return "证书数据无效"
            case .createTrust(let status):
                return "无法创建系统信任检查（\(status)）"
            case .configureAnchor(let status):
                return "无法配置动态证书链根锚点（\(status)）"
            }
        }
    }
}
