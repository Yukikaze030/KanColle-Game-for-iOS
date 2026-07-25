import Foundation
import Security
import Security.SecureTransport
import XCTest
@testable import GameCore

final class MitmIdentityMaterialTests: XCTestCase {
    private func makeCA() -> MitmCA {
        let service = "test.KanColle.Game.identity.\(UUID().uuidString)"
        addTeardownBlock {
            MitmCA.deleteStoredMaterial(keychainService: service)
        }
        return MitmCA(keychainService: service)
    }

    func testBuildsIdentityWithMatchingLeafAndPrivateKey() throws {
        let host = "w00g.kancolle-server.com"
        let material = try MitmIdentityMaterial(
            host: host,
            certificateAuthority: makeCA()
        )

        XCTAssertEqual(material.host, host)
        XCTAssertEqual(CFGetTypeID(material.identity), SecIdentityGetTypeID())

        let leafPublicKey = try XCTUnwrap(
            SecCertificateCopyKey(material.leafCertificate)
        )
        let privatePublicKey = try XCTUnwrap(
            SecKeyCopyPublicKey(material.privateKey)
        )
        XCTAssertEqual(
            SecKeyCopyExternalRepresentation(leafPublicKey, nil) as Data?,
            SecKeyCopyExternalRepresentation(privatePublicKey, nil) as Data?
        )

        var identityCertificate: SecCertificate?
        XCTAssertEqual(
            SecIdentityCopyCertificate(material.identity, &identityCertificate),
            errSecSuccess
        )
        XCTAssertEqual(
            identityCertificate.map { SecCertificateCopyData($0) as Data },
            SecCertificateCopyData(material.leafCertificate) as Data
        )

        var persistedKey: CFTypeRef?
        let persistenceStatus = SecItemCopyMatching(
            [
                kSecClass: kSecClassKey,
                kSecValueRef: material.privateKey,
                kSecReturnRef: true,
                kSecMatchLimit: kSecMatchLimitOne
            ] as CFDictionary,
            &persistedKey
        )
        XCTAssertEqual(persistenceStatus, errSecItemNotFound)
        XCTAssertNil(persistedKey)
    }

    func testCertificateChainStartsWithIdentityAndEndsWithRootCertificate() throws {
        let ca = makeCA()
        let material = try MitmIdentityMaterial(
            host: "w01g.kancolle-server.com",
            certificateAuthority: ca
        )

        XCTAssertEqual(CFArrayGetCount(material.certificateChain), 2)
        let first = unsafeBitCast(
            CFArrayGetValueAtIndex(material.certificateChain, 0),
            to: CFTypeRef.self
        )
        let second = unsafeBitCast(
            CFArrayGetValueAtIndex(material.certificateChain, 1),
            to: CFTypeRef.self
        )
        XCTAssertEqual(CFGetTypeID(first), SecIdentityGetTypeID())
        XCTAssertEqual(CFGetTypeID(second), SecCertificateGetTypeID())
        XCTAssertEqual(
            SecCertificateCopyData(material.rootCertificate) as Data,
            try ca.rootCertificateDER()
        )
    }

    func testRejectsInvalidDERWithHostSpecificErrors() throws {
        let host = "w02g.kancolle-server.com"
        let ca = makeCA()
        let issued = try ca.issueCertificate(forHost: host)
        let rootDER = try ca.rootCertificateDER()

        XCTAssertThrowsError(
            try MitmIdentityMaterial(
                host: host,
                leafCertificateDER: Data([0x00]),
                privateKeyDER: issued.privateKeyDER,
                rootCertificateDER: rootDER
            )
        ) { error in
            XCTAssertEqual(
                error as? MitmIdentityMaterial.MaterialError,
                .invalidLeafCertificate(host: host)
            )
        }

        XCTAssertThrowsError(
            try MitmIdentityMaterial(
                host: host,
                leafCertificateDER: issued.certificateDER,
                privateKeyDER: Data([0x00]),
                rootCertificateDER: rootDER
            )
        ) { error in
            guard case let .invalidPrivateKey(errorHost, _) =
                    error as? MitmIdentityMaterial.MaterialError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(errorHost, host)
        }

        XCTAssertThrowsError(
            try MitmIdentityMaterial(
                host: host,
                leafCertificateDER: issued.certificateDER,
                privateKeyDER: issued.privateKeyDER,
                rootCertificateDER: Data([0x00])
            )
        ) { error in
            XCTAssertEqual(
                error as? MitmIdentityMaterial.MaterialError,
                .invalidRootCertificate(host: host)
            )
        }
    }

    func testWrapsCertificateAuthorityErrorWithRequestedHost() {
        let host = "not a valid host"

        XCTAssertThrowsError(
            try MitmIdentityMaterial(
                host: host,
                certificateAuthority: makeCA()
            )
        ) { error in
            XCTAssertEqual(
                error as? MitmIdentityMaterial.MaterialError,
                .certificateAuthority(host: host, error: .invalidHost)
            )
        }
    }

    func testSameHostMaterialsCanConfigureSecureTransport() throws {
        let host = "w03g.kancolle-server.com"
        let ca = makeCA()
        let first = try MitmIdentityMaterial(
            host: host,
            certificateAuthority: ca
        )
        let second = try MitmIdentityMaterial(
            host: host,
            certificateAuthority: ca
        )

        XCTAssertEqual(
            SecCertificateCopyData(first.leafCertificate) as Data,
            SecCertificateCopyData(second.leafCertificate) as Data
        )

        for material in [first, second] {
            let context = try XCTUnwrap(
                SSLCreateContext(nil, .serverSide, .streamType)
            )
            XCTAssertEqual(
                SSLSetCertificate(context, material.certificateChain),
                errSecSuccess
            )
        }
    }
}
