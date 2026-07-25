import Foundation
import Security
import XCTest
@testable import GameCore

final class MitmCATests: XCTestCase {
    private func makeService() -> String {
        let service = "test.KanColle.Game.mitm.\(UUID().uuidString)"
        addTeardownBlock {
            MitmCA.deleteStoredMaterial(keychainService: service)
        }
        return service
    }

    private func makeCA() -> MitmCA {
        MitmCA(keychainService: makeService())
    }

    func testGenerateAndReloadCA() throws {
        let service = makeService()
        let ca = MitmCA(keychainService: service)

        let first = try ca.rootCertificateDER()
        let second = try ca.rootCertificateDER()
        let reloaded = try MitmCA(keychainService: service)
            .rootCertificateDER()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, reloaded)
        XCTAssertEqual(first.first, 0x30)

        let certificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, first as CFData)
        )
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(publicKey) as? [CFString: Any])
        XCTAssertEqual(attributes[kSecAttrKeyType] as? String, kSecAttrKeyTypeRSA as String)
        XCTAssertEqual(attributes[kSecAttrKeySizeInBits] as? Int, 2_048)
    }

    func testIssueSiteCertificateHasValidChainAndSAN() throws {
        let ca = makeCA()
        let rootDER = try ca.rootCertificateDER()
        let issued = try ca.issueCertificate(forHost: "w00g.kancolle-server.com")

        let rootCertificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, rootDER as CFData)
        )
        let siteCertificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, issued.certificateDER as CFData)
        )
        let summary = try XCTUnwrap(SecCertificateCopySubjectSummary(siteCertificate) as String?)
        XCTAssertTrue(summary.contains("w00g.kancolle-server.com"))

        let policy = SecPolicyCreateSSL(true, "w00g.kancolle-server.com" as CFString)
        var optionalTrust: SecTrust?
        XCTAssertEqual(
            SecTrustCreateWithCertificates(siteCertificate, policy, &optionalTrust),
            errSecSuccess
        )
        let trust = try XCTUnwrap(optionalTrust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(trust, true), errSecSuccess)
        var trustError: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(trust, &trustError), "\(String(describing: trustError))")
    }

    func testIssuedPrivateKeyCanCreateNativeIdentity() throws {
        let ca = makeCA()
        let issued = try ca.issueCertificate(forHost: "w01g.kancolle-server.com")
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2_048
        ]
        var importError: Unmanaged<CFError>?
        let privateKey = SecKeyCreateWithData(
            issued.privateKeyDER as CFData,
            attributes as CFDictionary,
            &importError
        )
        XCTAssertNotNil(privateKey, "\(String(describing: importError?.takeRetainedValue()))")

        let certificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, issued.certificateDER as CFData)
        )
        XCTAssertNotNil(SecIdentityCreate(nil, certificate, try XCTUnwrap(privateKey)))
    }

    func testIssueCachesPerNormalizedHost() throws {
        let ca = makeCA()

        let first = try ca.issueCertificate(forHost: "W01G.KANCOLLE-SERVER.COM.")
        let second = try ca.issueCertificate(forHost: "w01g.kancolle-server.com")

        XCTAssertEqual(first.certificateDER, second.certificateDER)
        XCTAssertEqual(first.privateKeyDER, second.privateKeyDER)
    }

    func testConcurrentIssuanceIsThreadSafe() throws {
        let ca = makeCA()
        let resultLock = NSLock()
        var certificates: [Data] = []
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let certificate = try ca.issueCertificate(
                    forHost: "w02g.kancolle-server.com"
                ).certificateDER
                resultLock.withLock { certificates.append(certificate) }
            } catch {
                resultLock.withLock { errors.append(error) }
            }
        }

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(certificates.count, 12)
        XCTAssertEqual(Set(certificates).count, 1)
    }

    func testConcurrentInstancesShareOnePersistentRoot() {
        let service = makeService()
        let resultLock = NSLock()
        var certificates: [Data] = []
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let certificate = try MitmCA(keychainService: service)
                    .rootCertificateDER()
                resultLock.withLock { certificates.append(certificate) }
            } catch {
                resultLock.withLock { errors.append(error) }
            }
        }

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(certificates.count, 8)
        XCTAssertEqual(Set(certificates).count, 1)
    }

    func testPEMEncoding() throws {
        let der = try makeCA().rootCertificateDER()
        let pem = MitmCA.pemEncode(der: der)

        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END CERTIFICATE-----\n"))
        XCTAssertTrue(pem.contains("\n-----END CERTIFICATE-----\n"))
    }
}
