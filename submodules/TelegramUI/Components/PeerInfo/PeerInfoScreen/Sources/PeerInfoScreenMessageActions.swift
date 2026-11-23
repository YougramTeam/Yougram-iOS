import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import TelegramCore
import TextFormat
import UndoUI
import ChatInterfaceState
import YougramSettingsUI

extension PeerInfoScreenNode {
    func deleteMessages(messageIds: Set<EngineMessage.Id>?) {
        if let messageIds = messageIds ?? self.state.selectedMessageIds, !messageIds.isEmpty {
            self.activeActionDisposable.set((self.context.sharedContext.chatAvailableMessageActions(engine: self.context.engine, accountPeerId: self.context.account.peerId, messageIds: messageIds, keepUpdated: false)
            |> deliverOnMainQueue).startStrict(next: { [weak self] actions in
                if let strongSelf = self, let peer = strongSelf.data?.peer, !actions.options.isEmpty {
                    let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                    var items: [ActionSheetItem] = []
                    var personalPeerName: String?
                    var isChannel = false
                    if case .user = peer {
                        personalPeerName = peer.compactDisplayTitle
                    } else if case let .channel(channel) = peer, case .broadcast = channel.info {
                        isChannel = true
                    }
                    
                    if actions.options.contains(.deleteGlobally) {
                        let globalTitle: String
                        if isChannel {
                            globalTitle = strongSelf.presentationData.strings.Conversation_DeleteMessagesForMe
                        } else if let personalPeerName = personalPeerName {
                            globalTitle = strongSelf.presentationData.strings.Conversation_DeleteMessagesFor(personalPeerName).string
                        } else {
                            globalTitle = strongSelf.presentationData.strings.Conversation_DeleteMessagesForEveryone
                        }
                        items.append(ActionSheetButtonItem(title: globalTitle, color: .destructive, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            if let strongSelf = self {
                                strongSelf.performNavigationButtonAction?(.selectionDone, nil, nil)
                                let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                            }
                        }))
                    }
                    if actions.options.contains(.deleteLocally) {
                        var localOptionText = strongSelf.presentationData.strings.Conversation_DeleteMessagesForMe
                        if strongSelf.context.account.peerId == strongSelf.peerId {
                            if messageIds.count == 1 {
                                localOptionText = strongSelf.presentationData.strings.Conversation_Moderate_Delete
                            } else {
                                localOptionText = strongSelf.presentationData.strings.Conversation_DeleteManyMessages
                            }
                        }
                        items.append(ActionSheetButtonItem(title: localOptionText, color: .destructive, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                            if let strongSelf = self {
                                strongSelf.performNavigationButtonAction?(.selectionDone, nil, nil)
                                let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forLocalPeer).startStandalone()
                            }
                        }))
                    }
                    actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                    strongSelf.view.endEditing(true)
                    strongSelf.controller?.present(actionSheet, in: .window(.root))
                }
            }))
        }
    }
    
    func advancedForwardMessages(messageIds: Set<EngineMessage.Id>?) {
        guard let messageIds = messageIds ?? self.state.selectedMessageIds, !messageIds.isEmpty else {
            return
        }
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let sortedIds = Array(messageIds).sorted()
        let peerSelectionController = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(
            context: self.context,
            updatedPresentationData: self.controller?.updatedPresentationData,
            filter: [.onlyWriteable, .excludeDisabled, .doNotSearchMessages],
            hasFilters: true,
            title: presentationData.strings.Yougram_AdvancedForward_Title,
            multipleSelection: true,
            forwardedMessageIds: [],
            selectForumThreads: true
        ))
        peerSelectionController.multiplePeersSelected = { [weak self, weak peerSelectionController] peers, peerMap, messageText, mode, _, _ in
            guard let strongSelf = self, let strongController = peerSelectionController, !peers.isEmpty else {
                return
            }
            strongController.dismiss()
            strongSelf.performNavigationButtonAction?(.selectionDone, nil, nil)

            var comment: YougramAdvancedForwardComment?
            if messageText.string.count > 0 {
                let inputText = trimChatInputText(convertMarkdownToAttributes(messageText))
                if inputText.length != 0 {
                    let entities = generateTextEntities(inputText.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(inputText))
                    comment = YougramAdvancedForwardComment(text: inputText.string, entities: entities)
                }
            }

            let currentPresentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
            let targetSummary = YougramAdvancedForwardManager.formatTargetSummary(
                peers: peers,
                peerMap: peerMap,
                accountPeerId: strongSelf.context.account.peerId,
                strings: currentPresentationData.strings,
                nameDisplayOrder: currentPresentationData.nameDisplayOrder
            )
            let targets = peers.map { YougramAdvancedForwardTarget(peerId: $0.id, threadId: nil) }
            let silent = (mode == .silent)
            let scheduleTime: Int32? = (mode == .whenOnline) ? scheduleWhenOnlineTimestamp : nil

            YougramAdvancedForwardManager.shared.start(
                context: strongSelf.context,
                messageIds: sortedIds,
                targets: targets,
                targetSummary: targetSummary,
                comment: comment,
                silent: silent,
                scheduleTime: scheduleTime,
                repeatPeriod: nil
            )
        }
        peerSelectionController.peerSelected = { [weak self, weak peerSelectionController] peer, threadId in
            peerSelectionController?.dismiss()
            guard let strongSelf = self else {
                return
            }
            strongSelf.performNavigationButtonAction?(.selectionDone, nil, nil)
            let currentPresentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
            let targetSummary = YougramAdvancedForwardManager.formatTargetSummary(
                peers: [peer],
                peerMap: [:],
                accountPeerId: strongSelf.context.account.peerId,
                strings: currentPresentationData.strings,
                nameDisplayOrder: currentPresentationData.nameDisplayOrder
            )
            YougramAdvancedForwardManager.shared.start(
                context: strongSelf.context,
                messageIds: sortedIds,
                targets: [YougramAdvancedForwardTarget(peerId: peer.id, threadId: threadId)],
                targetSummary: targetSummary
            )
        }
        self.controller?.push(peerSelectionController)
    }

    func forwardMessages(messageIds: Set<EngineMessage.Id>?) {
        if let messageIds = messageIds ?? self.state.selectedMessageIds, !messageIds.isEmpty {
            if self.data?.peer?.isServerCopyProtectionEnabled == true {
                self.advancedForwardMessages(messageIds: messageIds)
                return
            }
            let _ = (self.context.engine.data.get(EngineDataMap(
                messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init)
            ))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] messageMap in
                guard let strongSelf = self else {
                    return
                }
                for case let someMessage? in messageMap.values {
                    let raw = someMessage._asMessage()
                    if raw.isServerCopyProtected() || (raw.peers[raw.id.peerId]?.isServerCopyProtectionEnabled ?? false) || raw.isYougramDeleted {
                        strongSelf.advancedForwardMessages(messageIds: messageIds)
                        return
                    }
                }
                strongSelf.performStandardForwardMessages(messageIds: messageIds)
            })
        }
    }

    private func performStandardForwardMessages(messageIds: Set<EngineMessage.Id>) {
        if !messageIds.isEmpty {
            let peerSelectionController = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, updatedPresentationData: self.controller?.updatedPresentationData, filter: [.onlyWriteable, .excludeDisabled], hasFilters: true, multipleSelection: true, selectForumThreads: true))
            peerSelectionController.multiplePeersSelected = { [weak self, weak peerSelectionController] peers, peerMap, messageText, mode, forwardOptions, _ in
                guard let strongSelf = self, let strongController = peerSelectionController else {
                    return
                }
                strongController.dismiss()

                var result: [EnqueueMessage] = []
                if messageText.string.count > 0 {
                    let inputText = convertMarkdownToAttributes(messageText)
                    for text in breakChatInputText(trimChatInputText(inputText)) {
                        if text.length != 0 {
                            var attributes: [EngineMessage.Attribute] = []
                            let entities = generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text))
                            if !entities.isEmpty {
                                attributes.append(TextEntitiesMessageAttribute(entities: entities))
                            }
                            result.append(.message(text: text.string, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                        }
                    }
                }
                
                var attributes: [EngineMessage.Attribute] = []
                attributes.append(ForwardOptionsMessageAttribute(hideNames: forwardOptions?.hideNames == true, hideCaptions: forwardOptions?.hideCaptions == true))
                
                result.append(contentsOf: messageIds.map { messageId -> EnqueueMessage in
                    return .forward(source: messageId, threadId: nil, grouping: .auto, attributes: attributes, correlationId: nil)
                })
                
                var displayPeers: [EnginePeer] = []
                for peer in peers {
                    let _ = (enqueueMessages(account: strongSelf.context.account, peerId: peer.id, messages: result)
                    |> deliverOnMainQueue).startStandalone(next: { messageIds in
                        if let strongSelf = self {
                            let signals: [Signal<Bool, NoError>] = messageIds.compactMap({ id -> Signal<Bool, NoError>? in
                                guard let id = id else {
                                    return nil
                                }
                                return strongSelf.context.account.pendingMessageManager.pendingMessageStatus(id)
                                |> mapToSignal { status, _ -> Signal<Bool, NoError> in
                                    if status != nil {
                                        return .never()
                                    } else {
                                        return .single(true)
                                    }
                                }
                                |> take(1)
                            })
                            if strongSelf.shareStatusDisposable == nil {
                                strongSelf.shareStatusDisposable = MetaDisposable()
                            }
                            strongSelf.shareStatusDisposable?.set((combineLatest(signals)
                            |> deliverOnMainQueue).startStrict())
                        }
                    })
                    
                    if case let .secretChat(secretPeer) = peer {
                        if let peer = peerMap[secretPeer.regularPeerId] {
                            displayPeers.append(peer)
                        }
                    } else {
                        displayPeers.append(peer)
                    }
                }
                    
                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                let text: String
                var savedMessages = false
                if displayPeers.count == 1, let peerId = displayPeers.first?.id, peerId == strongSelf.context.account.peerId {
                    text = messageIds.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One : presentationData.strings.Conversation_ForwardTooltip_SavedMessages_Many
                    savedMessages = true
                } else {
                    if displayPeers.count == 1, let peer = displayPeers.first {
                        var peerName = peer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                        peerName = peerName.replacingOccurrences(of: "**", with: "")
                        text = messageIds.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_Chat_One(peerName).string : presentationData.strings.Conversation_ForwardTooltip_Chat_Many(peerName).string
                    } else if displayPeers.count == 2, let firstPeer = displayPeers.first, let secondPeer = displayPeers.last {
                        var firstPeerName = firstPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : firstPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                        firstPeerName = firstPeerName.replacingOccurrences(of: "**", with: "")
                        var secondPeerName = secondPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : secondPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                        secondPeerName = secondPeerName.replacingOccurrences(of: "**", with: "")
                        text = messageIds.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_TwoChats_One(firstPeerName, secondPeerName).string : presentationData.strings.Conversation_ForwardTooltip_TwoChats_Many(firstPeerName, secondPeerName).string
                    } else if let peer = displayPeers.first {
                        var peerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                        peerName = peerName.replacingOccurrences(of: "**", with: "")
                        text = messageIds.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_ManyChats_One(peerName, "\(displayPeers.count - 1)").string : presentationData.strings.Conversation_ForwardTooltip_ManyChats_Many(peerName, "\(displayPeers.count - 1)").string
                    } else {
                        text = ""
                    }
                }

                strongSelf.controller?.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: savedMessages, text: text), elevatedLayout: false, animateInAsReplacement: true, action: { action in
                    if savedMessages, let self, action == .info {
                        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
                        |> deliverOnMainQueue).start(next: { [weak self] peer in
                            guard let self, let peer else {
                                return
                            }
                            guard let navigationController = self.controller?.navigationController as? NavigationController else {
                                return
                            }
                            self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), forceOpenChat: true))
                        })
                    }
                    return false
                }), in: .current)
            }
            peerSelectionController.peerSelected = { [weak self, weak peerSelectionController] peer, threadId in
                let peerId = peer.id
                
                if let strongSelf = self, let _ = peerSelectionController {
                    if peerId == strongSelf.context.account.peerId {
                        Queue.mainQueue().after(0.88) {
                            strongSelf.hapticFeedback.success()
                        }
                        
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        strongSelf.controller?.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: true, text: messageIds.count == 1 ? presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One : presentationData.strings.Conversation_ForwardTooltip_SavedMessages_Many), elevatedLayout: false, animateInAsReplacement: true, action: { action in
                            if let self, action == .info {
                                let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
                                |> deliverOnMainQueue).start(next: { [weak self] peer in
                                    guard let self, let peer else {
                                        return
                                    }
                                    guard let navigationController = self.controller?.navigationController as? NavigationController else {
                                        return
                                    }
                                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer)))
                                })
                            }
                            return false
                        }), in: .current)
                        
                        strongSelf.performNavigationButtonAction?(.selectionDone, nil, nil)
                        
                        let _ = (enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: messageIds.map { id -> EnqueueMessage in
                            return .forward(source: id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil)
                        })
                        |> deliverOnMainQueue).startStandalone(next: { [weak self] messageIds in
                            if let strongSelf = self {
                                let signals: [Signal<Bool, NoError>] = messageIds.compactMap({ id -> Signal<Bool, NoError>? in
                                    guard let id = id else {
                                        return nil
                                    }
                                    return strongSelf.context.account.pendingMessageManager.pendingMessageStatus(id)
                                        |> mapToSignal { status, _ -> Signal<Bool, NoError> in
                                            if status != nil {
                                                return .never()
                                            } else {
                                                return .single(true)
                                            }
                                        }
                                        |> take(1)
                                })
                                strongSelf.activeActionDisposable.set((combineLatest(signals)
                                |> deliverOnMainQueue).startStrict())
                            }
                        })
                        if let peerSelectionController = peerSelectionController {
                            peerSelectionController.dismiss()
                        }
                    } else {
                        let _ = (ChatInterfaceState.update(engine: strongSelf.context.engine, peerId: peerId, threadId: threadId, { currentState in
                            return currentState.withUpdatedForwardMessageIds(Array(messageIds))
                        })
                        |> deliverOnMainQueue).startStandalone(completed: {
                            if let strongSelf = self {
                                let proceed: (ChatController) -> Void = { chatController in
                                    strongSelf.performNavigationButtonAction?(.selectionDone, nil, nil)
                                    
                                    if let navigationController = strongSelf.controller?.navigationController as? NavigationController {
                                        var viewControllers = navigationController.viewControllers
                                        if threadId != nil {
                                            viewControllers.insert(chatController, at: viewControllers.count - 2)
                                        } else {
                                            viewControllers.insert(chatController, at: viewControllers.count - 1)
                                        }
                                        navigationController.setViewControllers(viewControllers, animated: false)
                                        
                                        strongSelf.activeActionDisposable.set((chatController.ready.get()
                                        |> filter { $0 }
                                        |> take(1)
                                        |> deliverOnMainQueue).startStrict(next: { [weak navigationController] _ in
                                            viewControllers.removeAll(where: { $0 is PeerSelectionController })
                                            navigationController?.setViewControllers(viewControllers, animated: true)
                                        }))
                                    }
                                }
                                
                                if let threadId = threadId {
                                    let _ = (strongSelf.context.sharedContext.chatControllerForForumThread(context: strongSelf.context, peerId: peerId, threadId: threadId)
                                    |> deliverOnMainQueue).startStandalone(next: { chatController in
                                        proceed(chatController)
                                    })
                                } else {
                                    let chatController = strongSelf.context.sharedContext.makeChatController(context: strongSelf.context, chatLocation: .peer(id: peerId), subject: .none, botStart: nil, mode: .standard(.default), params: nil)
                                    proceed(chatController)
                                }
                            }
                        })
                    }
                }
            }
            self.controller?.push(peerSelectionController)
        }
    }
}
