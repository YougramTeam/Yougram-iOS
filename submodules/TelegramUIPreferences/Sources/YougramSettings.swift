import Foundation
import SwiftSignalKit
import TelegramCore

/// Yougram's own settings (Settings ▸ Yougram).
///
/// The record of truth is one AccountManager shared-data entry, so the Notification Service
/// extension reads the same values and screens can observe changes. Layout code reads
/// `YougramSettings.current` instead: synchronous, lock-protected, and mirrored to
/// UserDefaults so it is right from the first frame after launch, before the shared data
/// has been read. `SharedAccountContextImpl` keeps the mirror in sync with the entry;
/// writes go through `updateYougramSettingsInteractively`, which updates both.
///
/// Every field decodes with `decodeIfPresent` and a default: a blob from an older build
/// must never fail to decode, or every other setting would reset.
public struct YougramSettings: Codable, Equatable {
    // MARK: Privacy
    public var hidePhoneInSettings: Bool
    public var hideAccountNameInNotifications: Bool
    public var hideAds: Bool

    // MARK: Ghost Mode
    /// The master switch: each part below applies only while this is on (`ghostCoreOptions`).
    public var ghostModeEnabled: Bool
    public var ghostHideReadReceipts: Bool
    public var ghostHideVoiceListened: Bool
    public var ghostHideRoundWatched: Bool
    public var ghostHideStoryViews: Bool
    public var ghostHideOnline: Bool
    public var ghostHideTyping: Bool
    public var ghostHideUploading: Bool
    public var ghostHideChoosingSticker: Bool
    public var ghostHideOtherActivities: Bool
    public var ghostAutoOffline: Bool
    public var ghostReadOnInteract: Bool
    public var ghostSendAsScheduled: Bool
    /// Opening someone's story while Ghost Mode doesn't hide story views asks first.
    public var ghostStoryWarning: Bool

    // MARK: Passcode
    /// The lock screen's digit keys change places every time it appears.
    public var scramblePasscodeKeypad: Bool
    /// Entering the duress code also deletes the accounts backup from the keychain.
    public var duressDeleteBackup: Bool
    /// Entering the duress code also logs the accounts out on Telegram's servers, not only on this device.
    public var duressTerminateSessions: Bool

    // MARK: Accounts
    public var autoBackupAccounts: Bool

    // MARK: Chats
    public var quickFormattingPanel: Bool
    public var localVoiceTranscription: Bool
    public var sendHDPhotos: Bool
    public var hdPhotosFromClipboard: Bool
    public var hideReactions: Bool
    public var standardEmojiFirst: Bool
    public var disableRecordingHints: Bool
    public var disableAutoNextTopic: Bool
    public var discussionGroupButton: Bool
    /// Message context menu actions the user switched off (`YougramContextMenuAction.rawValue`).
    public var hiddenContextMenuActions: [String]
    /// A group or channel the user was banned or removed from stays in the chat list with the
    /// messages already on this device (`YougramCoreOptions.keepChatsAfterRemoval`).
    public var keepChatsAfterBan: Bool

    // MARK: Chat list and folders
    public var compactChatList: Bool
    public var hideAllChatsFolder: Bool
    public var foldersAtBottom: Bool
    public var rememberLastFolder: Bool
    public var compactFolderTabs: Bool
    public var keepBottomSearch: Bool

    // MARK: Tabs
    public var showContactsTab: Bool
    public var showTabLabels: Bool

    // MARK: Stories
    public var hideStories: Bool
    public var disableStorySwipe: Bool
    public var hideRepostToStory: Bool

    // MARK: Media
    public var airPlayButton: Bool
    public var disablePipOnSwipe: Bool
    public var disableLargeVideoControls: Bool

    // MARK: Appearance
    public var reduceGlass: Bool

    public static var defaultSettings: YougramSettings {
        return YougramSettings(
            hidePhoneInSettings: false,
            hideAccountNameInNotifications: false,
            hideAds: true,
            ghostModeEnabled: false,
            ghostHideReadReceipts: true,
            ghostHideVoiceListened: true,
            ghostHideRoundWatched: true,
            ghostHideStoryViews: true,
            ghostHideOnline: true,
            ghostHideTyping: true,
            ghostHideUploading: true,
            ghostHideChoosingSticker: true,
            ghostHideOtherActivities: true,
            ghostAutoOffline: false,
            ghostReadOnInteract: true,
            ghostSendAsScheduled: false,
            ghostStoryWarning: false,
            scramblePasscodeKeypad: false,
            duressDeleteBackup: true,
            duressTerminateSessions: false,
            autoBackupAccounts: false,
            quickFormattingPanel: false,
            localVoiceTranscription: true,
            sendHDPhotos: false,
            hdPhotosFromClipboard: false,
            hideReactions: false,
            standardEmojiFirst: false,
            disableRecordingHints: false,
            disableAutoNextTopic: false,
            discussionGroupButton: true,
            hiddenContextMenuActions: [],
            keepChatsAfterBan: true,
            compactChatList: false,
            hideAllChatsFolder: false,
            foldersAtBottom: false,
            rememberLastFolder: false,
            compactFolderTabs: false,
            keepBottomSearch: false,
            showContactsTab: true,
            showTabLabels: true,
            hideStories: false,
            disableStorySwipe: false,
            hideRepostToStory: false,
            airPlayButton: true,
            disablePipOnSwipe: false,
            disableLargeVideoControls: false,
            reduceGlass: false
        )
    }

    public init(
        hidePhoneInSettings: Bool,
        hideAccountNameInNotifications: Bool,
        hideAds: Bool,
        ghostModeEnabled: Bool,
        ghostHideReadReceipts: Bool,
        ghostHideVoiceListened: Bool,
        ghostHideRoundWatched: Bool,
        ghostHideStoryViews: Bool,
        ghostHideOnline: Bool,
        ghostHideTyping: Bool,
        ghostHideUploading: Bool,
        ghostHideChoosingSticker: Bool,
        ghostHideOtherActivities: Bool,
        ghostAutoOffline: Bool,
        ghostReadOnInteract: Bool,
        ghostSendAsScheduled: Bool,
        ghostStoryWarning: Bool,
        scramblePasscodeKeypad: Bool,
        duressDeleteBackup: Bool,
        duressTerminateSessions: Bool,
        autoBackupAccounts: Bool,
        quickFormattingPanel: Bool,
        localVoiceTranscription: Bool,
        sendHDPhotos: Bool,
        hdPhotosFromClipboard: Bool,
        hideReactions: Bool,
        standardEmojiFirst: Bool,
        disableRecordingHints: Bool,
        disableAutoNextTopic: Bool,
        discussionGroupButton: Bool,
        hiddenContextMenuActions: [String],
        keepChatsAfterBan: Bool,
        compactChatList: Bool,
        hideAllChatsFolder: Bool,
        foldersAtBottom: Bool,
        rememberLastFolder: Bool,
        compactFolderTabs: Bool,
        keepBottomSearch: Bool,
        showContactsTab: Bool,
        showTabLabels: Bool,
        hideStories: Bool,
        disableStorySwipe: Bool,
        hideRepostToStory: Bool,
        airPlayButton: Bool,
        disablePipOnSwipe: Bool,
        disableLargeVideoControls: Bool,
        reduceGlass: Bool
    ) {
        self.hidePhoneInSettings = hidePhoneInSettings
        self.hideAccountNameInNotifications = hideAccountNameInNotifications
        self.hideAds = hideAds
        self.ghostModeEnabled = ghostModeEnabled
        self.ghostHideReadReceipts = ghostHideReadReceipts
        self.ghostHideVoiceListened = ghostHideVoiceListened
        self.ghostHideRoundWatched = ghostHideRoundWatched
        self.ghostHideStoryViews = ghostHideStoryViews
        self.ghostHideOnline = ghostHideOnline
        self.ghostHideTyping = ghostHideTyping
        self.ghostHideUploading = ghostHideUploading
        self.ghostHideChoosingSticker = ghostHideChoosingSticker
        self.ghostHideOtherActivities = ghostHideOtherActivities
        self.ghostAutoOffline = ghostAutoOffline
        self.ghostReadOnInteract = ghostReadOnInteract
        self.ghostSendAsScheduled = ghostSendAsScheduled
        self.ghostStoryWarning = ghostStoryWarning
        self.scramblePasscodeKeypad = scramblePasscodeKeypad
        self.duressDeleteBackup = duressDeleteBackup
        self.duressTerminateSessions = duressTerminateSessions
        self.autoBackupAccounts = autoBackupAccounts
        self.quickFormattingPanel = quickFormattingPanel
        self.localVoiceTranscription = localVoiceTranscription
        self.sendHDPhotos = sendHDPhotos
        self.hdPhotosFromClipboard = hdPhotosFromClipboard
        self.hideReactions = hideReactions
        self.standardEmojiFirst = standardEmojiFirst
        self.disableRecordingHints = disableRecordingHints
        self.disableAutoNextTopic = disableAutoNextTopic
        self.discussionGroupButton = discussionGroupButton
        self.hiddenContextMenuActions = hiddenContextMenuActions
        self.keepChatsAfterBan = keepChatsAfterBan
        self.compactChatList = compactChatList
        self.hideAllChatsFolder = hideAllChatsFolder
        self.foldersAtBottom = foldersAtBottom
        self.rememberLastFolder = rememberLastFolder
        self.compactFolderTabs = compactFolderTabs
        self.keepBottomSearch = keepBottomSearch
        self.showContactsTab = showContactsTab
        self.showTabLabels = showTabLabels
        self.hideStories = hideStories
        self.disableStorySwipe = disableStorySwipe
        self.hideRepostToStory = hideRepostToStory
        self.airPlayButton = airPlayButton
        self.disablePipOnSwipe = disablePipOnSwipe
        self.disableLargeVideoControls = disableLargeVideoControls
        self.reduceGlass = reduceGlass
    }

    private enum CodingKeys: String, CodingKey {
        case hidePhoneInSettings, hideAccountNameInNotifications, hideAds, autoBackupAccounts
        case ghostModeEnabled, ghostHideReadReceipts, ghostHideVoiceListened, ghostHideRoundWatched, ghostHideStoryViews
        case ghostHideOnline, ghostHideTyping, ghostHideUploading, ghostHideChoosingSticker, ghostHideOtherActivities
        case ghostAutoOffline, ghostReadOnInteract, ghostSendAsScheduled, ghostStoryWarning
        case scramblePasscodeKeypad, duressDeleteBackup, duressTerminateSessions
        case quickFormattingPanel, localVoiceTranscription, sendHDPhotos, hdPhotosFromClipboard, hideReactions
        case standardEmojiFirst, disableRecordingHints, disableAutoNextTopic, discussionGroupButton, hiddenContextMenuActions
        case keepChatsAfterBan
        case compactChatList, hideAllChatsFolder, foldersAtBottom, rememberLastFolder, compactFolderTabs, keepBottomSearch
        case showContactsTab, showTabLabels
        case hideStories, disableStorySwipe, hideRepostToStory
        case airPlayButton, disablePipOnSwipe, disableLargeVideoControls
        case reduceGlass
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = YougramSettings.defaultSettings
        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            return ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        self.hidePhoneInSettings = bool(.hidePhoneInSettings, d.hidePhoneInSettings)
        self.hideAccountNameInNotifications = bool(.hideAccountNameInNotifications, d.hideAccountNameInNotifications)
        self.hideAds = bool(.hideAds, d.hideAds)
        self.ghostModeEnabled = bool(.ghostModeEnabled, d.ghostModeEnabled)
        self.ghostHideReadReceipts = bool(.ghostHideReadReceipts, d.ghostHideReadReceipts)
        self.ghostHideVoiceListened = bool(.ghostHideVoiceListened, d.ghostHideVoiceListened)
        self.ghostHideRoundWatched = bool(.ghostHideRoundWatched, d.ghostHideRoundWatched)
        self.ghostHideStoryViews = bool(.ghostHideStoryViews, d.ghostHideStoryViews)
        self.ghostHideOnline = bool(.ghostHideOnline, d.ghostHideOnline)
        self.ghostHideTyping = bool(.ghostHideTyping, d.ghostHideTyping)
        self.ghostHideUploading = bool(.ghostHideUploading, d.ghostHideUploading)
        self.ghostHideChoosingSticker = bool(.ghostHideChoosingSticker, d.ghostHideChoosingSticker)
        self.ghostHideOtherActivities = bool(.ghostHideOtherActivities, d.ghostHideOtherActivities)
        self.ghostAutoOffline = bool(.ghostAutoOffline, d.ghostAutoOffline)
        self.ghostReadOnInteract = bool(.ghostReadOnInteract, d.ghostReadOnInteract)
        self.ghostSendAsScheduled = bool(.ghostSendAsScheduled, d.ghostSendAsScheduled)
        self.ghostStoryWarning = bool(.ghostStoryWarning, d.ghostStoryWarning)
        self.scramblePasscodeKeypad = bool(.scramblePasscodeKeypad, d.scramblePasscodeKeypad)
        self.duressDeleteBackup = bool(.duressDeleteBackup, d.duressDeleteBackup)
        self.duressTerminateSessions = bool(.duressTerminateSessions, d.duressTerminateSessions)
        self.autoBackupAccounts = bool(.autoBackupAccounts, d.autoBackupAccounts)
        self.quickFormattingPanel = bool(.quickFormattingPanel, d.quickFormattingPanel)
        self.localVoiceTranscription = bool(.localVoiceTranscription, d.localVoiceTranscription)
        self.sendHDPhotos = bool(.sendHDPhotos, d.sendHDPhotos)
        self.hdPhotosFromClipboard = bool(.hdPhotosFromClipboard, d.hdPhotosFromClipboard)
        self.hideReactions = bool(.hideReactions, d.hideReactions)
        self.standardEmojiFirst = bool(.standardEmojiFirst, d.standardEmojiFirst)
        self.disableRecordingHints = bool(.disableRecordingHints, d.disableRecordingHints)
        self.disableAutoNextTopic = bool(.disableAutoNextTopic, d.disableAutoNextTopic)
        self.discussionGroupButton = bool(.discussionGroupButton, d.discussionGroupButton)
        self.hiddenContextMenuActions = ((try? c.decodeIfPresent([String].self, forKey: .hiddenContextMenuActions)) ?? nil) ?? d.hiddenContextMenuActions
        self.keepChatsAfterBan = bool(.keepChatsAfterBan, d.keepChatsAfterBan)
        self.compactChatList = bool(.compactChatList, d.compactChatList)
        self.hideAllChatsFolder = bool(.hideAllChatsFolder, d.hideAllChatsFolder)
        self.foldersAtBottom = bool(.foldersAtBottom, d.foldersAtBottom)
        self.rememberLastFolder = bool(.rememberLastFolder, d.rememberLastFolder)
        self.compactFolderTabs = bool(.compactFolderTabs, d.compactFolderTabs)
        self.keepBottomSearch = bool(.keepBottomSearch, d.keepBottomSearch)
        self.showContactsTab = bool(.showContactsTab, d.showContactsTab)
        self.showTabLabels = bool(.showTabLabels, d.showTabLabels)
        self.hideStories = bool(.hideStories, d.hideStories)
        self.disableStorySwipe = bool(.disableStorySwipe, d.disableStorySwipe)
        self.hideRepostToStory = bool(.hideRepostToStory, d.hideRepostToStory)
        self.airPlayButton = bool(.airPlayButton, d.airPlayButton)
        self.disablePipOnSwipe = bool(.disablePipOnSwipe, d.disablePipOnSwipe)
        self.disableLargeVideoControls = bool(.disableLargeVideoControls, d.disableLargeVideoControls)
        self.reduceGlass = bool(.reduceGlass, d.reduceGlass)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.hidePhoneInSettings, forKey: .hidePhoneInSettings)
        try c.encode(self.hideAccountNameInNotifications, forKey: .hideAccountNameInNotifications)
        try c.encode(self.hideAds, forKey: .hideAds)
        try c.encode(self.ghostModeEnabled, forKey: .ghostModeEnabled)
        try c.encode(self.ghostHideReadReceipts, forKey: .ghostHideReadReceipts)
        try c.encode(self.ghostHideVoiceListened, forKey: .ghostHideVoiceListened)
        try c.encode(self.ghostHideRoundWatched, forKey: .ghostHideRoundWatched)
        try c.encode(self.ghostHideStoryViews, forKey: .ghostHideStoryViews)
        try c.encode(self.ghostHideOnline, forKey: .ghostHideOnline)
        try c.encode(self.ghostHideTyping, forKey: .ghostHideTyping)
        try c.encode(self.ghostHideUploading, forKey: .ghostHideUploading)
        try c.encode(self.ghostHideChoosingSticker, forKey: .ghostHideChoosingSticker)
        try c.encode(self.ghostHideOtherActivities, forKey: .ghostHideOtherActivities)
        try c.encode(self.ghostAutoOffline, forKey: .ghostAutoOffline)
        try c.encode(self.ghostReadOnInteract, forKey: .ghostReadOnInteract)
        try c.encode(self.ghostSendAsScheduled, forKey: .ghostSendAsScheduled)
        try c.encode(self.ghostStoryWarning, forKey: .ghostStoryWarning)
        try c.encode(self.scramblePasscodeKeypad, forKey: .scramblePasscodeKeypad)
        try c.encode(self.duressDeleteBackup, forKey: .duressDeleteBackup)
        try c.encode(self.duressTerminateSessions, forKey: .duressTerminateSessions)
        try c.encode(self.autoBackupAccounts, forKey: .autoBackupAccounts)
        try c.encode(self.quickFormattingPanel, forKey: .quickFormattingPanel)
        try c.encode(self.localVoiceTranscription, forKey: .localVoiceTranscription)
        try c.encode(self.sendHDPhotos, forKey: .sendHDPhotos)
        try c.encode(self.hdPhotosFromClipboard, forKey: .hdPhotosFromClipboard)
        try c.encode(self.hideReactions, forKey: .hideReactions)
        try c.encode(self.standardEmojiFirst, forKey: .standardEmojiFirst)
        try c.encode(self.disableRecordingHints, forKey: .disableRecordingHints)
        try c.encode(self.disableAutoNextTopic, forKey: .disableAutoNextTopic)
        try c.encode(self.discussionGroupButton, forKey: .discussionGroupButton)
        try c.encode(self.hiddenContextMenuActions, forKey: .hiddenContextMenuActions)
        try c.encode(self.keepChatsAfterBan, forKey: .keepChatsAfterBan)
        try c.encode(self.compactChatList, forKey: .compactChatList)
        try c.encode(self.hideAllChatsFolder, forKey: .hideAllChatsFolder)
        try c.encode(self.foldersAtBottom, forKey: .foldersAtBottom)
        try c.encode(self.rememberLastFolder, forKey: .rememberLastFolder)
        try c.encode(self.compactFolderTabs, forKey: .compactFolderTabs)
        try c.encode(self.keepBottomSearch, forKey: .keepBottomSearch)
        try c.encode(self.showContactsTab, forKey: .showContactsTab)
        try c.encode(self.showTabLabels, forKey: .showTabLabels)
        try c.encode(self.hideStories, forKey: .hideStories)
        try c.encode(self.disableStorySwipe, forKey: .disableStorySwipe)
        try c.encode(self.hideRepostToStory, forKey: .hideRepostToStory)
        try c.encode(self.airPlayButton, forKey: .airPlayButton)
        try c.encode(self.disablePipOnSwipe, forKey: .disablePipOnSwipe)
        try c.encode(self.disableLargeVideoControls, forKey: .disableLargeVideoControls)
        try c.encode(self.reduceGlass, forKey: .reduceGlass)
    }

    public func isContextMenuActionHidden(_ action: String) -> Bool {
        return self.hiddenContextMenuActions.contains(action)
    }

    /// What TelegramCore's Ghost Mode follows: each part, while the master switch is on.
    public var ghostCoreOptions: YougramCoreOptions.GhostMode {
        var options = YougramCoreOptions.GhostMode()
        guard self.ghostModeEnabled else {
            return options
        }
        options.hideReadReceipts = self.ghostHideReadReceipts
        options.hideVoiceListened = self.ghostHideVoiceListened
        options.hideRoundWatched = self.ghostHideRoundWatched
        options.hideStoryViews = self.ghostHideStoryViews
        options.hideOnline = self.ghostHideOnline
        options.hideTyping = self.ghostHideTyping
        options.hideUploading = self.ghostHideUploading
        options.hideChoosingSticker = self.ghostHideChoosingSticker
        options.hideOtherActivities = self.ghostHideOtherActivities
        options.autoOffline = self.ghostAutoOffline
        options.readOnInteract = self.ghostReadOnInteract
        options.sendAsScheduled = self.ghostSendAsScheduled
        return options
    }

    // MARK: Synchronous access

    private static let lock = NSLock()
    private static let mirrorKey = "yougram.settings.v1"
    private static var cached: YougramSettings = {
        var value = YougramSettings.defaultSettings
        if let data = UserDefaults.standard.data(forKey: mirrorKey), let decoded = try? JSONDecoder().decode(YougramSettings.self, from: data) {
            value = decoded
        }
        applyCoreOptions(value)
        return value
    }()

    /// What TelegramCore follows itself (see `YougramCoreOptions`). Set before any account starts:
    /// `SharedAccountContextImpl.init` reads `current` before it loads the accounts.
    private static func applyCoreOptions(_ value: YougramSettings) {
        YougramCoreOptions.keepChatsAfterRemoval = value.keepChatsAfterBan
        YougramCoreOptions.ghostMode = value.ghostCoreOptions
    }
    private static let updatesPipe = ValuePipe<YougramSettings>()

    /// The current settings. Safe to read from any thread, including layout code.
    public static var current: YougramSettings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Emits the current value, then every change.
    public static var updates: Signal<YougramSettings, NoError> {
        return Signal { subscriber in
            subscriber.putNext(YougramSettings.current)
            return updatesPipe.signal().start(next: { value in
                subscriber.putNext(value)
            })
        }
    }

    /// Replace the in-process copy (called with every new value of the shared-data entry).
    public static func setCurrent(_ value: YougramSettings) {
        lock.lock()
        let changed = cached != value
        cached = value
        lock.unlock()
        applyCoreOptions(value)
        if changed {
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: mirrorKey)
            }
            updatesPipe.putNext(value)
        }
    }
}

/// Message context menu actions the user can switch off (Settings ▸ Yougram ▸ Chats ▸ Message Menu).
/// The raw values are stored, so never rename a case.
public enum YougramContextMenuAction: String, CaseIterable {
    case reply
    case copy
    case translate
    case speak
    case saveMedia
    case saveToFiles
    case viewReplies
    case edit
    case pin
    case copyLink
    case forward
    case report
    case select
    case stats
    case saveGif
    case viewStickerPack
    case delete

    public var isHidden: Bool {
        return YougramSettings.current.isContextMenuActionHidden(self.rawValue)
    }
}

public func updateYougramSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (YougramSettings) -> YougramSettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> YougramSettings in
        var updated = YougramSettings.defaultSettings
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.yougramSettings, { entry in
            let currentSettings = entry?.get(YougramSettings.self) ?? YougramSettings.current
            updated = f(currentSettings)
            return SharedPreferencesEntry(updated)
        })
        return updated
    }
    |> deliverOnMainQueue
    |> map { updated -> Void in
        YougramSettings.setCurrent(updated)
    }
}
