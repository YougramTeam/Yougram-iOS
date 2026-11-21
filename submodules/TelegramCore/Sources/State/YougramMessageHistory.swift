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
    private enum CodingKeys: String, CodingKey {
        case peerId
        case peerTitle
        case deletedCount
        case editedCount
        case updatedTimestamp
    }

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

    // AdaptedPostboxDecoder only decodes fixed-width Int32/Int64 (not Swift Int), so wire counts as Int32.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.peerId = try container.decode(PeerId.self, forKey: .peerId)
        self.peerTitle = try container.decode(String.self, forKey: .peerTitle)
        self.deletedCount = Int(try container.decode(Int32.self, forKey: .deletedCount))
        self.editedCount = Int(try container.decode(Int32.self, forKey: .editedCount))
        self.updatedTimestamp = try container.decode(Int32.self, forKey: .updatedTimestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.peerId, forKey: .peerId)
        try container.encode(self.peerTitle, forKey: .peerTitle)
        try container.encode(Int32(clamping: self.deletedCount), forKey: .deletedCount)
        try container.encode(Int32(clamping: self.editedCount), forKey: .editedCount)
        try container.encode(self.updatedTimestamp, forKey: .updatedTimestamp)
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
        } else if let game = item as? TelegramMediaGame {
            return game.title.isEmpty ? "[Game]" : "[Game: \(game.title)]"
        } else if let todo = item as? TelegramMediaTodo {
            return todo.text.isEmpty ? "[Checklist]" : "[Checklist: \(todo.text)]"
        } else if item is TelegramMediaGiveaway || item is TelegramMediaGiveawayResults {
            return "[Giveaway]"
        } else if item is TelegramMediaInvoice || item is TelegramMediaPaidContent {
            return "[Media]"
        }
    }
    return nil
}

private func yougramIsPreservableDeletedMessage(_ message: Message) -> Bool {
    let isEligibleNamespace: Bool
    if message.id.namespace == Namespaces.Message.Cloud {
        isEligibleNamespace = true
    } else if message.id.peerId.namespace == Namespaces.Peer.SecretChat && (message.id.namespace == Namespaces.Message.Local || message.id.namespace == Namespaces.Message.SecretIncoming) {
        isEligibleNamespace = true
    } else {
        isEligibleNamespace = false
    }
    guard isEligibleNamespace else {
        return false
    }
    if message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) {
        return false
    }
    // Keep view-once / secret-chat self-destructing messages deleting normally.
    // Do NOT exclude AutoremoveTimeoutMessageAttribute: Telegram attaches it to every message
    // in chats with an Auto-Delete timer, and timer expirations go through ManagedAutoremoveMessageOperations.
    if message.attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute }) {
        return false
    }
    return true
}

func yougramRecordDeletedMessages(transaction: Transaction, ids: [MessageId]) {
    guard YougramCoreOptions.saveDeletedMessages, !ids.isEmpty else {
        return
    }

    let now = Int32(Date().timeIntervalSince1970)
    var recordsByPeer: [PeerId: [YougramDeletedMessageRecord]] = [:]
    var seenIds = Set<MessageId>()

    for id in ids {
        guard seenIds.insert(id).inserted, let message = transaction.getMessage(id) else {
            continue
        }
        guard yougramIsPreservableDeletedMessage(message) else {
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

/// Records remotely deleted messages in Local History and marks eligible messages in-place with
/// `YougramDeletedMessageAttribute` so they remain visible in chat as semi-transparent instead of disappearing.
/// Returns the preserved IDs and the remaining IDs that should still be removed from Postbox.
func yougramPreserveDeletedMessages(transaction: Transaction, ids: [MessageId]) -> (preservedIds: Set<MessageId>, remainingToDelete: [MessageId]) {
    guard YougramCoreOptions.saveDeletedMessages, !ids.isEmpty else {
        return (Set(), ids)
    }

    yougramRecordDeletedMessages(transaction: transaction, ids: ids)

    let now = Int32(Date().timeIntervalSince1970)
    var preservedIds = Set<MessageId>()
    var remainingToDelete: [MessageId] = []
    var seenIds = Set<MessageId>()
    var newlyPreservedIncomingByPeer: [PeerId: [MessageIndex]] = [:]

    for id in ids {
        guard seenIds.insert(id).inserted else {
            continue
        }
        guard let message = transaction.getMessage(id) else {
            remainingToDelete.append(id)
            continue
        }
        guard yougramIsPreservableDeletedMessage(message) else {
            remainingToDelete.append(id)
            continue
        }

        preservedIds.insert(id)
        if message.isYougramDeleted {
            continue
        }

        if message.flags.contains(.Incoming) {
            newlyPreservedIncomingByPeer[message.id.peerId, default: []].append(message.index)
        }

        transaction.updateMessage(id, update: { currentMessage in
            if currentMessage.isYougramDeleted {
                return .skip
            }
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(
                    authorId: forwardInfo.author?.id,
                    sourceId: forwardInfo.source?.id,
                    sourceMessageId: forwardInfo.sourceMessageId,
                    date: forwardInfo.date,
                    authorSignature: forwardInfo.authorSignature,
                    psaType: forwardInfo.psaType,
                    flags: forwardInfo.flags
                )
            }
            var updatedTags = currentMessage.tags
            updatedTags.remove(.unseenPersonalMessage)
            updatedTags.remove(.unseenReaction)
            updatedTags.remove(.unseenPollVote)

            var attributes = currentMessage.attributes
            attributes.append(YougramDeletedMessageAttribute(deletedTimestamp: now))

            return .update(StoreMessage(
                id: currentMessage.id,
                customStableId: nil,
                globallyUniqueId: currentMessage.globallyUniqueId,
                groupingKey: currentMessage.groupingKey,
                threadId: currentMessage.threadId,
                timestamp: currentMessage.timestamp,
                flags: StoreMessageFlags(currentMessage.flags),
                tags: updatedTags,
                globalTags: currentMessage.globalTags,
                localTags: currentMessage.localTags,
                forwardInfo: storeForwardInfo,
                authorId: currentMessage.author?.id,
                text: currentMessage.text,
                attributes: attributes,
                media: currentMessage.media
            ))
        })
    }

    // Decrement unread counters for remotely deleted unread incoming messages so keeping
    // them visible in chat never leaves phantom unread badges on the chat list.
    for (peerId, incomingIndices) in newlyPreservedIncomingByPeer {
        guard let combinedReadState = transaction.getCombinedPeerReadState(peerId) else {
            continue
        }
        var byNamespace: [MessageId.Namespace: [MessageIndex]] = [:]
        for index in incomingIndices {
            byNamespace[index.id.namespace, default: []].append(index)
        }
        var updatedStates: [MessageId.Namespace: PeerReadState] = [:]
        for (namespace, state) in combinedReadState.states {
            guard let nsIndices = byNamespace[namespace], !nsIndices.isEmpty else {
                continue
            }
            switch state {
            case let .idBased(maxIncomingReadId, maxOutgoingReadId, maxKnownId, count, markedUnread):
                let removedUnread = Int32(clamping: nsIndices.filter { $0.id.id > maxIncomingReadId }.count)
                if removedUnread > 0 && count > 0 {
                    updatedStates[namespace] = .idBased(
                        maxIncomingReadId: maxIncomingReadId,
                        maxOutgoingReadId: maxOutgoingReadId,
                        maxKnownId: maxKnownId,
                        count: max(0, count - removedUnread),
                        markedUnread: markedUnread
                    )
                }
            case let .indexBased(maxIncomingReadIndex, maxOutgoingReadIndex, count, markedUnread):
                let removedUnread = Int32(clamping: nsIndices.filter { $0 > maxIncomingReadIndex }.count)
                if removedUnread > 0 && count > 0 {
                    updatedStates[namespace] = .indexBased(
                        maxIncomingReadIndex: maxIncomingReadIndex,
                        maxOutgoingReadIndex: maxOutgoingReadIndex,
                        count: max(0, count - removedUnread),
                        markedUnread: markedUnread
                    )
                }
            }
        }
        if !updatedStates.isEmpty {
            transaction.resetIncomingReadStates([peerId: updatedStates])
        }
    }

    return (preservedIds, remainingToDelete)
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
    if previousMessage.attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute }) {
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

private func buildHistoryStats(from entry: PreferencesEntry?) -> YougramHistoryStats {
    let index = entry?.get(YougramHistoryIndex.self) ?? YougramHistoryIndex()
    let sorted = index.entries.sorted { $0.updatedTimestamp > $1.updatedTimestamp }
    let totalDeleted = sorted.reduce(0) { $0 + $1.deletedCount }
    let totalEdited = sorted.reduce(0) { $0 + $1.editedCount }
    return YougramHistoryStats(entries: sorted, totalDeletedCount: totalDeleted, totalEditedCount: totalEdited)
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
            return buildHistoryStats(from: transaction.getPreferencesEntry(key: PreferencesKeys.yougramMessageHistoryIndex))
        }
    }

    func yougramAllHistoryStatsSignal() -> Signal<YougramHistoryStats, NoError> {
        return self.account.postbox.preferencesView(keys: [PreferencesKeys.yougramMessageHistoryIndex])
        |> map { view -> YougramHistoryStats in
            return buildHistoryStats(from: view.values[PreferencesKeys.yougramMessageHistoryIndex])
        }
        |> distinctUntilChanged
    }

    func yougramPeerHistorySignal(peerId: PeerId, threadId: Int64? = nil, includeEdited: Bool = false) -> Signal<([YougramDeletedMessageRecord], [YougramEditedMessageRecord]), NoError> {
        let postbox = self.account.postbox
        return postbox.preferencesView(keys: [PreferencesKeys.yougramMessageHistoryIndex])
        |> mapToSignal { _ -> Signal<([YougramDeletedMessageRecord], [YougramEditedMessageRecord]), NoError> in
            return postbox.transaction { transaction -> ([YougramDeletedMessageRecord], [YougramEditedMessageRecord]) in
                let history = loadPeerHistory(transaction: transaction, peerId: peerId)
                let deleted: [YougramDeletedMessageRecord]
                if let threadId {
                    deleted = history.deletedMessages.filter { $0.threadId == threadId }
                } else {
                    deleted = history.deletedMessages
                }
                let edited = includeEdited ? history.editedMessages : []
                return (deleted, edited)
            }
        }
    }

    func yougramEditHistorySignal(messageId: MessageId) -> Signal<YougramEditedMessageRecord?, NoError> {
        let postbox = self.account.postbox
        return postbox.preferencesView(keys: [PreferencesKeys.yougramMessageHistoryIndex])
        |> mapToSignal { _ -> Signal<YougramEditedMessageRecord?, NoError> in
            return postbox.transaction { transaction -> YougramEditedMessageRecord? in
                let history = loadPeerHistory(transaction: transaction, peerId: messageId.peerId)
                return history.editedMessages.first(where: { $0.messageId == messageId })
            }
        }
        |> distinctUntilChanged
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
