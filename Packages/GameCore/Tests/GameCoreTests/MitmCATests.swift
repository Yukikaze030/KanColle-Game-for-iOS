import Foundation
import Security
import XCTest
@testable import GameCore

final class MitmCATests: XCTestCase {
    private let metadataAccount = "root.certificate.der"

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

    private func deletePrivateKey(service: String) {
        XCTAssertEqual(
            SecItemDelete([
                kSecClass: kSecClassKey,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrApplicationTag: Data("\(service).ca".utf8)
            ] as CFDictionary),
            errSecSuccess
        )
    }

    private func createReplacementPrivateKey(service: String) throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048,
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: Data("\(service).ca".utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
        if let error {
            XCTFail("\(error.takeRetainedValue())")
        }
        _ = try XCTUnwrap(key)
    }

    private func deleteMetadata(service: String) {
        XCTAssertEqual(
            SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: metadataAccount
            ] as CFDictionary),
            errSecSuccess
        )
    }

    private func updateMetadata(service: String, certificateDER: Data) {
        XCTAssertEqual(
            SecItemUpdate([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: metadataAccount
            ] as CFDictionary, [
                kSecValueData: certificateDER
            ] as CFDictionary),
            errSecSuccess
        )
    }

    private func certificateQuery(der: Data) throws -> [CFString: Any] {
        let certificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, der as CFData)
        )
        let issuer = try XCTUnwrap(
            SecCertificateCopyNormalizedIssuerSequence(certificate)
        )
        var serialError: Unmanaged<CFError>?
        let serial = try XCTUnwrap(
            SecCertificateCopySerialNumberData(certificate, &serialError)
        )
        XCTAssertNil(serialError?.takeRetainedValue())
        return [
            kSecClass: kSecClassCertificate,
            kSecAttrIssuer: issuer,
            kSecAttrSerialNumber: serial
        ]
    }

    private func deleteCertificate(der: Data) throws {
        XCTAssertEqual(
            SecItemDelete(try certificateQuery(der: der) as CFDictionary),
            errSecSuccess
        )
    }

    private func certificateExists(der: Data) throws -> Bool {
        var query = try certificateQuery(der: der)
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        XCTAssertEqual(status, errSecSuccess)
        return status == errSecSuccess
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

    func testCorruptMetadataRecoversByRegeneratingRoot() throws {
        let service = makeService()
        let original = try MitmCA(keychainService: service).rootCertificateDER()
        updateMetadata(service: service, certificateDER: Data([0x01, 0x02, 0x03]))

        let recovered = try MitmCA(keychainService: service).rootCertificateDER()

        XCTAssertNotEqual(recovered, original)
        XCTAssertTrue(try certificateExists(der: recovered))
        XCTAssertFalse(try certificateExists(der: original))
    }

    func testMismatchedMetadataAndPrivateKeyRecoverWithoutDeletingOtherCA() throws {
        let service = makeService()
        let otherService = makeService()
        let original = try MitmCA(keychainService: service).rootCertificateDER()
        let other = try MitmCA(keychainService: otherService).rootCertificateDER()
        updateMetadata(service: service, certificateDER: other)

        let recovered = try MitmCA(keychainService: service).rootCertificateDER()

        XCTAssertNotEqual(recovered, original)
        XCTAssertNotEqual(recovered, other)
        XCTAssertTrue(try certificateExists(der: recovered))
        XCTAssertFalse(try certificateExists(der: original))
        XCTAssertTrue(try certificateExists(der: other))
        XCTAssertEqual(
            try MitmCA(keychainService: otherService).rootCertificateDER(),
            other
        )
    }

    func testMismatchedPrivateKeyRecoversAndRemovesOwnedCertificate() throws {
        let service = makeService()
        let original = try MitmCA(keychainService: service).rootCertificateDER()
        deletePrivateKey(service: service)
        try createReplacementPrivateKey(service: service)

        let recovered = try MitmCA(keychainService: service).rootCertificateDER()

        XCTAssertNotEqual(recovered, original)
        XCTAssertFalse(try certificateExists(der: original))
        XCTAssertTrue(try certificateExists(der: recovered))
    }

    func testKeyOnlyInterruptedStateRegeneratesRoot() throws {
        let service = makeService()
        let original = try MitmCA(keychainService: service).rootCertificateDER()
        deleteMetadata(service: service)
        try deleteCertificate(der: original)

        let recovered = try MitmCA(keychainService: service).rootCertificateDER()

        XCTAssertNotEqual(recovered, original)
        XCTAssertTrue(try certificateExists(der: recovered))
    }

    func testMetadataAndKeyWithoutClassCertificateRestoresCertificateItem() throws {
        let service = makeService()
        let original = try MitmCA(keychainService: service).rootCertificateDER()
        try deleteCertificate(der: original)
        XCTAssertFalse(try certificateExists(der: original))

        let reloaded = try MitmCA(keychainService: service).rootCertificateDER()

        XCTAssertEqual(reloaded, original)
        XCTAssertTrue(try certificateExists(der: original))
    }

    func testMetadataOnlyInterruptedStateRegeneratesRoot() throws {
        let service = makeService()
        let original = try MitmCA(keychainService: service).rootCertificateDER()
        deletePrivateKey(service: service)
        try deleteCertificate(der: original)

        let recovered = try MitmCA(keychainService: service).rootCertificateDER()

        XCTAssertNotEqual(recovered, original)
        XCTAssertTrue(try certificateExists(der: recovered))
    }

    func testDERTimeUsesGeneralizedTimeStartingIn2050() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let year2049 = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2049, month: 12, day: 31))
        )
        let year2050 = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2050, month: 1, day: 1))
        )

        let utcTime = MitmCA.derTimeForTesting(year2049)
        let generalizedTime = MitmCA.derTimeForTesting(year2050)

        XCTAssertEqual(utcTime.first, 0x17)
        XCTAssertEqual(generalizedTime.first, 0x18)
        XCTAssertEqual(String(data: utcTime.dropFirst(2), encoding: .ascii), "491231000000Z")
        XCTAssertEqual(
            String(data: generalizedTime.dropFirst(2), encoding: .ascii),
            "20500101000000Z"
        )
    }

    func testRootKeychainItemsHaveRequiredPersistenceAttributes() throws {
        let service = makeService()
        let rootDER = try MitmCA(keychainService: service).rootCertificateDER()

        // The legacy macOS Keychain omits kSecAttrAccessible from returned
        // attributes, so include the required value in the lookup itself.
        // Data-protection behavior is rechecked in task 6B's signed App host.
        var keyResult: CFTypeRef?
        let keyStatus = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: Data("\(service).ca".utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &keyResult)
        XCTAssertEqual(keyStatus, errSecSuccess)
        let storedKeyValue = try XCTUnwrap(keyResult)
        XCTAssertEqual(CFGetTypeID(storedKeyValue), SecKeyGetTypeID())

        var metadataResult: CFTypeRef?
        let metadataStatus = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "root.certificate.der",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &metadataResult)
        XCTAssertEqual(metadataStatus, errSecSuccess)
        XCTAssertEqual(metadataResult as? Data, rootDER)

        let rootCertificate = try XCTUnwrap(
            SecCertificateCreateWithData(nil, rootDER as CFData)
        )
        let issuer = try XCTUnwrap(
            SecCertificateCopyNormalizedIssuerSequence(rootCertificate)
        )
        var serialError: Unmanaged<CFError>?
        let serial = try XCTUnwrap(
            SecCertificateCopySerialNumberData(rootCertificate, &serialError)
        )
        XCTAssertNil(serialError?.takeRetainedValue())

        // Certificate labels may be rewritten from the subject on macOS.
        // Issuer + random serial is the stable certificate-class lookup key.
        var certificateResult: CFTypeRef?
        let certificateStatus = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrIssuer: issuer,
            kSecAttrSerialNumber: serial,
            kSecReturnData: true,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &certificateResult)
        XCTAssertEqual(certificateStatus, errSecSuccess)
        let certificateItem = try XCTUnwrap(certificateResult as? [CFString: Any])
        XCTAssertEqual(certificateItem[kSecValueData] as? Data, rootDER)
        let storedCertificateValue = try XCTUnwrap(certificateItem[kSecValueRef])
        XCTAssertEqual(
            CFGetTypeID(storedCertificateValue as CFTypeRef),
            SecCertificateGetTypeID()
        )
        let storedCertificate = storedCertificateValue as! SecCertificate
        XCTAssertEqual(SecCertificateCopyData(storedCertificate) as Data, rootDER)
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
