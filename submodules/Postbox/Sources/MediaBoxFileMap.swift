import Foundation
import Security
import RangeSet
import Crc32

final class MediaBoxFileMap {
    enum FileMapError: Error {
        case generic
    }
    
    private(set) var sum: Int64
    private(set) var ranges: RangeSet<Int64>
    private(set) var truncationSize: Int64?
    private(set) var progress: Float?
    // Yougram: AES-256-CTR partial encryption material stored inside the sealed file map.
    private(set) var partialSalt: Data?
    private(set) var partialIV: Data?

    private static func randomMaterial(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if status != errSecSuccess {
            bytes.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress {
                    arc4random_buf(base, count)
                }
            }
        }
        return bytes
    }

    init() {
        self.sum = 0
        self.ranges = RangeSet<Int64>()
        self.truncationSize = nil
        self.progress = nil
        if PostboxLocalEncryption.isActive {
            self.partialSalt = Self.randomMaterial(32)
            self.partialIV = Self.randomMaterial(16)
        } else {
            self.partialSalt = nil
            self.partialIV = nil
        }
    }
    
    private init(
        sum: Int64,
        ranges: RangeSet<Int64>,
        truncationSize: Int64?,
        progress: Float?,
        partialSalt: Data? = nil,
        partialIV: Data? = nil
    ) {
        self.sum = sum
        self.ranges = ranges
        self.truncationSize = truncationSize
        self.progress = progress
        self.partialSalt = partialSalt
        self.partialIV = partialIV
    }

    private static func decodeEncryptedBlob(_ data: Data, keys: YougramVaultKeyMaterial) throws -> MediaBoxFileMap {
        let plain = try YougramEncryptedBlob.open(data, key: keys.mediaKey, aad: "ygm1")
        guard plain.count >= 12 else {
            throw FileMapError.generic
        }
        var magic: UInt32 = 0
        var crc: UInt32 = 0
        var count: Int32 = 0
        _ = withUnsafeMutableBytes(of: &magic) { plain.copyBytes(to: $0, from: 0 ..< 4) }
        _ = withUnsafeMutableBytes(of: &crc) { plain.copyBytes(to: $0, from: 4 ..< 8) }
        _ = withUnsafeMutableBytes(of: &count) { plain.copyBytes(to: $0, from: 8 ..< 12) }
        guard magic == 0x7bac1487, count >= 0 else {
            throw FileMapError.generic
        }
        let payloadLength = 8 + Int64(count) * 16
        guard Int64(plain.count) >= 12 + payloadLength else {
            throw FileMapError.generic
        }
        let payloadEnd = 12 + Int(payloadLength)
        let payload = plain.subdata(in: 12 ..< payloadEnd)
        let calculatedCrc = payload.withUnsafeBytes { raw -> UInt32 in
            return Crc32(raw.baseAddress!, Int32(payload.count))
        }
        guard calculatedCrc == crc else {
            throw FileMapError.generic
        }
        var truncationSizeValue: Int64 = 0
        var sum: Int64 = 0
        var ranges = RangeSet<Int64>()
        payload.withUnsafeBytes { raw in
            let bytes = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            memcpy(&truncationSizeValue, bytes, 8)
            var offset = 8
            for _ in 0 ..< count {
                var intervalOffset: Int64 = 0
                var intervalLength: Int64 = 0
                memcpy(&intervalOffset, bytes.advanced(by: offset), 8)
                memcpy(&intervalLength, bytes.advanced(by: offset + 8), 8)
                offset += 16
                ranges.insert(contentsOf: intervalOffset ..< (intervalOffset + intervalLength))
                sum += intervalLength
            }
        }
        let mappedTruncationSize: Int64? = truncationSizeValue >= 0 ? truncationSizeValue : nil
        var salt: Data?
        var iv: Data?
        if plain.count == payloadEnd + 1 + 32 + 16, plain[payloadEnd] == 0x59 {
            salt = plain.subdata(in: (payloadEnd + 1) ..< (payloadEnd + 33))
            iv = plain.subdata(in: (payloadEnd + 33) ..< (payloadEnd + 49))
        }
        return MediaBoxFileMap(
            sum: sum,
            ranges: ranges,
            truncationSize: mappedTruncationSize,
            progress: nil,
            partialSalt: salt,
            partialIV: iv
        )
    }
    
    static func read(manager: MediaBoxFileManager, path: String) throws -> MediaBoxFileMap {
        guard let length = fileSize(path) else {
            throw FileMapError.generic
        }
        // Yougram: read sealed file maps when local encryption is active (and reject plaintext maps when active).
        if let keys = PostboxLocalEncryption.current {
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)), YougramEncryptedBlob.isEncrypted(raw) else {
                throw FileMapError.generic
            }
            return try Self.decodeEncryptedBlob(raw, keys: keys)
        }
        guard let fileItem = manager.open(path: path, mode: .readwrite) else {
            throw FileMapError.generic
        }
        
        var result: MediaBoxFileMap?
        
        try fileItem.access { fd in
            var firstUInt32: UInt32 = 0
            guard fd.read(&firstUInt32, 4) == 4 else {
                throw FileMapError.generic
            }
            
            if firstUInt32 == 0x7bac1487 {
                var crc: UInt32 = 0
                guard fd.read(&crc, 4) == 4 else {
                    throw FileMapError.generic
                }
                
                var count: Int32 = 0
                var sum: Int64 = 0
                var ranges = RangeSet<Int64>()
                
                guard fd.read(&count, 4) == 4 else {
                    throw FileMapError.generic
                }
                
                if count < 0 {
                    throw FileMapError.generic
                }
                
                // `count` comes straight from the file. Size the payload in 64-bit
                // arithmetic: `count * 2 * 8` in Int32 overflows (and traps) for any
                // count of 2^27 or more, before the checksum gets a chance to reject
                // the file. The legacy branch below already widens the same way.
                let payloadLength: Int64 = 8 + Int64(count) * 2 * 8
                if length < 4 + 4 + 4 + payloadLength {
                    throw FileMapError.generic
                }
                
                var truncationSizeValue: Int64 = 0
                
                var data = Data(count: Int(payloadLength))
                let dataCount = data.count
                if !(data.withUnsafeMutableBytes { rawBytes -> Bool in
                    let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

                    guard fd.read(bytes, dataCount) == dataCount else {
                        return false
                    }
                    
                    memcpy(&truncationSizeValue, bytes, 8)
                    
                    let calculatedCrc = Crc32(bytes, Int32(dataCount))
                    if calculatedCrc != crc {
                        return false
                    }
                    
                    var offset = 8
                    for _ in 0 ..< count {
                        var intervalOffset: Int64 = 0
                        var intervalLength: Int64 = 0
                        memcpy(&intervalOffset, bytes.advanced(by: offset), 8)
                        memcpy(&intervalLength, bytes.advanced(by: offset + 8), 8)
                        offset += 8 * 2
                        
                        ranges.insert(contentsOf: intervalOffset ..< (intervalOffset + intervalLength))
                        
                        sum += intervalLength
                    }
                    
                    return true
                }) {
                    throw FileMapError.generic
                }
                
                let mappedTruncationSize: Int64?
                if truncationSizeValue == -1 {
                    mappedTruncationSize = nil
                } else if truncationSizeValue < 0 {
                    mappedTruncationSize = nil
                } else {
                    mappedTruncationSize = truncationSizeValue
                }

                result = MediaBoxFileMap(
                    sum: sum,
                    ranges: ranges,
                    truncationSize: mappedTruncationSize,
                    progress: nil
                )
            } else {
                let crc: UInt32 = firstUInt32
                var count: Int32 = 0
                var sum: Int32 = 0
                var ranges = RangeSet<Int64>()
                
                guard fd.read(&count, 4) == 4 else {
                    throw FileMapError.generic
                }
                
                if count < 0 {
                    throw FileMapError.generic
                }
                
                if count < 0 || UInt64(length) < 4 + 4 + UInt64(count) * 2 * 4 {
                    throw FileMapError.generic
                }
                
                var truncationSizeValue: Int32 = 0
                
                var data = Data(count: Int(4 + count * 2 * 4))
                let dataCount = data.count
                if !(data.withUnsafeMutableBytes { rawBytes -> Bool in
                    let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

                    guard fd.read(bytes, dataCount) == dataCount else {
                        return false
                    }
                    
                    memcpy(&truncationSizeValue, bytes, 4)
                    
                    let calculatedCrc = Crc32(bytes, Int32(dataCount))
                    if calculatedCrc != crc {
                        return false
                    }
                    
                    var offset = 4
                    for _ in 0 ..< count {
                        var intervalOffset: Int32 = 0
                        var intervalLength: Int32 = 0
                        memcpy(&intervalOffset, bytes.advanced(by: offset), 4)
                        memcpy(&intervalLength, bytes.advanced(by: offset + 4), 4)
                        offset += 8
                        
                        ranges.insert(contentsOf: Int64(intervalOffset) ..< Int64(intervalOffset + intervalLength))
                        
                        sum += intervalLength
                    }
                    
                    return true
                }) {
                    throw FileMapError.generic
                }
                
                let mappedTruncationSize: Int64?
                if truncationSizeValue == -1 {
                    mappedTruncationSize = nil
                } else {
                    mappedTruncationSize = Int64(truncationSizeValue)
                }
                
                result = MediaBoxFileMap(
                    sum: Int64(sum),
                    ranges: ranges,
                    truncationSize: mappedTruncationSize,
                    progress: nil
                )
            }
        }
        
        guard let result = result else {
            throw FileMapError.generic
        }
        return result
    }
    
    func serialize(manager: MediaBoxFileManager, to path: String) {
        let buffer = WriteBuffer()
        var magic: UInt32 = 0x7bac1487
        buffer.write(&magic, offset: 0, length: 4)
        
        var zero: Int32 = 0
        buffer.write(&zero, offset: 0, length: 4)
        
        let rangeView = self.ranges.ranges
        var count: Int32 = Int32(rangeView.count)
        buffer.write(&count, offset: 0, length: 4)
        
        var truncationSizeValue: Int64 = self.truncationSize ?? -1
        buffer.write(&truncationSizeValue, offset: 0, length: 8)
        
        for range in rangeView {
            var intervalOffset = range.lowerBound
            var intervalLength = range.upperBound - range.lowerBound
            buffer.write(&intervalOffset, offset: 0, length: 8)
            buffer.write(&intervalLength, offset: 0, length: 8)
        }
        var crc: UInt32 = Crc32(buffer.memory.advanced(by: 4 + 4 + 4), Int32(buffer.length - (4 + 4 + 4)))
        memcpy(buffer.memory.advanced(by: 4), &crc, 4)

        // Yougram: seal file map + CTR salt/iv atomically when local encryption is active.
        if let keys = PostboxLocalEncryption.current {
            if self.partialSalt == nil || self.partialSalt?.count != 32 {
                self.partialSalt = Self.randomMaterial(32)
            }
            if self.partialIV == nil || self.partialIV?.count != 16 {
                self.partialIV = Self.randomMaterial(16)
            }
            var marker: UInt8 = 0x59
            buffer.write(&marker, offset: 0, length: 1)
            if let salt = self.partialSalt, let iv = self.partialIV {
                salt.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { buffer.write(base, offset: 0, length: 32) }
                }
                iv.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { buffer.write(base, offset: 0, length: 16) }
                }
            }
            let plainData = Data(bytes: buffer.memory, count: buffer.length)
            if let sealed = try? YougramEncryptedBlob.seal(plainData, key: keys.mediaKey, aad: "ygm1") {
                let _ = try? sealed.write(to: URL(fileURLWithPath: path), options: [.atomic])
            }
            return
        }

        guard let fileItem = manager.open(path: path, mode: .readwrite) else {
            postboxLog("MediaBoxFile: serialize: cannot open file")
            return
        }
        
        let _ = try? fileItem.access { file in
            let _ = file.seek(position: 0)
            let written = file.write(buffer.memory, count: buffer.length)
            assert(written == buffer.length)
        }
    }
    
    func fill(_ range: Range<Int64>) {
        var previousCount: Int64 = 0
        for intersectionRange in self.ranges.intersection(RangeSet<Int64>(range)).ranges {
            previousCount += intersectionRange.upperBound - intersectionRange.lowerBound
        }
        
        self.ranges.insert(contentsOf: range)
        self.sum += (range.upperBound - range.lowerBound) - previousCount
    }
    
    func truncate(_ size: Int64) {
        self.truncationSize = size
    }
    func progressUpdated(_ progress: Float) {
        self.progress = progress
    }
    
    func reset() {
        self.truncationSize = nil
        self.ranges = RangeSet<Int64>()
        self.sum = 0
        self.progress = nil
        if PostboxLocalEncryption.isActive {
            self.partialSalt = Self.randomMaterial(32)
            self.partialIV = Self.randomMaterial(16)
        } else {
            self.partialSalt = nil
            self.partialIV = nil
        }
    }
    
    func contains(_ range: Range<Int64>) -> Range<Int64>? {
        let maxValue: Int64
        if let truncationSize = self.truncationSize {
            maxValue = truncationSize
        } else {
            maxValue = Int64.max
        }
        let clippedUpperBound = min(maxValue, range.upperBound)
        let clippedRange: Range<Int64> = min(range.lowerBound, clippedUpperBound) ..< clippedUpperBound
        let clippedRangeSet = RangeSet<Int64>(clippedRange)
        
        if self.ranges.isSuperset(of: clippedRangeSet) {
            return clippedRange
        } else {
            return nil
        }
    }
}
