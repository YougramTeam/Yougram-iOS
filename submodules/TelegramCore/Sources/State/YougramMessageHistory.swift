import Foundation
import Postbox
import SwiftSignalKit

// Yougram: local Anti-Recall and Edit History database stored inside Postbox.
// Because entries live in Postbox ItemCache/Preferences tables, Local Encryption
// encrypts them transparently at rest inside SQLCipher.

public struct YougramDeletedMessageRecord: Codable, Equatable {
    public let messageId: MessageId
    public let authorId: PeerId?
    public let authorName: String?
    public let peerId: PeerId
    public let peerTitle: String
    public let threadId: Int64?
    public let text: String
    public let mediaSummary: String?
    public let timestamp: Int32
    public let deletedTimestamp: Int32

    public init(
        messageId: MessageId,
        authorId: PeerId?,
        authorName: String?,
        peerId: PeerId,
        peerTitle: String,
        threadId: Int64?,
        text: String,
        mediaSummary: String?,
        timestamp: Int32,
        deletedTimestamp: Int32
    ) {
        self.messageId = messageId
        self.authorId = authorId
        self.authorName = authorName
        self.peerId = peerId
        self.peerTitle = peerTitle
        self.threadId = threadId
        self.text = text
        self.mediaSummary = mediaSummary
        self.timestamp = timestamp
        self.deletedTimestamp = deletedTimestamp
    }
}

public struct YougramMessageEditVersion: Codable, Equatable {
    public let text: String
    public let timestamp: Int32

    public init(text: String, timestamp: Int32) {
        self.text = text
        self.timestamp = timestamp
    }
}

public struct YougramEditedMessageRecord: Codable, Equatable {
    public let messageId: MessageId
    public let peerId: PeerId
    public let authorName: String?
    public let versions: [YougramMessageEditVersion]

    public init(
        messageId: MessageId,
        peerId: PeerId,
        authorName: String?,
        versions: [YougramMessageEditVersion]
    ) {
        self.messageId = messageId
        self.peerId = peerId
        self.authorName = authorName
        self.versions = versions
    }
}

public struct YougramPeerMessageHistory: Codable, Equatable {
    public var peerTitle: String
    public var deletedMessages: [YougramDeletedMessageRecord]
    public var editedMessages: [YougramEditedMessageRecord]

    public init(
        peerTitle: String,
        deletedMessages: [YougramDeletedMessageRecord] = [],
        editedMessages: [YougramEditedMessageRecord] = []
    ) {
        self.peerTitle = peerTitle
        self.deletedMessages = deletedMessages
        self.editedMessages = editedMessages
    }
}

public struct YougramHistoryIndexEntry: Codable, Equatable {
    public let peerId: PeerId
    public let peerTitle: String
    public let deletedCount: Int
    public let editedCount: Int
    public let updatedTimestamp: Int32

    public init(
        peerId: PeerId,
        peerTitle: String,
        deletedCount: Int,
        editedCount: Int,
        updatedTimestamp: Int32
    ) {
        self.peerId = peerId
        self.peerTitle = peerTitle
        self.deletedCount = deletedCount
        self.editedCount = editedCount
        self.updatedTimestamp = updatedTimestamp
    }
}

public struct YougramHistoryStats: Equatable {
    public let entries: [YougramHistoryIndexEntry]
    public let totalDeletedCount: Int
    public let totalEditedCount: Int

    public init(
        entries: [YougramHistoryIndexEntry],
        totalDeletedCount: Int,
        totalEditedCount: Int
    ) {
        self.entries = entries
        self.totalDeletedCount = totalDeletedCount
        self.totalEditedCount = totalEditedCount
    }
}

private struct YougramHistoryIndex: Codable, Equatable {
    var entries: [YougramHistoryIndexEntry]

    init(entries: [YougramHistoryIndexEntry] = []) {
        self.entries = entries
    }
}

private let maxDeletedPerPeer = 500
private let maxEditedPerPeer = 200
private let maxEditVersionsPerMessage = 30

private func historyCacheKey(peerId: PeerId) -> ItemCacheEntryId {
    let key = ValueBoxKey(length: 8)
    key.setInt64(0, value: peerId.toInt64())
    return ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.yougramMessageHistory, key: key)
}

private func resolvedPeerTitle(transaction: Transaction, peerId: PeerId, fallbackTitle: String? = nil) -> String {
    if let title = transaction.getPeer(peerId)?.debugDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        return title
    }
    if let fallbackTitle, !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return fallbackTitle
    }
    return "Chat \(peerId.toInt64())"
}

private func loadPeerHistory(transaction: Transaction, peerId: PeerId, fallbackTitle: String? = nil) -> YougramPeerMessageHistory {
    if let stored = transaction.retrieveItemCacheEntry(id: historyCacheKey(peerId: peerId))?.get(YougramPeerMessageHistory.self) {
        return stored
    }
    return YougramPeerMessageHistory(peerTitle: resolvedPeerTitle(transaction: transaction, peerId: peerId, fallbackTitle: fallbackTitle))
}

private func savePeerHistory(transaction: Transaction, peerId: PeerId, history: YougramPeerMessageHistory, updatedTimestamp: Int32) {
    let cacheId = historyCacheKey(peerId: peerId)
    var index = transaction.getPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex)?.get(YougramHistoryIndex.self) ?? YougramHistoryIndex()

    if history.deletedMessages.isEmpty && history.editedMessages.isEmpty {
        transaction.removeItemCacheEntry(id: cacheId)
        index.entries.removeAll(where: { $0.peerId == peerId })
    } else {
        if let entry = CodableEntry(history) {
            transaction.putItemCacheEntry(id: cacheId, entry: entry)
        }
        let newIndexEntry = YougramHistoryIndexEntry(
            peerId: peerId,
            peerTitle: history.peerTitle,
            deletedCount: history.deletedMessages.count,
            editedCount: history.editedMessages.count,
            updatedTimestamp: updatedTimestamp
        )
        index.entries.removeAll(where: { $0.peerId == peerId })
        index.entries.append(newIndexEntry)
        index.entries.sort { $0.updatedTimestamp > $1.updatedTimestamp }
    }

    if index.entries.isEmpty {
        transaction.setPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex, value: nil)
    } else {
        transaction.setPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex, value: PreferencesEntry(index))
    }
}

private func yougramSummarizeMedia(_ media: [Media]) -> String? {
    for item in media {
        if item is TelegramMediaImage {
            return "[Photo]"
        } else if let file = item as? TelegramMediaFile {
            if file.isVoice {
                return "[Voice Message]"
            } else if file.isInstantVideo {
                return "[Video Message]"
            } else if file.isAnimatedSticker || file.isSticker {
                return "[Sticker]"
            } else if file.isAnimated {
                return "[GIF]"
            } else if file.isVideo {
                return "[Video]"
            } else if file.isMusic {
                return "[Audio]"
            } else if let name = file.fileName, !name.isEmpty {
                return "[File: \(name)]"
            } else {
                return "[File]"
            }
        } else if let poll = item as? TelegramMediaPoll {
            return "[Poll: \(poll.text)]"
        } else if item is TelegramMediaMap {
            return "[Location]"
        } else if let contact = item as? TelegramMediaContact {
            let fullName = [contact.firstName, contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return fullName.isEmpty ? "[Contact]" : "[Contact: \(fullName)]"
        } else if item is TelegramMediaWebpage {
            return "[Link]"
        } else if item is TelegramMediaDice {
            return "[Dice]"
        } else if item is TelegramMediaStory {
            return "[Story]"
        } else if item is TelegramMediaInvoice || item is TelegramMediaPaidContent {
            return "[Media]"
        }
    }
    return nil
}

func yougramRecordDeletedMessages(transaction: Transaction, ids: [MessageId]) {
    guard YougramCoreOptions.saveDeletedMessages, !ids.isEmpty else {
        return
    }

    let now = Int32(Date().timeIntervalSince1970)
    var recordsByPeer: [PeerId: [YougramDeletedMessageRecord]] = [:]

    for id in ids {
        guard id.namespace == Namespaces.Message.Cloud, let message = transaction.getMessage(id) else {
            continue
        }
        if message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) {
            continue
        }
        if message.attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }) {
            continue
        }

        let mediaSummary = yougramSummarizeMedia(message.media)
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mediaSummary == nil {
            continue
        }

        let peerTitle = resolvedPeerTitle(transaction: transaction, peerId: message.id.peerId)
        let rawAuthor = message.author?.debugDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorName: String? = rawAuthor.isEmpty ? nil : rawAuthor

        let record = YougramDeletedMessageRecord(
            messageId: message.id,
            authorId: message.author?.id,
            authorName: authorName,
            peerId: message.id.peerId,
            peerTitle: peerTitle,
            threadId: message.threadId,
            text: message.text,
            mediaSummary: mediaSummary,
            timestamp: message.timestamp,
            deletedTimestamp: now
        )
        recordsByPeer[message.id.peerId, default: []].append(record)
    }

    for (peerId, incoming) in recordsByPeer {
        var history = loadPeerHistory(transaction: transaction, peerId: peerId, fallbackTitle: incoming.first?.peerTitle)
        if let latestTitle = incoming.first?.peerTitle, !latestTitle.isEmpty {
            history.peerTitle = latestTitle
        }
        let existingIds = Set(history.deletedMessages.map(\.messageId))
        let uniqueIncoming = incoming.filter { !existingIds.contains($0.messageId) }
        guard !uniqueIncoming.isEmpty else {
            continue
        }

        history.deletedMessages = (uniqueIncoming + history.deletedMessages)
            .sorted {
                if $0.deletedTimestamp != $1.deletedTimestamp {
                    return $0.deletedTimestamp > $1.deletedTimestamp
                }
                return $0.messageId.id > $1.messageId.id
            }
        if history.deletedMessages.count > maxDeletedPerPeer {
            history.deletedMessages = Array(history.deletedMessages.prefix(maxDeletedPerPeer))
        }
        savePeerHistory(transaction: transaction, peerId: peerId, history: history, updatedTimestamp: now)
    }
}

func yougramRecordEditedMessage(transaction: Transaction, previousMessage: Message, newText: String) {
    guard YougramCoreOptions.saveEditHistory else {
        return
    }
    guard previousMessage.id.namespace == Namespaces.Message.Cloud else {
        return
    }
    guard previousMessage.text != newText, !previousMessage.text.isEmpty else {
        return
    }
    if previousMessage.attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }) {
        return
    }

    let peerId = previousMessage.id.peerId
    let peerTitle = resolvedPeerTitle(transaction: transaction, peerId: peerId)
    let rawAuthor = previousMessage.author?.debugDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let authorName: String? = rawAuthor.isEmpty ? nil : rawAuthor

    let previousEditDate = (previousMessage.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? previousMessage.timestamp
    let version = YougramMessageEditVersion(text: previousMessage.text, timestamp: previousEditDate)

    var history = loadPeerHistory(transaction: transaction, peerId: peerId, fallbackTitle: peerTitle)
    history.peerTitle = peerTitle

    if let existingIndex = history.editedMessages.firstIndex(where: { $0.messageId == previousMessage.id }) {
        var existing = history.editedMessages[existingIndex]
        if existing.versions.last?.text == version.text {
            return
        }
        var versions = existing.versions + [version]
        if versions.count > maxEditVersionsPerMessage {
            versions = Array(versions.suffix(maxEditVersionsPerMessage))
        }
        existing = YougramEditedMessageRecord(
            messageId: existing.messageId,
            peerId: existing.peerId,
            authorName: authorName ?? existing.authorName,
            versions: versions
        )
        history.editedMessages.remove(at: existingIndex)
        history.editedMessages.insert(existing, at: 0)
    } else {
        let record = YougramEditedMessageRecord(
            messageId: previousMessage.id,
            peerId: peerId,
            authorName: authorName,
            versions: [version]
        )
        history.editedMessages.insert(record, at: 0)
        if history.editedMessages.count > maxEditedPerPeer {
            history.editedMessages = Array(history.editedMessages.prefix(maxEditedPerPeer))
        }
    }

    let now = Int32(Date().timeIntervalSince1970)
    savePeerHistory(transaction: transaction, peerId: peerId, history: history, updatedTimestamp: now)
}

public extension TelegramEngine.Messages {
    func yougramDeletedMessages(peerId: PeerId, threadId: Int64? = nil) -> Signal<[YougramDeletedMessageRecord], NoError> {
        return self.account.postbox.transaction { transaction -> [YougramDeletedMessageRecord] in
            let history = loadPeerHistory(transaction: transaction, peerId: peerId)
            if let threadId {
                return history.deletedMessages.filter { $0.threadId == threadId }
            }
            return history.deletedMessages
        }
    }

    func yougramEditHistory(messageId: MessageId) -> Signal<YougramEditedMessageRecord?, NoError> {
        return self.account.postbox.transaction { transaction -> YougramEditedMessageRecord? in
            let history = loadPeerHistory(transaction: transaction, peerId: messageId.peerId)
            return history.editedMessages.first(where: { $0.messageId == messageId })
        }
    }

    func yougramPeerEditedMessages(peerId: PeerId) -> Signal<[YougramEditedMessageRecord], NoError> {
        return self.account.postbox.transaction { transaction -> [YougramEditedMessageRecord] in
            return loadPeerHistory(transaction: transaction, peerId: peerId).editedMessages
        }
    }

    func yougramAllHistoryStats() -> Signal<YougramHistoryStats, NoError> {
        return self.account.postbox.transaction { transaction -> YougramHistoryStats in
            let index = transaction.getPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex)?.get(YougramHistoryIndex.self) ?? YougramHistoryIndex()
            let sorted = index.entries.sorted { $0.updatedTimestamp > $1.updatedTimestamp }
            let totalDeleted = sorted.reduce(0) { $0 + $1.deletedCount }
            let totalEdited = sorted.reduce(0) { $0 + $1.editedCount }
            return YougramHistoryStats(entries: sorted, totalDeletedCount: totalDeleted, totalEditedCount: totalEdited)
        }
    }

    func yougramAllDeletedMessages(limit: Int = 200) -> Signal<[YougramDeletedMessageRecord], NoError> {
        return self.account.postbox.transaction { transaction -> [YougramDeletedMessageRecord] in
            let index = transaction.getPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex)?.get(YougramHistoryIndex.self) ?? YougramHistoryIndex()
            var allRecords: [YougramDeletedMessageRecord] = []
            for entry in index.entries {
                let history = loadPeerHistory(transaction: transaction, peerId: entry.peerId)
                allRecords.append(contentsOf: history.deletedMessages)
            }
            allRecords.sort { $0.deletedTimestamp > $1.deletedTimestamp }
            if allRecords.count > limit {
                return Array(allRecords.prefix(limit))
            }
            return allRecords
        }
    }

    func yougramClearHistory(peerId: PeerId? = nil) -> Signal<Void, NoError> {
        return self.account.postbox.transaction { transaction -> Void in
            if let peerId {
                savePeerHistory(transaction: transaction, peerId: peerId, history: YougramPeerMessageHistory(peerTitle: ""), updatedTimestamp: 0)
            } else {
                transaction.clearItemCacheCollection(collectionId: Namespaces.CachedItemCollection.yougramMessageHistory)
                transaction.setPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex, value: nil)
            }
        }
    }
}
