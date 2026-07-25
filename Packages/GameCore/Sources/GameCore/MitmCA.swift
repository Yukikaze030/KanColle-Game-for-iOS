import CryptoKit
import Foundation
import Security

/// A device-local certificate authority used only for the game's HTTPS hosts.
///
/// The root RSA key is non-exportable at this API boundary and remains in the
/// Keychain. Site keys are short-lived, exportable PKCS#1 representations so a
/// later TLS layer can recreate `SecKey` and call `SecIdentityCreate`.
public final class MitmCA: @unchecked Sendable {
    public enum CAError: Error, Equatable {
        case invalidHost
        case randomGeneration(OSStatus)
        case keyGeneration(OSStatus)
        case keyExport
        case signing
        case certificateEncoding
        case keychain(OSStatus)
    }

    public typealias IssuedCertificate = (
        certificateDER: Data,
        privateKeyDER: Data
    )

    private struct RootMaterial {
        let certificateDER: Data
        let privateKey: SecKey
    }

    private struct DER {
        static func sequence(_ values: Data...) -> Data {
            tagged(0x30, values.reduce(into: Data()) { $0.append($1) })
        }

        static func sequence(_ values: [Data]) -> Data {
            tagged(0x30, values.reduce(into: Data()) { $0.append($1) })
        }

        static func set(_ values: Data...) -> Data {
            tagged(0x31, values.reduce(into: Data()) { $0.append($1) })
        }

        static func tagged(_ tag: UInt8, _ value: Data) -> Data {
            Data([tag]) + length(value.count) + value
        }

        static func explicit(_ number: UInt8, _ value: Data) -> Data {
            tagged(0xA0 | number, value)
        }

        static func integer(_ value: Int) -> Data {
            precondition(value >= 0)
            if value == 0 {
                return tagged(0x02, Data([0]))
            }

            var remaining = value
            var bytes: [UInt8] = []
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            return integer(Data(bytes))
        }

        static func integer(_ bytes: Data) -> Data {
            var normalized = Data(bytes.drop(while: { $0 == 0 }))
            if normalized.isEmpty {
                normalized = Data([0])
            } else if normalized[normalized.startIndex] & 0x80 != 0 {
                normalized.insert(0, at: normalized.startIndex)
            }
            return tagged(0x02, normalized)
        }

        static func boolean(_ value: Bool) -> Data {
            tagged(0x01, Data([value ? 0xFF : 0x00]))
        }

        static func null() -> Data {
            tagged(0x05, Data())
        }

        static func octetString(_ value: Data) -> Data {
            tagged(0x04, value)
        }

        static func bitString(_ value: Data, unusedBits: UInt8 = 0) -> Data {
            tagged(0x03, Data([unusedBits]) + value)
        }

        static func utf8String(_ value: String) -> Data? {
            value.data(using: .utf8).map { tagged(0x0C, $0) }
        }

        static func time(_ date: Date) -> Data {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let year = calendar.component(.year, from: date)
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if (1950...2049).contains(year) {
                formatter.dateFormat = "yyMMddHHmmss'Z'"
                return tagged(0x17, Data(formatter.string(from: date).utf8))
            }
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return tagged(0x18, Data(formatter.string(from: date).utf8))
        }

        static func objectIdentifier(_ components: [UInt64]) -> Data? {
            guard components.count >= 2,
                  components[0] <= 2,
                  components[1] <= 39 || components[0] == 2
            else {
                return nil
            }

            var body = Data()
            appendBase128(components[0] * 40 + components[1], to: &body)
            for component in components.dropFirst(2) {
                appendBase128(component, to: &body)
            }
            return tagged(0x06, body)
        }

        private static func appendBase128(_ value: UInt64, to data: inout Data) {
            if value == 0 {
                data.append(0)
                return
            }

            var remaining = value
            var bytes: [UInt8] = []
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0x7F), at: 0)
                remaining >>= 7
            }
            for index in bytes.indices.dropLast() {
                bytes[index] |= 0x80
            }
            data.append(contentsOf: bytes)
        }

        private static func length(_ count: Int) -> Data {
            if count < 0x80 {
                return Data([UInt8(count)])
            }

            var remaining = count
            var bytes: [UInt8] = []
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
    }

    private enum OID {
        static let commonName: [UInt64] = [2, 5, 4, 3]
        static let rsaEncryption: [UInt64] = [1, 2, 840, 113549, 1, 1, 1]
        static let sha256WithRSAEncryption: [UInt64] = [1, 2, 840, 113549, 1, 1, 11]
        static let basicConstraints: [UInt64] = [2, 5, 29, 19]
        static let keyUsage: [UInt64] = [2, 5, 29, 15]
        static let subjectKeyIdentifier: [UInt64] = [2, 5, 29, 14]
        static let extendedKeyUsage: [UInt64] = [2, 5, 29, 37]
        static let serverAuth: [UInt64] = [1, 3, 6, 1, 5, 5, 7, 3, 1]
        static let subjectAlternativeName: [UInt64] = [2, 5, 29, 17]
    }

    private let service: String
    private let lock = NSLock()
    private static let persistenceLock = NSLock()
    private var cachedRoot: RootMaterial?
    private var siteCertificateCache: [String: IssuedCertificate] = [:]

    public init(keychainService: String = "KanColle.Game.mitm") {
        service = keychainService
    }

    /// Returns the self-signed RSA-2048 X.509 v3 root certificate.
    ///
    /// The first call creates the key and certificate. Later instances load the
    /// exact same material from the Keychain.
    public func rootCertificateDER() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try rootMaterialLocked().certificateDER
    }

    /// Issues and caches one RSA-2048 server certificate per normalized host.
    ///
    /// `privateKeyDER` is the native RSA external representation returned by
    /// `SecKeyCopyExternalRepresentation` (PKCS#1). It is intentionally not
    /// wrapped as PKCS#8: `SecKeyCreateWithData` can import this representation
    /// directly, after which `SecIdentityCreate` combines it with the returned
    /// certificate without a PKCS#12 round-trip.
    public func issueCertificate(forHost host: String) throws -> IssuedCertificate {
        let normalizedHost = try Self.normalize(host: host)

        lock.lock()
        defer { lock.unlock() }

        if let cached = siteCertificateCache[normalizedHost] {
            return cached
        }

        let root = try rootMaterialLocked()
        let siteKey = try Self.generateEphemeralRSAKey()
        guard let publicKey = SecKeyCopyPublicKey(siteKey),
              let privateKeyDER = SecKeyCopyExternalRepresentation(siteKey, nil) as Data?
        else {
            throw CAError.keyExport
        }

        let certificateDER = try Self.makeCertificate(
            subjectCommonName: normalizedHost,
            issuerCommonName: Self.rootCommonName,
            publicKey: publicKey,
            signingKey: root.privateKey,
            // The one-day backdate plus 397 future days stays within Apple's
            // current 398-day maximum TLS leaf validity.
            validityDays: 397,
            isCA: false,
            dnsName: normalizedHost
        )
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw CAError.certificateEncoding
        }

        let issued = (
            certificateDER: certificateDER,
            privateKeyDER: privateKeyDER
        )
        siteCertificateCache[normalizedHost] = issued
        return issued
    }

    /// Encodes certificate DER for export through the certificate-install UI.
    public static func pemEncode(der: Data) -> String {
        let base64 = der.base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed]
        ).trimmingCharacters(in: .newlines)
        return "-----BEGIN CERTIFICATE-----\n"
            + base64
            + "\n-----END CERTIFICATE-----\n"
    }

    static func derTimeForTesting(_ date: Date) -> Data {
        DER.time(date)
    }

    // Internal test support. Production recovery uses the throwing cleanup
    // path below; teardown is intentionally best-effort so one failed test
    // cannot mask the original assertion failure.
    static func deleteStoredMaterial(keychainService: String) {
        let ca = MitmCA(keychainService: keychainService)
        ca.lock.lock()
        defer { ca.lock.unlock() }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }

        let certificateDER = try? ca.copyStoredRootCertificate()
        let privateKey = try? ca.copyStoredRootPrivateKey()
        try? ca.removeStoredMaterial(
            certificateDER: certificateDER,
            privateKey: privateKey
        )
    }

    // MARK: - Root persistence

    private static let rootCommonName = "KanColle Game Local CA"
    private static let rootCertificateAccount = "root.certificate.der"

    private func rootMaterialLocked() throws -> RootMaterial {
        if let cachedRoot {
            return cachedRoot
        }

        // Instance locks protect each site's cache. This process-wide lock also
        // makes first-run Keychain creation atomic when multiple MitmCA
        // instances for the same service are created concurrently.
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }

        let storedCertificate = try copyStoredRootCertificate()
        let storedPrivateKey = try copyStoredRootPrivateKey()
        if let certificateDER = storedCertificate,
           let privateKey = storedPrivateKey,
           Self.keysMatch(certificateDER: certificateDER, privateKey: privateKey) {
            try ensureRootClassCertificate(certificateDER)
            let material = RootMaterial(
                certificateDER: certificateDER,
                privateKey: privateKey
            )
            cachedRoot = material
            return material
        }

        // Recover atomically from a prior interrupted first-run generation.
        if storedCertificate != nil || storedPrivateKey != nil {
            try removeStoredMaterial(
                certificateDER: storedCertificate,
                privateKey: storedPrivateKey
            )
        }
        // If both lookups are empty, an old-version certificate-only item
        // cannot be attributed to this service because macOS may rewrite its
        // label. Never scan/delete by the shared CN: such an orphan is harmless,
        // and metadata-first writes below can no longer create this state.

        let (publicKey, privateKey) = try generatePersistentRootKeyPair()
        var newCertificateDER: Data?
        do {
            let certificateDER = try Self.makeCertificate(
                subjectCommonName: Self.rootCommonName,
                issuerCommonName: Self.rootCommonName,
                publicKey: publicKey,
                signingKey: privateKey,
                validityDays: 3_650,
                isCA: true,
                dnsName: nil
            )
            newCertificateDER = certificateDER
            // Stable metadata is the commit marker. The certificate-class item
            // is written second and repaired on load if creation was interrupted.
            try storeRootMetadata(certificateDER)
            try storeRootClassCertificate(certificateDER)
            let material = RootMaterial(
                certificateDER: certificateDER,
                privateKey: privateKey
            )
            cachedRoot = material
            return material
        } catch {
            do {
                try removeStoredMaterial(
                    certificateDER: newCertificateDER,
                    privateKey: privateKey
                )
            } catch let cleanupError {
                throw cleanupError
            }
            throw error
        }
    }

    private func copyStoredRootCertificate() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.rootCertificateAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CAError.keychain(status)
        }
        guard let data = result as? Data else {
            throw CAError.keychain(errSecDecode)
        }
        return data
    }

    private func copyStoredRootPrivateKey() throws -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrApplicationTag: rootKeyTag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CAError.keychain(status)
        }
        guard let key = result else {
            throw CAError.keychain(errSecDecode)
        }
        guard CFGetTypeID(key) == SecKeyGetTypeID() else {
            throw CAError.keychain(errSecDecode)
        }
        return unsafeDowncast(key as AnyObject, to: SecKey.self)
    }

    private func generatePersistentRootKeyPair() throws -> (SecKey, SecKey) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrIsExtractable: false,
                kSecAttrApplicationTag: rootKeyTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var publicKey: SecKey?
        var privateKey: SecKey?
        let status = SecKeyGeneratePair(
            attributes as CFDictionary,
            &publicKey,
            &privateKey
        )
        guard status == errSecSuccess,
              let publicKey,
              let privateKey
        else {
            throw CAError.keyGeneration(status)
        }
        return (publicKey, privateKey)
    }

    private func storeRootMetadata(_ certificateDER: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.rootCertificateAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: certificateDER
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CAError.keychain(status)
        }
    }

    private func ensureRootClassCertificate(_ certificateDER: Data) throws {
        if try rootClassCertificateExists(certificateDER) {
            return
        }
        try storeRootClassCertificate(certificateDER)
    }

    private func storeRootClassCertificate(_ certificateDER: Data) throws {
        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateDER as CFData
        ) else {
            throw CAError.certificateEncoding
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: service,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueRef: certificate
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem,
           try rootClassCertificateExists(certificateDER) {
            return
        }
        guard status == errSecSuccess else {
            throw CAError.keychain(status)
        }
    }

    private func rootClassCertificateExists(_ certificateDER: Data) throws -> Bool {
        var query = try Self.classCertificateQuery(certificateDER)
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw CAError.keychain(status)
        }
        guard let result, CFGetTypeID(result) == SecCertificateGetTypeID() else {
            throw CAError.keychain(errSecDecode)
        }
        return true
    }

    private func removeStoredMaterial(
        certificateDER: Data?,
        privateKey: SecKey?
    ) throws {
        var deletedKeyMatchedCertificate = false
        if let privateKey,
           let certificate = try findClassCertificate(matching: privateKey) {
            try Self.deleteItem([
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate
            ])
            deletedKeyMatchedCertificate = true
        }
        // If a replacement/corrupt key has no certificate, metadata is the
        // remaining precise locator. If both locate different certificates,
        // prefer the key-matched item so corrupt metadata cannot delete another
        // service's otherwise healthy certificate.
        if !deletedKeyMatchedCertificate,
           let certificateDER,
           SecCertificateCreateWithData(
               nil,
               certificateDER as CFData
           ) != nil {
            try Self.deleteItem(try Self.classCertificateQuery(certificateDER))
        }

        try Self.deleteItem([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: rootKeyTag
        ])
        try Self.deleteItem([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.rootCertificateAccount
        ])
    }

    private func findClassCertificate(matching privateKey: SecKey) throws -> SecCertificate? {
        guard let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let expectedKeyDER = SecKeyCopyExternalRepresentation(
                  privatePublicKey,
                  nil
              ) as Data?
        else {
            throw CAError.certificateEncoding
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CAError.keychain(status)
        }

        let values: [CFTypeRef]
        if let array = result as? [AnyObject] {
            values = array.map { $0 as CFTypeRef }
        } else if let result {
            values = [result]
        } else {
            throw CAError.keychain(errSecDecode)
        }
        for value in values where CFGetTypeID(value) == SecCertificateGetTypeID() {
            let certificate = unsafeDowncast(value as AnyObject, to: SecCertificate.self)
            guard let publicKey = SecCertificateCopyKey(certificate),
                  let keyDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
            else {
                continue
            }
            if keyDER == expectedKeyDER {
                return certificate
            }
        }
        return nil
    }

    private static func classCertificateQuery(_ certificateDER: Data) throws -> [CFString: Any] {
        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateDER as CFData
        ), let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate)
        else {
            throw CAError.certificateEncoding
        }
        var serialError: Unmanaged<CFError>?
        guard let serial = SecCertificateCopySerialNumberData(
            certificate,
            &serialError
        ) else {
            _ = serialError?.takeRetainedValue()
            throw CAError.certificateEncoding
        }
        if let serialError {
            _ = serialError.takeRetainedValue()
            throw CAError.certificateEncoding
        }
        return [
            kSecClass: kSecClassCertificate,
            kSecAttrIssuer: issuer,
            kSecAttrSerialNumber: serial
        ]
    }

    private static func deleteItem(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CAError.keychain(status)
        }
    }

    private var rootKeyTag: Data {
        Data("\(service).ca".utf8)
    }

    // MARK: - Certificate construction

    private static func generateEphemeralRSAKey() throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &error
        ) else {
            let nsError = error?.takeRetainedValue() as Error? as NSError?
            let status = OSStatus(nsError?.code ?? Int(errSecInternalError))
            throw CAError.keyGeneration(status)
        }
        return key
    }

    private static func makeCertificate(
        subjectCommonName: String,
        issuerCommonName: String,
        publicKey: SecKey,
        signingKey: SecKey,
        validityDays: Int,
        isCA: Bool,
        dnsName: String?
    ) throws -> Data {
        guard let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let signatureAlgorithm = algorithmIdentifier(),
              let issuer = distinguishedName(commonName: issuerCommonName),
              let subject = distinguishedName(commonName: subjectCommonName),
              let subjectPublicKeyInfo = subjectPublicKeyInfo(publicKeyDER: publicKeyDER)
        else {
            throw CAError.certificateEncoding
        }

        let now = Date()
        let notBefore = now.addingTimeInterval(-24 * 60 * 60)
        let notAfter = now.addingTimeInterval(
            TimeInterval(validityDays) * 24 * 60 * 60
        )
        let validity = DER.sequence(
            DER.time(notBefore),
            DER.time(notAfter)
        )
        let extensions = try certificateExtensions(
            publicKeyDER: publicKeyDER,
            isCA: isCA,
            dnsName: dnsName
        )
        let tbsCertificate = DER.sequence(
            DER.explicit(0, DER.integer(2)),
            DER.integer(try randomSerial()),
            signatureAlgorithm,
            issuer,
            validity,
            subject,
            subjectPublicKeyInfo,
            DER.explicit(3, DER.sequence(extensions))
        )

        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &signingError
        ) as Data? else {
            _ = signingError?.takeRetainedValue()
            throw CAError.signing
        }
        return DER.sequence(
            tbsCertificate,
            signatureAlgorithm,
            DER.bitString(signature)
        )
    }

    private static func algorithmIdentifier() -> Data? {
        guard let oid = DER.objectIdentifier(OID.sha256WithRSAEncryption) else {
            return nil
        }
        return DER.sequence(oid, DER.null())
    }

    private static func distinguishedName(commonName: String) -> Data? {
        guard let commonNameOID = DER.objectIdentifier(OID.commonName),
              let value = DER.utf8String(commonName)
        else {
            return nil
        }
        return DER.sequence(DER.set(DER.sequence(commonNameOID, value)))
    }

    private static func subjectPublicKeyInfo(publicKeyDER: Data) -> Data? {
        guard let rsaOID = DER.objectIdentifier(OID.rsaEncryption) else {
            return nil
        }
        let algorithm = DER.sequence(rsaOID, DER.null())
        return DER.sequence(algorithm, DER.bitString(publicKeyDER))
    }

    private static func certificateExtensions(
        publicKeyDER: Data,
        isCA: Bool,
        dnsName: String?
    ) throws -> [Data] {
        guard let basicConstraintsOID = DER.objectIdentifier(OID.basicConstraints),
              let keyUsageOID = DER.objectIdentifier(OID.keyUsage),
              let subjectKeyIdentifierOID = DER.objectIdentifier(OID.subjectKeyIdentifier)
        else {
            throw CAError.certificateEncoding
        }

        let basicConstraintsValue = isCA
            ? DER.sequence(DER.boolean(true), DER.integer(0))
            : DER.sequence()
        let basicConstraints = DER.sequence(
            basicConstraintsOID,
            DER.boolean(true),
            DER.octetString(basicConstraintsValue)
        )

        let keyUsageValue = isCA
            ? DER.bitString(Data([0x06]), unusedBits: 1)
            : DER.bitString(Data([0xA0]), unusedBits: 5)
        let keyUsage = DER.sequence(
            keyUsageOID,
            DER.boolean(true),
            DER.octetString(keyUsageValue)
        )

        let keyIdentifier = Data(Insecure.SHA1.hash(data: publicKeyDER))
        let subjectKeyIdentifier = DER.sequence(
            subjectKeyIdentifierOID,
            DER.octetString(DER.octetString(keyIdentifier))
        )
        var extensions = [
            basicConstraints,
            keyUsage,
            subjectKeyIdentifier
        ]

        if let dnsName {
            guard let dnsData = dnsName.data(using: .ascii),
                  let extendedKeyUsageOID = DER.objectIdentifier(OID.extendedKeyUsage),
                  let serverAuthOID = DER.objectIdentifier(OID.serverAuth),
                  let subjectAlternativeNameOID = DER.objectIdentifier(
                    OID.subjectAlternativeName
                  )
            else {
                throw CAError.certificateEncoding
            }

            extensions.append(
                DER.sequence(
                    extendedKeyUsageOID,
                    DER.octetString(DER.sequence(serverAuthOID))
                )
            )
            extensions.append(
                DER.sequence(
                    subjectAlternativeNameOID,
                    DER.octetString(DER.sequence(DER.tagged(0x82, dnsData)))
                )
            )
        }
        return extensions
    }

    private static func randomSerial() throws -> Data {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CAError.randomGeneration(status)
        }
        if bytes.allSatisfy({ $0 == 0 }) {
            bytes[bytes.index(before: bytes.endIndex)] = 1
        }
        return bytes
    }

    private static func keysMatch(
        certificateDER: Data,
        privateKey: SecKey
    ) -> Bool {
        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateDER as CFData
        ), let certificatePublicKey = SecCertificateCopyKey(certificate),
        let privatePublicKey = SecKeyCopyPublicKey(privateKey),
        let certificateKeyDER = SecKeyCopyExternalRepresentation(
            certificatePublicKey,
            nil
        ) as Data?,
        let privateKeyDER = SecKeyCopyExternalRepresentation(
            privatePublicKey,
            nil
        ) as Data? else {
            return false
        }
        return certificateKeyDER == privateKeyDER
    }

    private static func normalize(host: String) throws -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty,
              normalized.utf8.count <= 253,
              normalized.data(using: .ascii) != nil
        else {
            throw CAError.invalidHost
        }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else {
                return false
            }
            return label.utf8.allSatisfy {
                (48...57).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45
            }
        }) else {
            throw CAError.invalidHost
        }
        return normalized
    }
}
