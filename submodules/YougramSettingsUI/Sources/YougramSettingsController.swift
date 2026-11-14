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

private let yougramPurple = [UIColor(rgb: 0xB78EFF), UIColor(rgb: 0x6233E0)]

/// The Settings row that opens Settings ▸ Yougram.
public let yougramSettingsIcon: UIImage? = renderSettingsIcon(name: "Item List/Icons/Settings", backgroundColors: yougramPurple)

private let sourceCodeURL = "https://github.com/YougramTeam/Yougram-iOS"

private enum YougramScreen {
    case main
    case general
    case appearance
    case chats
    case privacy
    case contextMenu
}

private func yougramEntries(screen: YougramScreen, settings: YougramSettings, strings: PresentationStrings) -> [YougramSettingsEntry] {
    var b = YougramEntriesBuilder()
    switch screen {
    case .main:
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        b.appHeader(version: strings.Yougram_Settings_Version(version).string, text: strings.Yougram_Settings_Description)
        b.newSection()
        b.header(strings.Yougram_Settings_Categories)
        b.link(strings.Yougram_Settings_General, icon: PresentationResourcesSettings.settings, to: .general)
        b.link(strings.Yougram_Settings_Appearance, icon: PresentationResourcesSettings.appearance, to: .appearance)
        b.link(strings.Yougram_Settings_Chats, icon: PresentationResourcesSettings.privateChats, to: .chats)
        b.link(strings.Yougram_Settings_Privacy, icon: PresentationResourcesSettings.security, to: .privacy)
        b.newSection()
        b.header(strings.Yougram_Settings_Links)
        b.link(strings.Yougram_Settings_SourceCode, icon: PresentationResourcesSettings.links, label: strings.Yougram_Settings_SourceCodeValue, to: .url(sourceCodeURL))
    case .general:
        b.header(strings.Yougram_General_Accounts)
        b.link(strings.Yougram_General_AccountsBackup, icon: PresentationResourcesSettings.activeSessions, to: .accountsBackup)
        b.toggle(strings.Yougram_General_AutoBackup, settings, \.autoBackupAccounts)
        b.info(strings.Yougram_General_AccountsInfo)
        b.newSection()
        b.header(strings.Yougram_General_Features)
        b.toggle(strings.Yougram_General_Transcription, settings, \.localVoiceTranscription)
        b.info(strings.Yougram_General_TranscriptionInfo)
        b.newSection()
        b.toggle(strings.Yougram_General_HideAds, settings, \.hideAds)
        b.info(strings.Yougram_General_HideAdsInfo)
    case .privacy:
        b.toggle(strings.Yougram_Privacy_HidePhone, settings, \.hidePhoneInSettings)
        b.info(strings.Yougram_Privacy_HidePhoneInfo)
        b.newSection()
        b.toggle(strings.Yougram_Privacy_HideAccountInNotifications, settings, \.hideAccountNameInNotifications)
        b.info(strings.Yougram_Privacy_HideAccountInNotificationsInfo)
        b.newSection()
        b.header(strings.Yougram_Privacy_Passcode)
        b.toggle(strings.Yougram_Privacy_ScrambleKeypad, settings, \.scramblePasscodeKeypad)
        b.link(strings.Yougram_Privacy_DuressCode, to: .duressCode)
        b.info(strings.Yougram_Privacy_ScrambleKeypadInfo)
    case .appearance:
        b.header(strings.Yougram_Appearance_ChatList)
        b.toggle(strings.Yougram_Appearance_CompactChatList, settings, \.compactChatList)
        b.newSection()
        b.header(strings.Yougram_Appearance_Folders)
        b.toggle(strings.Yougram_Appearance_HideAllChats, settings, \.hideAllChatsFolder)
        b.toggle(strings.Yougram_Appearance_FoldersAtBottom, settings, \.foldersAtBottom)
        b.toggle(strings.Yougram_Appearance_RememberFolder, settings, \.rememberLastFolder)
        b.toggle(strings.Yougram_Appearance_CompactFolders, settings, \.compactFolderTabs)
        b.info(strings.Yougram_Appearance_FoldersInfo)
        b.newSection()
        b.header(strings.Yougram_Appearance_Tabs)
        b.toggle(strings.Yougram_Appearance_ContactsTab, settings, \.showContactsTab)
        b.toggle(strings.Yougram_Appearance_TabLabels, settings, \.showTabLabels, requiresRestart: true)
        b.toggle(strings.Yougram_Appearance_BottomSearch, settings, \.keepBottomSearch)
        b.newSection()
        b.header(strings.Yougram_Appearance_Stories)
        b.toggle(strings.Yougram_Appearance_HideStories, settings, \.hideStories)
        b.toggle(strings.Yougram_Appearance_DisableStorySwipe, settings, \.disableStorySwipe)
        b.toggle(strings.Yougram_Appearance_HideRepostToStory, settings, \.hideRepostToStory)
        b.newSection()
        b.header(strings.Yougram_Appearance_Glass)
        b.toggle(strings.Yougram_Appearance_ReduceGlass, settings, \.reduceGlass, requiresRestart: true)
        b.info(strings.Yougram_Appearance_ReduceGlassInfo)
    case .chats:
        b.header(strings.Yougram_Chats_Input)
        b.toggle(strings.Yougram_Chats_QuickFormatting, settings, \.quickFormattingPanel)
        b.toggle(strings.Yougram_Chats_RecordingHints, settings, \.disableRecordingHints)
        b.info(strings.Yougram_Chats_QuickFormattingInfo)
        b.newSection()
        b.header(strings.Yougram_Chats_Messages)
        b.toggle(strings.Yougram_Chats_HideReactions, settings, \.hideReactions)
        b.toggle(strings.Yougram_Chats_StandardEmojiFirst, settings, \.standardEmojiFirst)
        b.link(strings.Yougram_Chats_ContextMenu, to: .contextMenu)
        b.newSection()
        b.header(strings.Yougram_Chats_Navigation)
        b.toggle(strings.Yougram_Chats_DisableNextTopic, settings, \.disableAutoNextTopic)
        b.toggle(strings.Yougram_Chats_DiscussionButton, settings, \.discussionGroupButton)
        b.info(strings.Yougram_Chats_NavigationInfo)
        b.newSection()
        b.header(strings.Yougram_Chats_GroupsAndChannels)
        b.toggle(strings.Yougram_Chats_KeepBannedChats, settings, \.keepChatsAfterBan)
        b.info(strings.Yougram_Chats_KeepBannedChatsInfo)
        b.newSection()
        b.header(strings.Yougram_Chats_Media)
        b.toggle(strings.Yougram_Chats_SendHD, settings, \.sendHDPhotos)
        b.toggle(strings.Yougram_Chats_PasteHD, settings, \.hdPhotosFromClipboard)
        b.toggle(strings.Yougram_Chats_AirPlay, settings, \.airPlayButton)
        b.toggle(strings.Yougram_Chats_DisablePip, settings, \.disablePipOnSwipe)
        b.toggle(strings.Yougram_Chats_SmallVideoControls, settings, \.disableLargeVideoControls)
    case .contextMenu:
        for action in YougramContextMenuAction.allCases {
            b.contextMenuToggle(yougramContextMenuActionTitle(action, strings: strings), settings, action)
        }
        b.info(strings.Yougram_ContextMenu_Info)
    }
    return b.entries
}

func yougramContextMenuActionTitle(_ action: YougramContextMenuAction, strings: PresentationStrings) -> String {
    switch action {
    case .reply:
        return strings.Conversation_ContextMenuReply
    case .copy:
        return strings.Conversation_ContextMenuCopy
    case .translate:
        return strings.Conversation_ContextMenuTranslate
    case .speak:
        return strings.Conversation_ContextMenuSpeak
    case .saveMedia:
        return strings.Gallery_SaveToGallery
    case .saveToFiles:
        return strings.Conversation_SaveToFiles
    case .viewReplies:
        return strings.Conversation_TitleRepliesEmpty
    case .edit:
        return strings.Conversation_Edit
    case .pin:
        return strings.Conversation_Pin
    case .copyLink:
        return strings.Conversation_ContextMenuCopyLink
    case .forward:
        return strings.Conversation_ContextMenuForward
    case .report:
        return strings.Conversation_ContextMenuReport
    case .select:
        return strings.Conversation_ContextMenuSelect
    case .stats:
        return strings.Conversation_ContextViewStats
    case .saveGif:
        return strings.Conversation_SaveGif
    case .viewStickerPack:
        return strings.StickerPack_ViewPack
    case .delete:
        return strings.Conversation_ContextMenuDelete
    }
}

private func yougramTitle(_ screen: YougramScreen, strings: PresentationStrings) -> String {
    switch screen {
    case .main:
        return strings.Yougram_Settings_Title
    case .general:
        return strings.Yougram_Settings_General
    case .appearance:
        return strings.Yougram_Settings_Appearance
    case .chats:
        return strings.Yougram_Settings_Chats
    case .privacy:
        return strings.Yougram_Settings_Privacy
    case .contextMenu:
        return strings.Yougram_ContextMenu_Title
    }
}

private func yougramScreenController(context: AccountContext, screen: YougramScreen) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = YougramSettingsArguments(updateToggle: { key, value, requiresRestart in
        let _ = updateYougramSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            settings[keyPath: key] = value
            return settings
        }).start()
        if requiresRestart {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: presentationData.strings.Yougram_Settings_RestartNotice, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
        }
    }, updateContextMenuAction: { action, isVisible in
        let _ = updateYougramSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            var hidden = Set(settings.hiddenContextMenuActions)
            if isVisible {
                hidden.remove(action.rawValue)
            } else {
                hidden.insert(action.rawValue)
            }
            settings.hiddenContextMenuActions = YougramContextMenuAction.allCases.map(\.rawValue).filter { hidden.contains($0) }
            return settings
        }).start()
    }, open: { target in
        switch target {
        case .general:
            pushControllerImpl?(yougramScreenController(context: context, screen: .general))
        case .appearance:
            pushControllerImpl?(yougramScreenController(context: context, screen: .appearance))
        case .chats:
            pushControllerImpl?(yougramScreenController(context: context, screen: .chats))
        case .privacy:
            pushControllerImpl?(yougramScreenController(context: context, screen: .privacy))
        case .contextMenu:
            pushControllerImpl?(yougramScreenController(context: context, screen: .contextMenu))
        case .accountsBackup:
            pushControllerImpl?(yougramAccountsBackupController(context: context))
        case .duressCode:
            if let controller = yougramDuressCodeController(context: context, present: { c in presentControllerImpl?(c) }) {
                pushControllerImpl?(controller)
            }
        case let .url(url):
            context.sharedContext.applicationBindings.openUrl(url)
        }
    }, performAction: { _ in
    })

    let signal = combineLatest(context.sharedContext.presentationData, YougramSettings.updates)
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(yougramTitle(screen, strings: presentationData.strings)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: yougramEntries(screen: screen, settings: settings, strings: presentationData.strings), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    return controller
}

/// Settings ▸ Yougram.
public func yougramSettingsController(context: AccountContext) -> ViewController {
    return yougramScreenController(context: context, screen: .main)
}
