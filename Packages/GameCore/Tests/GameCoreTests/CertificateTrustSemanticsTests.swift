import Foundation
import Security
import XCTest
@testable import GameCore

/// Guards the security semantics used by CertificateTrustModel. These tests do
/// not install trust settings: a newly generated root must remain untrusted by
/// the system even though it can explicitly validate its own dynamic leaf.
final class CertificateTrustSemanticsTests: XCTestCase {
    private let host = "w00g.kancolle-server.com"

    private func makeCA() -> MitmCA {
        let service = "test.KanColle.Game.trust.\(UUID().uuidString)"
        addTeardownBlock {
            MitmCA.deleteStoredMaterial(keychainService: service)
        }
        return MitmCA(keychainService: service)
    }

    func testNewRootDoesNotPassDefaultSystemAnchorEvaluation() throws {
        let rootDER = try makeCA().rootCertificateDER()
        let root = try XCTUnwrap(
            SecCertificateCreateWithData(nil, rootDER as CFData)
        )
        XCTAssertEqual(
            SecCertificateCopySubjectSummary(root) as String?,
            "KanColle Game Local CA"
        )

        let policy = SecPolicyCreateBasicX509()
        var optionalTrust: SecTrust?
        XCTAssertEqual(
            SecTrustCreateWithCertificates(root, policy, &optionalTrust),
            errSecSuccess
        )
        let trust = try XCTUnwrap(optionalTrust)
        var trustError: CFError?

        XCTAssertFalse(SecTrustEvaluateWithError(trust, &trustError))
        XCTAssertNotNil(trustError)
    }

    func testExplicitRootAnchorValidatesDynamicLeafChain() throws {
        let ca = makeCA()
        let root = try XCTUnwrap(
            SecCertificateCreateWithData(
                nil,
                try ca.rootCertificateDER() as CFData
            )
        )
        let leaf = try XCTUnwrap(
            SecCertificateCreateWithData(
                nil,
                try ca.issueCertificate(forHost: host).certificateDER as CFData
            )
        )

        let policy = SecPolicyCreateSSL(true, host as CFString)
        var optionalTrust: SecTrust?
        XCTAssertEqual(
            SecTrustCreateWithCertificates(leaf, policy, &optionalTrust),
            errSecSuccess
        )
        let trust = try XCTUnwrap(optionalTrust)
        XCTAssertEqual(
            SecTrustSetAnchorCertificates(trust, [root] as CFArray),
            errSecSuccess
        )
        XCTAssertEqual(
            SecTrustSetAnchorCertificatesOnly(trust, true),
            errSecSuccess
        )
        var trustError: CFError?

        XCTAssertTrue(
            SecTrustEvaluateWithError(trust, &trustError),
            String(describing: trustError)
        )
    }

    func testExplicitLeafValidationCannotSubstituteForSystemRootTrust() throws {
        let ca = makeCA()
        let root = try XCTUnwrap(
            SecCertificateCreateWithData(
                nil,
                try ca.rootCertificateDER() as CFData
            )
        )
        let leaf = try XCTUnwrap(
            SecCertificateCreateWithData(
                nil,
                try ca.issueCertificate(forHost: host).certificateDER as CFData
            )
        )

        var rootTrust: SecTrust?
        XCTAssertEqual(
            SecTrustCreateWithCertificates(
                root,
                SecPolicyCreateBasicX509(),
                &rootTrust
            ),
            errSecSuccess
        )
        var rootError: CFError?
        let systemRootTrusted = SecTrustEvaluateWithError(
            try XCTUnwrap(rootTrust),
            &rootError
        )
        XCTAssertFalse(systemRootTrusted)

        var leafTrust: SecTrust?
        XCTAssertEqual(
            SecTrustCreateWithCertificates(
                leaf,
                SecPolicyCreateSSL(true, host as CFString),
                &leafTrust
            ),
            errSecSuccess
        )
        let explicitLeafTrust = try XCTUnwrap(leafTrust)
        XCTAssertEqual(
            SecTrustSetAnchorCertificates(
                explicitLeafTrust,
                [root] as CFArray
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            SecTrustSetAnchorCertificatesOnly(explicitLeafTrust, true),
            errSecSuccess
        )
        var leafError: CFError?
        let explicitLeafValid = SecTrustEvaluateWithError(
            explicitLeafTrust,
            &leafError
        )
        XCTAssertTrue(explicitLeafValid)

        // Production requires both checks, so this combination is untrusted.
        let isFullyTrusted = systemRootTrusted && explicitLeafValid
        XCTAssertFalse(isFullyTrusted)
    }
}
