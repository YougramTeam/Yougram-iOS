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

private struct BackupScreenState: Equatable {
    var backups: [YougramAccountBackup]?
    var signedInPeerIds: Set<Int64>
    var syncsWithICloud: Bool
    var isWorking: Bool
}

private func backupEntries(state: BackupScreenState, strings: PresentationStrings) -> [YougramSettingsEntry] {
    var b = YougramEntriesBuilder()
    b.action(strings.Yougram_Backup_BackUpNow, tag: "backup")
    b.action(strings.Yougram_Backup_Restore, tag: "restore")
    b.info(strings.Yougram_Backup_Info)
    b.newSection()
    // Where the keychain items live, not app behaviour, so not a YougramSettings field.
    b.taggedToggle(strings.Yougram_Backup_ICloud, value: state.syncsWithICloud, tag: "iCloud")
    b.info(strings.Yougram_Backup_ICloudInfo)
    b.newSection()
    b.header(strings.Yougram_Backup_Saved)
    if let backups = state.backups {
        if backups.isEmpty {
            b.info(strings.Yougram_Backup_Empty)
        } else {
            for backup in backups {
                let label = state.signedInPeerIds.contains(backup.peerId) ? strings.Yougram_Backup_SignedIn : strings.Yougram_Backup_NotSignedIn
                b.backup(backup.name, label: label, peerId: backup.peerId)
            }
            b.newSection()
            b.action(strings.Yougram_Backup_DeleteAll, destructive: true, tag: "deleteAll")
        }
    } else {
        b.info(strings.Yougram_Backup_Failed)
    }
    return b.entries
}

func yougramAccountsBackupController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise(BackupScreenState(backups: [], signedInPeerIds: [], syncsWithICloud: YougramAccountsBackupStore.syncsWithICloud, isWorking: false), ignoreRepeated: true)
    let stateValue = Atomic(value: BackupScreenState(backups: [], signedInPeerIds: [], syncsWithICloud: YougramAccountsBackupStore.syncsWithICloud, isWorking: false))
    let updateState: ((BackupScreenState) -> BackupScreenState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var presentControllerImpl: ((ViewController) -> Void)?
    let actionsDisposable = DisposableSet()

    let reload: () -> Void = {
        actionsDisposable.add((Signal<[YougramAccountBackup]?, NoError> { subscriber in
            subscriber.putNext(YougramAccountsBackupStore.loadAll())
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(Queue.concurrentDefaultQueue())
        |> deliverOnMainQueue).start(next: { backups in
            updateState { state in
                var state = state
                state.backups = backups
                return state
            }
        }))
    }

    let showToast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    let confirm: (String, String, @escaping () -> Void) -> Void = { text, actionTitle, action in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = ActionSheetController(presentationData: presentationData)
        let dismissAction: () -> Void = { [weak controller] in
            controller?.dismissAnimated()
        }
        controller.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: text),
                ActionSheetButtonItem(title: actionTitle, color: .destructive, action: {
                    dismissAction()
                    action()
                })
            ]),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, action: { dismissAction() })])
        ])
        presentControllerImpl?(controller)
    }

    let arguments = YougramSettingsArguments(updateToggle: { _, _, _ in
    }, customToggle: { _, isOn in
        // The only tagged switch here: "Sync with iCloud Keychain".
        YougramAccountsBackupStore.syncsWithICloud = isOn
        updateState { state in
            var state = state
            state.syncsWithICloud = isOn
            return state
        }
        Queue.concurrentDefaultQueue().async {
            YougramAccountsBackupStore.resaveAll()
        }
    }, performAction: { tag in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        if tag == "backup" {
            actionsDisposable.add(yougramBackUpAccounts(sharedContext: context.sharedContext).start(next: { count in
                if let count {
                    showToast(strings.Yougram_Backup_BackedUp("\(count)").string)
                } else {
                    showToast(strings.Yougram_Backup_Failed)
                }
                reload()
            }))
        } else if tag == "restore" {
            actionsDisposable.add(yougramRestoreAccounts(accountManager: context.sharedContext.accountManager).start(next: { count in
                if let count {
                    showToast(count == 0 ? strings.Yougram_Backup_NothingToRestore : strings.Yougram_Backup_Restored("\(count)").string)
                } else {
                    showToast(strings.Yougram_Backup_Failed)
                }
            }))
        } else if tag == "deleteAll" {
            confirm(strings.Yougram_Backup_DeleteAllConfirm, strings.Yougram_Backup_DeleteAll, {
                Queue.concurrentDefaultQueue().async {
                    YougramAccountsBackupStore.deleteAll()
                    Queue.mainQueue().async {
                        reload()
                    }
                }
            })
        } else if tag.hasPrefix("deleteBackup:"), let peerId = Int64(tag.dropFirst("deleteBackup:".count)) {
            confirm(strings.Yougram_Backup_DeleteConfirm, strings.Yougram_Backup_Delete, {
                Queue.concurrentDefaultQueue().async {
                    YougramAccountsBackupStore.delete(peerId: peerId)
                    Queue.mainQueue().async {
                        reload()
                    }
                }
            })
        }
    })

    // Which backed-up accounts are signed in right now.
    let signedIn = context.sharedContext.accountManager.accountRecords()
    |> map { view -> Set<Int64> in
        var result = Set<Int64>()
        for record in view.records {
            var peerId: Int64?
            var isLoggedOut = false
            for attribute in record.attributes {
                switch attribute {
                case let .backupData(value):
                    peerId = value.data?.peerId
                case .loggedOut:
                    isLoggedOut = true
                default:
                    break
                }
            }
            if let peerId, !isLoggedOut {
                result.insert(peerId)
            }
        }
        return result
    }
    |> distinctUntilChanged

    actionsDisposable.add((signedIn |> deliverOnMainQueue).start(next: { ids in
        updateState { state in
            var state = state
            state.signedInPeerIds = ids
            return state
        }
    }))

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.Yougram_Backup_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: backupEntries(state: state, strings: presentationData.strings), style: .blocks)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionsDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    reload()
    return controller
}

/// Called after a new account signs in when "Back Up New Logins Automatically" is on.
public func yougramAutoBackUpAccountsIfEnabled(sharedContext: SharedAccountContext) {
    guard YougramSettings.current.autoBackupAccounts else {
        return
    }
    let _ = yougramBackUpAccounts(sharedContext: sharedContext).start()
}
