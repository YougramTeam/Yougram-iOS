import Foundation

final class SharedAccountMediaManager {
    private let basePath: String
    
    init(basePath: String) {
        self.basePath = basePath
    }
    
    private func fileNameForId(_ id: MediaResourceId) -> String {
        if let keys = PostboxLocalEncryption.current {
            return PostboxLocalEncryption.obfuscatedFileName(for: id.stringRepresentation, keys: keys)
        }
        return "\(id.stringRepresentation)"
    }
    
    private func pathForId(_ id: MediaResourceId) -> String {
        return "\(self.basePath)/\(fileNameForId(id))"
    }
    
    func resourceData(resourceId: MediaResourceId) -> Data? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: self.pathForId(resourceId))) else {
            return nil
        }
        if let keys = PostboxLocalEncryption.current {
            return try? YougramEncryptedBlob.open(raw, key: keys.sharedMediaKey, aad: "ygsm:" + resourceId.stringRepresentation)
        }
        if YougramEncryptedBlob.isEncrypted(raw) {
            return nil
        }
        return raw
    }
    
    func storeResourceData(resourceId: MediaResourceId, data: Data) {
        if let keys = PostboxLocalEncryption.current {
            if let sealed = try? YougramEncryptedBlob.seal(data, key: keys.sharedMediaKey, aad: "ygsm:" + resourceId.stringRepresentation) {
                let _ = try? sealed.write(to: URL(fileURLWithPath: self.pathForId(resourceId)), options: [.atomic])
            }
            return
        }
        let _ = try? data.write(to: URL(fileURLWithPath: self.pathForId(resourceId)))
    }
}
