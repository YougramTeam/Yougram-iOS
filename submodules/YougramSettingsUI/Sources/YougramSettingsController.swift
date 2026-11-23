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
import PasscodeCore

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
    case ghostMode
    case contextMenu
}

private func isYougramGhostSubToggle(_ key: WritableKeyPath<YougramSettings, Bool>) -> Bool {
    return key == \.ghostHideReadReceipts ||
        key == \.ghostHideVoiceListened ||
        key == \.ghostHideRoundWatched ||
        key == \.ghostHideStoryViews ||
        key == \.ghostHideOnline ||
        key == \.ghostHideTyping ||
        key == \.ghostHideUploading ||
        key == \.ghostHideChoosingSticker ||
        key == \.ghostHideOtherActivities ||
        key == \.ghostAutoOffline ||
        key == \.ghostReadOnInteract ||
        key == \.ghostSendAsScheduled
}

private enum YougramSearchableKind {
    case link(label: String, target: YougramSettingsLink)
    case toggle(key: WritableKeyPath<YougramSettings, Bool>, requiresRestart: Bool)
}

private struct YougramSearchableItem {
    let title: String
    let category: String
    let iconName: String
    let keywords: String
    let destructive: Bool
    let enabled: Bool
    let kind: YougramSearchableKind
}

private func yougramAllSearchableItems(
    settings: YougramSettings,
    localEncryptionEnabled: Bool,
    strings: PresentationStrings
) -> [YougramSearchableItem] {
    let ghostOn = settings.ghostModeEnabled
    let ghostStateLabel = ghostOn ? strings.Yougram_Ghost_On : strings.Yougram_Ghost_Off
    let historyOn = settings.saveDeletedMessages || settings.saveEditHistory
    let historyStateLabel = historyOn ? strings.Yougram_Ghost_On : strings.Yougram_Ghost_Off
    let encryptionStateLabel = localEncryptionEnabled ? strings.Yougram_Encryption_On : strings.Yougram_Encryption_Off
    let totalMenuActions = YougramContextMenuAction.allCases.count
    let hiddenMenuActions = settings.hiddenContextMenuActions.count
    let menuStateLabel = hiddenMenuActions > 0 ? "\(totalMenuActions - hiddenMenuActions)/\(totalMenuActions)" : ""

    return [
        // Screens / Quick Access
        YougramSearchableItem(title: strings.Yougram_Ghost_Title, category: strings.Yougram_Settings_Privacy, iconName: "eye.slash", keywords: "ghost stealth invisible privacy", destructive: false, enabled: true, kind: .link(label: ghostStateLabel, target: .ghostMode)),
        YougramSearchableItem(title: strings.Yougram_Privacy_LocalHistory, category: strings.Yougram_Settings_Privacy, iconName: "clock.arrow.circlepath", keywords: "anti recall anti-recall deleted edit history log database", destructive: false, enabled: true, kind: .link(label: historyStateLabel, target: .localHistory)),
        YougramSearchableItem(title: strings.Yougram_Privacy_LocalEncryption, category: strings.Yougram_Settings_Privacy, iconName: "lock.shield", keywords: "vault encrypt cipher security storage lock password", destructive: false, enabled: true, kind: .link(label: encryptionStateLabel, target: .localEncryption)),
        YougramSearchableItem(title: strings.Yougram_General_AccountsBackup, category: strings.Yougram_Settings_General, iconName: "key", keywords: "account backup restore icloud keychain session", destructive: false, enabled: true, kind: .link(label: "", target: .accountsBackup)),
        YougramSearchableItem(title: strings.Yougram_Privacy_DuressCode, category: strings.Yougram_Settings_Privacy, iconName: "flame", keywords: "duress panic wipe code passcode emergency", destructive: true, enabled: true, kind: .link(label: "", target: .duressCode)),
        YougramSearchableItem(title: strings.Yougram_Chats_ContextMenu, category: strings.Yougram_Settings_Chats, iconName: "list.bullet", keywords: "message menu context actions hide customize", destructive: false, enabled: true, kind: .link(label: menuStateLabel, target: .contextMenu)),

        // Privacy
        YougramSearchableItem(title: strings.Yougram_Ghost_StoryWarning, category: strings.Yougram_Settings_Privacy, iconName: "exclamationmark.triangle", keywords: "story warning prompt confirm ghost", destructive: false, enabled: true, kind: .toggle(key: \.ghostStoryWarning, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Privacy_AllowCopyProtected, category: strings.Yougram_Settings_Privacy, iconName: "doc.on.doc", keywords: "copy download screenshot protected content restrict save", destructive: false, enabled: true, kind: .toggle(key: \.allowCopyProtectedContent, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Privacy_HideBlockedUsers, category: strings.Yougram_Settings_Privacy, iconName: "person.crop.circle.badge.xmark", keywords: "blocked users filter hide group messages", destructive: false, enabled: true, kind: .toggle(key: \.hideBlockedUsersMessages, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Privacy_HidePhone, category: strings.Yougram_Settings_Privacy, iconName: "phone.down", keywords: "phone number hide settings profile screen share", destructive: false, enabled: true, kind: .toggle(key: \.hidePhoneInSettings, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Privacy_HideAccountInNotifications, category: strings.Yougram_Settings_Privacy, iconName: "bell.slash", keywords: "notifications hide account name", destructive: false, enabled: true, kind: .toggle(key: \.hideAccountNameInNotifications, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Privacy_ScrambleKeypad, category: strings.Yougram_Settings_Privacy, iconName: "circle.grid.3x3", keywords: "passcode scramble keypad randomize digits", destructive: false, enabled: true, kind: .toggle(key: \.scramblePasscodeKeypad, requiresRestart: false)),

        // Ghost Mode toggles
        YougramSearchableItem(title: strings.Yougram_Ghost_Title, category: strings.Yougram_Ghost_Title, iconName: "eye.slash", keywords: "ghost mode master enable stealth", destructive: false, enabled: true, kind: .toggle(key: \.ghostModeEnabled, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_ReadReceipts, category: strings.Yougram_Ghost_Title, iconName: "checkmark.circle", keywords: "read receipts unread checkmarks blue ticks ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideReadReceipts, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_VoiceListened, category: strings.Yougram_Ghost_Title, iconName: "waveform", keywords: "voice audio listened ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideVoiceListened, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_RoundWatched, category: strings.Yougram_Ghost_Title, iconName: "video.circle", keywords: "round video note watched ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideRoundWatched, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_StoryViews, category: strings.Yougram_Ghost_Title, iconName: "eye", keywords: "stories view count anonymous ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideStoryViews, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_Online, category: strings.Yougram_Ghost_Title, iconName: "circle", keywords: "online status presence offline last seen ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideOnline, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_Typing, category: strings.Yougram_Ghost_Title, iconName: "keyboard", keywords: "typing activity indicator ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideTyping, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_Uploading, category: strings.Yougram_Ghost_Title, iconName: "arrow.up.doc", keywords: "uploading sending photo video activity ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideUploading, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_ChoosingSticker, category: strings.Yougram_Ghost_Title, iconName: "face.smiling", keywords: "sticker choosing activity ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideChoosingSticker, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_OtherActivities, category: strings.Yougram_Ghost_Title, iconName: "ellipsis.circle", keywords: "game recording activity ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostHideOtherActivities, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_AutoOffline, category: strings.Yougram_Ghost_Title, iconName: "moon", keywords: "auto offline last seen ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostAutoOffline, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_ReadOnInteract, category: strings.Yougram_Ghost_Title, iconName: "arrow.uturn.right", keywords: "read on interact reply react send ghost", destructive: false, enabled: ghostOn && settings.ghostHideReadReceipts, kind: .toggle(key: \.ghostReadOnInteract, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Ghost_SendAsScheduled, category: strings.Yougram_Ghost_Title, iconName: "clock", keywords: "schedule silent send ghost", destructive: false, enabled: ghostOn, kind: .toggle(key: \.ghostSendAsScheduled, requiresRestart: false)),

        // General
        YougramSearchableItem(title: strings.Yougram_General_AutoBackup, category: strings.Yougram_Settings_General, iconName: "icloud", keywords: "auto backup logins accounts keychain", destructive: false, enabled: true, kind: .toggle(key: \.autoBackupAccounts, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_General_Transcription, category: strings.Yougram_Settings_General, iconName: "waveform", keywords: "voice speech transcribe free transcription apple", destructive: false, enabled: true, kind: .toggle(key: \.localVoiceTranscription, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_General_HideAds, category: strings.Yougram_Settings_General, iconName: "nosign", keywords: "ads sponsored channel promoted block remove", destructive: false, enabled: true, kind: .toggle(key: \.hideAds, requiresRestart: false)),

        // Appearance
        YougramSearchableItem(title: strings.Yougram_Appearance_CompactChatList, category: strings.Yougram_Settings_Appearance, iconName: "rectangle.compress.vertical", keywords: "compact chat list rows density", destructive: false, enabled: true, kind: .toggle(key: \.compactChatList, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_HideAllChats, category: strings.Yougram_Settings_Appearance, iconName: "folder.badge.minus", keywords: "folders hide all chats tab", destructive: false, enabled: true, kind: .toggle(key: \.hideAllChatsFolder, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_FoldersAtBottom, category: strings.Yougram_Settings_Appearance, iconName: "tray.and.arrow.down", keywords: "folders bottom tabs layout", destructive: false, enabled: true, kind: .toggle(key: \.foldersAtBottom, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_RememberFolder, category: strings.Yougram_Settings_Appearance, iconName: "folder", keywords: "folders remember last open", destructive: false, enabled: true, kind: .toggle(key: \.rememberLastFolder, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_CompactFolders, category: strings.Yougram_Settings_Appearance, iconName: "rectangle.split.3x1", keywords: "folders compact tabs width", destructive: false, enabled: true, kind: .toggle(key: \.compactFolderTabs, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_ContactsTab, category: strings.Yougram_Settings_Appearance, iconName: "person.2", keywords: "contacts tab bar show hide", destructive: false, enabled: true, kind: .toggle(key: \.showContactsTab, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_TabLabels, category: strings.Yougram_Settings_Appearance, iconName: "tag", keywords: "tab bar labels titles restart", destructive: false, enabled: true, kind: .toggle(key: \.showTabLabels, requiresRestart: true)),
        YougramSearchableItem(title: strings.Yougram_Appearance_BottomSearch, category: strings.Yougram_Settings_Appearance, iconName: "magnifyingglass", keywords: "search bottom tab bar", destructive: false, enabled: true, kind: .toggle(key: \.keepBottomSearch, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_HideStories, category: strings.Yougram_Settings_Appearance, iconName: "eye.slash", keywords: "stories hide chat list", destructive: false, enabled: true, kind: .toggle(key: \.hideStories, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_DisableStorySwipe, category: strings.Yougram_Settings_Appearance, iconName: "camera", keywords: "story camera swipe disable gesture", destructive: false, enabled: true, kind: .toggle(key: \.disableStorySwipe, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_HideRepostToStory, category: strings.Yougram_Settings_Appearance, iconName: "arrowshape.turn.up.right", keywords: "repost story hide button", destructive: false, enabled: true, kind: .toggle(key: \.hideRepostToStory, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Appearance_ReduceGlass, category: strings.Yougram_Settings_Appearance, iconName: "sparkles", keywords: "liquid glass blur transparency reduce restart", destructive: false, enabled: true, kind: .toggle(key: \.reduceGlass, requiresRestart: true)),

        // Chats
        YougramSearchableItem(title: strings.Yougram_Chats_QuickFormatting, category: strings.Yougram_Settings_Chats, iconName: "textformat", keywords: "quick formatting bold italic code keyboard panel", destructive: false, enabled: true, kind: .toggle(key: \.quickFormattingPanel, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_RecordingHints, category: strings.Yougram_Settings_Chats, iconName: "mic.slash", keywords: "recording hints voice disable tooltip", destructive: false, enabled: true, kind: .toggle(key: \.disableRecordingHints, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_HideReactions, category: strings.Yougram_Settings_Chats, iconName: "heart.slash", keywords: "reactions hide bubbles chat", destructive: false, enabled: true, kind: .toggle(key: \.hideReactions, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_StandardEmojiFirst, category: strings.Yougram_Settings_Chats, iconName: "face.smiling", keywords: "emoji picker keyboard standard first", destructive: false, enabled: true, kind: .toggle(key: \.standardEmojiFirst, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_DisableNextTopic, category: strings.Yougram_Settings_Chats, iconName: "arrow.right.circle", keywords: "forum topic pull next disable", destructive: false, enabled: true, kind: .toggle(key: \.disableAutoNextTopic, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_DiscussionButton, category: strings.Yougram_Settings_Chats, iconName: "bubble.left", keywords: "channel discussion comments group button", destructive: false, enabled: true, kind: .toggle(key: \.discussionGroupButton, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_KeepBannedChats, category: strings.Yougram_Settings_Chats, iconName: "tray", keywords: "banned kicked chats channels keep local", destructive: false, enabled: true, kind: .toggle(key: \.keepChatsAfterBan, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_SendHD, category: strings.Yougram_Settings_Chats, iconName: "photo", keywords: "hd photos high quality upload send", destructive: false, enabled: true, kind: .toggle(key: \.sendHDPhotos, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_PasteHD, category: strings.Yougram_Settings_Chats, iconName: "doc.on.clipboard", keywords: "hd clipboard paste photo high quality", destructive: false, enabled: true, kind: .toggle(key: \.hdPhotosFromClipboard, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_AirPlay, category: strings.Yougram_Settings_Chats, iconName: "airplayvideo", keywords: "airplay video player menu", destructive: false, enabled: true, kind: .toggle(key: \.airPlayButton, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_DisablePip, category: strings.Yougram_Settings_Chats, iconName: "rectangle.on.rectangle", keywords: "picture in picture pip swipe disable", destructive: false, enabled: true, kind: .toggle(key: \.disablePipOnSwipe, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_SmallVideoControls, category: strings.Yougram_Settings_Chats, iconName: "slider.horizontal.3", keywords: "small compact video controls player", destructive: false, enabled: true, kind: .toggle(key: \.disableLargeVideoControls, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_CameraOptimization, category: strings.Yougram_Settings_Chats, iconName: "speedometer", keywords: "camera optimization circle video lag crash performance", destructive: false, enabled: true, kind: .toggle(key: \.cameraOptimization, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_CameraStartUltraWide, category: strings.Yougram_Settings_Chats, iconName: "camera.aperture", keywords: "camera zoom 0.5 ultra wide back default", destructive: false, enabled: true, kind: .toggle(key: \.cameraStartUltraWide, requiresRestart: false)),
        YougramSearchableItem(title: strings.Yougram_Chats_CameraZoomSlider, category: strings.Yougram_Settings_Chats, iconName: "slider.horizontal.3", keywords: "camera zoom slider video message", destructive: false, enabled: true, kind: .toggle(key: \.cameraZoomSlider, requiresRestart: false)),
    ]
}

private func yougramMainQuickAndCategoryEntries(
    into b: inout YougramEntriesBuilder,
    settings: YougramSettings,
    localEncryptionEnabled: Bool,
    theme: PresentationTheme,
    strings: PresentationStrings
) {
    let historyOn = settings.saveDeletedMessages || settings.saveEditHistory
    b.header(strings.Yougram_Settings_QuickAccess)
    b.link(
        strings.Yougram_Ghost_Title,
        icon: yougramIcon("eye.slash", theme: theme),
        label: settings.ghostModeEnabled ? strings.Yougram_Ghost_On : strings.Yougram_Ghost_Off,
        to: .ghostMode
    )
    b.link(
        strings.Yougram_Privacy_LocalHistory,
        icon: yougramIcon("clock.arrow.circlepath", theme: theme),
        label: historyOn ? strings.Yougram_Ghost_On : strings.Yougram_Ghost_Off,
        to: .localHistory
    )
    b.link(
        strings.Yougram_Privacy_LocalEncryption,
        icon: yougramIcon("lock.shield", theme: theme),
        label: localEncryptionEnabled ? strings.Yougram_Encryption_On : strings.Yougram_Encryption_Off,
        to: .localEncryption
    )
    b.link(
        strings.Yougram_General_AccountsBackup,
        icon: yougramIcon("key", theme: theme),
        to: .accountsBackup
    )
    b.newSection()
    b.header(strings.Yougram_Settings_Categories)
    b.link(
        strings.Yougram_Settings_Privacy,
        icon: yougramIcon("hand.raised", theme: theme),
        label: strings.Yougram_Settings_PrivacySummary,
        labelStyle: .detailText,
        to: .privacy
    )
    b.link(
        strings.Yougram_Settings_Chats,
        icon: yougramIcon("bubble.left.and.bubble.right", theme: theme),
        label: strings.Yougram_Settings_ChatsSummary,
        labelStyle: .detailText,
        to: .chats
    )
    b.link(
        strings.Yougram_Settings_Appearance,
        icon: yougramIcon("paintbrush", theme: theme),
        label: strings.Yougram_Settings_AppearanceSummary,
        labelStyle: .detailText,
        to: .appearance
    )
    b.link(
        strings.Yougram_Settings_General,
        icon: yougramIcon("slider.horizontal.3", theme: theme),
        label: strings.Yougram_Settings_GeneralSummary,
        labelStyle: .detailText,
        to: .general
    )
}

private func yougramSearchEntries(
    query: String,
    settings: YougramSettings,
    localEncryptionEnabled: Bool,
    theme: PresentationTheme,
    strings: PresentationStrings
) -> [YougramSettingsEntry] {
    var b = YougramEntriesBuilder()
    b.searchInput(text: query, placeholder: strings.Yougram_Settings_SearchPlaceholder)
    b.newSection()

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        yougramMainQuickAndCategoryEntries(
            into: &b,
            settings: settings,
            localEncryptionEnabled: localEncryptionEnabled,
            theme: theme,
            strings: strings
        )
        return b.entries
    }

    let tokens = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let matches = yougramAllSearchableItems(
        settings: settings,
        localEncryptionEnabled: localEncryptionEnabled,
        strings: strings
    ).filter { item in
        let haystack = "\(item.title) \(item.category) \(item.keywords)".lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    if matches.isEmpty {
        b.info(strings.Yougram_Settings_SearchNoResults(trimmed).string)
        return b.entries
    }

    for item in matches {
        let icon = yougramIcon(item.iconName, theme: theme, enabled: item.enabled, destructive: item.destructive)
        switch item.kind {
        case let .link(label, target):
            let detail = label.isEmpty ? item.category : "\(item.category) · \(label)"
            b.link(item.title, icon: icon, label: detail, labelStyle: .detailText, to: target)
        case let .toggle(key, requiresRestart):
            b.toggle(item.title, settings, key, icon: icon, subtitle: item.category, enabled: item.enabled, requiresRestart: requiresRestart)
        }
    }
    return b.entries
}

private func yougramEntries(screen: YougramScreen, settings: YougramSettings, localEncryptionEnabled: Bool, theme: PresentationTheme, strings: PresentationStrings) -> [YougramSettingsEntry] {
    var b = YougramEntriesBuilder()
    switch screen {
    case .main:
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        b.appHeader(version: strings.Yougram_Settings_Version(version).string, text: strings.Yougram_Settings_Description)
        b.newSection()
        yougramMainQuickAndCategoryEntries(
            into: &b,
            settings: settings,
            localEncryptionEnabled: localEncryptionEnabled,
            theme: theme,
            strings: strings
        )
        b.newSection()
        b.header(strings.Yougram_Settings_Links)
        b.link(strings.Yougram_Settings_SourceCode, icon: yougramIcon("chevron.left.forwardslash.chevron.right", theme: theme), label: strings.Yougram_Settings_SourceCodeValue, to: .url(sourceCodeURL))
    case .general:
        b.header(strings.Yougram_General_Accounts)
        b.link(strings.Yougram_General_AccountsBackup, icon: yougramIcon("key", theme: theme), to: .accountsBackup)
        b.toggle(strings.Yougram_General_AutoBackup, settings, \.autoBackupAccounts, icon: yougramIcon("icloud", theme: theme))
        b.info(strings.Yougram_General_AccountsInfo)
        b.newSection()
        b.header(strings.Yougram_General_Features)
        b.toggle(strings.Yougram_General_Transcription, settings, \.localVoiceTranscription, icon: yougramIcon("waveform", theme: theme))
        b.info(strings.Yougram_General_TranscriptionInfo)
        b.newSection()
        b.toggle(strings.Yougram_General_HideAds, settings, \.hideAds, icon: yougramIcon("nosign", theme: theme))
        b.info(strings.Yougram_General_HideAdsInfo)
    case .privacy:
        b.header(strings.Yougram_Privacy_StealthSection)
        b.link(strings.Yougram_Ghost_Title, icon: yougramIcon("eye.slash", theme: theme), label: settings.ghostModeEnabled ? strings.Yougram_Ghost_On : strings.Yougram_Ghost_Off, to: .ghostMode)
        b.toggle(strings.Yougram_Ghost_StoryWarning, settings, \.ghostStoryWarning, icon: yougramIcon("exclamationmark.triangle", theme: theme))
        b.info(strings.Yougram_Privacy_GhostModeInfo)
        b.newSection()
        b.header(strings.Yougram_Privacy_DataSection)
        b.link(strings.Yougram_Privacy_LocalHistory, icon: yougramIcon("clock.arrow.circlepath", theme: theme), label: (settings.saveDeletedMessages || settings.saveEditHistory) ? strings.Yougram_Ghost_On : strings.Yougram_Ghost_Off, to: .localHistory)
        b.link(strings.Yougram_Privacy_LocalEncryption, icon: yougramIcon("lock.shield", theme: theme), label: localEncryptionEnabled ? strings.Yougram_Encryption_On : strings.Yougram_Encryption_Off, to: .localEncryption)
        b.info(strings.Yougram_Privacy_LocalHistoryInfo)
        b.newSection()
        b.header(strings.Yougram_Privacy_ContentSection)
        b.toggle(strings.Yougram_Privacy_AllowCopyProtected, settings, \.allowCopyProtectedContent, icon: yougramIcon("doc.on.doc", theme: theme))
        b.toggle(strings.Yougram_Privacy_HideBlockedUsers, settings, \.hideBlockedUsersMessages, icon: yougramIcon("person.crop.circle.badge.xmark", theme: theme))
        b.info("\(strings.Yougram_Privacy_AllowCopyProtectedInfo)\n\n\(strings.Yougram_Privacy_HideBlockedUsersInfo)")
        b.newSection()
        b.header(strings.Yougram_Privacy_IdentitySection)
        b.toggle(strings.Yougram_Privacy_HidePhone, settings, \.hidePhoneInSettings, icon: yougramIcon("phone.down", theme: theme))
        b.toggle(strings.Yougram_Privacy_HideAccountInNotifications, settings, \.hideAccountNameInNotifications, icon: yougramIcon("bell.slash", theme: theme))
        b.info("\(strings.Yougram_Privacy_HidePhoneInfo)\n\n\(strings.Yougram_Privacy_HideAccountInNotificationsInfo)")
        b.newSection()
        b.header(strings.Yougram_Privacy_Passcode)
        b.toggle(strings.Yougram_Privacy_ScrambleKeypad, settings, \.scramblePasscodeKeypad, icon: yougramIcon("circle.grid.3x3", theme: theme))
        b.link(strings.Yougram_Privacy_DuressCode, icon: yougramIcon("flame", theme: theme, destructive: true), to: .duressCode)
        b.info(strings.Yougram_Privacy_ScrambleKeypadInfo)
    case .ghostMode:
        b.toggle(strings.Yougram_Ghost_Title, settings, \.ghostModeEnabled, icon: yougramIcon("eye.slash", theme: theme))
        b.info(strings.Yougram_Ghost_EnableInfo)
        b.newSection()
        b.header(strings.Yougram_Ghost_DontSend)
        b.toggle(strings.Yougram_Ghost_ReadReceipts, settings, \.ghostHideReadReceipts, icon: yougramIcon("checkmark.circle", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_VoiceListened, settings, \.ghostHideVoiceListened, icon: yougramIcon("waveform", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_RoundWatched, settings, \.ghostHideRoundWatched, icon: yougramIcon("video.circle", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_StoryViews, settings, \.ghostHideStoryViews, icon: yougramIcon("eye", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_Online, settings, \.ghostHideOnline, icon: yougramIcon("circle", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.info(strings.Yougram_Ghost_DontSendInfo)
        b.newSection()
        b.header(strings.Yougram_Ghost_Activity)
        b.toggle(strings.Yougram_Ghost_Typing, settings, \.ghostHideTyping, icon: yougramIcon("keyboard", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_Uploading, settings, \.ghostHideUploading, icon: yougramIcon("arrow.up.doc", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_ChoosingSticker, settings, \.ghostHideChoosingSticker, icon: yougramIcon("face.smiling", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.toggle(strings.Yougram_Ghost_OtherActivities, settings, \.ghostHideOtherActivities, icon: yougramIcon("ellipsis.circle", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.info(strings.Yougram_Ghost_ActivityInfo)
        b.newSection()
        b.header(strings.Yougram_Ghost_Options)
        b.toggle(strings.Yougram_Ghost_AutoOffline, settings, \.ghostAutoOffline, icon: yougramIcon("moon", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.info(strings.Yougram_Ghost_AutoOfflineInfo)
        b.newSection()
        let readOnInteractEnabled = settings.ghostModeEnabled && settings.ghostHideReadReceipts
        b.toggle(strings.Yougram_Ghost_ReadOnInteract, settings, \.ghostReadOnInteract, icon: yougramIcon("arrow.uturn.right", theme: theme, enabled: readOnInteractEnabled), enabled: readOnInteractEnabled)
        b.info(strings.Yougram_Ghost_ReadOnInteractInfo)
        b.newSection()
        b.toggle(strings.Yougram_Ghost_SendAsScheduled, settings, \.ghostSendAsScheduled, icon: yougramIcon("clock", theme: theme, enabled: settings.ghostModeEnabled), enabled: settings.ghostModeEnabled)
        b.info(strings.Yougram_Ghost_SendAsScheduledInfo)
    case .appearance:
        b.header(strings.Yougram_Appearance_ChatList)
        b.toggle(strings.Yougram_Appearance_CompactChatList, settings, \.compactChatList, icon: yougramIcon("rectangle.compress.vertical", theme: theme))
        b.newSection()
        b.header(strings.Yougram_Appearance_Folders)
        b.toggle(strings.Yougram_Appearance_HideAllChats, settings, \.hideAllChatsFolder, icon: yougramIcon("folder.badge.minus", theme: theme))
        b.toggle(strings.Yougram_Appearance_FoldersAtBottom, settings, \.foldersAtBottom, icon: yougramIcon("tray.and.arrow.down", theme: theme))
        b.toggle(strings.Yougram_Appearance_RememberFolder, settings, \.rememberLastFolder, icon: yougramIcon("folder", theme: theme))
        b.toggle(strings.Yougram_Appearance_CompactFolders, settings, \.compactFolderTabs, icon: yougramIcon("rectangle.split.3x1", theme: theme))
        b.info(strings.Yougram_Appearance_FoldersInfo)
        b.newSection()
        b.header(strings.Yougram_Appearance_Tabs)
        b.toggle(strings.Yougram_Appearance_ContactsTab, settings, \.showContactsTab, icon: yougramIcon("person.2", theme: theme))
        b.toggle(strings.Yougram_Appearance_TabLabels, settings, \.showTabLabels, icon: yougramIcon("tag", theme: theme), requiresRestart: true)
        b.toggle(strings.Yougram_Appearance_BottomSearch, settings, \.keepBottomSearch, icon: yougramIcon("magnifyingglass", theme: theme))
        b.newSection()
        b.header(strings.Yougram_Appearance_Stories)
        b.toggle(strings.Yougram_Appearance_HideStories, settings, \.hideStories, icon: yougramIcon("eye.slash", theme: theme))
        b.toggle(strings.Yougram_Appearance_DisableStorySwipe, settings, \.disableStorySwipe, icon: yougramIcon("camera", theme: theme))
        b.toggle(strings.Yougram_Appearance_HideRepostToStory, settings, \.hideRepostToStory, icon: yougramIcon("arrowshape.turn.up.right", theme: theme))
        b.newSection()
        b.header(strings.Yougram_Appearance_Glass)
        b.toggle(strings.Yougram_Appearance_ReduceGlass, settings, \.reduceGlass, icon: yougramIcon("sparkles", theme: theme), requiresRestart: true)
        b.info(strings.Yougram_Appearance_ReduceGlassInfo)
    case .chats:
        let totalMenuActions = YougramContextMenuAction.allCases.count
        let hiddenMenuActions = settings.hiddenContextMenuActions.count
        let menuLabel = hiddenMenuActions > 0 ? "\(totalMenuActions - hiddenMenuActions)/\(totalMenuActions)" : ""

        b.header(strings.Yougram_Chats_Input)
        b.toggle(strings.Yougram_Chats_QuickFormatting, settings, \.quickFormattingPanel, icon: yougramIcon("textformat", theme: theme))
        b.toggle(strings.Yougram_Chats_RecordingHints, settings, \.disableRecordingHints, icon: yougramIcon("mic.slash", theme: theme))
        b.info(strings.Yougram_Chats_QuickFormattingInfo)
        b.newSection()
        b.header(strings.Yougram_Chats_Messages)
        b.toggle(strings.Yougram_Chats_HideReactions, settings, \.hideReactions, icon: yougramIcon("heart.slash", theme: theme))
        b.toggle(strings.Yougram_Chats_StandardEmojiFirst, settings, \.standardEmojiFirst, icon: yougramIcon("face.smiling", theme: theme))
        b.link(strings.Yougram_Chats_ContextMenu, icon: yougramIcon("list.bullet", theme: theme), label: menuLabel, to: .contextMenu)
        b.newSection()
        b.header(strings.Yougram_Chats_Navigation)
        b.toggle(strings.Yougram_Chats_DisableNextTopic, settings, \.disableAutoNextTopic, icon: yougramIcon("arrow.right.circle", theme: theme))
        b.toggle(strings.Yougram_Chats_DiscussionButton, settings, \.discussionGroupButton, icon: yougramIcon("bubble.left", theme: theme))
        b.info(strings.Yougram_Chats_NavigationInfo)
        b.newSection()
        b.header(strings.Yougram_Chats_GroupsAndChannels)
        b.toggle(strings.Yougram_Chats_KeepBannedChats, settings, \.keepChatsAfterBan, icon: yougramIcon("tray", theme: theme))
        b.info(strings.Yougram_Chats_KeepBannedChatsInfo)
        b.newSection()
        b.header(strings.Yougram_Chats_Media)
        b.toggle(strings.Yougram_Chats_SendHD, settings, \.sendHDPhotos, icon: yougramIcon("photo", theme: theme))
        b.toggle(strings.Yougram_Chats_PasteHD, settings, \.hdPhotosFromClipboard, icon: yougramIcon("doc.on.clipboard", theme: theme))
        b.toggle(strings.Yougram_Chats_AirPlay, settings, \.airPlayButton, icon: yougramIcon("airplayvideo", theme: theme))
        b.toggle(strings.Yougram_Chats_DisablePip, settings, \.disablePipOnSwipe, icon: yougramIcon("rectangle.on.rectangle", theme: theme))
        b.toggle(strings.Yougram_Chats_SmallVideoControls, settings, \.disableLargeVideoControls, icon: yougramIcon("slider.horizontal.3", theme: theme))
        b.newSection()
        b.header(strings.Yougram_Chats_Camera)
        b.toggle(strings.Yougram_Chats_CameraOptimization, settings, \.cameraOptimization, icon: yougramIcon("speedometer", theme: theme))
        b.toggle(strings.Yougram_Chats_CameraStartUltraWide, settings, \.cameraStartUltraWide, icon: yougramIcon("camera.aperture", theme: theme))
        b.toggle(strings.Yougram_Chats_CameraZoomSlider, settings, \.cameraZoomSlider, icon: yougramIcon("slider.horizontal.3", theme: theme))
        b.info(strings.Yougram_Chats_CameraOptimizationInfo)
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
    case .ghostMode:
        return strings.Yougram_Ghost_Title
    case .contextMenu:
        return strings.Yougram_ContextMenu_Title
    }
}

private func yougramScreenController(context: AccountContext, screen: YougramScreen) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var focusSearchFieldImpl: (() -> Void)?
    var endEditingImpl: (() -> Void)?

    let isSearchingPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    let searchQueryPromise = ValuePromise<String>("", ignoreRepeated: true)

    let arguments = YougramSettingsArguments(updateToggle: { key, value, requiresRestart in
        let _ = updateYougramSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            let isGhostSub = isYougramGhostSubToggle(key)
            if isGhostSub && !settings.ghostModeEnabled {
                return settings
            }
            settings[keyPath: key] = value
            if key == \.ghostModeEnabled && value == true && !settings.hasAnyGhostFeatureEnabled {
                settings.ghostHideReadReceipts = true
                settings.ghostHideVoiceListened = true
                settings.ghostHideRoundWatched = true
                settings.ghostHideStoryViews = true
                settings.ghostHideOnline = true
                settings.ghostHideTyping = true
                settings.ghostHideUploading = true
                settings.ghostHideChoosingSticker = true
                settings.ghostHideOtherActivities = true
            } else if isGhostSub && settings.ghostModeEnabled && !settings.hasAnyGhostFeatureEnabled {
                settings.ghostModeEnabled = false
            }
            return settings
        }).start()
        if key == \.hideBlockedUsersMessages && value == true {
            let _ = context.engine.privacy.yougramRefreshBlockedPeers().startStandalone()
        }
        if key == \.scramblePasscodeKeypad {
            let rootPath = YougramLocalEncryptionHooks.currentRootPath?() ?? (context.sharedContext.applicationBindings.containerPath + "/telegram-data")
            if YougramVaultStore.shared.isEnabled(rootPath: rootPath) {
                try? YougramVaultStore.shared.setScrambledKeypad(value, rootPath: rootPath)
            }
        }
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
    }, updateSearchQuery: { query in
        searchQueryPromise.set(query)
    }, open: { target in
        endEditingImpl?()
        switch target {
        case .general:
            pushControllerImpl?(yougramScreenController(context: context, screen: .general))
        case .appearance:
            pushControllerImpl?(yougramScreenController(context: context, screen: .appearance))
        case .chats:
            pushControllerImpl?(yougramScreenController(context: context, screen: .chats))
        case .privacy:
            pushControllerImpl?(yougramScreenController(context: context, screen: .privacy))
        case .ghostMode:
            pushControllerImpl?(yougramScreenController(context: context, screen: .ghostMode))
        case .localEncryption:
            pushControllerImpl?(yougramLocalEncryptionController(context: context))
        case .localHistory:
            pushControllerImpl?(yougramLocalHistoryController(context: context))
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

    let rootPath = YougramLocalEncryptionHooks.currentRootPath?() ?? (context.sharedContext.applicationBindings.containerPath + "/telegram-data")
    let searchStateSignal: Signal<(Bool, String), NoError> = screen == .main
        ? combineLatest(isSearchingPromise.get(), searchQueryPromise.get())
        : .single((false, ""))

    let signal = combineLatest(
        context.sharedContext.presentationData,
        YougramSettings.updates,
        .single(()) |> then(YougramVaultStore.shared.stateChanges),
        searchStateSignal
    )
    |> deliverOnMainQueue
    |> map { presentationData, settings, _, searchState -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (isSearching, searchQuery) = searchState
        let localEncryptionEnabled = YougramVaultStore.shared.isEnabled(rootPath: rootPath)
        let theme = presentationData.theme
        let strings = presentationData.strings

        let rightNavigationButton: ItemListNavigationButton?
        if screen == .main {
            if isSearching {
                rightNavigationButton = ItemListNavigationButton(content: .text(strings.Common_Cancel), style: .regular, enabled: true, action: {
                    endEditingImpl?()
                    searchQueryPromise.set("")
                    isSearchingPromise.set(false)
                })
            } else {
                rightNavigationButton = ItemListNavigationButton(content: .icon(.search), style: .regular, enabled: true, action: {
                    isSearchingPromise.set(true)
                    focusSearchFieldImpl?()
                })
            }
        } else {
            rightNavigationButton = nil
        }

        let entries: [YougramSettingsEntry]
        if screen == .main && isSearching {
            entries = yougramSearchEntries(
                query: searchQuery,
                settings: settings,
                localEncryptionEnabled: localEncryptionEnabled,
                theme: theme,
                strings: strings
            )
        } else {
            entries = yougramEntries(
                screen: screen,
                settings: settings,
                localEncryptionEnabled: localEncryptionEnabled,
                theme: theme,
                strings: strings
            )
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(yougramTitle(screen, strings: strings)),
            leftNavigationButton: nil,
            rightNavigationButton: rightNavigationButton,
            backNavigationButton: ItemListBackButton(title: strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: screen == .ghostMode
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    focusSearchFieldImpl = { [weak controller] in
        Queue.mainQueue().after(0.06) {
            controller?.forEachItemNode { node in
                if let inputNode = node as? ItemListSingleLineInputItemNode {
                    inputNode.focus()
                }
            }
        }
    }
    endEditingImpl = { [weak controller] in
        controller?.view.endEditing(true)
    }
    return controller
}

/// Settings ▸ Yougram.
public func yougramSettingsController(context: AccountContext) -> ViewController {
    return yougramScreenController(context: context, screen: .main)
}
