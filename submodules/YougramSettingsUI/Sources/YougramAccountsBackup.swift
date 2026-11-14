import Foundation
import Security
import SwiftSignalKit
import TelegramCore
import AccountContext

/// One backed-up session, as stored in the keychain.
///
/// Deliberately not `AccountRecord`/`TelegramAccountRecordAttribute`: that attribute's decoder
/// falls back to a `preconditionFailure()` on input it doesn't recognise, and a keychain item
/// is outside data. Only what a record needs to sign the account back in is kept.
public struct YougramAccountBackup: Codable, Equatable {
    public var name: String
    public var date: Date
    public var isTestingEnvironment: Bool
    public var data: AccountBackupData

    public var peerId: Int64 {
        return self.data.peerId
    }
}

/// Stores account backups as keychain generic passwords, one per account.
///
/// Items are `WhenUnlocked` and live in the app's default keychain access group, so they
/// survive deleting the app. With iCloud sync on they are written `kSecAttrSynchronizable`
/// and reach the user's other devices through iCloud Keychain (end-to-end encrypted).
/// All keychain calls are synchronous: call from a background queue.
public enum YougramAccountsBackupStore {
    private static let syncDefaultsKey = "yougram.accountsBackup.iCloudSync"

    private static var service: String {
        return (Bundle.main.bundleIdentifier ?? "Yougram") + ".yougram.accounts"
    }

    public static var syncsWithICloud: Bool {
        get {
            return UserDefaults.standard.bool(forKey: syncDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: syncDefaultsKey)
        }
    }

    private static func baseQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Match both local and iCloud-synced items.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }

    public static func save(_ backup: YougramAccountBackup) -> Bool {
        guard let data = try? JSONEncoder().encode(backup) else {
            return false
        }
        // Delete first: an item can't change between local and synchronizable in place.
        var deleteQuery = baseQuery()
        deleteQuery[kSecAttrAccount as String] = "\(backup.peerId)"
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(backup.peerId)",
            kSecAttrLabel as String: backup.name,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: syncsWithICloud ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecValueData as String: data
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func loadAll() -> [YougramAccountBackup]? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            return nil
        }
        let items: [Data]
        if let array = result as? [Data] {
            items = array
        } else if let single = result as? Data {
            items = [single]
        } else {
            items = []
        }
        var backups: [Int64: YougramAccountBackup] = [:]
        for item in items {
            // A copy synced from another device can coexist with a local one; keep the newest.
            if let backup = try? JSONDecoder().decode(YougramAccountBackup.self, from: item) {
                if let existing = backups[backup.peerId], existing.date > backup.date {
                    continue
                }
                backups[backup.peerId] = backup
            }
        }
        return backups.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    @discardableResult
    public static func delete(peerId: Int64) -> Bool {
        var query = baseQuery()
        query[kSecAttrAccount as String] = "\(peerId)"
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    public static func deleteAll() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Re-save every backup so it moves to (or out of) iCloud Keychain.
    public static func resaveAll() {
        for backup in loadAll() ?? [] {
            let _ = save(backup)
        }
    }
}

private let backupQueue = Queue(name: "org.yougram.accountsBackup")

/// Backs up every signed-in account. Emits how many were saved, or nil on a keychain error.
public func yougramBackUpAccounts(sharedContext: SharedAccountContext) -> Signal<Int?, NoError> {
    return combineLatest(
        sharedContext.accountManager.accountRecords() |> take(1),
        sharedContext.activeAccountsWithInfo |> take(1)
    )
    |> deliverOn(backupQueue)
    |> map { view, accountsWithInfo -> Int? in
        var names: [AccountRecordId: String] = [:]
        for info in accountsWithInfo.accounts {
            names[info.account.id] = yougramAccountDisplayName(info.peer)
        }
        var saved = 0
        for record in view.records {
            var backupData: AccountBackupData?
            var isTestingEnvironment = false
            var isLoggedOut = false
            for attribute in record.attributes {
                switch attribute {
                case let .backupData(value):
                    backupData = value.data
                case let .environment(value):
                    isTestingEnvironment = value.environment == .test
                case .loggedOut:
                    isLoggedOut = true
                default:
                    break
                }
            }
            guard let data = backupData, data.peerId != 0, !isLoggedOut else {
                continue
            }
            let backup = YougramAccountBackup(
                name: names[record.id] ?? "ID \(data.peerId)",
                date: Date(),
                isTestingEnvironment: isTestingEnvironment,
                data: data
            )
            if !YougramAccountsBackupStore.save(backup) {
                return nil
            }
            saved += 1
        }
        return saved
    }
    |> deliverOnMainQueue
}

/// Creates an account record for every backup whose account isn't signed in. The app's
/// account-records observer then brings each one up with the backed-up session keys.
/// Emits how many were restored, or nil on a keychain error.
public func yougramRestoreAccounts(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Int?, NoError> {
    return Signal<[YougramAccountBackup]?, NoError> { subscriber in
        subscriber.putNext(YougramAccountsBackupStore.loadAll())
        subscriber.putCompletion()
        return EmptyDisposable
    }
    |> runOn(backupQueue)
    |> mapToSignal { backups -> Signal<Int?, NoError> in
        guard let backups else {
            return .single(nil)
        }
        return accountManager.transaction { transaction -> Int? in
            let records = transaction.getRecords()
            var signedIn = Set<Int64>()
            var maxOrder: Int32 = 0
            for record in records {
                var isLoggedOut = false
                var peerId: Int64?
                for attribute in record.attributes {
                    switch attribute {
                    case .loggedOut:
                        isLoggedOut = true
                    case let .backupData(value):
                        peerId = value.data?.peerId
                    case let .sortOrder(value):
                        maxOrder = max(maxOrder, value.order)
                    default:
                        break
                    }
                }
                if let peerId, !isLoggedOut {
                    signedIn.insert(peerId)
                }
            }
            var restored = 0
            for backup in backups where !signedIn.contains(backup.peerId) {
                maxOrder += 1
                let _ = transaction.createRecord([
                    .backupData(AccountBackupDataAttribute(data: backup.data)),
                    .environment(AccountEnvironmentAttribute(environment: backup.isTestingEnvironment ? .test : .production)),
                    .sortOrder(AccountSortOrderAttribute(order: maxOrder))
                ])
                signedIn.insert(backup.peerId)
                restored += 1
            }
            return restored
        }
    }
    |> deliverOnMainQueue
}

func yougramAccountDisplayName(_ peer: EnginePeer) -> String {
    let title = peer.debugDisplayTitle
    if !title.isEmpty {
        return title
    }
    if let username = peer.addressName, !username.isEmpty {
        return "@" + username
    }
    return "ID \(peer.id.id._internalGetInt64Value())"
}
