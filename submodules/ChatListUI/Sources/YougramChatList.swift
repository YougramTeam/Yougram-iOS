import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import ChatListFilterTabContainerNode

// Yougram's chat list settings (Settings ▸ Yougram ▸ Chat List and Folders, Stories), as the chat list reads them.

/// The settings that rebuild the folder list (`ChatListControllerImpl.reloadFilters`).
struct YougramChatListFolderSettings: Equatable {
    let hideAllChatsFolder: Bool
    let foldersAtBottom: Bool

    init(_ settings: YougramSettings) {
        self.hideAllChatsFolder = settings.hideAllChatsFolder
        self.foldersAtBottom = settings.foldersAtBottom
    }
}

/// The settings that change the chat list screen's own layout: a change lays it out again.
struct YougramChatListScreenSettings: Equatable {
    let compactFolderTabs: Bool
    let keepBottomSearch: Bool
    let hideStories: Bool
    let disableStorySwipe: Bool

    init(_ settings: YougramSettings) {
        self.compactFolderTabs = settings.compactFolderTabs
        self.keepBottomSearch = settings.keepBottomSearch
        self.hideStories = settings.hideStories
        self.disableStorySwipe = settings.disableStorySwipe
    }
}

/// Whether a folder list has a folder of its own besides All Chats.
func yougramChatListHasFolders(_ filters: [ChatListFilter]) -> Bool {
    return filters.contains(where: { filter in
        if case .filter = filter {
            return true
        } else {
            return false
        }
    })
}

/// Hide Stories: the chat list's story subscriptions come out empty, so the header has no stories row, no "My Story"
/// item and no archive story ring; a change applies at once.
func yougramStorySubscriptions(_ signal: Signal<EngineStorySubscriptions, NoError>) -> Signal<EngineStorySubscriptions, NoError> {
    return combineLatest(
        signal,
        YougramSettings.updates |> map { $0.hideStories } |> distinctUntilChanged
    )
    |> map { subscriptions, hideStories -> EngineStorySubscriptions in
        if hideStories {
            return EngineStorySubscriptions(accountItem: nil, items: [], hasMoreToken: nil)
        }
        return subscriptions
    }
}

/// Disable Story Swipe (and Hide Stories): no story camera from swiping right on the first folder or pulling the
/// stories row.
func yougramDisablesStoryCameraSwipe() -> Bool {
    let settings = YougramSettings.current
    return settings.disableStorySwipe || settings.hideStories
}

// MARK: Remember Last Folder

private let yougramInMemoryFolderLock = NSLock()
private var yougramInMemoryFolders: [Int64: Int64] = [:]

private func yougramLastChatListFolderKey(accountId: AccountRecordId) -> String {
    return "yougram.chatList.lastFolder.\(accountId.int64)"
}

/// The folder open last on this account: nil before one was stored, `.all` for All Chats.
func yougramLastChatListFolder(accountId: AccountRecordId) -> ChatListFilterTabEntryId? {
    let id: Int64
    if YougramCoreOptions.localEncryptionEnabled {
        yougramInMemoryFolderLock.lock()
        let memValue = yougramInMemoryFolders[accountId.int64]
        yougramInMemoryFolderLock.unlock()
        guard let memValue else {
            return nil
        }
        id = memValue
    } else {
        guard let value = UserDefaults.standard.object(forKey: yougramLastChatListFolderKey(accountId: accountId)) as? NSNumber else {
            return nil
        }
        id = value.int64Value
    }
    if id < 0 {
        return .all
    } else {
        return .filter(Int32(clamping: id))
    }
}

func yougramStoreLastChatListFolder(accountId: AccountRecordId, filter: ChatListFilterTabEntryId) {
    let value: Int64
    switch filter {
    case .all:
        value = -1
    case let .filter(id):
        value = Int64(id)
    }
    let key = yougramLastChatListFolderKey(accountId: accountId)
    if YougramCoreOptions.localEncryptionEnabled {
        yougramInMemoryFolderLock.lock()
        yougramInMemoryFolders[accountId.int64] = value
        yougramInMemoryFolderLock.unlock()
        if UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return
    }
    if (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value != value {
        UserDefaults.standard.set(NSNumber(value: value), forKey: key)
    }
}
