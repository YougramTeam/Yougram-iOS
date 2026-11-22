import Foundation
import CryptoKit
import XCTest
import SwiftSignalKit
import sqlcipher
@testable import Postbox

final class YougramLocalEncryptionTests: XCTestCase {
    private var queue: Queue!
    private var tempRoot: String!
    private var openedBoxes: [SqliteValueBox] = []

    override func setUp() {
        super.setUp()
        self.queue = Queue(name: "YougramLocalEncryptionTests")
        self.tempRoot = NSTemporaryDirectory() + "YougramLocalEncryptionTests-" + UUID().uuidString
        let _ = try? FileManager.default.createDirectory(atPath: self.tempRoot, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDown() {
        PostboxLocalEncryption.deactivate()
        self.queue.sync {
            for box in self.openedBoxes {
                box.internalClose()
            }
            self.openedBoxes.removeAll()
        }
        let _ = try? FileManager.default.removeItem(atPath: self.tempRoot)
        super.tearDown()
    }

    private func makeMasterKey(fill byte: UInt8 = 0xA5) -> Data {
        return Data((0 ..< 32).map { UInt8((Int(byte) + $0) & 0xff) })
    }

    func testKeyMaterialDomainSeparationAndZeroize() {
        let material = YougramVaultKeyMaterial(masterKey: self.makeMasterKey())
        let dbKeys = [
            material.postboxDatabaseParameters.key.data,
            material.accountManagerDatabaseParameters.key.data,
            material.accountManagerGuardDatabaseParameters.key.data,
            material.storageBoxDatabaseParameters.key.data
        ]
        XCTAssertEqual(Set(dbKeys).count, dbKeys.count)

        let dataKeys = [
            material.atomicStateKey,
            material.loginTokensKey,
            material.mediaKey,
            material.mediaHeaderKey,
            material.mediaFilenameKey
        ]
        XCTAssertEqual(Set(dataKeys).count, dataKeys.count)

        material.invalidate()
        XCTAssertTrue(material.mediaKey.allSatisfy { $0 == 0 })
        XCTAssertTrue(material.postboxDatabaseParameters.key.data.allSatisfy { $0 == 0 })
    }

    func testEncryptedBlobRoundtripAndTamperRejection() throws {
        let material = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x33))
        defer { material.invalidate() }

        let plaintext = Data("hello yougram secret state".utf8)
        let sealed = try YougramEncryptedBlob.seal(plaintext, key: material.atomicStateKey, aad: "ygas1")
        XCTAssertTrue(YougramEncryptedBlob.isEncrypted(sealed))
        XCTAssertFalse(sealed.range(of: plaintext) != nil)

        let opened = try YougramEncryptedBlob.open(sealed, key: material.atomicStateKey, aad: "ygas1")
        XCTAssertEqual(opened, plaintext)

        XCTAssertThrowsError(try YougramEncryptedBlob.open(sealed, key: material.loginTokensKey, aad: "ygas1"))
        XCTAssertThrowsError(try YougramEncryptedBlob.open(sealed, key: material.atomicStateKey, aad: "wrong-aad"))

        var tampered = sealed
        tampered[tampered.count - 5] ^= 0xff
        XCTAssertThrowsError(try YougramEncryptedBlob.open(tampered, key: material.atomicStateKey, aad: "ygas1"))
    }

    func testChunkedFileCryptoEmptySmallMultiChunkRangeAndTrailer() throws {
        let keys = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x17))
        defer { keys.invalidate() }

        // Empty file
        let emptyPath = self.tempRoot + "/empty.ygcf"
        try YougramChunkedFileCrypto.encryptData(Data(), originalFileName: "empty-id", toPath: emptyPath, keys: keys)
        XCTAssertTrue(YougramChunkedFileCrypto.isChunkedFile(atPath: emptyPath))
        XCTAssertEqual(YougramChunkedFileCrypto.plaintextSize(atPath: emptyPath, keys: keys), 0)
        XCTAssertEqual(YougramChunkedFileCrypto.originalFileName(atPath: emptyPath, keys: keys), "empty-id")
        XCTAssertEqual(try YougramChunkedFileCrypto.decryptData(fromPath: emptyPath, keys: keys), Data())

        // Multi-chunk (~150 KiB across 3 x 64 KiB chunks)
        let multiCount = 150_000
        let multiData = Data((0 ..< multiCount).map { UInt8(($0 * 31 + 7) & 0xff) })
        let multiPath = self.tempRoot + "/multi.ygcf"
        try YougramChunkedFileCrypto.encryptData(multiData, originalFileName: "orig-resource-id", toPath: multiPath, keys: keys)
        XCTAssertEqual(YougramChunkedFileCrypto.plaintextSize(atPath: multiPath, keys: keys), Int64(multiCount))
        XCTAssertEqual(try YougramChunkedFileCrypto.decryptData(fromPath: multiPath, keys: keys), multiData)

        // Cross-chunk range read (spanning chunk 0 -> chunk 2)
        let sliceRange: Range<Int64> = 65_000 ..< 132_000
        let slice = try YougramChunkedFileCrypto.decryptRange(fromPath: multiPath, range: sliceRange, keys: keys)
        XCTAssertEqual(slice, multiData.subdata(in: Int(sliceRange.lowerBound) ..< Int(sliceRange.upperBound)))

        // Pointer buffer range read
        var ptrBuf = [UInt8](repeating: 0, count: 5000)
        let readCount = ptrBuf.withUnsafeMutableBufferPointer { buf in
            return YougramChunkedFileCrypto.decryptRange(
                fromPath: multiPath,
                range: 65_500 ..< 70_500,
                into: buf.baseAddress!,
                maxCount: buf.count,
                keys: keys
            )
        }
        XCTAssertEqual(readCount, 5000)
        XCTAssertEqual(Data(ptrBuf), multiData.subdata(in: 65_500 ..< 70_500))

        // Trailer rename & verification
        XCTAssertTrue(YougramChunkedFileCrypto.updateOriginalFileName(atPath: multiPath, newOriginalFileName: "renamed-resource-id", keys: keys))
        XCTAssertEqual(YougramChunkedFileCrypto.originalFileName(atPath: multiPath, keys: keys), "renamed-resource-id")
        XCTAssertEqual(try YougramChunkedFileCrypto.decryptData(fromPath: multiPath, keys: keys), multiData)

        // Wrong key rejection & byte-flip tamper detection
        let wrongKeys = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x99))
        defer { wrongKeys.invalidate() }
        XCTAssertNil(YougramChunkedFileCrypto.plaintextSize(atPath: multiPath, keys: wrongKeys))
        XCTAssertThrowsError(try YougramChunkedFileCrypto.decryptData(fromPath: multiPath, keys: wrongKeys))

        var corrupted = try Data(contentsOf: URL(fileURLWithPath: multiPath))
        corrupted[100] ^= 0x01
        let corruptedPath = self.tempRoot + "/corrupted.ygcf"
        try corrupted.write(to: URL(fileURLWithPath: corruptedPath))
        XCTAssertThrowsError(try YougramChunkedFileCrypto.decryptData(fromPath: corruptedPath, keys: keys))
    }

    func testPartialCTROutOfOrderWritesAndConversion() throws {
        let keys = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x55))
        defer { keys.invalidate() }

        let salt = Data((0 ..< 32).map { UInt8(($0 + 1) & 0xff) })
        let iv = Data((0 ..< 16).map { UInt8(($0 + 9) & 0xff) })
        let fullPlain = Data((0 ..< 80_000).map { UInt8(($0 * 13 + 3) & 0xff) })

        let partialPath = self.tempRoot + "/partial.bin"
        let fd = Darwin.open(partialPath, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        Darwin.ftruncate(fd, Int64(fullPlain.count))

        // Write second half first, then first half at unaligned boundary.
        let split = 40_007
        for partRange in [split ..< fullPlain.count, 0 ..< split] {
            let chunk = fullPlain.subdata(in: partRange)
            var enc = [UInt8](repeating: 0, count: chunk.count)
            let ok = chunk.withUnsafeBytes { rawSrc in
                enc.withUnsafeMutableBufferPointer { dst in
                    return YougramChunkedFileCrypto.transformPartialBytes(
                        input: rawSrc.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        count: chunk.count,
                        fileOffset: Int64(partRange.lowerBound),
                        salt: salt,
                        iv: iv,
                        mediaKey: keys.mediaKey,
                        output: dst.baseAddress!
                    )
                }
            }
            XCTAssertTrue(ok)
            let written = enc.withUnsafeBufferPointer { buf in
                return Darwin.pwrite(fd, buf.baseAddress!, buf.count, Int64(partRange.lowerBound))
            }
            XCTAssertEqual(written, chunk.count)
        }
        Darwin.close(fd)

        let diskData = try Data(contentsOf: URL(fileURLWithPath: partialPath))
        XCTAssertNotEqual(diskData, fullPlain)

        let completePath = self.tempRoot + "/converted.ygcf"
        try YougramChunkedFileCrypto.convertPartialToChunked(
            partialPath: partialPath,
            plaintextSize: Int64(fullPlain.count),
            salt: salt,
            iv: iv,
            originalFileName: "partial-orig",
            toCompletePath: completePath,
            keys: keys
        )
        XCTAssertEqual(try YougramChunkedFileCrypto.decryptData(fromPath: completePath, keys: keys), fullPlain)
        XCTAssertEqual(YougramChunkedFileCrypto.originalFileName(atPath: completePath, keys: keys), "partial-orig")
    }

    func testEphemeralMediaCacheMaterializeEvictAndPurge() throws {
        let keys = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x71))
        defer { keys.invalidate() }

        let cache = YougramEphemeralMediaCache()
        let encPath = self.tempRoot + "/enc_sample"
        let payload = Data("ephemeral plaintext video payload".utf8)
        try YougramChunkedFileCrypto.encryptData(payload, originalFileName: "sample", toPath: encPath, keys: keys)

        let mat = cache.materialize(encryptedPath: encPath, pathExtension: "mp4", keys: keys)
        XCTAssertNotNil(mat)
        XCTAssertTrue(mat!.path.hasSuffix(".mp4"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: mat!.path)), payload)

        cache.evict(encryptedPath: encPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mat!.path))

        let mat2 = cache.materialize(encryptedPath: encPath, pathExtension: nil, keys: keys)
        XCTAssertNotNil(mat2)
        cache.purgeAllSessions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mat2!.path))
    }

    func testSqliteValueBoxRekeyStandaloneAndWrongKeyNoWipe() throws {
        let keys = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x22))
        defer { keys.invalidate() }

        let dbDir = self.tempRoot + "/testdb"
        let table = ValueBoxTable(id: 7, keyType: .int64, compactValuesOnCreation: false)
        let key = ValueBoxKey(length: 8)
        key.setInt64(0, value: 42)
        let secretPayload = Data("super-secret-message-text".utf8)

        self.queue.sync {
            let box = SqliteValueBox(
                basePath: dbDir,
                queue: self.queue,
                isTemporary: false,
                isReadOnly: false,
                useCaches: false,
                removeDatabaseOnError: true,
                encryptionParameters: nil,
                upgradeProgress: { _ in }
            )!
            box.begin()
            box.set(table, key: key, value: MemoryBuffer(data: secretPayload))
            box.commit()
            try! box.rekey(to: keys.postboxDatabaseParameters)
            box.internalClose()
        }

        let sqliteBytes = try Data(contentsOf: URL(fileURLWithPath: dbDir + "/db_sqlite"))
        XCTAssertNil(sqliteBytes.range(of: secretPayload))

        PostboxLocalEncryption.activate(masterKey: self.makeMasterKey(fill: 0x22))

        // Opening with wrong key while local encryption is active must fail closed WITHOUT wiping db_sqlite.
        self.queue.sync {
            let wrongParams = YougramVaultKeyMaterial(masterKey: self.makeMasterKey(fill: 0x99)).postboxDatabaseParameters
            let wrongBox = SqliteValueBox(
                basePath: dbDir,
                queue: self.queue,
                isTemporary: false,
                isReadOnly: false,
                useCaches: false,
                removeDatabaseOnError: true,
                encryptionParameters: wrongParams,
                upgradeProgress: { _ in }
            )
            XCTAssertNil(wrongBox)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbDir + "/db_sqlite"))

        // Standalone decrypt back to plaintext and verify contents intact.
        try SqliteValueBox.rekeyStandaloneDatabase(basePath: dbDir, from: keys.postboxDatabaseParameters, to: nil)
        PostboxLocalEncryption.deactivate()

        self.queue.sync {
            let plainBox = SqliteValueBox(
                basePath: dbDir,
                queue: self.queue,
                isTemporary: false,
                isReadOnly: false,
                useCaches: false,
                removeDatabaseOnError: true,
                encryptionParameters: nil,
                upgradeProgress: { _ in }
            )!
            self.openedBoxes.append(plainBox)
            plainBox.begin()
            let readBack = plainBox.get(table, key: key)?.makeData()
            plainBox.commit()
            XCTAssertEqual(readBack, secretPayload)
        }
    }

    func testMediaBoxMigrationRoundtrip() throws {
        let masterKey = self.makeMasterKey(fill: 0x44)
        let keys = YougramVaultKeyMaterial(masterKey: masterKey)
        defer { keys.invalidate() }

        let mediaDir = self.tempRoot + "/media"
        let resourceId = MediaResourceId("telegram-cloud-photo-size-2-123456-99")
        let resourcePayload = Data("unique-plaintext-photo-bytes-1234567890".utf8)
        let repPayload = Data("cached-thumbnail-payload".utf8)

        let mediaBox = MediaBox(basePath: mediaDir, isMainProcess: true)
        mediaBox.storeResourceData(resourceId, data: resourcePayload, synchronous: true)
        let plainRepPath = mediaBox.cachedRepresentationPathForId(resourceId.stringRepresentation, representationId: "thumb", keepDuration: .general)
        try repPayload.write(to: URL(fileURLWithPath: plainRepPath))

        try mediaBox.migrateMediaFiles(encrypt: true, keys: keys)
        PostboxLocalEncryption.activate(masterKey: masterKey)

        // Plaintext filename and plaintext bytes must be absent on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaDir + "/" + resourceId.stringRepresentation))
        let encPaths = mediaBox.storePathsForId(resourceId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: encPaths.complete))
        let encDisk = try Data(contentsOf: URL(fileURLWithPath: encPaths.complete))
        XCTAssertNil(encDisk.range(of: resourcePayload))

        let encRepPath = mediaBox.cachedRepresentationPathForId(resourceId.stringRepresentation, representationId: "thumb", keepDuration: .general)
        XCTAssertTrue(encRepPath.contains(":"))
        XCTAssertEqual(mediaBox.readEncryptedOrRawData(atPath: encRepPath), repPayload)

        let semaphore = DispatchSemaphore(value: 0)
        var rangedData: Data?
        let _ = mediaBox.resourceData(id: resourceId, size: Int64(resourcePayload.count), in: 7 ..< 21, attemptSynchronously: true).start(next: { data, complete in
            if complete {
                rangedData = data
                semaphore.signal()
            }
        })
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5.0), .success)
        XCTAssertEqual(rangedData, resourcePayload.subdata(in: 7 ..< 21))

        // Decrypt back to plaintext filenames & contents.
        try mediaBox.migrateMediaFiles(encrypt: false, keys: keys)
        PostboxLocalEncryption.deactivate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaDir + "/" + resourceId.stringRepresentation))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: mediaDir + "/" + resourceId.stringRepresentation)), resourcePayload)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plainRepPath)), repPayload)
    }

    func testV2KeySeparationCascadeBlobAndChunkedHeader() throws {
        let master = self.makeMasterKey(fill: 0x61)
        let v2 = YougramVaultKeyMaterial(masterKey: master, version: 2)
        let v1 = YougramVaultKeyMaterial(masterKey: master, version: 1)
        defer {
            v2.invalidate()
            v1.invalidate()
        }

        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v1.version, 1)
        XCTAssertNotEqual(v2.postboxDatabaseParameters.key.data, v1.postboxDatabaseParameters.key.data)
        XCTAssertNotEqual(v2.mediaKey, v1.mediaKey)
        XCTAssertNotEqual(v2.sharedMediaKey, v2.mediaKey)

        // YGE2 dual-cipher cascade roundtrip
        let secret = Data("dual-cipher-cascade-payload".utf8)
        let sealedV2 = try YougramEncryptedBlob.seal(secret, key: v2.atomicStateKey, aad: "ygas1")
        XCTAssertEqual(sealedV2.prefix(4), YougramEncryptedBlob.magicV2)
        XCTAssertEqual(try YougramEncryptedBlob.open(sealedV2, key: v2.atomicStateKey, aad: "ygas1"), secret)

        // Legacy YGE1 backward-compatibility open
        let nonce = AES.GCM.Nonce()
        let legacyCombined = try AES.GCM.seal(secret, using: SymmetricKey(data: v1.atomicStateKey), nonce: nonce, authenticating: Data("ygas1".utf8)).combined!
        var legacyBlob = YougramEncryptedBlob.magic
        legacyBlob.append(legacyCombined)
        XCTAssertTrue(YougramEncryptedBlob.isEncrypted(legacyBlob))
        XCTAssertEqual(try YougramEncryptedBlob.open(legacyBlob, key: v1.atomicStateKey, aad: "ygas1"), secret)

        // YGCF v2 header check
        let path = self.tempRoot + "/v2check.ygcf"
        let mediaData = Data(repeating: 0xAB, count: 1024)
        try YougramChunkedFileCrypto.encryptData(mediaData, originalFileName: "v2-name", toPath: path, keys: v2)
        let header = YougramChunkedFileCrypto.readHeader(atPath: path, keys: v2)
        XCTAssertEqual(header?.formatVersion, 2)
        XCTAssertEqual(header?.tagSize, 32)
        XCTAssertEqual(try YougramChunkedFileCrypto.decryptData(fromPath: path, keys: v2), mediaData)
    }
}
