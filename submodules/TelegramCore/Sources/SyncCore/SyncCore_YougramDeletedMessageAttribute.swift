import Foundation
import Postbox

// Yougram: marks a message that was remotely deleted while Anti-Recall was enabled,
// keeping it visible in chat history with semi-transparent styling.
public class YougramDeletedMessageAttribute: MessageAttribute {
    public let deletedTimestamp: Int32

    public init(deletedTimestamp: Int32) {
        self.deletedTimestamp = deletedTimestamp
    }

    required public init(decoder: PostboxDecoder) {
        self.deletedTimestamp = decoder.decodeInt32ForKey("t", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.deletedTimestamp, forKey: "t")
    }
}

public extension Message {
    var yougramDeletedAttribute: YougramDeletedMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? YougramDeletedMessageAttribute {
                return attribute
            }
        }
        return nil
    }

    var isYougramDeleted: Bool {
        return self.yougramDeletedAttribute != nil
    }
}
