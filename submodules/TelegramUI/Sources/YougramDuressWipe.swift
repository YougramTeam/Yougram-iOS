import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext
import WalletContext
import YougramSettingsUI

/// Settings ▸ Yougram ▸ Privacy ▸ Duress Code: what entering the duress code on the lock screen
/// does (installed as `AppLockContext.duressCodeHandler` in `AppDelegate`).
///
/// 1. Optionally deletes the accounts backup from the keychain.
/// 2. Signs out of every account on this device. Each account's folder (its database, chats and
///    media) is deleted by `managedCleanupAccounts` once its record is gone. With "Log Out on
///    Telegram's Servers" the records are marked logged out instead: the cleanup sends
///    `auth.logOut`, then removes them, and so needs a connection to finish. Either way the
///    accounts leave the app at once, since logged-out records are not activated.
/// 3. Once no account is active, turns off the passcode (a credential reset, as on a fresh install,
///    which also drops the duress code), so the lock screen goes away on the login screen.
func yougramPerformDuressWipe(sharedContext: SharedAccountContextImpl, appLockContext: AppLockContext) {
    let accountManager = sharedContext.accountManager
    let settings = YougramSettings.current
    Logger.shared.log("Yougram", "duress code: signing out (deleteBackup: \(settings.duressDeleteBackup), logOutOnServers: \(settings.duressTerminateSessions))")

    let backupRemoved: Signal<Void, NoError>
    if settings.duressDeleteBackup {
        backupRemoved = Signal { subscriber in
            DispatchQueue.global(qos: .userInitiated).async {
                let _ = YougramAccountsBackupStore.deleteAll()
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    } else {
        backupRemoved = .complete()
    }

    let accountsRemoved: Signal<Void, NoError> = accountManager.transaction { transaction -> [AccountRecordId] in
        let ids = transaction.getRecords().map { $0.id }
        if settings.duressTerminateSessions {
            return ids
        }
        for id in ids {
            transaction.updateRecord(id, { _ in
                return nil
            })
        }
        return []
    }
    |> mapToSignal { ids -> Signal<Void, NoError> in
        var signal: Signal<Void, NoError> = .complete()
        for id in ids {
            signal = signal |> then(logoutFromAccount(id: id, accountManager: accountManager, alreadyLoggedOutRemotely: false))
        }
        return signal
    }

    // The lock screen stays up until the accounts are gone, so it never uncovers one.
    let accountsInactive: Signal<Void, NoError> = sharedContext.activeAccountContexts
    |> filter { primary, accounts, _ in
        return primary == nil && accounts.isEmpty
    }
    |> take(1)
    |> map { _ -> Void in
        return Void()
    }
    |> timeout(15.0, queue: Queue.mainQueue(), alternate: .single(Void()))

    let passcodeRemoved: Signal<Void, NoError> = Signal { subscriber in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try resetWalletLocalSecrets()
            } catch {
                Logger.shared.log("Yougram", "duress code: passcode reset failed: \(error)")
            }
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
    |> then(accountManager.transaction { transaction -> Void in
        // Re-reads the credential store, which now has no passcode; AppLock then dismisses the
        // lock screen by itself.
        let _ = transaction.getAccessChallengeData()
    })

    let _ = (backupRemoved
    |> then(accountsRemoved)
    |> then(accountsInactive)
    |> then(passcodeRemoved)
    |> deliverOnMainQueue).start(completed: {
        appLockContext.unlock()
    })
}
