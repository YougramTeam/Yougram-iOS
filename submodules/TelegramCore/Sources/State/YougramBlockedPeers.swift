import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

// Yougram: local per-account blocked-peer ID cache used to hide messages from blocked users in groups and channels.

public struct YougramBlockedPeersStore: Codable, Equatable {
    public var peerIds: [PeerId]
    public var hasSynced: Bool

    public init(peerIds: [PeerId] = [], hasSynced: Bool = false) {
        self.peerIds = peerIds
        self.hasSynced = hasSynced
    }
}

private let blockedPeersRefreshLock = NSLock()
private var activeBlockedPeerRefreshes = Set<PeerId>()

private func loadBlockedPeersStore(transaction: Transaction) -> YougramBlockedPeersStore {
    return transaction.getPreferencesEntry(key: PreferencesKeys.yougramBlockedPeerIds)?.get(YougramBlockedPeersStore.self) ?? YougramBlockedPeersStore()
}

private func saveBlockedPeersStore(transaction: Transaction, store: YougramBlockedPeersStore) {
    transaction.setPreferencesEntry(key: PreferencesKeys.yougramBlockedPeerIds, value: PreferencesEntry(store))
}

func yougramSetPeerBlocked(transaction: Transaction, peerId: PeerId, isBlocked: Bool) {
    var store = loadBlockedPeersStore(transaction: transaction)
    var set = Set(store.peerIds)
    let changed: Bool
    if isBlocked {
        changed = set.insert(peerId).inserted
    } else {
        changed = set.remove(peerId) != nil
    }
    if changed {
        store.peerIds = Array(set)
        saveBlockedPeersStore(transaction: transaction, store: store)
    }
}

func yougramReplaceBlockedPeers(transaction: Transaction, peerIds: [PeerId]) {
    var unique: [PeerId] = []
    var seen = Set<PeerId>()
    for peerId in peerIds where seen.insert(peerId).inserted {
        unique.append(peerId)
    }
    let store = YougramBlockedPeersStore(peerIds: unique, hasSynced: true)
    saveBlockedPeersStore(transaction: transaction, store: store)
}

func _internal_yougramBlockedPeerIds(account: Account) -> Signal<Set<PeerId>, NoError> {
    let accountPeerId = account.peerId
    return account.postbox.preferencesView(keys: [PreferencesKeys.yougramBlockedPeerIds])
    |> map { view -> YougramBlockedPeersStore in
        return view.values[PreferencesKeys.yougramBlockedPeerIds]?.get(YougramBlockedPeersStore.self) ?? YougramBlockedPeersStore()
    }
    |> map { store -> Set<PeerId> in
        if !store.hasSynced && YougramCoreOptions.hideBlockedUsersMessages {
            blockedPeersRefreshLock.lock()
            let inserted = activeBlockedPeerRefreshes.insert(accountPeerId).inserted
            blockedPeersRefreshLock.unlock()
            if inserted {
                let _ = (_internal_yougramRefreshBlockedPeers(account: account)
                |> afterDisposed {
                    blockedPeersRefreshLock.lock()
                    activeBlockedPeerRefreshes.remove(accountPeerId)
                    blockedPeersRefreshLock.unlock()
                }).start()
            }
        }
        return Set(store.peerIds)
    }
    |> distinctUntilChanged
}

func _internal_yougramRefreshBlockedPeers(account: Account) -> Signal<Void, NoError> {
    func fetchPage(offset: Int32, accumulated: [PeerId]) -> Signal<[PeerId]?, NoError> {
        return account.network.request(Api.functions.contacts.getBlocked(flags: 0, offset: offset, limit: 100))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.contacts.Blocked?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<[PeerId]?, NoError> in
            guard let result else {
                return .single(nil)
            }
            let blocked: [Api.PeerBlocked]
            let count: Int
            let isSlice: Bool
            switch result {
            case let .blocked(data):
                blocked = data.blocked
                count = Int(offset) + blocked.count
                isSlice = false
            case let .blockedSlice(data):
                blocked = data.blocked
                count = max(0, Int(data.count))
                isSlice = true
            }

            var merged = accumulated
            var seen = Set(accumulated)
            for item in blocked {
                if case let .peerBlocked(data) = item {
                    let peerId = data.peerId.peerId
                    if seen.insert(peerId).inserted {
                        merged.append(peerId)
                    }
                }
            }

            let nextOffset = Int32(clamping: Int64(offset) + Int64(blocked.count))
            if isSlice && !blocked.isEmpty && Int(nextOffset) < count && merged.count < 2000 {
                return fetchPage(offset: nextOffset, accumulated: merged)
            } else {
                return .single(merged)
            }
        }
    }

    return fetchPage(offset: 0, accumulated: [])
    |> mapToSignal { peerIds -> Signal<Void, NoError> in
        guard let peerIds else {
            return .complete()
        }
        return account.postbox.transaction { transaction -> Void in
            yougramReplaceBlockedPeers(transaction: transaction, peerIds: peerIds)
        }
    }
}
