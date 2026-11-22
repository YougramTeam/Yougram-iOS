import Foundation
import CryptoKit
import CommonCrypto
import Security
import ManagedFile

/// Domain-separated subkeys derived from a 32-byte Master Vault Key (`VMK`).
public final class YougramVaultKeyMaterial: @unchecked Sendable {
    public let version: Int
    private let lock = NSLock()
    private var _masterKey: Data
    private var _postboxDatabaseKey: Data
    private var _postboxDatabaseSalt: Data
    private var _accountManagerDatabaseKey: Data
    private var _accountManagerDatabaseSalt: Data
    private var _accountManagerGuardDatabaseKey: Data
    private var _accountManagerGuardDatabaseSalt: Data
    private var _storageBoxDatabaseKey: Data
    private var _storageBoxDatabaseSalt: Data
    private var _atomicStateKey: Data
    private var _loginTokensKey: Data
    private var _mediaKey: Data
    private var _mediaHeaderKey: Data
    private var _mediaFilenameKey: Data
    private var _sharedMediaKey: Data
    private var invalidated = false

    private static let domainSalt = Data("yougram.vault.v1".utf8)
    private static let domainSaltV2 = Data("yougram.vault.v2".utf8)

    public init(masterKey: Data, version: Int = 2) {
        precondition(masterKey.count == 32, "Yougram master key must be 32 bytes")
        let resolvedVersion = version >= 2 ? 2 : 1
        self.version = resolvedVersion
        let ikm = SymmetricKey(data: masterKey)
        self._masterKey = Data(masterKey)
        if resolvedVersion >= 2 {
            self._postboxDatabaseKey = Self.hkdfSHA512(ikm: ikm, info: "db.postbox.key.v2", count: 32)
            self._postboxDatabaseSalt = Self.hkdfSHA512(ikm: ikm, info: "db.postbox.salt.v2", count: 16)
            self._accountManagerDatabaseKey = Self.hkdfSHA512(ikm: ikm, info: "db.account-manager.key.v2", count: 32)
            self._accountManagerDatabaseSalt = Self.hkdfSHA512(ikm: ikm, info: "db.account-manager.salt.v2", count: 16)
            self._accountManagerGuardDatabaseKey = Self.hkdfSHA512(ikm: ikm, info: "db.account-manager-guard.key.v2", count: 32)
            self._accountManagerGuardDatabaseSalt = Self.hkdfSHA512(ikm: ikm, info: "db.account-manager-guard.salt.v2", count: 16)
            self._storageBoxDatabaseKey = Self.hkdfSHA512(ikm: ikm, info: "db.storage-box.key.v2", count: 32)
            self._storageBoxDatabaseSalt = Self.hkdfSHA512(ikm: ikm, info: "db.storage-box.salt.v2", count: 16)
            self._atomicStateKey = Self.hkdfSHA512(ikm: ikm, info: "file.atomic-state.v2", count: 32)
            self._loginTokensKey = Self.hkdfSHA512(ikm: ikm, info: "file.login-tokens.v2", count: 32)
            self._mediaKey = Self.hkdfSHA512(ikm: ikm, info: "media.content.v2", count: 32)
            self._mediaHeaderKey = Self.hkdfSHA512(ikm: ikm, info: "media.header.v2", count: 32)
            self._mediaFilenameKey = Self.hkdfSHA512(ikm: ikm, info: "media.filename.v2", count: 32)
            self._sharedMediaKey = Self.hkdfSHA512(ikm: ikm, info: "media.shared.v2", count: 32)
        } else {
            self._postboxDatabaseKey = Self.hkdf(ikm: ikm, info: "db.postbox.key.v1", count: 32)
            self._postboxDatabaseSalt = Self.hkdf(ikm: ikm, info: "db.postbox.salt.v1", count: 16)
            self._accountManagerDatabaseKey = Self.hkdf(ikm: ikm, info: "db.account-manager.key.v1", count: 32)
            self._accountManagerDatabaseSalt = Self.hkdf(ikm: ikm, info: "db.account-manager.salt.v1", count: 16)
            self._accountManagerGuardDatabaseKey = Self.hkdf(ikm: ikm, info: "db.account-manager-guard.key.v1", count: 32)
            self._accountManagerGuardDatabaseSalt = Self.hkdf(ikm: ikm, info: "db.account-manager-guard.salt.v1", count: 16)
            self._storageBoxDatabaseKey = Self.hkdf(ikm: ikm, info: "db.storage-box.key.v1", count: 32)
            self._storageBoxDatabaseSalt = Self.hkdf(ikm: ikm, info: "db.storage-box.salt.v1", count: 16)
            self._atomicStateKey = Self.hkdf(ikm: ikm, info: "file.atomic-state.v1", count: 32)
            self._loginTokensKey = Self.hkdf(ikm: ikm, info: "file.login-tokens.v1", count: 32)
            self._mediaKey = Self.hkdf(ikm: ikm, info: "media.content.v1", count: 32)
            self._mediaHeaderKey = Self.hkdf(ikm: ikm, info: "media.header.v1", count: 32)
            self._mediaFilenameKey = Self.hkdf(ikm: ikm, info: "media.filename.v1", count: 32)
            self._sharedMediaKey = Self.hkdf(ikm: ikm, info: "media.shared.v1", count: 32)
        }
    }

    deinit {
        self.invalidate()
    }

    /// RFC 5869 HKDF-SHA256 implemented via CryptoKit HMAC so it has no extra OS-version constraints.
    static func hkdf(ikm: SymmetricKey, salt: Data = domainSalt, info: String, count: Int) -> Data {
        let infoData = Data(info.utf8)
        let prkBytes = Data(HMAC<SHA256>.authenticationCode(for: ikm.withUnsafeBytes { Data($0) }, using: SymmetricKey(data: salt)))
        let prk = SymmetricKey(data: prkBytes)
        var okm = Data()
        okm.reserveCapacity(count)
        var t = Data()
        var counter: UInt8 = 1
        while okm.count < count {
            var input = t
            input.append(infoData)
            input.append(counter)
            t = Data(HMAC<SHA256>.authenticationCode(for: input, using: prk))
            okm.append(t)
            counter &+= 1
        }
        return Data(okm.prefix(count))
    }

    /// RFC 5869 HKDF-SHA512 implemented via CryptoKit HMAC for v2 vault subkey and cascade derivation.
    static func hkdfSHA512(ikm: SymmetricKey, salt: Data = domainSaltV2, info: String, count: Int) -> Data {
        let infoData = Data(info.utf8)
        var ikmBytes = ikm.withUnsafeBytes { Data($0) }
        var prkBytes = Data(HMAC<SHA512>.authenticationCode(for: ikmBytes, using: SymmetricKey(data: salt)))
        Self.zeroize(&ikmBytes)
        let prk = SymmetricKey(data: prkBytes)
        Self.zeroize(&prkBytes)
        var okm = Data()
        okm.reserveCapacity(count)
        var t = Data()
        var counter: UInt8 = 1
        while okm.count < count {
            var input = t
            input.append(infoData)
            input.append(counter)
            t = Data(HMAC<SHA512>.authenticationCode(for: input, using: prk))
            okm.append(t)
            counter &+= 1
        }
        return Data(okm.prefix(count))
    }

    public func invalidate() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.invalidated else { return }
        self.invalidated = true
        Self.zeroize(&self._masterKey)
        Self.zeroize(&self._postboxDatabaseKey)
        Self.zeroize(&self._postboxDatabaseSalt)
        Self.zeroize(&self._accountManagerDatabaseKey)
        Self.zeroize(&self._accountManagerDatabaseSalt)
        Self.zeroize(&self._accountManagerGuardDatabaseKey)
        Self.zeroize(&self._accountManagerGuardDatabaseSalt)
        Self.zeroize(&self._storageBoxDatabaseKey)
        Self.zeroize(&self._storageBoxDatabaseSalt)
        Self.zeroize(&self._atomicStateKey)
        Self.zeroize(&self._loginTokensKey)
        Self.zeroize(&self._mediaKey)
        Self.zeroize(&self._mediaHeaderKey)
        Self.zeroize(&self._mediaFilenameKey)
        Self.zeroize(&self._sharedMediaKey)
    }

    private static func zeroize(_ data: inout Data) {
        if !data.isEmpty {
            data.resetBytes(in: 0 ..< data.count)
        }
    }

    public var postboxDatabaseParameters: ValueBoxEncryptionParameters {
        self.lock.lock()
        defer { self.lock.unlock() }
        return ValueBoxEncryptionParameters(
            forceEncryptionIfNoSet: true,
            key: ValueBoxEncryptionParameters.Key(data: Data(self._postboxDatabaseKey))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(self._postboxDatabaseSalt))!
        )
    }

    public var accountManagerDatabaseParameters: ValueBoxEncryptionParameters {
        self.lock.lock()
        defer { self.lock.unlock() }
        return ValueBoxEncryptionParameters(
            forceEncryptionIfNoSet: true,
            key: ValueBoxEncryptionParameters.Key(data: Data(self._accountManagerDatabaseKey))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(self._accountManagerDatabaseSalt))!
        )
    }

    public var accountManagerGuardDatabaseParameters: ValueBoxEncryptionParameters {
        self.lock.lock()
        defer { self.lock.unlock() }
        return ValueBoxEncryptionParameters(
            forceEncryptionIfNoSet: true,
            key: ValueBoxEncryptionParameters.Key(data: Data(self._accountManagerGuardDatabaseKey))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(self._accountManagerGuardDatabaseSalt))!
        )
    }

    public var storageBoxDatabaseParameters: ValueBoxEncryptionParameters {
        self.lock.lock()
        defer { self.lock.unlock() }
        return ValueBoxEncryptionParameters(
            forceEncryptionIfNoSet: true,
            key: ValueBoxEncryptionParameters.Key(data: Data(self._storageBoxDatabaseKey))!,
            salt: ValueBoxEncryptionParameters.Salt(data: Data(self._storageBoxDatabaseSalt))!
        )
    }

    public var atomicStateKey: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Data(self._atomicStateKey)
    }

    public var loginTokensKey: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Data(self._loginTokensKey)
    }

    public var mediaKey: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Data(self._mediaKey)
    }

    public var mediaHeaderKey: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Data(self._mediaHeaderKey)
    }

    public var mediaFilenameKey: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Data(self._mediaFilenameKey)
    }

    public var sharedMediaKey: Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Data(self._sharedMediaKey)
    }
}

public enum YougramLocalEncryptionError: Error {
    case invalidKey
    case invalidFormat
    case authenticationFailed
    case ioFailed
}

/// Whole-blob authenticated encryption:
/// - `YGE1` (legacy read support): single-layer AES-256-GCM
/// - `YGE2` (default write format): Dual-Cipher Cascade (AES-256-GCM wrapped inside ChaCha20-Poly1305)
public enum YougramEncryptedBlob {
    public static let magic = Data([0x59, 0x47, 0x45, 0x31])   // "YGE1"
    public static let magicV2 = Data([0x59, 0x47, 0x45, 0x32]) // "YGE2"
    private static let yge2Salt = Data("yougram.yge2.cascade".utf8)

    public static func isEncrypted(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefix = data.prefix(4)
        return prefix == Self.magic || prefix == Self.magicV2
    }

    private static func deriveCascadeKeys(key: Data, aad: String) -> (aesKey: SymmetricKey, chachaKey: SymmetricKey) {
        let ikm = SymmetricKey(data: key)
        var aesData = YougramVaultKeyMaterial.hkdfSHA512(ikm: ikm, salt: Self.yge2Salt, info: "yge2.aes:" + aad, count: 32)
        var chachaData = YougramVaultKeyMaterial.hkdfSHA512(ikm: ikm, salt: Self.yge2Salt, info: "yge2.chacha:" + aad, count: 32)
        let aesKey = SymmetricKey(data: aesData)
        let chachaKey = SymmetricKey(data: chachaData)
        if !aesData.isEmpty { aesData.resetBytes(in: 0 ..< aesData.count) }
        if !chachaData.isEmpty { chachaData.resetBytes(in: 0 ..< chachaData.count) }
        return (aesKey, chachaKey)
    }

    public static func seal(_ plaintext: Data, key: Data, aad: String) throws -> Data {
        guard key.count == 32 else { throw YougramLocalEncryptionError.invalidKey }
        let (aesKey, chachaKey) = Self.deriveCascadeKeys(key: key, aad: aad)

        let innerNonce = try AES.GCM.Nonce(data: randomBytes(12))
        let innerSealed = try AES.GCM.seal(plaintext, using: aesKey, nonce: innerNonce, authenticating: Data((aad + ":aes").utf8))
        guard let innerCombined = innerSealed.combined else {
            throw YougramLocalEncryptionError.authenticationFailed
        }

        let outerNonce = try ChaChaPoly.Nonce(data: randomBytes(12))
        let outerSealed = try ChaChaPoly.seal(innerCombined, using: chachaKey, nonce: outerNonce, authenticating: Data((aad + ":chacha").utf8))
        let outerCombined = outerSealed.combined

        var result = Data(capacity: 4 + outerCombined.count)
        result.append(Self.magicV2)
        result.append(outerCombined)
        return result
    }

    public static func open(_ data: Data, key: Data, aad: String) throws -> Data {
        guard key.count == 32 else { throw YougramLocalEncryptionError.invalidKey }
        guard data.count >= 4 else { throw YougramLocalEncryptionError.invalidFormat }
        let header = data.prefix(4)
        if header == Self.magicV2 {
            guard data.count >= 4 + 28 + 28 else {
                throw YougramLocalEncryptionError.invalidFormat
            }
            let (aesKey, chachaKey) = Self.deriveCascadeKeys(key: key, aad: aad)
            do {
                let outerBox = try ChaChaPoly.SealedBox(combined: data.dropFirst(4))
                let innerCombined = try ChaChaPoly.open(outerBox, using: chachaKey, authenticating: Data((aad + ":chacha").utf8))
                let innerBox = try AES.GCM.SealedBox(combined: innerCombined)
                return try AES.GCM.open(innerBox, using: aesKey, authenticating: Data((aad + ":aes").utf8))
            } catch {
                throw YougramLocalEncryptionError.authenticationFailed
            }
        } else if header == Self.magic {
            guard data.count >= 4 + 12 + 16 else {
                throw YougramLocalEncryptionError.invalidFormat
            }
            do {
                let box = try AES.GCM.SealedBox(combined: data.dropFirst(4))
                return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
            } catch {
                throw YougramLocalEncryptionError.authenticationFailed
            }
        } else {
            throw YougramLocalEncryptionError.invalidFormat
        }
    }
}

private func randomBytes(_ count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
        guard let base = buffer.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, count, base)
    }
    if status != errSecSuccess {
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                arc4random_buf(base, count)
            }
        }
    }
    return data
}

private func readLittleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { dst in
        data.copyBytes(to: dst, from: offset ..< (offset + 4))
    }
    return UInt32(littleEndian: value)
}

private func readLittleEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
    var value: UInt64 = 0
    _ = withUnsafeMutableBytes(of: &value) { dst in
        data.copyBytes(to: dst, from: offset ..< (offset + 8))
    }
    return UInt64(littleEndian: value)
}

private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

private func appendLittleEndian(_ value: UInt64, to data: inout Data) {
    var le = value.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}

/// Chunked Dual-Cipher (`YGCF` v2: AES-256-GCM + ChaCha20-Poly1305 cascade, HMAC-SHA512 header)
/// with backward-compatible `YGCF` v1 reader, O(1) range reads, and encrypted trailer,
/// plus deterministic AES-256-CTR support for sparse partial downloads.
public enum YougramChunkedFileCrypto {
    public static let magic = Data([0x59, 0x47, 0x43, 0x46]) // "YGCF"
    public static let trailerMagic = Data([0x59, 0x47, 0x54, 0x31]) // "YGT1"
    public static let headerSize = 68
    public static let headerSizeV2 = 84
    public static let defaultChunkSize = 65536
    public static let tagSize = 16
    public static let tagSizeV2 = 32

    public struct Header {
        public let formatVersion: UInt8
        public let headerSize: Int
        public let tagSize: Int
        public let chunkSize: Int
        public let plaintextSize: Int64
        public let fileSalt: Data
        public let dataEndOffset: Int64
        public let totalFileSize: Int64
        public let fileKey: SymmetricKey
        public let outerFileKey: SymmetricKey?

        public var chunkCount: Int64 {
            if self.plaintextSize == 0 {
                return 0
            }
            let cs = Int64(self.chunkSize)
            return (self.plaintextSize + cs - 1) / cs
        }
    }

    public static func isChunkedFile(atPath path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: 4)
        let n = Darwin.read(fd, &buf, 4)
        return n == 4 && buf == [0x59, 0x47, 0x43, 0x46]
    }

    private static func deriveFileKey(mediaKey: Data, fileSalt: Data) -> SymmetricKey {
        let derived = YougramVaultKeyMaterial.hkdf(
            ikm: SymmetricKey(data: mediaKey),
            salt: fileSalt,
            info: "ygcf.file.v1",
            count: 32
        )
        return SymmetricKey(data: derived)
    }

    private static func deriveFileKeysV2(mediaKey: Data, fileSalt: Data) -> (aesKey: SymmetricKey, chachaKey: SymmetricKey) {
        let ikm = SymmetricKey(data: mediaKey)
        var aesData = YougramVaultKeyMaterial.hkdfSHA512(ikm: ikm, salt: fileSalt, info: "ygcf.v2.aes", count: 32)
        var chachaData = YougramVaultKeyMaterial.hkdfSHA512(ikm: ikm, salt: fileSalt, info: "ygcf.v2.chacha", count: 32)
        let aesKey = SymmetricKey(data: aesData)
        let chachaKey = SymmetricKey(data: chachaData)
        if !aesData.isEmpty { aesData.resetBytes(in: 0 ..< aesData.count) }
        if !chachaData.isEmpty { chachaData.resetBytes(in: 0 ..< chachaData.count) }
        return (aesKey, chachaKey)
    }

    private static func chunkNonceData(index: UInt64, domain: UInt32) -> Data {
        var nonceData = Data(capacity: 12)
        appendLittleEndian(domain, to: &nonceData)
        appendLittleEndian(index, to: &nonceData)
        return nonceData
    }

    private static func chunkAAD(fileSalt: Data, index: UInt64, plaintextSize: UInt64) -> Data {
        var aad = Data(capacity: 48)
        aad.append(fileSalt)
        appendLittleEndian(index, to: &aad)
        appendLittleEndian(plaintextSize, to: &aad)
        return aad
    }

    private static func nameAAD(fileSalt: Data) -> Data {
        var aad = Data("ygcf.name.v1:".utf8)
        aad.append(fileSalt)
        return aad
    }

    private static func makeHeaderBytesV2(chunkSize: UInt32, plaintextSize: UInt64, fileSalt: Data, mediaHeaderKey: Data) -> Data {
        var header = Data(capacity: headerSizeV2)
        header.append(magic)
        header.append(2) // version 2 (Dual-Cipher Cascade + HMAC-SHA512)
        header.append(0) // flags
        appendLittleEndian(UInt16(0), to: &header)
        appendLittleEndian(chunkSize, to: &header)
        appendLittleEndian(plaintextSize, to: &header)
        header.append(fileSalt)
        let mac = Data(HMAC<SHA512>.authenticationCode(for: header, using: SymmetricKey(data: mediaHeaderKey)))
        header.append(mac.prefix(32))
        return header
    }

    private static func makeTrailerV1(originalFileName: String, fileSalt: Data, fileKey: SymmetricKey) throws -> Data {
        let nameData = Data(originalFileName.utf8)
        let nonce = try AES.GCM.Nonce(data: randomBytes(12))
        let sealed = try AES.GCM.seal(nameData, using: fileKey, nonce: nonce, authenticating: nameAAD(fileSalt: fileSalt))
        guard let combined = sealed.combined else {
            throw YougramLocalEncryptionError.authenticationFailed
        }
        var trailer = Data(capacity: combined.count + 8)
        trailer.append(combined)
        appendLittleEndian(UInt32(combined.count), to: &trailer)
        trailer.append(trailerMagic)
        return trailer
    }

    private static func makeTrailerV2(originalFileName: String, fileSalt: Data, aesKey: SymmetricKey, chachaKey: SymmetricKey) throws -> Data {
        let nameData = Data(originalFileName.utf8)
        let aad = nameAAD(fileSalt: fileSalt)
        let innerNonce = try AES.GCM.Nonce(data: randomBytes(12))
        let innerSealed = try AES.GCM.seal(nameData, using: aesKey, nonce: innerNonce, authenticating: aad)
        guard let innerCombined = innerSealed.combined else {
            throw YougramLocalEncryptionError.authenticationFailed
        }
        let outerNonce = try ChaChaPoly.Nonce(data: randomBytes(12))
        let outerSealed = try ChaChaPoly.seal(innerCombined, using: chachaKey, nonce: outerNonce, authenticating: aad)
        let outerCombined = outerSealed.combined

        var trailer = Data(capacity: outerCombined.count + 8)
        trailer.append(outerCombined)
        appendLittleEndian(UInt32(outerCombined.count), to: &trailer)
        trailer.append(trailerMagic)
        return trailer
    }

    private static func sealChunkV2<C: DataProtocol>(
        _ chunk: C,
        aesKey: SymmetricKey,
        chachaKey: SymmetricKey,
        fileSalt: Data,
        index: UInt64,
        plaintextSize: UInt64
    ) throws -> Data {
        let aad = chunkAAD(fileSalt: fileSalt, index: index, plaintextSize: plaintextSize)
        let innerNonce = try AES.GCM.Nonce(data: chunkNonceData(index: index, domain: 1))
        let innerSealed = try AES.GCM.seal(chunk, using: aesKey, nonce: innerNonce, authenticating: aad)
        var innerPayload = Data(capacity: chunk.count + tagSize)
        innerPayload.append(innerSealed.ciphertext)
        innerPayload.append(innerSealed.tag)

        let outerNonce = try ChaChaPoly.Nonce(data: chunkNonceData(index: index, domain: 2))
        let outerSealed = try ChaChaPoly.seal(innerPayload, using: chachaKey, nonce: outerNonce, authenticating: aad)
        var out = Data(capacity: chunk.count + tagSizeV2)
        out.append(outerSealed.ciphertext)
        out.append(outerSealed.tag)
        return out
    }

    private static func openChunk(
        diskBytes: Data,
        chunkPlainLen: Int,
        header: Header,
        chunkIndex: UInt64
    ) throws -> Data {
        let aad = chunkAAD(fileSalt: header.fileSalt, index: chunkIndex, plaintextSize: UInt64(header.plaintextSize))
        if header.formatVersion >= 2 {
            guard let outerKey = header.outerFileKey else {
                throw YougramLocalEncryptionError.invalidFormat
            }
            let outerNonce = try ChaChaPoly.Nonce(data: chunkNonceData(index: chunkIndex, domain: 2))
            let outerBox = try ChaChaPoly.SealedBox(
                nonce: outerNonce,
                ciphertext: diskBytes.prefix(chunkPlainLen + tagSize),
                tag: diskBytes.suffix(tagSize)
            )
            let innerBytes: Data
            do {
                innerBytes = try ChaChaPoly.open(outerBox, using: outerKey, authenticating: aad)
            } catch {
                throw YougramLocalEncryptionError.authenticationFailed
            }
            let innerNonce = try AES.GCM.Nonce(data: chunkNonceData(index: chunkIndex, domain: 1))
            let innerBox = try AES.GCM.SealedBox(
                nonce: innerNonce,
                ciphertext: innerBytes.prefix(chunkPlainLen),
                tag: innerBytes.suffix(tagSize)
            )
            do {
                return try AES.GCM.open(innerBox, using: header.fileKey, authenticating: aad)
            } catch {
                throw YougramLocalEncryptionError.authenticationFailed
            }
        } else {
            let nonce = try AES.GCM.Nonce(data: chunkNonceData(index: chunkIndex, domain: 0))
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: diskBytes.prefix(chunkPlainLen),
                tag: diskBytes.suffix(tagSize)
            )
            do {
                return try AES.GCM.open(box, using: header.fileKey, authenticating: aad)
            } catch {
                throw YougramLocalEncryptionError.authenticationFailed
            }
        }
    }

    public static func readHeader(atPath path: String, keys: YougramVaultKeyMaterial) -> Header? {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        return self.readHeader(fd: fd, keys: keys)
    }

    private static func readHeader(fd: Int32, keys: YougramVaultKeyMaterial) -> Header? {
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        let totalFileSize = Int64(st.st_size)
        guard totalFileSize >= Int64(headerSize + 8) else { return nil }

        var prefixHeader = Data(count: 52)
        let prefixRead = prefixHeader.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return preadFull(fd: fd, buffer: base, count: 52, offset: 0)
        }
        guard prefixRead == 52, prefixHeader.prefix(4) == magic else { return nil }
        let formatVersion = prefixHeader[4]
        guard formatVersion == 1 || formatVersion == 2 else { return nil }

        let hdrSize = formatVersion == 2 ? headerSizeV2 : headerSize
        let tSize = formatVersion == 2 ? tagSizeV2 : tagSize
        guard totalFileSize >= Int64(hdrSize + 8) else { return nil }

        let macLen = formatVersion == 2 ? 32 : 16
        var storedMac = Data(count: macLen)
        let macRead = storedMac.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return preadFull(fd: fd, buffer: base, count: macLen, offset: 52)
        }
        guard macRead == macLen else { return nil }

        if formatVersion == 2 {
            let expectedMac = Data(HMAC<SHA512>.authenticationCode(for: prefixHeader, using: SymmetricKey(data: keys.mediaHeaderKey))).prefix(32)
            guard storedMac == expectedMac else { return nil }
        } else {
            let expectedMac = Data(HMAC<SHA256>.authenticationCode(for: prefixHeader, using: SymmetricKey(data: keys.mediaHeaderKey))).prefix(16)
            guard storedMac == expectedMac else { return nil }
        }

        let chunkSizeU32 = readLittleEndianUInt32(prefixHeader, offset: 8)
        guard chunkSizeU32 >= 4096 && chunkSizeU32 <= 4 * 1024 * 1024 else { return nil }
        let plaintextSizeU64 = readLittleEndianUInt64(prefixHeader, offset: 12)
        guard plaintextSizeU64 <= UInt64(Int64.max / 2) else { return nil }
        let plaintextSize = Int64(plaintextSizeU64)
        let fileSalt = Data(prefixHeader[20 ..< 52])

        let chunkCount: Int64 = plaintextSize == 0 ? 0 : (plaintextSize + Int64(chunkSizeU32) - 1) / Int64(chunkSizeU32)
        let (chunkOverhead, overflow1) = chunkCount.multipliedReportingOverflow(by: Int64(tSize))
        guard !overflow1 else { return nil }
        let (payloadSize, overflow2) = plaintextSize.addingReportingOverflow(chunkOverhead)
        guard !overflow2 else { return nil }
        let (dataEndOffset, overflow3) = Int64(hdrSize).addingReportingOverflow(payloadSize)
        guard !overflow3 else { return nil }

        // Require the 8-byte trailer footer so file truncation is caught immediately.
        guard totalFileSize >= dataEndOffset + 8 else { return nil }
        var footer = Data(count: 8)
        let footerRead = footer.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return preadFull(fd: fd, buffer: base, count: 8, offset: totalFileSize - 8)
        }
        guard footerRead == 8, footer.suffix(4) == trailerMagic else { return nil }
        let trailerLen = Int64(readLittleEndianUInt32(footer, offset: 0))
        let minTrailerLen: Int64 = formatVersion == 2 ? 56 : 28
        guard trailerLen >= minTrailerLen, dataEndOffset + trailerLen + 8 == totalFileSize else { return nil }

        if formatVersion == 2 {
            let (aesKey, chachaKey) = deriveFileKeysV2(mediaKey: keys.mediaKey, fileSalt: fileSalt)
            return Header(
                formatVersion: formatVersion,
                headerSize: hdrSize,
                tagSize: tSize,
                chunkSize: Int(chunkSizeU32),
                plaintextSize: plaintextSize,
                fileSalt: fileSalt,
                dataEndOffset: dataEndOffset,
                totalFileSize: totalFileSize,
                fileKey: aesKey,
                outerFileKey: chachaKey
            )
        } else {
            let fileKey = deriveFileKey(mediaKey: keys.mediaKey, fileSalt: fileSalt)
            return Header(
                formatVersion: formatVersion,
                headerSize: hdrSize,
                tagSize: tSize,
                chunkSize: Int(chunkSizeU32),
                plaintextSize: plaintextSize,
                fileSalt: fileSalt,
                dataEndOffset: dataEndOffset,
                totalFileSize: totalFileSize,
                fileKey: fileKey,
                outerFileKey: nil
            )
        }
    }

    public static func plaintextSize(atPath path: String, keys: YougramVaultKeyMaterial) -> Int64? {
        return self.readHeader(atPath: path, keys: keys)?.plaintextSize
    }

    public static func originalFileName(atPath path: String, keys: YougramVaultKeyMaterial) -> String? {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard let header = self.readHeader(fd: fd, keys: keys) else { return nil }
        let sealedLen = Int(header.totalFileSize - header.dataEndOffset - 8)
        let minLen = header.formatVersion >= 2 ? 56 : 28
        guard sealedLen >= minLen && sealedLen <= 16384 else { return nil }
        var sealedData = Data(count: sealedLen)
        let n = sealedData.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return preadFull(fd: fd, buffer: base, count: sealedLen, offset: header.dataEndOffset)
        }
        guard n == sealedLen else { return nil }
        let aad = nameAAD(fileSalt: header.fileSalt)
        if header.formatVersion >= 2 {
            guard let outerKey = header.outerFileKey,
                  let outerBox = try? ChaChaPoly.SealedBox(combined: sealedData),
                  let innerCombined = try? ChaChaPoly.open(outerBox, using: outerKey, authenticating: aad),
                  let innerBox = try? AES.GCM.SealedBox(combined: innerCombined),
                  let nameData = try? AES.GCM.open(innerBox, using: header.fileKey, authenticating: aad) else {
                return nil
            }
            return String(data: nameData, encoding: .utf8)
        } else {
            guard let box = try? AES.GCM.SealedBox(combined: sealedData),
                  let nameData = try? AES.GCM.open(box, using: header.fileKey, authenticating: aad) else {
                return nil
            }
            return String(data: nameData, encoding: .utf8)
        }
    }

    public static func updateOriginalFileName(atPath path: String, newOriginalFileName: String, keys: YougramVaultKeyMaterial) -> Bool {
        let fd = Darwin.open(path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard let header = self.readHeader(fd: fd, keys: keys) else { return false }
        let trailer: Data?
        if header.formatVersion >= 2, let outerKey = header.outerFileKey {
            trailer = try? makeTrailerV2(originalFileName: newOriginalFileName, fileSalt: header.fileSalt, aesKey: header.fileKey, chachaKey: outerKey)
        } else {
            trailer = try? makeTrailerV1(originalFileName: newOriginalFileName, fileSalt: header.fileSalt, fileKey: header.fileKey)
        }
        guard let trailer else {
            return false
        }
        guard Darwin.ftruncate(fd, header.dataEndOffset) == 0 else { return false }
        guard Darwin.lseek(fd, header.dataEndOffset, SEEK_SET) == header.dataEndOffset else { return false }
        let written = trailer.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: fd, buffer: base, count: trailer.count)
        }
        if written {
            Darwin.fsync(fd)
        }
        return written
    }

    public static func encryptData(_ data: Data, originalFileName: String, toPath path: String, keys: YougramVaultKeyMaterial) throws {
        let fileSalt = try randomBytes(32)
        let (aesKey, chachaKey) = deriveFileKeysV2(mediaKey: keys.mediaKey, fileSalt: fileSalt)
        let chunkSize = defaultChunkSize
        let plaintextSize = data.count
        let header = makeHeaderBytesV2(chunkSize: UInt32(chunkSize), plaintextSize: UInt64(plaintextSize), fileSalt: fileSalt, mediaHeaderKey: keys.mediaHeaderKey)

        let tmpPath = path + ".ygtmp-\(UUID().uuidString)"
        let fd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        var cleanupTmp = true
        defer {
            Darwin.close(fd)
            if cleanupTmp {
                Darwin.unlink(tmpPath)
            }
        }

        let headerOk = header.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: fd, buffer: base, count: header.count)
        }
        guard headerOk else { throw YougramLocalEncryptionError.ioFailed }

        var offset = 0
        var chunkIndex: UInt64 = 0
        while offset < plaintextSize {
            let end = min(plaintextSize, offset + chunkSize)
            let chunk = data.subdata(in: offset ..< end)
            let out = try sealChunkV2(chunk, aesKey: aesKey, chachaKey: chachaKey, fileSalt: fileSalt, index: chunkIndex, plaintextSize: UInt64(plaintextSize))
            let ok = out.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                return writeFull(fd: fd, buffer: base, count: out.count)
            }
            guard ok else { throw YougramLocalEncryptionError.ioFailed }
            offset = end
            chunkIndex &+= 1
        }

        let trailer = try makeTrailerV2(originalFileName: originalFileName, fileSalt: fileSalt, aesKey: aesKey, chachaKey: chachaKey)
        let trailerOk = trailer.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: fd, buffer: base, count: trailer.count)
        }
        guard trailerOk else { throw YougramLocalEncryptionError.ioFailed }

        Darwin.fsync(fd)
        guard Darwin.rename(tmpPath, path) == 0 else {
            throw YougramLocalEncryptionError.ioFailed
        }
        cleanupTmp = false
    }

    public static func encryptFile(fromPath: String, originalFileName: String, toPath path: String, keys: YougramVaultKeyMaterial) throws {
        let inFd = Darwin.open(fromPath, O_RDONLY)
        guard inFd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        defer { Darwin.close(inFd) }

        var st = stat()
        guard Darwin.fstat(inFd, &st) == 0 else { throw YougramLocalEncryptionError.ioFailed }
        let plaintextSize = Int64(st.st_size)

        let fileSalt = try randomBytes(32)
        let (aesKey, chachaKey) = deriveFileKeysV2(mediaKey: keys.mediaKey, fileSalt: fileSalt)
        let chunkSize = defaultChunkSize
        let header = makeHeaderBytesV2(chunkSize: UInt32(chunkSize), plaintextSize: UInt64(plaintextSize), fileSalt: fileSalt, mediaHeaderKey: keys.mediaHeaderKey)

        let tmpPath = path + ".ygtmp-\(UUID().uuidString)"
        let outFd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard outFd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        var cleanupTmp = true
        defer {
            Darwin.close(outFd)
            if cleanupTmp {
                Darwin.unlink(tmpPath)
            }
        }

        let headerOk = header.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: outFd, buffer: base, count: header.count)
        }
        guard headerOk else { throw YougramLocalEncryptionError.ioFailed }

        var buffer = Data(count: chunkSize)
        var remaining = plaintextSize
        var chunkIndex: UInt64 = 0
        while remaining > 0 {
            let toRead = Int(min(Int64(chunkSize), remaining))
            let actual = buffer.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return readExactOrEOF(fd: inFd, buffer: base, count: toRead)
            }
            guard actual == toRead else { throw YougramLocalEncryptionError.ioFailed }
            let out = try sealChunkV2(buffer.prefix(toRead), aesKey: aesKey, chachaKey: chachaKey, fileSalt: fileSalt, index: chunkIndex, plaintextSize: UInt64(plaintextSize))
            let ok = out.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                return writeFull(fd: outFd, buffer: base, count: out.count)
            }
            guard ok else { throw YougramLocalEncryptionError.ioFailed }
            remaining -= Int64(toRead)
            chunkIndex &+= 1
        }

        let trailer = try makeTrailerV2(originalFileName: originalFileName, fileSalt: fileSalt, aesKey: aesKey, chachaKey: chachaKey)
        let trailerOk = trailer.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: outFd, buffer: base, count: trailer.count)
        }
        guard trailerOk else { throw YougramLocalEncryptionError.ioFailed }

        Darwin.fsync(outFd)
        guard Darwin.rename(tmpPath, path) == 0 else {
            throw YougramLocalEncryptionError.ioFailed
        }
        cleanupTmp = false
    }

    public static func decryptData(fromPath path: String, keys: YougramVaultKeyMaterial) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        defer { Darwin.close(fd) }
        guard let header = self.readHeader(fd: fd, keys: keys) else {
            throw YougramLocalEncryptionError.authenticationFailed
        }
        guard header.plaintextSize <= 256 * 1024 * 1024 else {
            throw YougramLocalEncryptionError.invalidFormat
        }
        return try self.decryptRange(fd: fd, header: header, range: 0 ..< header.plaintextSize)
    }

    public static func decryptRange(fromPath path: String, range: Range<Int64>, keys: YougramVaultKeyMaterial) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        defer { Darwin.close(fd) }
        guard let header = self.readHeader(fd: fd, keys: keys) else {
            throw YougramLocalEncryptionError.authenticationFailed
        }
        return try self.decryptRange(fd: fd, header: header, range: range)
    }

    public static func decryptRange(
        fromPath path: String,
        range: Range<Int64>,
        into buffer: UnsafeMutablePointer<UInt8>,
        maxCount: Int,
        keys: YougramVaultKeyMaterial
    ) -> Int? {
        guard maxCount > 0 else { return 0 }
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard let header = self.readHeader(fd: fd, keys: keys) else { return nil }
        let clampedLower = max(0, min(header.plaintextSize, range.lowerBound))
        let clampedUpper = max(clampedLower, min(header.plaintextSize, min(range.upperBound, clampedLower + Int64(maxCount))))
        if clampedLower == clampedUpper {
            return 0
        }
        guard let data = try? self.decryptRange(fd: fd, header: header, range: clampedLower ..< clampedUpper) else {
            return nil
        }
        let copyCount = min(maxCount, data.count)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, copyCount > 0 {
                memcpy(buffer, base, copyCount)
            }
        }
        return copyCount
    }

    private static func decryptRange(fd: Int32, header: Header, range: Range<Int64>) throws -> Data {
        let lower = max(0, min(header.plaintextSize, range.lowerBound))
        let upper = max(lower, min(header.plaintextSize, range.upperBound))
        if lower == upper {
            return Data()
        }

        let chunkSize = Int64(header.chunkSize)
        let firstChunk = lower / chunkSize
        let lastChunk = (upper - 1) / chunkSize
        let stride = Int64(header.chunkSize + header.tagSize)

        var result = Data()
        result.reserveCapacity(Int(upper - lower))

        for chunkIdx in firstChunk ... lastChunk {
            let chunkPlainStart = chunkIdx * chunkSize
            let chunkPlainLen = Int(min(chunkSize, header.plaintextSize - chunkPlainStart))
            let diskOffset = Int64(header.headerSize) + chunkIdx * stride
            let diskLen = chunkPlainLen + header.tagSize

            var diskBytes = Data(count: diskLen)
            let readLen = diskBytes.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return preadFull(fd: fd, buffer: base, count: diskLen, offset: diskOffset)
            }
            guard readLen == diskLen else {
                throw YougramLocalEncryptionError.ioFailed
            }

            let plainChunk = try openChunk(diskBytes: diskBytes, chunkPlainLen: chunkPlainLen, header: header, chunkIndex: UInt64(chunkIdx))

            let sliceLower = Int(max(0, lower - chunkPlainStart))
            let sliceUpper = Int(min(Int64(chunkPlainLen), upper - chunkPlainStart))
            if sliceLower == 0 && sliceUpper == chunkPlainLen {
                result.append(plainChunk)
            } else {
                result.append(plainChunk.subdata(in: sliceLower ..< sliceUpper))
            }
        }
        return result
    }

    public static func decryptFile(fromPath: String, toPath: String, keys: YougramVaultKeyMaterial, protection: FileProtectionType? = nil) throws {
        let inFd = Darwin.open(fromPath, O_RDONLY)
        guard inFd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        defer { Darwin.close(inFd) }
        guard let header = self.readHeader(fd: inFd, keys: keys) else {
            throw YougramLocalEncryptionError.authenticationFailed
        }

        let tmpPath = toPath + ".ygtmp-\(UUID().uuidString)"
        let outFd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard outFd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        var cleanupTmp = true
        defer {
            Darwin.close(outFd)
            if cleanupTmp {
                Darwin.unlink(tmpPath)
            }
        }

        if let protection {
            let _ = try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: tmpPath)
        }

        let chunkSize = Int64(header.chunkSize)
        let totalChunks = header.chunkCount
        let stride = Int64(header.chunkSize + header.tagSize)
        for chunkIdx in 0 ..< totalChunks {
            let chunkPlainStart = chunkIdx * chunkSize
            let chunkPlainLen = Int(min(chunkSize, header.plaintextSize - chunkPlainStart))
            let diskOffset = Int64(header.headerSize) + chunkIdx * stride
            let diskLen = chunkPlainLen + header.tagSize

            var diskBytes = Data(count: diskLen)
            let readLen = diskBytes.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return preadFull(fd: inFd, buffer: base, count: diskLen, offset: diskOffset)
            }
            guard readLen == diskLen else {
                throw YougramLocalEncryptionError.ioFailed
            }

            let plainChunk = try openChunk(diskBytes: diskBytes, chunkPlainLen: chunkPlainLen, header: header, chunkIndex: UInt64(chunkIdx))

            let ok = plainChunk.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                return writeFull(fd: outFd, buffer: base, count: plainChunk.count)
            }
            guard ok else { throw YougramLocalEncryptionError.ioFailed }
        }

        Darwin.fsync(outFd)
        guard Darwin.rename(tmpPath, toPath) == 0 else {
            throw YougramLocalEncryptionError.ioFailed
        }
        cleanupTmp = false
    }

    // MARK: - AES-256-CTR for sparse partial files

    public static func derivePartialKey(mediaKey: Data, salt: Data) -> Data {
        return YougramVaultKeyMaterial.hkdfSHA512(
            ikm: SymmetricKey(data: mediaKey),
            salt: salt,
            info: "ygpr.partial.v2",
            count: 32
        )
    }

    public static func transformPartialBytes(
        input: UnsafePointer<UInt8>,
        count: Int,
        fileOffset: Int64,
        salt: Data,
        iv: Data,
        mediaKey: Data,
        output: UnsafeMutablePointer<UInt8>
    ) -> Bool {
        if count == 0 { return true }
        guard count > 0, fileOffset >= 0, salt.count == 32, iv.count == 16, mediaKey.count == 32 else {
            return false
        }
        let partialKey = derivePartialKey(mediaKey: mediaKey, salt: salt)
        let firstBlock = UInt64(fileOffset / 16)
        let firstBlockByteOffset = Int(fileOffset % 16)
        let lastBlock = UInt64((fileOffset + Int64(count) - 1) / 16)
        let totalBlocks = Int(lastBlock - firstBlock + 1)

        let batchBlocks = 256
        var counterBlocks = [UInt8](repeating: 0, count: batchBlocks * 16)
        var keystreamBlocks = [UInt8](repeating: 0, count: batchBlocks * 16)
        var ivBytes = [UInt8](iv)

        var processed = 0
        var blockOffset = 0
        while blockOffset < totalBlocks {
            let currentBlocks = min(batchBlocks, totalBlocks - blockOffset)
            for i in 0 ..< currentBlocks {
                let blockIndex = firstBlock + UInt64(blockOffset + i)
                let baseIdx = i * 16
                for b in 0 ..< 16 {
                    counterBlocks[baseIdx + b] = ivBytes[b]
                }
                addToBigEndian128(&counterBlocks, offset: baseIdx, addend: blockIndex)
            }

            var outLen = 0
            let status = partialKey.withUnsafeBytes { keyRaw -> CCCryptorStatus in
                guard let keyPtr = keyRaw.baseAddress else { return CCCryptorStatus(kCCParamError) }
                return CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr,
                    32,
                    nil,
                    &counterBlocks,
                    currentBlocks * 16,
                    &keystreamBlocks,
                    currentBlocks * 16,
                    &outLen
                )
            }
            guard status == kCCSuccess, outLen == currentBlocks * 16 else {
                return false
            }

            let ksStart = (blockOffset == 0) ? firstBlockByteOffset : 0
            let ksAvailable = outLen - ksStart
            let toXor = min(count - processed, ksAvailable)
            for j in 0 ..< toXor {
                output[processed + j] = input[processed + j] ^ keystreamBlocks[ksStart + j]
            }
            processed += toXor
            blockOffset += currentBlocks
        }
        ivBytes.withUnsafeMutableBufferPointer { ptr in
            if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
        }
        return processed == count
    }

    public static func convertPartialToChunked(
        partialPath: String,
        plaintextSize: Int64,
        salt: Data,
        iv: Data,
        originalFileName: String,
        toCompletePath path: String,
        keys: YougramVaultKeyMaterial
    ) throws {
        let inFd = Darwin.open(partialPath, O_RDONLY)
        guard inFd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        defer { Darwin.close(inFd) }

        let fileSalt = try randomBytes(32)
        let (aesKey, chachaKey) = deriveFileKeysV2(mediaKey: keys.mediaKey, fileSalt: fileSalt)
        let chunkSize = defaultChunkSize
        let header = makeHeaderBytesV2(chunkSize: UInt32(chunkSize), plaintextSize: UInt64(plaintextSize), fileSalt: fileSalt, mediaHeaderKey: keys.mediaHeaderKey)

        let tmpPath = path + ".ygtmp-\(UUID().uuidString)"
        let outFd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard outFd >= 0 else { throw YougramLocalEncryptionError.ioFailed }
        var cleanupTmp = true
        defer {
            Darwin.close(outFd)
            if cleanupTmp {
                Darwin.unlink(tmpPath)
            }
        }

        let headerOk = header.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: outFd, buffer: base, count: header.count)
        }
        guard headerOk else { throw YougramLocalEncryptionError.ioFailed }

        var cipherChunk = Data(count: chunkSize)
        var plainChunk = Data(count: chunkSize)
        var fileOffset: Int64 = 0
        var chunkIndex: UInt64 = 0

        while fileOffset < plaintextSize {
            let toRead = Int(min(Int64(chunkSize), plaintextSize - fileOffset))
            let actual = cipherChunk.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return preadFull(fd: inFd, buffer: base, count: toRead, offset: fileOffset)
            }
            guard actual == toRead else { throw YougramLocalEncryptionError.ioFailed }

            let transformed = cipherChunk.withUnsafeBytes { src -> Bool in
                plainChunk.withUnsafeMutableBytes { dst -> Bool in
                    guard let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return false
                    }
                    return transformPartialBytes(input: s, count: toRead, fileOffset: fileOffset, salt: salt, iv: iv, mediaKey: keys.mediaKey, output: d)
                }
            }
            guard transformed else { throw YougramLocalEncryptionError.authenticationFailed }

            let out = try sealChunkV2(plainChunk.prefix(toRead), aesKey: aesKey, chachaKey: chachaKey, fileSalt: fileSalt, index: chunkIndex, plaintextSize: UInt64(plaintextSize))
            let ok = out.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                return writeFull(fd: outFd, buffer: base, count: out.count)
            }
            guard ok else { throw YougramLocalEncryptionError.ioFailed }

            fileOffset += Int64(toRead)
            chunkIndex &+= 1
        }

        let trailer = try makeTrailerV2(originalFileName: originalFileName, fileSalt: fileSalt, aesKey: aesKey, chachaKey: chachaKey)
        let trailerOk = trailer.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return writeFull(fd: outFd, buffer: base, count: trailer.count)
        }
        guard trailerOk else { throw YougramLocalEncryptionError.ioFailed }

        Darwin.fsync(outFd)
        guard Darwin.rename(tmpPath, path) == 0 else {
            throw YougramLocalEncryptionError.ioFailed
        }
        cleanupTmp = false
    }
}

private func addToBigEndian128(_ bytes: inout [UInt8], offset: Int, addend: UInt64) {
    var carry = addend
    var idx = 15
    while idx >= 0 && carry > 0 {
        let sum = UInt64(bytes[offset + idx]) + (carry & 0xff)
        bytes[offset + idx] = UInt8(sum & 0xff)
        carry = (carry >> 8) + (sum >> 8)
        idx -= 1
    }
}

private func preadFull(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int, offset: Int64) -> Int {
    var total = 0
    while total < count {
        let n = Darwin.pread(fd, buffer.advanced(by: total), count - total, offset + Int64(total))
        if n > 0 {
            total += n
        } else if n == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            return -1
        }
    }
    return total
}

private func readExactOrEOF(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) -> Int {
    var total = 0
    while total < count {
        let n = Darwin.read(fd, buffer.advanced(by: total), count - total)
        if n > 0 {
            total += n
        } else if n == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            return -1
        }
    }
    return total
}

private func writeFull(fd: Int32, buffer: UnsafeRawPointer, count: Int) -> Bool {
    var total = 0
    while total < count {
        let n = Darwin.write(fd, buffer.advanced(by: total), count - total)
        if n > 0 {
            total += n
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

/// LRU-capped ephemeral decrypted media cache stored inside `NSTemporaryDirectory()/yg-session-<random>/`
/// with `FileProtectionType.complete` and synchronously purged on launch, backgrounding, lock, and termination.
public final class YougramEphemeralMediaCache: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let encryptedPath: String
        let pathExtension: String
    }

    private struct SourceStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int
        let fileSize: Int64
    }

    private final class Entry {
        let key: CacheKey
        let ephemeralPath: String
        let plaintextSize: Int64
        let stamp: SourceStamp
        var lastAccess: UInt64

        init(key: CacheKey, ephemeralPath: String, plaintextSize: Int64, stamp: SourceStamp, lastAccess: UInt64) {
            self.key = key
            self.ephemeralPath = ephemeralPath
            self.plaintextSize = plaintextSize
            self.stamp = stamp
            self.lastAccess = lastAccess
        }
    }

    private let lock = NSLock()
    private let maxBytes: Int64 = 128 * 1024 * 1024
    private var sessionRoot: String?
    private var entries: [CacheKey: Entry] = [:]
    private var totalBytes: Int64 = 0
    private var accessCounter: UInt64 = 0

    public init() {
    }

    private static func normalizedTmpDir() -> String {
        let tmp = NSTemporaryDirectory()
        return tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp
    }

    private func ensureSessionRootLocked() -> String {
        if let existing = self.sessionRoot {
            return existing
        }
        let rand = (try? randomBytes(8)) ?? Data((0 ..< 8).map { _ in UInt8.random(in: 0 ... 255) })
        let hex = rand.map { String(format: "%02x", $0) }.joined()
        let path = Self.normalizedTmpDir() + "/yg-session-" + hex
        let _ = try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        self.sessionRoot = path
        return path
    }

    public func ephemeralSubdirectory(_ name: String) -> String {
        self.lock.lock()
        let root = self.ensureSessionRootLocked()
        self.lock.unlock()
        let cleanName = name.replacingOccurrences(of: "/", with: "_")
        let dir = root + "/" + cleanName
        let _ = try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        return dir
    }

    public func ephemeralTempFilePath(pathExtension: String? = nil) -> String {
        self.lock.lock()
        let root = self.ensureSessionRootLocked()
        self.lock.unlock()
        let rand = UUID().uuidString
        if let ext = pathExtension, !ext.isEmpty {
            return root + "/tmp-" + rand + "." + ext
        }
        return root + "/tmp-" + rand
    }

    private func sourceStamp(for path: String) -> SourceStamp? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return SourceStamp(
            device: UInt64(UInt32(bitPattern: st.st_dev)),
            inode: UInt64(st.st_ino),
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            fileSize: Int64(st.st_size)
        )
    }

    public func materialize(encryptedPath: String, pathExtension: String?, keys: YougramVaultKeyMaterial) -> (path: String, size: Int64)? {
        guard let stamp = self.sourceStamp(for: encryptedPath) else {
            return nil
        }
        let ext = pathExtension ?? ""
        let cacheKey = CacheKey(encryptedPath: encryptedPath, pathExtension: ext)

        self.lock.lock()
        if let existing = self.entries[cacheKey], existing.stamp == stamp, FileManager.default.fileExists(atPath: existing.ephemeralPath) {
            self.accessCounter &+= 1
            existing.lastAccess = self.accessCounter
            let result = (existing.ephemeralPath, existing.plaintextSize)
            self.lock.unlock()
            return result
        }
        let root = self.ensureSessionRootLocked()
        self.lock.unlock()

        guard let header = YougramChunkedFileCrypto.readHeader(atPath: encryptedPath, keys: keys) else {
            return nil
        }
        let digest = SHA256.hash(data: Data((encryptedPath + "\0" + ext).utf8))
        let nameHex = digest.map { String(format: "%02x", $0) }.joined()
        let targetPath = ext.isEmpty ? (root + "/" + nameHex) : (root + "/" + nameHex + "." + ext)

        do {
            try YougramChunkedFileCrypto.decryptFile(fromPath: encryptedPath, toPath: targetPath, keys: keys, protection: .complete)
        } catch {
            return nil
        }

        self.lock.lock()
        defer { self.lock.unlock() }
        // If purged concurrently, drop the newly decrypted file immediately.
        guard self.sessionRoot == root else {
            Darwin.unlink(targetPath)
            return nil
        }
        if let prev = self.entries.removeValue(forKey: cacheKey) {
            self.totalBytes = max(0, self.totalBytes - prev.plaintextSize)
        }
        self.accessCounter &+= 1
        let entry = Entry(key: cacheKey, ephemeralPath: targetPath, plaintextSize: header.plaintextSize, stamp: stamp, lastAccess: self.accessCounter)
        self.entries[cacheKey] = entry
        self.totalBytes += header.plaintextSize
        self.evictIfNeededLocked(preserving: cacheKey)
        return (targetPath, header.plaintextSize)
    }

    private func evictIfNeededLocked(preserving: CacheKey) {
        guard self.totalBytes > self.maxBytes else { return }
        let sorted = self.entries.values.sorted { $0.lastAccess < $1.lastAccess }
        for entry in sorted {
            if self.totalBytes <= self.maxBytes {
                break
            }
            if entry.key == preserving {
                continue
            }
            self.entries.removeValue(forKey: entry.key)
            self.totalBytes = max(0, self.totalBytes - entry.plaintextSize)
            Darwin.unlink(entry.ephemeralPath)
        }
    }

    public func evict(encryptedPath: String) {
        self.lock.lock()
        var pathsToRemove: [String] = []
        let matchingKeys = self.entries.keys.filter { $0.encryptedPath == encryptedPath }
        for key in matchingKeys {
            if let entry = self.entries.removeValue(forKey: key) {
                self.totalBytes = max(0, self.totalBytes - entry.plaintextSize)
                pathsToRemove.append(entry.ephemeralPath)
            }
        }
        self.lock.unlock()
        for path in pathsToRemove {
            Darwin.unlink(path)
        }
    }

    public func purgeAllSessions() {
        self.lock.lock()
        self.entries.removeAll()
        self.totalBytes = 0
        self.sessionRoot = nil
        self.lock.unlock()

        let tmpDir = Self.normalizedTmpDir()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for item in contents where item.hasPrefix("yg-session-") {
                let _ = try? FileManager.default.removeItem(atPath: tmpDir + "/" + item)
            }
        }
    }
}

/// Process-wide coordinator for active Postbox / MediaBox / StorageBox encryption keys.
/// `current` is nil when Local Encryption is disabled, leaving upstream behaviour untouched.
public enum PostboxLocalEncryption {
    private static let lock = NSLock()
    private static var _current: YougramVaultKeyMaterial?

    public static let ephemeralCache = YougramEphemeralMediaCache()

    public static var current: YougramVaultKeyMaterial? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._current
    }

    public static var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._current != nil
    }

    @discardableResult
    public static func activate(masterKey: Data, version: Int = 2) -> YougramVaultKeyMaterial {
        let material = YougramVaultKeyMaterial(masterKey: masterKey, version: version)
        self.lock.lock()
        let previous = self._current
        self._current = material
        self.lock.unlock()
        previous?.invalidate()
        return material
    }

    public static func deactivate() {
        self.lock.lock()
        let previous = self._current
        self._current = nil
        self.lock.unlock()
        previous?.invalidate()
        self.ephemeralCache.purgeAllSessions()
    }

    public static func hmacHex128(_ string: String, key: Data, useSHA512: Bool = false) -> String {
        let bytes: [UInt8]
        if useSHA512 {
            let mac = HMAC<SHA512>.authenticationCode(for: Data(string.utf8), using: SymmetricKey(data: key))
            bytes = Array(mac.prefix(16))
        } else {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: SymmetricKey(data: key))
            bytes = Array(mac.prefix(16))
        }
        var result = ""
        result.reserveCapacity(32)
        for byte in bytes {
            result.append(String(format: "%02x", byte))
        }
        return result
    }

    public static func obfuscatedFileName(for logicalName: String, keys: YougramVaultKeyMaterial) -> String {
        if logicalName.hasPrefix("enc_") {
            return logicalName
        }
        return "enc_" + hmacHex128(logicalName, key: keys.mediaFilenameKey, useSHA512: keys.version >= 2)
    }
}
