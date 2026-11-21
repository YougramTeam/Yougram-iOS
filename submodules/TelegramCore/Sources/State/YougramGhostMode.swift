import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

// Yougram: Ghost Mode (`YougramCoreOptions.ghostMode`). Every helper here returns upstream's answer while its option
// is off, which is what the extensions and tests see.

// MARK: - Read receipts held on this device

/// The chats whose read state Ghost Mode kept on this device instead of sending it.
///
/// A hidden read leaves this device's read mark ahead of the server's while the server still counts messages unread.
/// Upstream reads that as a push still in flight: validation answers `.retry` and the synchronizer restarts it at
/// once, so a held read would spin `getHistory` + `getPeerDialogs` for as long as it lasts. Validation keeps the
/// local mark for a chat listed here instead (`validatePeerReadState`). The list outlives the option: a chat read in
/// Ghost Mode stays ahead of the server after Ghost Mode is turned off, until a push catches the server up
/// (`yougramReleaseGhostReadIfCaughtUp`) or the server reports it read (validation).
struct YougramGhostHeldReads: Codable, Equatable {
    var peerIds: [Int64]
}

private func heldReadPeerIds(transaction: Transaction) -> [Int64] {
    return transaction.getPreferencesEntry(key: PreferencesKeys.yougramGhostHeldReads)?.get(YougramGhostHeldReads.self)?.peerIds ?? []
}

func yougramGhostReadIsHeld(transaction: Transaction, peerId: PeerId) -> Bool {
    return heldReadPeerIds(transaction: transaction).contains(peerId.toInt64())
}

func yougramHoldGhostRead(transaction: Transaction, peerId: PeerId) {
    var peerIds = heldReadPeerIds(transaction: transaction)
    if !peerIds.contains(peerId.toInt64()) {
        peerIds.append(peerId.toInt64())
        transaction.setPreferencesEntry(key: PreferencesKeys.yougramGhostHeldReads, value: PreferencesEntry(YougramGhostHeldReads(peerIds: peerIds)))
    }
}

func yougramReleaseGhostRead(transaction: Transaction, peerId: PeerId) {
    var peerIds = heldReadPeerIds(transaction: transaction)
    if let index = peerIds.firstIndex(of: peerId.toInt64()) {
        peerIds.remove(at: index)
        transaction.setPreferencesEntry(key: PreferencesKeys.yougramGhostHeldReads, value: PreferencesEntry(YougramGhostHeldReads(peerIds: peerIds)))
    }
}

/// Forgets a held read once a push has sent the server `pushedState`, unless this device read further meanwhile.
func yougramReleaseGhostReadIfCaughtUp(transaction: Transaction, peerId: PeerId, pushedState: PeerReadState) {
    guard yougramGhostReadIsHeld(transaction: transaction, peerId: peerId) else {
        return
    }
    if let readStates = transaction.getPeerReadStates(peerId) {
        for (namespace, currentState) in readStates {
            if namespace != Namespaces.Message.Cloud && namespace != Namespaces.Message.SecretIncoming {
                continue
            }
            switch (currentState, pushedState) {
            case let (.idBased(currentMaxIncomingReadId, _, _, _, _), .idBased(pushedMaxIncomingReadId, _, _, _, _)):
                if currentMaxIncomingReadId > pushedMaxIncomingReadId {
                    return
                }
            case let (.indexBased(currentMaxIncomingReadIndex, _, _, _), .indexBased(pushedMaxIncomingReadIndex, _, _, _)):
                if currentMaxIncomingReadIndex > pushedMaxIncomingReadIndex {
                    return
                }
            default:
                break
            }
            break
        }
    }
    yougramReleaseGhostRead(transaction: transaction, peerId: peerId)
}

/// Read states fetched from the server (account reset, chat-list fill, pinned chats, folder dialogs), with the local
/// mark kept for each held chat the server hasn't caught up with: the rule a replayed `.ResetReadState` already
/// follows (`applyResetReadState`). The kept state takes the server's outgoing mark and newest id; its count is the
/// local one, which already counts the messages these fetches store before resetting the read states. With nothing
/// held, `states` comes back unchanged.
func yougramKeepingGhostHeldReads(transaction: Transaction, _ states: [PeerId: [MessageId.Namespace: PeerReadState]]) -> [PeerId: [MessageId.Namespace: PeerReadState]] {
    let heldPeerIds = heldReadPeerIds(transaction: transaction)
    if heldPeerIds.isEmpty {
        return states
    }
    var result = states
    for value in heldPeerIds {
        let peerId = PeerId(value)
        guard var namespaces = result[peerId], let fetchedState = namespaces[Namespaces.Message.Cloud], case let .idBased(serverMaxIncomingReadId, serverMaxOutgoingReadId, serverMaxKnownId, serverCount, serverMarkedUnread) = fetchedState else {
            continue
        }
        guard let localStates = transaction.getPeerReadStates(peerId) else {
            continue
        }
        for (namespace, localState) in localStates where namespace == Namespaces.Message.Cloud {
            if case let .idBased(localMaxIncomingReadId, localMaxOutgoingReadId, _, localCount, localMarkedUnread) = localState, localReadMarkIsAheadOfServer(localMaxIncomingReadId: localMaxIncomingReadId, serverMaxIncomingReadId: serverMaxIncomingReadId, serverCount: serverCount, serverMarkedUnread: serverMarkedUnread) {
                namespaces[Namespaces.Message.Cloud] = .idBased(maxIncomingReadId: localMaxIncomingReadId, maxOutgoingReadId: max(localMaxOutgoingReadId, serverMaxOutgoingReadId), maxKnownId: serverMaxKnownId, count: localCount, markedUnread: localMarkedUnread)
                result[peerId] = namespaces
            }
        }
    }
    return result
}

/// Ghost Mode's stand-in for a read-state push: the read stays on this device, the chat is listed as held, and the
/// operation is confirmed unless validation follows (it confirms itself).
func yougramHoldGhostReadInsteadOfPush(postbox: Postbox, peerId: PeerId, confirm: Bool) -> Signal<Never, PeerReadStateValidationError> {
    return postbox.transaction { transaction -> Void in
        yougramHoldGhostRead(transaction: transaction, peerId: peerId)
        if confirm {
            transaction.confirmSynchronizedIncomingReadState(peerId)
        }
    }
    |> castError(PeerReadStateValidationError.self)
    |> ignoreValues
}

// MARK: - Read on Interact

/// Sends the read receipts Ghost Mode held in a chat, after the user sent a message or reacted there. In a forum
/// topic or a monoforum thread it sends that thread's read mark; elsewhere, the chat's held read state, if it has one.
func _internal_yougramReadOnInteract(postbox: Postbox, network: Network, stateManager: AccountStateManager, peerId: PeerId, threadId: Int64?) -> Signal<Never, NoError> {
    let options = YougramCoreOptions.ghostMode
    if options.hideReadReceipts {
        guard options.readOnInteract else {
            return .complete()
        }
    } else {
        return postbox.transaction { transaction -> Signal<Never, NoError> in
            return yougramPushHeldReadState(postbox: postbox, network: network, stateManager: stateManager, peerId: peerId)
        }
        |> switchToLatest
    }
    return postbox.transaction { transaction -> Signal<Never, NoError> in
        guard let peer = transaction.getPeer(peerId) else {
            return .complete()
        }
        if let threadId, peer.isForumOrMonoForum {
            guard let inputPeer = apiInputPeer(peer), let data = transaction.getMessageHistoryThreadInfo(peerId: peerId, threadId: threadId)?.data.get(MessageHistoryThreadData.self), data.maxIncomingReadId > 0 else {
                return .complete()
            }
            if peer.isForum {
                return network.request(Api.functions.messages.readDiscussion(peer: inputPeer, msgId: Int32(clamping: threadId), readMaxId: data.maxIncomingReadId))
                |> `catch` { _ -> Signal<Api.Bool, NoError> in
                    return .single(.boolFalse)
                }
                |> ignoreValues
            } else {
                guard let subPeer = transaction.getPeer(PeerId(threadId)).flatMap(apiInputPeer) else {
                    return .complete()
                }
                return network.request(Api.functions.messages.readSavedHistory(parentPeer: inputPeer, peer: subPeer, maxId: data.maxIncomingReadId))
                |> `catch` { _ -> Signal<Api.Bool, NoError> in
                    return .single(.boolFalse)
                }
                |> ignoreValues
            }
        }
        return yougramPushHeldReadState(postbox: postbox, network: network, stateManager: stateManager, peerId: peerId)
    }
    |> switchToLatest
}

// MARK: - Voice and video messages

/// Whether playing this message's voice or video message stays on this device (Ghost Mode): it is marked played
/// here and the server isn't told. Self-destructing media always reports, as upstream: the sender's timer and the
/// media's deletion depend on it.
func yougramGhostKeepsContentConsumptionLocal(_ message: Message) -> Bool {
    let options = YougramCoreOptions.ghostMode
    guard options.hideVoiceListened || options.hideRoundWatched else {
        return false
    }
    for attribute in message.attributes {
        if attribute is AutoremoveTimeoutMessageAttribute || attribute is AutoclearTimeoutMessageAttribute {
            return false
        }
    }
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            if file.isInstantVideo {
                return options.hideRoundWatched
            } else if file.isVoice {
                return options.hideVoiceListened
            }
        }
    }
    return false
}

// MARK: - Activity indicators

/// Whether Ghost Mode keeps this activity from the chat. Speaking in a voice chat is not hidden: the call's
/// participant list shows it anyway.
func yougramGhostHidesActivity(_ activity: PeerInputActivity) -> Bool {
    let options = YougramCoreOptions.ghostMode
    switch activity {
    case .typingText:
        return options.hideTyping
    case .uploadingFile, .uploadingPhoto, .uploadingVideo, .uploadingInstantVideo:
        return options.hideUploading
    case .choosingSticker:
        return options.hideChoosingSticker
    case .recordingVoice, .recordingInstantVideo, .playingGame, .interactingWithEmoji, .seeingEmojiInteraction:
        return options.hideOtherActivities
    case .speakingInGroupCall:
        return false
    }
}

// MARK: - Online status

/// Ends the online status a sent message gives (Ghost Mode's "Go Offline Automatically"). The server shows the user
/// as last seen just now, which the sent message already told.
func yougramGhostGoOfflineAfterSending(network: Network) {
    guard YougramCoreOptions.ghostMode.autoOffline else {
        return
    }
    let _ = (network.request(Api.functions.account.updateStatus(offline: .boolTrue))
    |> `catch` { _ -> Signal<Api.Bool, NoError> in
        return .single(.boolFalse)
    }).start()
}

// MARK: - Sending as scheduled messages

/// How far ahead Ghost Mode schedules a message it sends as a scheduled one.
let yougramGhostScheduleDelay: Int32 = 12

/// Ghost Mode's "Send as Scheduled": each message that could be scheduled goes out as a scheduled message
/// `yougramGhostScheduleDelay` seconds ahead. Left alone: Saved Messages, secret chats, bots, monoforums, paid
/// messages, quick replies, suggested posts and messages the user scheduled themselves.
func yougramGhostScheduledMessages(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, messages: [(Bool, EnqueueMessage)], now: Int32) -> [(Bool, EnqueueMessage)] {
    guard YougramCoreOptions.ghostMode.sendAsScheduled else {
        return messages
    }
    guard peerId != accountPeerId else {
        return messages
    }
    guard let peer = transaction.getPeer(peerId) else {
        return messages
    }
    switch peer {
    case let user as TelegramUser:
        if user.botInfo != nil || user.flags.contains(.requireStars) {
            return messages
        }
    case let channel as TelegramChannel:
        if channel.isMonoForum || channel.sendPaidMessageStars != nil {
            return messages
        }
    case is TelegramGroup:
        break
    default:
        return messages
    }
    let scheduleTime = now + yougramGhostScheduleDelay
    return messages.map { transformedMedia, message -> (Bool, EnqueueMessage) in
        let keepsAsIs = message.attributes.contains(where: { attribute in
            return attribute is OutgoingScheduleInfoMessageAttribute || attribute is OutgoingQuickReplyMessageAttribute || attribute is PaidStarsMessageAttribute || attribute is SuggestedPostMessageAttribute
        })
        if keepsAsIs {
            return (transformedMedia, message)
        }
        return (transformedMedia, message.withUpdatedAttributes { attributes in
            return attributes + [OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: nil)]
        })
    }
}
