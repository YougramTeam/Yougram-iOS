import Foundation
import SwiftSignalKit
import Postbox
internal import TelegramApi

// MARK: - Large Chat List Selection Helpers

public extension TelegramEngine.Messages {
    func yougramAllChatListPeerIds(
        group: EngineChatList.Group,
        filterPredicate: ChatListFilterPredicate?
    ) -> Signal<[EnginePeer.Id], NoError> {
        return self.account.postbox.transaction { transaction -> [EnginePeer.Id] in
            var seen = Set<PeerId>()
            var result: [PeerId] = []

            func appendPeers(groupId: PeerGroupId, predicate: ChatListFilterPredicate?) {
                let peers = transaction.getChatListPeers(
                    groupId: groupId,
                    filterPredicate: predicate,
                    additionalFilter: nil
                )
                for peer in peers {
                    if seen.insert(peer.id).inserted {
                        result.append(peer.id)
                    }
                }
            }

            appendPeers(groupId: group._asGroup(), predicate: filterPredicate)
            if let filterPredicate {
                for additionalGroupId in filterPredicate.includeAdditionalPeerGroupIds {
                    appendPeers(groupId: additionalGroupId, predicate: filterPredicate)
                }
            }
            return result
        }
    }

    func yougramAnyPeerHasUnread(peerIds: Set<EnginePeer.Id>) -> Signal<Bool, NoError> {
        if peerIds.isEmpty {
            return .single(false)
        }
        return self.account.postbox.transaction { transaction -> Bool in
            for peerId in peerIds {
                if let state = transaction.getCombinedPeerReadState(peerId), state.isUnread {
                    return true
                }
            }
            return false
        }
    }

    func yougramClassifyPeerTypes(
        peerIds: [EnginePeer.Id]
    ) -> Signal<(havePrivateChats: Bool, haveNonPrivateChats: Bool), NoError> {
        if peerIds.isEmpty {
            return .single((false, false))
        }
        return self.account.postbox.transaction { transaction -> (havePrivateChats: Bool, haveNonPrivateChats: Bool) in
            var havePrivateChats = false
            var haveNonPrivateChats = false
            for peerId in peerIds {
                guard let peer = transaction.getPeer(peerId) else {
                    continue
                }
                if peer is TelegramUser || peer is TelegramSecretChat {
                    havePrivateChats = true
                } else {
                    haveNonPrivateChats = true
                }
                if havePrivateChats && haveNonPrivateChats {
                    break
                }
            }
            return (havePrivateChats, haveNonPrivateChats)
        }
    }
}

// MARK: - Chat Export Public Types

public enum YougramChatExportFormat: String, CaseIterable, Equatable {
    case html
    case json
    case txt

    public var fileExtension: String {
        return self.rawValue
    }
}

public struct YougramChatExportOptions: Equatable {
    public var format: YougramChatExportFormat
    public var fromDate: Int32?
    public var toDate: Int32?
    public var includeCachedMedia: Bool
    public var photosOnly: Bool
    public var maxSingleFileSizeBytes: Int64?
    public var maxTotalExportSizeBytes: Int64?
    public var fetchCloudHistory: Bool
    public var includeServiceMessages: Bool
    public var includeYougramDeletedMessages: Bool

    public init(
        format: YougramChatExportFormat = .html,
        fromDate: Int32? = nil,
        toDate: Int32? = nil,
        includeCachedMedia: Bool = true,
        photosOnly: Bool = false,
        maxSingleFileSizeBytes: Int64? = nil,
        maxTotalExportSizeBytes: Int64? = nil,
        fetchCloudHistory: Bool = false,
        includeServiceMessages: Bool = true,
        includeYougramDeletedMessages: Bool = true
    ) {
        self.format = format
        self.fromDate = fromDate
        self.toDate = toDate
        self.includeCachedMedia = includeCachedMedia
        self.photosOnly = photosOnly
        self.maxSingleFileSizeBytes = maxSingleFileSizeBytes
        self.maxTotalExportSizeBytes = maxTotalExportSizeBytes
        self.fetchCloudHistory = fetchCloudHistory
        self.includeServiceMessages = includeServiceMessages
        self.includeYougramDeletedMessages = includeYougramDeletedMessages
    }
}

public struct YougramChatExportProgress: Equatable {
    public enum Phase: Equatable {
        case loadingLocal
        case fetchingCloud(fetchedCount: Int)
        case writing(processed: Int, total: Int)
        case packaging
    }

    public let phase: Phase

    public init(phase: Phase) {
        self.phase = phase
    }
}

public struct YougramChatExportResult: Equatable {
    public let shareURL: URL
    public let stagingDirectoryURL: URL
    public let exportedMessageCount: Int
    public let exportedMediaCount: Int
    public let skippedMediaSizeLimitCount: Int
    public let skippedMediaNotCachedCount: Int
    public let totalBytes: Int64
    public let truncatedByTotalSizeLimit: Bool
    public let cloudFetchWarning: String?

    public init(
        shareURL: URL,
        stagingDirectoryURL: URL,
        exportedMessageCount: Int,
        exportedMediaCount: Int,
        skippedMediaSizeLimitCount: Int,
        skippedMediaNotCachedCount: Int,
        totalBytes: Int64,
        truncatedByTotalSizeLimit: Bool,
        cloudFetchWarning: String?
    ) {
        self.shareURL = shareURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.exportedMessageCount = exportedMessageCount
        self.exportedMediaCount = exportedMediaCount
        self.skippedMediaSizeLimitCount = skippedMediaSizeLimitCount
        self.skippedMediaNotCachedCount = skippedMediaNotCachedCount
        self.totalBytes = totalBytes
        self.truncatedByTotalSizeLimit = truncatedByTotalSizeLimit
        self.cloudFetchWarning = cloudFetchWarning
    }
}

public enum YougramChatExportEvent: Equatable {
    case progress(YougramChatExportProgress)
    case completed(YougramChatExportResult)
}

public enum YougramChatExportError: Error, Equatable {
    case chatNotFound
    case noMessagesMatched
    case writeFailed
    case cancelled
}

// MARK: - Internal Export Model

private enum ExportMediaKind: String {
    case photo
    case video
    case voice
    case videoNote = "video_note"
    case audio
    case sticker
    case animation
    case document
    case location
    case contact
    case poll
    case webpage
    case dice
    case story
    case game
    case todo
    case giveaway
    case invoice
    case other
}

private struct ExportMediaAttachment {
    var kind: ExportMediaKind
    var summary: String
    var resource: MediaResource?
    var fallbackResources: [MediaResource] = []
    var preferredExtension: String?
    var originalFileName: String?
    var mimeType: String?
    var declaredSize: Int64?
    var durationSeconds: Int?
    var width: Int32?
    var height: Int32?
    var relativePath: String?
    var exportedSizeBytes: Int64?
    var statusNote: String?
}

private struct ExportMessageRecord {
    let sortTimestamp: Int32
    let sortNamespace: Int32
    let sortId: Int32
    let messageId: MessageId
    let timestamp: Int32
    let senderName: String
    let senderPeerId: Int64?
    let isOutgoing: Bool
    let isService: Bool
    let text: String
    let replyToMessageId: Int32?
    let replyPreviewText: String?
    let replyPreviewAuthor: String?
    let forwardFromName: String?
    let editedTimestamp: Int32?
    let previousEditVersions: [YougramMessageEditVersion]
    let isDeleted: Bool
    let deletedTimestamp: Int32?
    var media: [ExportMediaAttachment]
}

// MARK: - Message Extraction & Formatting Helpers

private func sanitizeExportBaseName(_ rawTitle: String, peerId: PeerId) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_- "))
    let filteredScalars = rawTitle.unicodeScalars.map { scalar -> Character in
        if allowed.contains(scalar) {
            return Character(scalar)
        }
        return "_"
    }
    var cleaned = String(filteredScalars)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "_")
    while cleaned.contains("__") {
        cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
    }
    cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    if cleaned.isEmpty {
        cleaned = "chat_\(peerId.toInt64())"
    }
    if cleaned.count > 48 {
        cleaned = String(cleaned.prefix(48))
    }
    return "Yougram_\(cleaned)"
}

private func sanitizeMediaFileName(_ rawName: String, fallback: String) -> String {
    let base = (rawName as NSString).lastPathComponent
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t\0")
    let scalars = base.unicodeScalars.map { forbidden.contains($0) ? Character("_") : Character($0) }
    var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
        return fallback
    }
    if cleaned.count > 80 {
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        let maxStem = max(16, 80 - (ext.isEmpty ? 0 : ext.count + 1))
        let trimmedStem = String(stem.prefix(maxStem))
        cleaned = ext.isEmpty ? trimmedStem : "\(trimmedStem).\(ext)"
    }
    return cleaned
}

private func inferredExtension(mimeType: String?, fileName: String?, fallback: String) -> String {
    if let fileName {
        let ext = (fileName as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty && ext.count <= 10 {
            return ext.lowercased()
        }
    }
    switch mimeType?.lowercased() {
    case "image/jpeg", "image/jpg":
        return "jpg"
    case "image/png":
        return "png"
    case "image/webp":
        return "webp"
    case "image/gif":
        return "gif"
    case "image/heic":
        return "heic"
    case "video/mp4":
        return "mp4"
    case "video/webm":
        return "webm"
    case "video/quicktime":
        return "mov"
    case "audio/ogg", "application/ogg":
        return "ogg"
    case "audio/mpeg", "audio/mp3":
        return "mp3"
    case "audio/mp4", "audio/m4a", "audio/aac":
        return "m4a"
    case "audio/flac":
        return "flac"
    case "application/pdf":
        return "pdf"
    case "application/x-tgsticker":
        return "tgs"
    case "text/plain":
        return "txt"
    default:
        return fallback
    }
}

private func describeServiceAction(
    _ action: TelegramMediaAction,
    actorName: String,
    peers: SimpleDictionary<PeerId, Peer>
) -> String {
    switch action.action {
    case let .groupCreated(title):
        return "\(actorName) created group \"\(title)\""
    case let .addedMembers(peerIds):
        let names = peerIds.compactMap { peers[$0]?.debugDisplayTitle }.filter { !$0.isEmpty }
        return names.isEmpty ? "\(actorName) added members" : "\(actorName) added \(names.joined(separator: ", "))"
    case let .removedMembers(peerIds):
        let names = peerIds.compactMap { peers[$0]?.debugDisplayTitle }.filter { !$0.isEmpty }
        return names.isEmpty ? "\(actorName) removed a member" : "\(actorName) removed \(names.joined(separator: ", "))"
    case let .photoUpdated(image):
        return image != nil ? "\(actorName) updated chat photo" : "\(actorName) removed chat photo"
    case let .titleUpdated(title):
        return "\(actorName) changed title to \"\(title)\""
    case .pinnedMessageUpdated:
        return "\(actorName) pinned a message"
    case .joinedByLink:
        return "\(actorName) joined via invite link"
    case .joinedByRequest:
        return "\(actorName) joined via request"
    case .joinedChannel:
        return "Joined channel"
    case let .channelMigratedFromGroup(title, _):
        return "Channel upgraded from group \"\(title)\""
    case .groupMigratedToChannel:
        return "Group upgraded to supergroup"
    case .historyCleared:
        return "History was cleared"
    case .historyScreenshot:
        return "\(actorName) took a screenshot"
    case let .messageAutoremoveTimeoutUpdated(period, _):
        return period > 0 ? "Auto-delete timer set to \(period)s" : "Auto-delete timer disabled"
    case let .phoneCall(_, discardReason, duration, isVideo):
        let callKind = isVideo ? "Video call" : "Voice call"
        if let duration, duration > 0 {
            return "\(callKind) (\(duration)s)"
        }
        if let discardReason {
            switch discardReason {
            case .missed:
                return "Missed \(callKind.lowercased())"
            case .busy:
                return "Declined \(callKind.lowercased())"
            case .disconnect:
                return "Disconnected \(callKind.lowercased())"
            case .hangup:
                return callKind
            }
        }
        return callKind
    case let .customText(text, _, _):
        return text
    case let .topicCreated(title, _, _):
        return "\(actorName) created topic \"\(title)\""
    case .topicEdited:
        return "\(actorName) updated topic"
    case let .gameScore(_, score):
        return "\(actorName) scored \(score)"
    case let .paymentSent(currency, totalAmount, _, _, _):
        return "Payment sent (\(totalAmount) \(currency))"
    case .peerJoined:
        return "\(actorName) joined Telegram"
    case let .boostsApplied(boosts):
        return "\(actorName) boosted chat (\(boosts))"
    default:
        return "Service message"
    }
}

private func extractMediaAttachments(_ mediaList: [Media]) -> [ExportMediaAttachment] {
    var attachments: [ExportMediaAttachment] = []
    for item in mediaList {
        if let image = item as? TelegramMediaImage {
            let sortedReps = image.representations.sorted {
                Int64($0.dimensions.width) * Int64($0.dimensions.height) > Int64($1.dimensions.width) * Int64($1.dimensions.height)
            }
            let largest = sortedReps.first ?? largestImageRepresentation(image.representations)
            let dims = largest?.dimensions
            let res = largest?.resource
            let fallbacks: [MediaResource] = sortedReps.dropFirst().map { $0.resource }
            attachments.append(ExportMediaAttachment(
                kind: .photo,
                summary: "[Photo]",
                resource: res,
                fallbackResources: fallbacks,
                preferredExtension: "jpg",
                originalFileName: nil,
                mimeType: "image/jpeg",
                declaredSize: res?.size,
                durationSeconds: nil,
                width: dims?.width,
                height: dims?.height,
                relativePath: nil,
                exportedSizeBytes: nil,
                statusNote: nil
            ))
        } else if let file = item as? TelegramMediaFile {
            var kind: ExportMediaKind = .document
            var summary = "[File]"
            var defaultExt = "bin"
            var durationSeconds: Int?
            var dims: PixelDimensions?

            for attribute in file.attributes {
                switch attribute {
                case let .ImageSize(size):
                    dims = size
                case let .Video(duration, size, flags, _, _, _):
                    dims = size
                    durationSeconds = Int(duration.rounded())
                    if flags.contains(.instantRoundVideo) {
                        kind = .videoNote
                        summary = "[Video Message]"
                    } else {
                        kind = .video
                        summary = "[Video]"
                    }
                    defaultExt = "mp4"
                case let .Audio(isVoice, duration, title, performer, _):
                    durationSeconds = duration
                    if isVoice {
                        kind = .voice
                        summary = "[Voice Message]"
                        defaultExt = "ogg"
                    } else if kind == .document {
                        kind = .audio
                        let label = [performer, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
                        summary = label.isEmpty ? "[Audio]" : "[Audio: \(label)]"
                        defaultExt = "mp3"
                    }
                case .Sticker:
                    kind = .sticker
                    summary = "[Sticker]"
                    defaultExt = file.isAnimatedSticker ? "tgs" : (file.mimeType == "video/webm" ? "webm" : "webp")
                case .Animated:
                    if kind == .document {
                        kind = .animation
                        summary = "[GIF]"
                        defaultExt = "mp4"
                    }
                default:
                    break
                }
            }

            if kind == .document, let name = file.fileName, !name.isEmpty {
                summary = "[File: \(name)]"
            }

            let resolvedExt = inferredExtension(
                mimeType: file.mimeType,
                fileName: file.fileName,
                fallback: defaultExt
            )

            attachments.append(ExportMediaAttachment(
                kind: kind,
                summary: summary,
                resource: file.resource,
                preferredExtension: resolvedExt,
                originalFileName: file.fileName,
                mimeType: file.mimeType,
                declaredSize: file.size ?? file.resource.size,
                durationSeconds: durationSeconds,
                width: dims?.width,
                height: dims?.height,
                relativePath: nil,
                exportedSizeBytes: nil,
                statusNote: nil
            ))
        } else if let map = item as? TelegramMediaMap {
            let venueTitle = map.venue?.title
            let coords = String(format: "%.5f, %.5f", map.latitude, map.longitude)
            let summary = venueTitle.flatMap { $0.isEmpty ? nil : "[Location: \($0) (\(coords))]" } ?? "[Location: \(coords)]"
            attachments.append(ExportMediaAttachment(
                kind: .location,
                summary: summary,
                resource: nil,
                preferredExtension: nil,
                originalFileName: nil,
                mimeType: nil,
                declaredSize: nil,
                durationSeconds: nil,
                width: nil,
                height: nil,
                relativePath: nil,
                exportedSizeBytes: nil,
                statusNote: nil
            ))
        } else if let contact = item as? TelegramMediaContact {
            let name = [contact.firstName, contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            let details = [name, contact.phoneNumber].filter { !$0.isEmpty }.joined(separator: " • ")
            attachments.append(ExportMediaAttachment(
                kind: .contact,
                summary: details.isEmpty ? "[Contact]" : "[Contact: \(details)]",
                resource: nil,
                preferredExtension: nil,
                originalFileName: nil,
                mimeType: nil,
                declaredSize: nil,
                durationSeconds: nil,
                width: nil,
                height: nil,
                relativePath: nil,
                exportedSizeBytes: nil,
                statusNote: nil
            ))
        } else if let poll = item as? TelegramMediaPoll {
            let opts = poll.options.map(\.text).filter { !$0.isEmpty }.joined(separator: " | ")
            let summary = opts.isEmpty ? "[Poll: \(poll.text)]" : "[Poll: \(poll.text) (\(opts))]"
            attachments.append(ExportMediaAttachment(
                kind: .poll,
                summary: summary,
                resource: nil,
                preferredExtension: nil,
                originalFileName: nil,
                mimeType: nil,
                declaredSize: nil,
                width: nil,
                height: nil,
                relativePath: nil,
                exportedSizeBytes: nil,
                statusNote: nil
            ))
        } else if let webpage = item as? TelegramMediaWebpage {
            if case let .Loaded(loaded) = webpage.content {
                let parts = [loaded.title, loaded.url].compactMap { $0 }.filter { !$0.isEmpty }
                attachments.append(ExportMediaAttachment(
                    kind: .webpage,
                    summary: parts.isEmpty ? "[Link]" : "[Link: \(parts.joined(separator: " — "))]",
                    resource: nil,
                    preferredExtension: nil,
                    originalFileName: nil,
                    mimeType: nil,
                    declaredSize: nil,
                    durationSeconds: nil,
                    width: nil,
                    height: nil,
                    relativePath: nil,
                    exportedSizeBytes: nil,
                    statusNote: nil
                ))
            } else {
                attachments.append(ExportMediaAttachment(
                    kind: .webpage,
                    summary: "[Link]",
                    resource: nil,
                    preferredExtension: nil,
                    originalFileName: nil,
                    mimeType: nil,
                    declaredSize: nil,
                    durationSeconds: nil,
                    width: nil,
                    height: nil,
                    relativePath: nil,
                    exportedSizeBytes: nil,
                    statusNote: nil
                ))
            }
        } else if item is TelegramMediaDice {
            attachments.append(ExportMediaAttachment(kind: .dice, summary: "[Dice]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        } else if item is TelegramMediaStory {
            attachments.append(ExportMediaAttachment(kind: .story, summary: "[Story]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        } else if let game = item as? TelegramMediaGame {
            attachments.append(ExportMediaAttachment(kind: .game, summary: game.title.isEmpty ? "[Game]" : "[Game: \(game.title)]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        } else if let todo = item as? TelegramMediaTodo {
            attachments.append(ExportMediaAttachment(kind: .todo, summary: todo.text.isEmpty ? "[Checklist]" : "[Checklist: \(todo.text)]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        } else if item is TelegramMediaGiveaway || item is TelegramMediaGiveawayResults {
            attachments.append(ExportMediaAttachment(kind: .giveaway, summary: "[Giveaway]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        } else if let invoice = item as? TelegramMediaInvoice {
            attachments.append(ExportMediaAttachment(kind: .invoice, summary: invoice.title.isEmpty ? "[Invoice]" : "[Invoice: \(invoice.title)]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        } else if !(item is TelegramMediaAction) {
            attachments.append(ExportMediaAttachment(kind: .other, summary: "[Media]", resource: nil, preferredExtension: nil, originalFileName: nil, mimeType: nil, declaredSize: nil, durationSeconds: nil, width: nil, height: nil, relativePath: nil, exportedSizeBytes: nil, statusNote: nil))
        }
    }
    return attachments
}

private func buildExportRecord(
    from message: Message,
    chatTitle: String,
    editHistoryById: [MessageId: [YougramMessageEditVersion]]
) -> ExportMessageRecord? {
    let isService = message.media.contains(where: { $0 is TelegramMediaAction })
    let isDeleted = message.attributes.contains(where: { $0 is YougramDeletedMessageAttribute })
    let deletedTimestamp = (message.attributes.first(where: { $0 is YougramDeletedMessageAttribute }) as? YougramDeletedMessageAttribute)?.deletedTimestamp

    let actorName: String
    if let author = message.author {
        let title = author.debugDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        actorName = title.isEmpty ? "User \(author.id.toInt64())" : title
    } else if !message.flags.contains(.Incoming) {
        actorName = "You"
    } else {
        actorName = chatTitle
    }

    var text = message.text
    if isService, let action = message.media.first(where: { $0 is TelegramMediaAction }) as? TelegramMediaAction {
        let actionText = describeServiceAction(action, actorName: actorName, peers: message.peers)
        if text.isEmpty {
            text = actionText
        }
    }

    var replyId: Int32?
    var replyPreviewText: String?
    var replyPreviewAuthor: String?
    for attribute in message.attributes {
        if let reply = attribute as? ReplyMessageAttribute {
            replyId = reply.messageId.id
            if let quoted = reply.quote?.text, !quoted.isEmpty {
                replyPreviewText = quoted
            } else if let targetMsg = message.associatedMessages[reply.messageId] {
                if !targetMsg.text.isEmpty {
                    replyPreviewText = targetMsg.text
                } else {
                    replyPreviewText = extractMediaAttachments(targetMsg.media).first?.summary
                }
                replyPreviewAuthor = targetMsg.author?.debugDisplayTitle
            }
            break
        }
    }

    var forwardName: String?
    if let fwd = message.forwardInfo {
        if let authorName = fwd.author?.debugDisplayTitle, !authorName.isEmpty {
            forwardName = authorName
        } else if let sourceName = fwd.source?.debugDisplayTitle, !sourceName.isEmpty {
            forwardName = sourceName
        } else if let sig = fwd.authorSignature, !sig.isEmpty {
            forwardName = sig
        }
    }

    return ExportMessageRecord(
        sortTimestamp: message.timestamp,
        sortNamespace: message.id.namespace,
        sortId: message.id.id,
        messageId: message.id,
        timestamp: message.timestamp,
        senderName: actorName,
        senderPeerId: message.author?.id.toInt64(),
        isOutgoing: !message.flags.contains(.Incoming),
        isService: isService,
        text: text,
        replyToMessageId: replyId,
        replyPreviewText: replyPreviewText,
        replyPreviewAuthor: replyPreviewAuthor,
        forwardFromName: forwardName,
        editedTimestamp: message.editedTime,
        previousEditVersions: editHistoryById[message.id] ?? [],
        isDeleted: isDeleted,
        deletedTimestamp: deletedTimestamp,
        media: extractMediaAttachments(message.media)
    )
}

private func isMediaEligibleForExport(_ attachment: ExportMediaAttachment, photosOnly: Bool) -> Bool {
    guard attachment.resource != nil else {
        return false
    }
    if photosOnly {
        if attachment.kind == .photo {
            return true
        }
        if let mime = attachment.mimeType?.lowercased(), mime.hasPrefix("image/") {
            return true
        }
        return false
    }
    return true
}

// MARK: - Output Formatting Helpers

private func escapeHTML(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for ch in text {
        switch ch {
        case "&":
            result.append("&amp;")
        case "<":
            result.append("&lt;")
        case ">":
            result.append("&gt;")
        case "\"":
            result.append("&quot;")
        case "'":
            result.append("&#39;")
        default:
            result.append(ch)
        }
    }
    return result
}

private func escapeHTMLWithBreaks(_ text: String) -> String {
    return escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
}

private func escapeJSONString(_ text: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
       var str = String(data: data, encoding: .utf8),
       str.count >= 2 {
        str.removeFirst()
        str.removeLast()
        return str
    }
    return "\"\""
}

private func formatByteCount(_ bytes: Int64) -> String {
    let kb: Double = 1024.0
    let mb: Double = kb * 1024.0
    let gb: Double = mb * 1024.0
    let b = Double(bytes)
    if b >= gb {
        return String(format: "%.2f GB", b / gb)
    } else if b >= mb {
        return String(format: "%.1f MB", b / mb)
    } else if b >= kb {
        return String(format: "%.1f KB", b / kb)
    } else {
        return "\(bytes) B"
    }
}

private func htmlHeader(
    chatTitle: String,
    peerId: PeerId,
    exportedAt: String,
    options: YougramChatExportOptions,
    fromLabel: String?,
    toLabel: String?
) -> String {
    let rangeLabel: String
    if let fromLabel, let toLabel {
        rangeLabel = "\(fromLabel) — \(toLabel)"
    } else if let fromLabel {
        rangeLabel = "From \(fromLabel)"
    } else if let toLabel {
        rangeLabel = "Until \(toLabel)"
    } else {
        rangeLabel = "All available messages"
    }

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(escapeHTML(chatTitle)) — Chat Export</title>
    <style>
    :root {
      --bg: #eef2f6;
      --surface: #ffffff;
      --surface-out: #e3f2fd;
      --surface-service: rgba(0, 0, 0, 0.06);
      --text: #14181f;
      --muted: #64748b;
      --accent: #0284c7;
      --border: rgba(15, 23, 42, 0.08);
      --deleted: #dc2626;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0f141b;
        --surface: #1b222c;
        --surface-out: #1d364d;
        --surface-service: rgba(255, 255, 255, 0.08);
        --text: #f1f5f9;
        --muted: #94a3b8;
        --accent: #38bdf8;
        --border: rgba(255, 255, 255, 0.09);
        --deleted: #f87171;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 24px 14px 48px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.45;
    }
    .container { max-width: 820px; margin: 0 auto; }
    header.export-header {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 18px 20px;
      margin-bottom: 18px;
    }
    header.export-header h1 { margin: 0 0 6px; font-size: 20px; }
    .meta { color: var(--muted); font-size: 13px; }
    .day-divider {
      text-align: center;
      margin: 20px 0 12px;
    }
    .day-divider span {
      display: inline-block;
      background: var(--surface-service);
      color: var(--muted);
      font-size: 12px;
      font-weight: 600;
      padding: 4px 12px;
      border-radius: 999px;
    }
    .msg {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 11px 14px;
      margin-bottom: 9px;
    }
    .msg.outgoing { background: var(--surface-out); }
    .msg.deleted { border-left: 3px solid var(--deleted); }
    .msg.service {
      background: var(--surface-service);
      text-align: center;
      font-size: 13px;
      color: var(--muted);
      border-radius: 10px;
      padding: 7px 12px;
    }
    .msg-head {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 10px;
      margin-bottom: 4px;
    }
    .sender { font-weight: 600; font-size: 14px; color: var(--accent); }
    .time { font-size: 12px; color: var(--muted); white-space: nowrap; }
    .badge {
      display: inline-block;
      font-size: 11px;
      font-weight: 600;
      padding: 1px 6px;
      border-radius: 5px;
      margin-left: 6px;
      background: var(--surface-service);
      color: var(--muted);
    }
    .badge.deleted { color: var(--deleted); }
    .reply-box, .forward-box {
      border-left: 3px solid var(--accent);
      padding: 4px 8px;
      margin: 5px 0 7px;
      font-size: 13px;
      color: var(--muted);
      background: rgba(125, 125, 125, 0.06);
      border-radius: 4px;
    }
    .body { word-wrap: break-word; overflow-wrap: anywhere; font-size: 15px; }
    .media { margin-top: 8px; }
    .media img { max-width: 100%; max-height: 460px; border-radius: 10px; display: block; }
    .media video { max-width: 100%; max-height: 460px; border-radius: 10px; display: block; }
    .media audio { width: 100%; max-width: 380px; display: block; }
    .media-chip {
      display: inline-block;
      padding: 6px 10px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: rgba(125, 125, 125, 0.05);
      color: var(--text);
      font-size: 13px;
      text-decoration: none;
    }
    .edits { margin-top: 6px; font-size: 12px; color: var(--muted); }
    </style>
    </head>
    <body>
    <div class="container">
    <header class="export-header">
      <h1>\(escapeHTML(chatTitle))</h1>
      <div class="meta">Peer ID: \(peerId.toInt64()) &bull; Range: \(escapeHTML(rangeLabel)) &bull; Media: \(options.includeCachedMedia ? (options.photosOnly ? "Photos only" : "All cached media") : "Off") &bull; Exported \(escapeHTML(exportedAt))</div>
    </header>
    <main>
    """
}

private func renderHTMLMessage(
    _ msg: ExportMessageRecord,
    timeString: String,
    previousDateDay: inout String?,
    dayString: String
) -> String {
    var html = ""
    if previousDateDay != dayString {
        previousDateDay = dayString
        html += "<div class=\"day-divider\"><span>\(escapeHTML(dayString))</span></div>\n"
    }

    if msg.isService {
        html += "<article class=\"msg service\">\(escapeHTML(msg.text)) <span class=\"time\">\(escapeHTML(timeString))</span></article>\n"
        return html
    }

    var classes = "msg"
    if msg.isOutgoing {
        classes += " outgoing"
    }
    if msg.isDeleted {
        classes += " deleted"
    }

    html += "<article class=\"\(classes)\" id=\"msg-\(msg.messageId.id)\">\n"
    html += "<div class=\"msg-head\"><span class=\"sender\">\(escapeHTML(msg.senderName))"
    if msg.editedTimestamp != nil {
        html += "<span class=\"badge\">edited</span>"
    }
    if msg.isDeleted {
        html += "<span class=\"badge deleted\">deleted</span>"
    }
    html += "</span><span class=\"time\">\(escapeHTML(timeString))</span></div>\n"

    if let forwardFrom = msg.forwardFromName {
        html += "<div class=\"forward-box\">Forwarded from <strong>\(escapeHTML(forwardFrom))</strong></div>\n"
    }

    if let replyId = msg.replyToMessageId {
        let authorPrefix = msg.replyPreviewAuthor.flatMap { $0.isEmpty ? nil : "\(escapeHTML($0)): " } ?? ""
        let preview = msg.replyPreviewText.map { escapeHTML(String($0.prefix(160))) } ?? "Message #\(replyId)"
        html += "<div class=\"reply-box\">Reply to #\(replyId): \(authorPrefix)\(preview)</div>\n"
    }

    if !msg.text.isEmpty {
        html += "<div class=\"body\">\(escapeHTMLWithBreaks(msg.text))</div>\n"
    }

    for media in msg.media {
        html += "<div class=\"media\">"
        if let relPath = media.relativePath {
            let escapedPath = escapeHTML(relPath)
            switch media.kind {
            case .photo:
                html += "<a href=\"\(escapedPath)\"><img src=\"\(escapedPath)\" alt=\"Photo\" loading=\"lazy\"></a>"
            case .video, .videoNote, .animation:
                html += "<video controls preload=\"metadata\" src=\"\(escapedPath)\"></video>"
            case .voice, .audio:
                html += "<audio controls preload=\"none\" src=\"\(escapedPath)\"></audio>"
            case .sticker:
                if relPath.lowercased().hasSuffix(".webp") || relPath.lowercased().hasSuffix(".png") {
                    html += "<img src=\"\(escapedPath)\" alt=\"Sticker\" style=\"max-width:180px\">"
                } else {
                    html += "<a class=\"media-chip\" href=\"\(escapedPath)\">\(escapeHTML(media.summary))</a>"
                }
            default:
                let label = media.originalFileName ?? media.summary
                let sizeNote = media.exportedSizeBytes.map { " (\(formatByteCount($0)))" } ?? ""
                html += "<a class=\"media-chip\" href=\"\(escapedPath)\">\(escapeHTML(label))\(escapeHTML(sizeNote))</a>"
            }
        } else {
            let note = media.statusNote.map { " (\($0))" } ?? ""
            html += "<span class=\"media-chip\">\(escapeHTML(media.summary))\(escapeHTML(note))</span>"
        }
        html += "</div>\n"
    }

    if !msg.previousEditVersions.isEmpty {
        html += "<details class=\"edits\"><summary>Previous versions (\(msg.previousEditVersions.count))</summary><ul>"
        for version in msg.previousEditVersions {
            html += "<li>\(escapeHTML(version.text))</li>"
        }
        html += "</ul></details>\n"
    }

    html += "</article>\n"
    return html
}

private func renderTXTMessage(
    _ msg: ExportMessageRecord,
    dateTimeString: String
) -> String {
    var lines: [String] = []
    if msg.isService {
        lines.append("[\(dateTimeString)] *** \(msg.text) ***")
        return lines.joined(separator: "\n") + "\n\n"
    }

    var tags: [String] = []
    if msg.editedTimestamp != nil {
        tags.append("edited")
    }
    if msg.isDeleted {
        tags.append("deleted")
    }
    let tagSuffix = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
    lines.append("[\(dateTimeString)] \(msg.senderName)\(tagSuffix):")

    if let forwardFrom = msg.forwardFromName {
        lines.append("  Forwarded from: \(forwardFrom)")
    }
    if let replyId = msg.replyToMessageId {
        let preview = msg.replyPreviewText.map { String($0.prefix(140)) } ?? "Message #\(replyId)"
        lines.append("  In reply to #\(replyId): \(preview)")
    }
    if !msg.text.isEmpty {
        lines.append(msg.text)
    }
    for media in msg.media {
        if let relPath = media.relativePath {
            let sizeInfo = media.exportedSizeBytes.map { ", \(formatByteCount($0))" } ?? ""
            lines.append("  \(media.summary) -> \(relPath)\(sizeInfo)")
        } else if let note = media.statusNote {
            lines.append("  \(media.summary) (\(note))")
        } else {
            lines.append("  \(media.summary)")
        }
    }
    if !msg.previousEditVersions.isEmpty {
        for (idx, version) in msg.previousEditVersions.enumerated() {
            lines.append("  [Edit v\(idx + 1)]: \(version.text)")
        }
    }
    return lines.joined(separator: "\n") + "\n\n"
}

private func renderJSONMessage(
    _ msg: ExportMessageRecord,
    isoFormatter: ISO8601DateFormatter,
    isFirst: Bool
) -> String {
    var obj: [String: Any] = [
        "id": Int(msg.messageId.id),
        "type": msg.isService ? "service" : "message",
        "date": isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(msg.timestamp))),
        "date_unixtime": Int(msg.timestamp),
        "from": msg.senderName,
        "is_outgoing": msg.isOutgoing,
        "text": msg.text
    ]
    if let senderPeerId = msg.senderPeerId {
        obj["from_id"] = senderPeerId
    }
    if let replyId = msg.replyToMessageId {
        obj["reply_to_message_id"] = Int(replyId)
    }
    if let forwardFrom = msg.forwardFromName {
        obj["forwarded_from"] = forwardFrom
    }
    if let editedTimestamp = msg.editedTimestamp {
        obj["edited"] = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(editedTimestamp)))
    }
    if msg.isDeleted {
        obj["is_deleted"] = true
        if let deletedTimestamp = msg.deletedTimestamp {
            obj["deleted_at"] = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(deletedTimestamp)))
        }
    }
    if !msg.previousEditVersions.isEmpty {
        obj["previous_edits"] = msg.previousEditVersions.map { version -> [String: Any] in
            return [
                "text": version.text,
                "date": isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(version.timestamp)))
            ]
        }
    }
    if !msg.media.isEmpty {
        obj["media"] = msg.media.map { media -> [String: Any] in
            var dict: [String: Any] = [
                "kind": media.kind.rawValue,
                "summary": media.summary
            ]
            if let path = media.relativePath {
                dict["file"] = path
            }
            if let fileName = media.originalFileName {
                dict["file_name"] = fileName
            }
            if let mimeType = media.mimeType {
                dict["mime_type"] = mimeType
            }
            if let size = media.exportedSizeBytes ?? media.declaredSize {
                dict["size_bytes"] = size
            }
            if let duration = media.durationSeconds {
                dict["duration_seconds"] = duration
            }
            if let width = media.width, let height = media.height {
                dict["width"] = Int(width)
                dict["height"] = Int(height)
            }
            if let note = media.statusNote {
                dict["status"] = note
            }
            return dict
        }
    }

    let prefix = isFirst ? "    " : ",\n    "
    if let jsonData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: jsonData, encoding: .utf8) {
        let indented = str.replacingOccurrences(of: "\n", with: "\n    ")
        return prefix + indented
    }
    return ""
}

// MARK: - Cloud History Fetch Helper

private func fetchCloudHistoryRecords(
    account: Account,
    peerId: PeerId,
    chatTitle: String,
    fromDate: Int32?,
    toDate: Int32?,
    editHistoryById: [MessageId: [YougramMessageEditVersion]],
    existingIds: Set<MessageId>,
    isCancelled: @escaping () -> Bool,
    onPageFetched: @escaping (Int) -> Void
) -> Signal<([ExportMessageRecord], String?), NoError> {
    if peerId.namespace == Namespaces.Peer.SecretChat {
        return .single(([], "Secret chats exist only on this device; skipped cloud history fetch."))
    }

    return account.postbox.transaction { transaction -> (Api.InputPeer?, Bool) in
        guard let peer = transaction.getPeer(peerId) else {
            return (nil, false)
        }
        return (apiInputPeer(peer), peer.isForumOrMonoForum)
    }
    |> mapToSignal { inputPeer, peerIsForum -> Signal<([ExportMessageRecord], String?), NoError> in
        guard let inputPeer else {
            return .single(([], "Cloud peer metadata unavailable; exported local cache only."))
        }

        return Signal { subscriber in
            let queue = Queue()
            let currentDisposable = MetaDisposable()

            var collected: [ExportMessageRecord] = []
            var seenIds = existingIds

            func fetchPage(offsetId: Int32, offsetDate: Int32) {
                if isCancelled() {
                    subscriber.putNext((collected, nil))
                    subscriber.putCompletion()
                    return
                }

                let rpc = account.network.request(
                    Api.functions.messages.getHistory(
                        peer: inputPeer,
                        offsetId: offsetId,
                        offsetDate: offsetDate,
                        addOffset: 0,
                        limit: 100,
                        maxId: 0,
                        minId: 0,
                        hash: 0
                    ),
                    automaticFloodWait: true
                )

                currentDisposable.set(
                    (rpc
                    |> deliverOn(queue)).start(next: { result in
                        if isCancelled() {
                            subscriber.putNext((collected, nil))
                            subscriber.putCompletion()
                            return
                        }

                        let apiMessages: [Api.Message]
                        let apiChats: [Api.Chat]
                        let apiUsers: [Api.User]
                        switch result {
                        case let .channelMessages(data):
                            apiMessages = data.messages
                            apiChats = data.chats
                            apiUsers = data.users
                        case let .messages(data):
                            apiMessages = data.messages
                            apiChats = data.chats
                            apiUsers = data.users
                        case let .messagesSlice(data):
                            apiMessages = data.messages
                            apiChats = data.chats
                            apiUsers = data.users
                        case .messagesNotModified:
                            apiMessages = []
                            apiChats = []
                            apiUsers = []
                        }

                        if apiMessages.isEmpty {
                            subscriber.putNext((collected, nil))
                            subscriber.putCompletion()
                            return
                        }

                        var peers: [PeerId: Peer] = [:]
                        for user in apiUsers {
                            if let parsed = TelegramUser.merge(nil, rhs: user) {
                                peers[parsed.id] = parsed
                            }
                        }
                        for chat in apiChats {
                            if let parsed = parseTelegramGroupOrChannel(chat: chat) {
                                peers[parsed.id] = parsed
                            }
                        }

                        var minIdInBatch: Int32 = Int32.max
                        var minTimestampInBatch: Int32 = Int32.max

                        for apiMsg in apiMessages {
                            guard let storeMsg = StoreMessage(
                                apiMessage: apiMsg,
                                accountPeerId: account.peerId,
                                peerIsForum: peerIsForum
                            ) else {
                                continue
                            }
                            if case let .Id(msgId) = storeMsg.id {
                                minIdInBatch = min(minIdInBatch, msgId.id)
                            }
                            minTimestampInBatch = min(minTimestampInBatch, storeMsg.timestamp)

                            if let fromDate, storeMsg.timestamp < fromDate {
                                continue
                            }
                            if let toDate, storeMsg.timestamp > toDate {
                                continue
                            }

                            guard let rendered = locallyRenderedMessage(
                                message: storeMsg,
                                peers: peers,
                                associatedThreadInfo: nil
                            ) else {
                                continue
                            }

                            if seenIds.insert(rendered.id).inserted,
                               let record = buildExportRecord(
                                   from: rendered,
                                   chatTitle: chatTitle,
                                   editHistoryById: editHistoryById
                               ) {
                                collected.append(record)
                            }
                        }

                        onPageFetched(collected.count)

                        if minIdInBatch == Int32.max || minIdInBatch <= 1 {
                            subscriber.putNext((collected, nil))
                            subscriber.putCompletion()
                            return
                        }
                        if offsetId != 0 && minIdInBatch >= offsetId {
                            subscriber.putNext((collected, nil))
                            subscriber.putCompletion()
                            return
                        }
                        if let fromDate, minTimestampInBatch < fromDate {
                            subscriber.putNext((collected, nil))
                            subscriber.putCompletion()
                            return
                        }

                        fetchPage(offsetId: minIdInBatch, offsetDate: 0)
                    }, error: { rpcError in
                        let warning = "Cloud fetch stopped early (\(rpcError.errorDescription ?? "error \(rpcError.errorCode)")); exported available messages."
                        subscriber.putNext((collected, warning))
                        subscriber.putCompletion()
                    })
                )
            }

            queue.async {
                let startOffsetDate: Int32 = toDate.map { $0 == Int32.max ? Int32.max : ($0 &+ 1) } ?? 0
                fetchPage(offsetId: 0, offsetDate: startOffsetDate)
            }

            return ActionDisposable {
                currentDisposable.dispose()
            }
        }
    }
}

// MARK: - Chat Export Entry Point

public extension TelegramEngine.Messages {
    func yougramExportChat(
        peerId: EnginePeer.Id,
        fallbackTitle: String?,
        options: YougramChatExportOptions
    ) -> Signal<YougramChatExportEvent, YougramChatExportError> {
        let account = self.account
        let postbox = account.postbox

        return Signal { subscriber in
            let cancelledFlag = Atomic<Bool>(value: false)
            let innerDisposable = MetaDisposable()

            subscriber.putNext(.progress(YougramChatExportProgress(phase: .loadingLocal)))

            let localPhase: Signal<(String, [ExportMessageRecord], [MessageId: [YougramMessageEditVersion]], Set<MessageId>), YougramChatExportError> = postbox.transaction { transaction -> (String, [ExportMessageRecord], [MessageId: [YougramMessageEditVersion]], Set<MessageId>)? in
                let resolvedTitle: String
                if let peer = transaction.getPeer(peerId) {
                    let debugTitle = peer.debugDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    resolvedTitle = debugTitle.isEmpty ? (fallbackTitle ?? "Chat \(peerId.toInt64())") : debugTitle
                } else if let fallbackTitle, !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resolvedTitle = fallbackTitle
                } else {
                    return nil
                }

                let rawEdited = loadPeerEditedVersionsForExport(transaction: transaction, peerId: peerId)
                var localRecords: [ExportMessageRecord] = []
                var seenIds = Set<MessageId>()

                let namespaces: [MessageId.Namespace] = [
                    Namespaces.Message.Cloud,
                    Namespaces.Message.Local,
                    Namespaces.Message.SecretIncoming
                ]

                for ns in namespaces {
                    if cancelledFlag.with({ $0 }) {
                        return (resolvedTitle, [], [:], Set())
                    }
                    let startTimestamp = options.fromDate ?? 0
                    var cursor = MessageIndex(id: MessageId(peerId: peerId, namespace: ns, id: 0), timestamp: startTimestamp)
                    let upperBound = options.toDate.map {
                        MessageIndex.upperBound(peerId: peerId, timestamp: $0, namespace: ns)
                    } ?? MessageIndex.upperBound(peerId: peerId, namespace: ns)
                    var includeFrom = true

                    while cursor <= upperBound {
                        if cancelledFlag.with({ $0 }) {
                            return (resolvedTitle, [], [:], Set())
                        }
                        let batch = transaction.getMessages(
                            peerId: peerId,
                            namespace: ns,
                            from: cursor,
                            includeFrom: includeFrom,
                            to: upperBound,
                            limit: 500
                        )
                        if batch.isEmpty {
                            break
                        }
                        for msg in batch {
                            if let fromDate = options.fromDate, msg.timestamp < fromDate {
                                continue
                            }
                            if let toDate = options.toDate, msg.timestamp > toDate {
                                continue
                            }
                            if seenIds.insert(msg.id).inserted,
                               let record = buildExportRecord(
                                   from: msg,
                                   chatTitle: resolvedTitle,
                                   editHistoryById: rawEdited
                               ) {
                                localRecords.append(record)
                            }
                        }
                        guard let lastIndex = batch.last?.index, lastIndex > cursor else {
                            break
                        }
                        cursor = lastIndex
                        includeFrom = false
                    }
                }

                return (resolvedTitle, localRecords, rawEdited, seenIds)
            }
            |> castError(YougramChatExportError.self)
            |> mapToSignal { value -> Signal<(String, [ExportMessageRecord], [MessageId: [YougramMessageEditVersion]], Set<MessageId>), YougramChatExportError> in
                guard let value else {
                    return .fail(.chatNotFound)
                }
                if cancelledFlag.with({ $0 }) {
                    return .fail(.cancelled)
                }
                return .single(value)
            }

            let fullPipeline = localPhase
            |> mapToSignal { chatTitle, localRecords, editMap, seenIds -> Signal<YougramChatExportEvent, YougramChatExportError> in
                let deletedRecordsSignal: Signal<[YougramDeletedMessageRecord], NoError>
                if options.includeYougramDeletedMessages {
                    deletedRecordsSignal = self.yougramDeletedMessages(peerId: peerId)
                } else {
                    deletedRecordsSignal = .single([])
                }

                let cloudRecordsSignal: Signal<([ExportMessageRecord], String?), NoError>
                if options.fetchCloudHistory {
                    subscriber.putNext(.progress(YougramChatExportProgress(phase: .fetchingCloud(fetchedCount: 0))))
                    cloudRecordsSignal = fetchCloudHistoryRecords(
                        account: account,
                        peerId: peerId,
                        chatTitle: chatTitle,
                        fromDate: options.fromDate,
                        toDate: options.toDate,
                        editHistoryById: editMap,
                        existingIds: seenIds,
                        isCancelled: { cancelledFlag.with { $0 } },
                        onPageFetched: { count in
                            subscriber.putNext(.progress(YougramChatExportProgress(phase: .fetchingCloud(fetchedCount: count))))
                        }
                    )
                } else {
                    cloudRecordsSignal = .single(([], nil))
                }

                return combineLatest(cloudRecordsSignal, deletedRecordsSignal)
                |> castError(YougramChatExportError.self)
                |> mapToSignal { cloudResult, deletedLogs -> Signal<YougramChatExportEvent, YougramChatExportError> in
                    if cancelledFlag.with({ $0 }) {
                        return .fail(.cancelled)
                    }

                    let (cloudRecords, cloudWarning) = cloudResult
                    var allRecords: [ExportMessageRecord] = []
                    allRecords.reserveCapacity(localRecords.count + cloudRecords.count + deletedLogs.count)

                    var presentIds = Set<MessageId>()
                    for rec in localRecords {
                        if !options.includeYougramDeletedMessages && rec.isDeleted {
                            continue
                        }
                        if !options.includeServiceMessages && rec.isService {
                            continue
                        }
                        if presentIds.insert(rec.messageId).inserted {
                            allRecords.append(rec)
                        }
                    }

                    for rec in cloudRecords {
                        if !options.includeServiceMessages && rec.isService {
                            continue
                        }
                        if presentIds.insert(rec.messageId).inserted {
                            allRecords.append(rec)
                        }
                    }

                    if options.includeYougramDeletedMessages {
                        for del in deletedLogs {
                            if let fromDate = options.fromDate, del.timestamp < fromDate {
                                continue
                            }
                            if let toDate = options.toDate, del.timestamp > toDate {
                                continue
                            }
                            guard presentIds.insert(del.messageId).inserted else {
                                continue
                            }
                            let syntheticMedia: [ExportMediaAttachment]
                            if let mediaSummary = del.mediaSummary, !mediaSummary.isEmpty {
                                syntheticMedia = [ExportMediaAttachment(
                                    kind: .other,
                                    summary: mediaSummary,
                                    resource: nil,
                                    preferredExtension: nil,
                                    originalFileName: nil,
                                    mimeType: nil,
                                    declaredSize: nil,
                                    durationSeconds: nil,
                                    width: nil,
                                    height: nil,
                                    relativePath: nil,
                                    exportedSizeBytes: nil,
                                    statusNote: "deleted before export"
                                )]
                            } else {
                                syntheticMedia = []
                            }

                            let senderTitle = (del.authorName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? del.peerTitle
                            allRecords.append(ExportMessageRecord(
                                sortTimestamp: del.timestamp,
                                sortNamespace: del.messageId.namespace,
                                sortId: del.messageId.id,
                                messageId: del.messageId,
                                timestamp: del.timestamp,
                                senderName: senderTitle,
                                senderPeerId: del.authorId?.toInt64(),
                                isOutgoing: del.authorId == account.peerId,
                                isService: false,
                                text: del.text,
                                replyToMessageId: nil,
                                replyPreviewText: nil,
                                replyPreviewAuthor: nil,
                                forwardFromName: nil,
                                editedTimestamp: nil,
                                previousEditVersions: editMap[del.messageId] ?? [],
                                isDeleted: true,
                                deletedTimestamp: del.deletedTimestamp,
                                media: syntheticMedia
                            ))
                        }
                    }

                    if allRecords.isEmpty {
                        return .fail(.noMessagesMatched)
                    }

                    allRecords.sort { lhs, rhs in
                        if lhs.sortTimestamp != rhs.sortTimestamp {
                            return lhs.sortTimestamp < rhs.sortTimestamp
                        }
                        if lhs.sortNamespace != rhs.sortNamespace {
                            return lhs.sortNamespace < rhs.sortNamespace
                        }
                        if lhs.sortId != rhs.sortId {
                            return lhs.sortId < rhs.sortId
                        }
                        return false
                    }

                    return Signal { exportSubscriber in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let fileManager = FileManager.default
                            let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("yougram-export-\(UUID().uuidString)", isDirectory: true)
                            let safeBaseName = sanitizeExportBaseName(chatTitle, peerId: peerId)
                            let bundleDir = stagingDir.appendingPathComponent(safeBaseName, isDirectory: true)
                            let mediaDir = bundleDir.appendingPathComponent("media", isDirectory: true)
                            let ext = options.format.fileExtension
                            let mainFileName = "\(safeBaseName).\(ext)"
                            let mainFileURL = bundleDir.appendingPathComponent(mainFileName, isDirectory: false)

                            func cleanupOnAbort() {
                                try? fileManager.removeItem(at: stagingDir)
                            }

                            do {
                                try fileManager.createDirectory(at: bundleDir, withIntermediateDirectories: true, attributes: nil)
                                if !fileManager.createFile(atPath: mainFileURL.path, contents: nil, attributes: nil) {
                                    cleanupOnAbort()
                                    exportSubscriber.putError(.writeFailed)
                                    return
                                }
                            } catch {
                                cleanupOnAbort()
                                exportSubscriber.putError(.writeFailed)
                                return
                            }

                            guard let handle = try? FileHandle(forWritingTo: mainFileURL) else {
                                cleanupOnAbort()
                                exportSubscriber.putError(.writeFailed)
                                return
                            }

                            let dayFormatter = DateFormatter()
                            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
                            dayFormatter.dateFormat = "yyyy-MM-dd"

                            let timeFormatter = DateFormatter()
                            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
                            timeFormatter.dateFormat = "HH:mm:ss"

                            let dateTimeFormatter = DateFormatter()
                            dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
                            dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

                            let isoFormatter = ISO8601DateFormatter()
                            let exportedAtISO = isoFormatter.string(from: Date())
                            let exportedAtReadable = dateTimeFormatter.string(from: Date())
                            let fromLabel = options.fromDate.map { dateTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
                            let toLabel = options.toDate.map { dateTimeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }

                            let headerString: String
                            let footerString: String
                            switch options.format {
                            case .html:
                                headerString = htmlHeader(
                                    chatTitle: chatTitle,
                                    peerId: peerId,
                                    exportedAt: exportedAtReadable,
                                    options: options,
                                    fromLabel: fromLabel,
                                    toLabel: toLabel
                                )
                                footerString = "</main>\n</div>\n</body>\n</html>\n"
                            case .json:
                                var metaLines: [String] = []
                                metaLines.append("  \"chat_title\": \(escapeJSONString(chatTitle)),")
                                metaLines.append("  \"peer_id\": \(peerId.toInt64()),")
                                metaLines.append("  \"exported_at\": \(escapeJSONString(exportedAtISO)),")
                                if let fromLabel {
                                    metaLines.append("  \"from_date\": \(escapeJSONString(fromLabel)),")
                                }
                                if let toLabel {
                                    metaLines.append("  \"to_date\": \(escapeJSONString(toLabel)),")
                                }
                                metaLines.append("  \"messages\": [")
                                headerString = "{\n" + metaLines.joined(separator: "\n") + "\n"
                                footerString = "\n  ]\n}\n"
                            case .txt:
                                var headerParts = [
                                    "Chat Export: \(chatTitle) (ID: \(peerId.toInt64()))",
                                    "Exported: \(exportedAtReadable)"
                                ]
                                if let fromLabel {
                                    headerParts.append("From: \(fromLabel)")
                                }
                                if let toLabel {
                                    headerParts.append("To: \(toLabel)")
                                }
                                headerParts.append(String(repeating: "=", count: 48))
                                headerString = headerParts.joined(separator: "\n") + "\n\n"
                                footerString = ""
                            }

                            var totalExportedBytes: Int64 = 0
                            let footerByteCount = Int64(footerString.utf8.count)

                            func writeString(_ string: String) -> Bool {
                                guard let data = string.data(using: .utf8) else {
                                    return false
                                }
                                do {
                                    if #available(iOS 13.4, *) {
                                        try handle.write(contentsOf: data)
                                    } else {
                                        handle.write(data)
                                    }
                                    totalExportedBytes += Int64(data.count)
                                    return true
                                } catch {
                                    return false
                                }
                            }

                            if !writeString(headerString) {
                                try? handle.close()
                                cleanupOnAbort()
                                exportSubscriber.putError(.writeFailed)
                                return
                            }

                            var exportedMessageCount = 0
                            var exportedMediaCount = 0
                            var skippedMediaSizeLimitCount = 0
                            var skippedMediaNotCachedCount = 0
                            var truncatedByTotalSizeLimit = false
                            var usedFileNames = Set<String>()
                            var mediaDirectoryCreated = false
                            var previousDay: String?

                            let totalCount = allRecords.count
                            let progressStride = max(1, min(100, totalCount / 25))

                            for (index, originalRecord) in allRecords.enumerated() {
                                if cancelledFlag.with({ $0 }) {
                                    try? handle.close()
                                    cleanupOnAbort()
                                    exportSubscriber.putError(.cancelled)
                                    return
                                }

                                var record = originalRecord
                                if options.includeCachedMedia && !record.media.isEmpty {
                                    for mIdx in record.media.indices {
                                        var attachment = record.media[mIdx]
                                        guard isMediaEligibleForExport(attachment, photosOnly: options.photosOnly),
                                              let primaryResource = attachment.resource else {
                                            continue
                                        }

                                        let candidateResources = [primaryResource] + attachment.fallbackResources
                                        var resolvedSourcePath: String?
                                        for candidate in candidateResources {
                                            if let path = postbox.mediaBox.completedResourcePath(
                                                candidate,
                                                pathExtension: attachment.preferredExtension
                                            ), fileManager.fileExists(atPath: path) {
                                                resolvedSourcePath = path
                                                break
                                            }
                                        }
                                        guard let sourcePath = resolvedSourcePath,
                                              let attrs = try? fileManager.attributesOfItem(atPath: sourcePath),
                                              let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
                                              fileSize >= 0 else {
                                            skippedMediaNotCachedCount += 1
                                            attachment.statusNote = "not cached"
                                            record.media[mIdx] = attachment
                                            continue
                                        }

                                        if let maxFileBytes = options.maxSingleFileSizeBytes, fileSize > maxFileBytes {
                                            skippedMediaSizeLimitCount += 1
                                            attachment.statusNote = "skipped: >\(formatByteCount(maxFileBytes))"
                                            record.media[mIdx] = attachment
                                            continue
                                        }

                                        if let maxTotalBytes = options.maxTotalExportSizeBytes,
                                           totalExportedBytes + fileSize + footerByteCount + 4096 > maxTotalBytes {
                                            skippedMediaSizeLimitCount += 1
                                            attachment.statusNote = "skipped: export size limit"
                                            record.media[mIdx] = attachment
                                            continue
                                        }

                                        if !mediaDirectoryCreated {
                                            do {
                                                try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true, attributes: nil)
                                                mediaDirectoryCreated = true
                                            } catch {
                                                attachment.statusNote = "copy failed"
                                                record.media[mIdx] = attachment
                                                continue
                                            }
                                        }

                                        let fallbackExt = attachment.preferredExtension ?? "bin"
                                        let fallbackName = "msg_\(record.messageId.id)_\(mIdx + 1).\(fallbackExt)"
                                        var candidateName = attachment.originalFileName.map {
                                            sanitizeMediaFileName($0, fallback: fallbackName)
                                        } ?? fallbackName
                                        if usedFileNames.contains(candidateName) {
                                            let stem = (candidateName as NSString).deletingPathExtension
                                            let pathExt = (candidateName as NSString).pathExtension
                                            let unique = "\(record.messageId.id)_\(mIdx + 1)"
                                            candidateName = pathExt.isEmpty ? "\(stem)_\(unique)" : "\(stem)_\(unique).\(pathExt)"
                                        }
                                        usedFileNames.insert(candidateName)

                                        let destURL = mediaDir.appendingPathComponent(candidateName, isDirectory: false)
                                        do {
                                            if fileManager.fileExists(atPath: destURL.path) {
                                                try fileManager.removeItem(at: destURL)
                                            }
                                            try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath), to: destURL)
                                            attachment.relativePath = "media/\(candidateName)"
                                            attachment.exportedSizeBytes = fileSize
                                            exportedMediaCount += 1
                                            totalExportedBytes += fileSize
                                        } catch {
                                            attachment.statusNote = "copy failed"
                                        }
                                        record.media[mIdx] = attachment
                                    }
                                }

                                let date = Date(timeIntervalSince1970: TimeInterval(record.timestamp))
                                let renderedChunk: String
                                switch options.format {
                                case .html:
                                    renderedChunk = renderHTMLMessage(
                                        record,
                                        timeString: timeFormatter.string(from: date),
                                        previousDateDay: &previousDay,
                                        dayString: dayFormatter.string(from: date)
                                    )
                                case .json:
                                    renderedChunk = renderJSONMessage(
                                        record,
                                        isoFormatter: isoFormatter,
                                        isFirst: exportedMessageCount == 0
                                    )
                                case .txt:
                                    renderedChunk = renderTXTMessage(
                                        record,
                                        dateTimeString: dateTimeFormatter.string(from: date)
                                    )
                                }

                                let chunkBytes = Int64(renderedChunk.utf8.count)
                                if let maxTotalBytes = options.maxTotalExportSizeBytes,
                                   exportedMessageCount > 0,
                                   totalExportedBytes + chunkBytes + footerByteCount > maxTotalBytes {
                                    // Clean up any media copied for this overflowed message
                                    for media in record.media {
                                        if let relPath = media.relativePath {
                                            let fileName = (relPath as NSString).lastPathComponent
                                            let url = mediaDir.appendingPathComponent(fileName)
                                            try? fileManager.removeItem(at: url)
                                            if let size = media.exportedSizeBytes {
                                                totalExportedBytes = max(0, totalExportedBytes - size)
                                            }
                                            exportedMediaCount = max(0, exportedMediaCount - 1)
                                        }
                                    }
                                    truncatedByTotalSizeLimit = true
                                    break
                                }

                                if !writeString(renderedChunk) {
                                    try? handle.close()
                                    cleanupOnAbort()
                                    exportSubscriber.putError(.writeFailed)
                                    return
                                }

                                exportedMessageCount += 1
                                if index % progressStride == 0 || index == totalCount - 1 {
                                    exportSubscriber.putNext(.progress(YougramChatExportProgress(
                                        phase: .writing(processed: index + 1, total: totalCount)
                                    )))
                                }
                            }

                            if !footerString.isEmpty {
                                _ = writeString(footerString)
                            }
                            try? handle.close()

                            if cancelledFlag.with({ $0 }) {
                                cleanupOnAbort()
                                exportSubscriber.putError(.cancelled)
                                return
                            }

                            exportSubscriber.putNext(.progress(YougramChatExportProgress(phase: .packaging)))

                            let finalShareURL: URL
                            if exportedMediaCount > 0 {
                                let zipURL = stagingDir.appendingPathComponent("\(safeBaseName).zip", isDirectory: false)
                                var coordinationError: NSError?
                                var copyError: Error?
                                let coordinator = NSFileCoordinator(filePresenter: nil)
                                coordinator.coordinate(readingItemAt: bundleDir, options: .forUploading, error: &coordinationError) { tempZipURL in
                                    do {
                                        if fileManager.fileExists(atPath: zipURL.path) {
                                            try fileManager.removeItem(at: zipURL)
                                        }
                                        try fileManager.copyItem(at: tempZipURL, to: zipURL)
                                    } catch {
                                        copyError = error
                                    }
                                }
                                if coordinationError == nil && copyError == nil && fileManager.fileExists(atPath: zipURL.path) {
                                    finalShareURL = zipURL
                                } else {
                                    // Fallback: share standalone main document so user still receives the transcript
                                    finalShareURL = mainFileURL
                                }
                            } else {
                                let standaloneURL = stagingDir.appendingPathComponent(mainFileName, isDirectory: false)
                                do {
                                    if fileManager.fileExists(atPath: standaloneURL.path) {
                                        try fileManager.removeItem(at: standaloneURL)
                                    }
                                    try fileManager.moveItem(at: mainFileURL, to: standaloneURL)
                                    try? fileManager.removeItem(at: bundleDir)
                                    finalShareURL = standaloneURL
                                } catch {
                                    finalShareURL = mainFileURL
                                }
                            }

                            exportSubscriber.putNext(.completed(YougramChatExportResult(
                                shareURL: finalShareURL,
                                stagingDirectoryURL: stagingDir,
                                exportedMessageCount: exportedMessageCount,
                                exportedMediaCount: exportedMediaCount,
                                skippedMediaSizeLimitCount: skippedMediaSizeLimitCount,
                                skippedMediaNotCachedCount: skippedMediaNotCachedCount,
                                totalBytes: totalExportedBytes,
                                truncatedByTotalSizeLimit: truncatedByTotalSizeLimit,
                                cloudFetchWarning: cloudWarning
                            )))
                            exportSubscriber.putCompletion()
                        }
                        return EmptyDisposable
                    }
                }
            }

            innerDisposable.set(fullPipeline.start(
                next: { event in
                    subscriber.putNext(event)
                },
                error: { error in
                    subscriber.putError(error)
                },
                completed: {
                    subscriber.putCompletion()
                }
            ))

            return ActionDisposable {
                _ = cancelledFlag.swap(true)
                innerDisposable.dispose()
            }
        }
    }
}

private func loadPeerEditedVersionsForExport(
    transaction: Transaction,
    peerId: PeerId
) -> [MessageId: [YougramMessageEditVersion]] {
    let key = ValueBoxKey(length: 8)
    key.setInt64(0, value: peerId.toInt64())
    let cacheId = ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.yougramMessageHistory, key: key)
    guard let history = transaction.retrieveItemCacheEntry(id: cacheId)?.get(YougramPeerMessageHistory.self) else {
        return [:]
    }
    var result: [MessageId: [YougramMessageEditVersion]] = [:]
    for record in history.editedMessages {
        result[record.messageId] = record.versions
    }
    return result
}
