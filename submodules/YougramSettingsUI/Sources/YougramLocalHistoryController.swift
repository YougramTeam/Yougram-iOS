import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

// Yougram: Local History management screen, per-chat View Deleted list, and message Edit History viewer.

private let historyDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}()

private func formatHistoryTimestamp(_ timestamp: Int32) -> String {
    return historyDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

private func copyTextWithToast(context: AccountContext, text: String, present: ((ViewController) -> Void)?) {
    guard !text.isEmpty else {
        return
    }
    UIPasteboard.general.string = text
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present?(UndoOverlayController(
        presentationData: presentationData,
        content: .copy(text: presentationData.strings.Conversation_MessageCopied),
        elevatedLayout: false,
        action: { _ in return false }
    ))
}

private enum HistoryEntry: ItemListNodeEntry {
    case header(id: Int32, section: Int32, text: String)
    case info(id: Int32, section: Int32, text: String)
    case toggle(id: Int32, section: Int32, title: String, value: Bool, tag: String)
    case disclosure(id: Int32, section: Int32, title: String, titleBold: Bool, label: String, arrow: Bool, actionTag: String)
    case action(id: Int32, section: Int32, title: String, destructive: Bool, tag: String)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, s, _),
             let .info(_, s, _),
             let .toggle(_, s, _, _, _),
             let .disclosure(_, s, _, _, _, _, _),
             let .action(_, s, _, _, _):
            return s
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(id, _, _),
             let .info(id, _, _),
             let .toggle(id, _, _, _, _),
             let .disclosure(id, _, _, _, _, _, _),
             let .action(id, _, _, _, _):
            return id
        }
    }

    static func <(lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! HistoryArguments
        switch self {
        case let .header(_, section, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .info(_, section, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .toggle(_, section, title, value, tag):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: section, style: .blocks, updated: { newValue in
                args.toggle(tag, newValue)
            })
        case let .disclosure(_, section, title, titleBold, label, arrow, actionTag):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                titleFont: titleBold ? .bold : .regular,
                label: label,
                labelStyle: arrow ? .text : .multilineDetailText,
                sectionId: section,
                style: .blocks,
                disclosureStyle: arrow ? .arrow : .none,
                action: {
                    args.performAction(actionTag)
                }
            )
        case let .action(_, section, title, destructive, tag):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: destructive ? .destructive : .generic,
                alignment: .natural,
                sectionId: section,
                style: .blocks,
                action: {
                    args.performAction(tag)
                }
            )
        }
    }
}

private final class HistoryArguments {
    let toggle: (String, Bool) -> Void
    let performAction: (String) -> Void

    init(toggle: @escaping (String, Bool) -> Void, performAction: @escaping (String) -> Void) {
        self.toggle = toggle
        self.performAction = performAction
    }
}

/// Settings ▸ Yougram ▸ Privacy ▸ Local History
public func yougramLocalHistoryController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    let refreshPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    var refreshCounter = 0
    var latestEntriesByPeerId: [Int64: YougramHistoryIndexEntry] = [:]

    let arguments = HistoryArguments(
        toggle: { tag, value in
            let _ = updateYougramSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                switch tag {
                case "saveDeleted":
                    settings.saveDeletedMessages = value
                case "saveEdits":
                    settings.saveEditHistory = value
                default:
                    break
                }
                return settings
            }).start()
        },
        performAction: { tag in
            if tag.hasPrefix("peer:"), let peerInt64 = Int64(tag.dropFirst("peer:".count)), let entry = latestEntriesByPeerId[peerInt64] {
                pushImpl?(yougramDeletedMessagesController(context: context, peerId: entry.peerId, peerTitle: entry.peerTitle, includeEdited: true))
            } else if tag == "clearAll" {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let strings = presentationData.strings
                let alert = textAlertController(
                    context: context,
                    title: strings.Yougram_History_ClearAll,
                    text: strings.Yougram_History_ClearAllConfirm,
                    actions: [
                        TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                        TextAlertAction(type: .destructiveAction, title: strings.Yougram_History_ClearAllAction, action: {
                            let _ = (context.engine.messages.yougramClearHistory(peerId: nil)
                            |> deliverOnMainQueue).startStandalone(completed: {
                                refreshCounter += 1
                                refreshPromise.set(refreshCounter)
                            })
                        })
                    ]
                )
                presentImpl?(alert)
            }
        }
    )

    let statsSignal = refreshPromise.get()
    |> mapToSignal { _ -> Signal<YougramHistoryStats, NoError> in
        return context.engine.messages.yougramAllHistoryStats()
    }

    let signal = combineLatest(context.sharedContext.presentationData, YougramSettings.updates, statsSignal)
    |> deliverOnMainQueue
    |> map { presentationData, settings, stats -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var map: [Int64: YougramHistoryIndexEntry] = [:]
        for entry in stats.entries {
            map[entry.peerId.toInt64()] = entry
        }
        latestEntriesByPeerId = map

        var entries: [HistoryEntry] = []
        var nextId: Int32 = 0
        func id() -> Int32 {
            nextId += 1
            return nextId
        }

        entries.append(.toggle(id: id(), section: 0, title: strings.Yougram_History_SaveDeleted, value: settings.saveDeletedMessages, tag: "saveDeleted"))
        entries.append(.toggle(id: id(), section: 0, title: strings.Yougram_History_SaveEdits, value: settings.saveEditHistory, tag: "saveEdits"))
        entries.append(.info(id: id(), section: 0, text: strings.Yougram_History_Info))

        entries.append(.header(id: id(), section: 1, text: strings.Yougram_History_SavedChats))
        if stats.entries.isEmpty {
            entries.append(.info(id: id(), section: 1, text: strings.Yougram_History_Empty))
        } else {
            for entry in stats.entries {
                let summary = "\(strings.Yougram_History_DeletedCountLabel): \(entry.deletedCount) · \(strings.Yougram_History_EditedCountLabel): \(entry.editedCount)"
                entries.append(.disclosure(
                    id: id(),
                    section: 1,
                    title: entry.peerTitle,
                    titleBold: false,
                    label: summary,
                    arrow: true,
                    actionTag: "peer:\(entry.peerId.toInt64())"
                ))
            }
        }

        if !stats.entries.isEmpty {
            entries.append(.action(id: id(), section: 2, title: strings.Yougram_History_ClearAll, destructive: true, tag: "clearAll"))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(strings.Yougram_Privacy_LocalHistory),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    return controller
}

/// Lists locally preserved deleted messages (and optionally edited messages) for a chat or thread.
public func yougramDeletedMessagesController(
    context: AccountContext,
    peerId: EnginePeer.Id,
    peerTitle: String,
    threadId: Int64? = nil,
    includeEdited: Bool = false
) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    let refreshPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    var refreshCounter = 0
    var copyableTexts: [String: String] = [:]
    var editedById: [String: YougramEditedMessageRecord] = [:]

    let arguments = HistoryArguments(
        toggle: { _, _ in },
        performAction: { tag in
            if tag.hasPrefix("copy:"), let text = copyableTexts[tag] {
                copyTextWithToast(context: context, text: text, present: presentImpl)
            } else if tag.hasPrefix("edited:"), let record = editedById[tag] {
                pushImpl?(yougramEditHistoryController(context: context, messageId: record.messageId, currentText: nil))
            } else if tag == "clearChat" {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let strings = presentationData.strings
                let alert = textAlertController(
                    context: context,
                    title: strings.Yougram_History_ClearChat,
                    text: strings.Yougram_History_ClearChatConfirm,
                    actions: [
                        TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                        TextAlertAction(type: .destructiveAction, title: strings.Yougram_History_ClearAllAction, action: {
                            let _ = (context.engine.messages.yougramClearHistory(peerId: peerId)
                            |> deliverOnMainQueue).startStandalone(completed: {
                                refreshCounter += 1
                                refreshPromise.set(refreshCounter)
                            })
                        })
                    ]
                )
                presentImpl?(alert)
            }
        }
    )

    let dataSignal = refreshPromise.get()
    |> mapToSignal { _ -> Signal<([YougramDeletedMessageRecord], [YougramEditedMessageRecord]), NoError> in
        let deleted = context.engine.messages.yougramDeletedMessages(peerId: peerId, threadId: threadId)
        let edited: Signal<[YougramEditedMessageRecord], NoError> = includeEdited ? context.engine.messages.yougramPeerEditedMessages(peerId: peerId) : .single([])
        return combineLatest(deleted, edited)
    }

    let signal = combineLatest(context.sharedContext.presentationData, dataSignal)
    |> deliverOnMainQueue
    |> map { presentationData, data -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (deletedRecords, editedRecords) = data
        let strings = presentationData.strings

        var newCopyable: [String: String] = [:]
        var newEdited: [String: YougramEditedMessageRecord] = [:]
        var entries: [HistoryEntry] = []
        var nextId: Int32 = 0
        func id() -> Int32 {
            nextId += 1
            return nextId
        }

        var section: Int32 = 0
        if includeEdited || !deletedRecords.isEmpty {
            entries.append(.header(id: id(), section: section, text: strings.Yougram_History_DeletedSection))
        }
        if deletedRecords.isEmpty {
            entries.append(.info(id: id(), section: section, text: strings.Yougram_History_NoDeleted))
        } else {
            for (index, record) in deletedRecords.enumerated() {
                let headerParts = [record.authorName, formatHistoryTimestamp(record.deletedTimestamp)].compactMap { $0 }.filter { !$0.isEmpty }
                let title = headerParts.joined(separator: " • ")
                let bodyParts = [record.mediaSummary, record.text].compactMap { $0 }.filter { !$0.isEmpty }
                let body = bodyParts.joined(separator: "\n")
                let tag = "copy:\(index)"
                newCopyable[tag] = record.text.isEmpty ? body : record.text
                entries.append(.disclosure(
                    id: id(),
                    section: section,
                    title: title,
                    titleBold: true,
                    label: body,
                    arrow: false,
                    actionTag: tag
                ))
            }
            entries.append(.info(id: id(), section: section, text: strings.Yougram_History_TapToCopy))
        }

        if includeEdited && !editedRecords.isEmpty {
            section += 1
            entries.append(.header(id: id(), section: section, text: strings.Yougram_History_EditedSection))
            for record in editedRecords {
                let tag = "edited:\(record.messageId.namespace)_\(record.messageId.id)"
                newEdited[tag] = record
                let preview = record.versions.last?.text ?? ""
                let title = record.authorName ?? peerTitle
                entries.append(.disclosure(
                    id: id(),
                    section: section,
                    title: title,
                    titleBold: false,
                    label: preview,
                    arrow: true,
                    actionTag: tag
                ))
            }
        }

        if !deletedRecords.isEmpty || (includeEdited && !editedRecords.isEmpty) {
            section += 1
            entries.append(.action(id: id(), section: section, title: strings.Yougram_History_ClearChat, destructive: true, tag: "clearChat"))
        }

        copyableTexts = newCopyable
        editedById = newEdited

        let titleText = peerTitle.isEmpty ? strings.Yougram_History_ViewDeleted : peerTitle
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(titleText),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    return controller
}

/// Lists saved previous text versions of an edited message.
public func yougramEditHistoryController(
    context: AccountContext,
    messageId: EngineMessage.Id,
    currentText: String? = nil
) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    var copyableTexts: [String: String] = [:]

    let arguments = HistoryArguments(
        toggle: { _, _ in },
        performAction: { tag in
            if let text = copyableTexts[tag] {
                copyTextWithToast(context: context, text: text, present: presentImpl)
            }
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.yougramEditHistory(messageId: messageId))
    |> deliverOnMainQueue
    |> map { presentationData, record -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var newCopyable: [String: String] = [:]
        var entries: [HistoryEntry] = []
        var nextId: Int32 = 0
        func id() -> Int32 {
            nextId += 1
            return nextId
        }

        var section: Int32 = 0
        if let currentText, !currentText.isEmpty {
            entries.append(.header(id: id(), section: section, text: strings.Yougram_History_CurrentVersion))
            newCopyable["current"] = currentText
            entries.append(.disclosure(
                id: id(),
                section: section,
                title: strings.Yougram_History_CurrentVersion,
                titleBold: true,
                label: currentText,
                arrow: false,
                actionTag: "current"
            ))
            section += 1
        }

        let versions = Array((record?.versions ?? []).reversed())
        entries.append(.header(id: id(), section: section, text: strings.Yougram_History_PreviousVersions))
        if versions.isEmpty {
            entries.append(.info(id: id(), section: section, text: strings.Yougram_History_NoEdits))
        } else {
            for (index, version) in versions.enumerated() {
                let tag = "ver:\(index)"
                newCopyable[tag] = version.text
                entries.append(.disclosure(
                    id: id(),
                    section: section,
                    title: formatHistoryTimestamp(version.timestamp),
                    titleBold: true,
                    label: version.text,
                    arrow: false,
                    actionTag: tag
                ))
            }
            entries.append(.info(id: id(), section: section, text: strings.Yougram_History_TapToCopy))
        }

        copyableTexts = newCopyable

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(strings.Yougram_History_EditHistory),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    return controller
}
