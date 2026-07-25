import Foundation
import Security

/// Immutable TLS server identity material issued by ``MitmCA`` for one host.
///
/// The imported leaf private key is intentionally ephemeral. It is created
/// without `kSecAttrIsPermanent` and is retained only for this object's
/// lifetime. `certificateChain` is ready to pass directly to
/// `SSLSetCertificate`.
public final class MitmIdentityMaterial {
    public enum MaterialError: Error, Equatable {
        case certificateAuthority(host: String, error: MitmCA.CAError)
        case invalidLeafCertificate(host: String)
        case invalidPrivateKey(host: String, errorCode: Int?)
        case invalidRootCertificate(host: String)
        case leafNotSignedByRoot(host: String)
        case publicKeyExtractionFailed(host: String)
        case privateKeyDoesNotMatchLeafCertificate(host: String)
        case identityCreationFailed(host: String)
    }

    public let host: String
    public let leafCertificate: SecCertificate
    public let privateKey: SecKey
    public let identity: SecIdentity
    public let rootCertificate: SecCertificate

    /// `[SecIdentity, SecCertificate]`, suitable for `SSLSetCertificate`.
    public let certificateChain: CFArray

    /// Issues and assembles fresh TLS material using the supplied CA.
    ///
    /// Per-host issuance caching and synchronization are owned by ``MitmCA``;
    /// this type contains no mutable shared state.
    public convenience init(
        host: String,
        certificateAuthority: MitmCA
    ) throws {
        let issued: MitmCA.IssuedCertificate
        let rootDER: Data
        do {
            issued = try certificateAuthority.issueCertificate(forHost: host)
            rootDER = try certificateAuthority.rootCertificateDER()
        } catch let error as MitmCA.CAError {
            throw MaterialError.certificateAuthority(host: host, error: error)
        }

        try self.init(
            host: host,
            leafCertificateDER: issued.certificateDER,
            privateKeyDER: issued.privateKeyDER,
            rootCertificateDER: rootDER
        )
    }

    /// Assembles already-issued DER material.
    ///
    /// This initializer is also the validation boundary for data supplied by
    /// a certificate authority. The private key import remains nonpersistent.
    public init(
        host: String,
        leafCertificateDER: Data,
        privateKeyDER: Data,
        rootCertificateDER: Data
    ) throws {
        guard let leafCertificate = SecCertificateCreateWithData(
            nil,
            leafCertificateDER as CFData
        ) else {
            throw MaterialError.invalidLeafCertificate(host: host)
        }

        guard let rootCertificate = SecCertificateCreateWithData(
            nil,
            rootCertificateDER as CFData
        ) else {
            throw MaterialError.invalidRootCertificate(host: host)
        }

        try Self.validate(
            leafCertificate: leafCertificate,
            rootCertificate: rootCertificate,
            host: host
        )

        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2_048,
            kSecAttrIsPermanent: false
        ]
        var keyImportError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            privateKeyDER as CFData,
            keyAttributes as CFDictionary,
            &keyImportError
        ) else {
            let errorCode = keyImportError.map {
                CFErrorGetCode($0.takeRetainedValue())
            }
            throw MaterialError.invalidPrivateKey(
                host: host,
                errorCode: errorCode
            )
        }

        guard let leafPublicKey = SecCertificateCopyKey(leafCertificate),
              let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let leafPublicKeyDER = SecKeyCopyExternalRepresentation(
                  leafPublicKey,
                  nil
              ) as Data?,
              let privatePublicKeyDER = SecKeyCopyExternalRepresentation(
                  privatePublicKey,
                  nil
              ) as Data?
        else {
            throw MaterialError.publicKeyExtractionFailed(host: host)
        }
        guard leafPublicKeyDER == privatePublicKeyDER else {
            throw MaterialError.privateKeyDoesNotMatchLeafCertificate(host: host)
        }

        guard let identity = SecIdentityCreate(
            nil,
            leafCertificate,
            privateKey
        ) else {
            throw MaterialError.identityCreationFailed(host: host)
        }

        self.host = host
        self.leafCertificate = leafCertificate
        self.privateKey = privateKey
        self.identity = identity
        self.rootCertificate = rootCertificate
        certificateChain = [identity, rootCertificate] as CFArray
    }

    private static func validate(
        leafCertificate: SecCertificate,
        rootCertificate: SecCertificate,
        host: String
    ) throws {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var optionalTrust: SecTrust?
        guard SecTrustCreateWithCertificates(
            leafCertificate,
            policy,
            &optionalTrust
        ) == errSecSuccess,
              let trust = optionalTrust,
              SecTrustSetAnchorCertificates(
                  trust,
                  [rootCertificate] as CFArray
              ) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else {
            throw MaterialError.leafNotSignedByRoot(host: host)
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            throw MaterialError.leafNotSignedByRoot(host: host)
        }
    }
}
