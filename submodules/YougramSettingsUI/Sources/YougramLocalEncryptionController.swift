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
import PasscodeUI

private final class YougramSettingsPasscodeHolder {
    let session: PasscodeSession
    init(_ session: PasscodeSession) {
        self.session = session
    }
    deinit {
        self.session.invalidate()
    }
}

private enum EncryptionEntry: ItemListNodeEntry {
    case info(id: Int32, section: Int32, text: String)
    case action(id: Int32, section: Int32, title: String, destructive: Bool, tag: String)
    case disclosure(id: Int32, section: Int32, icon: UIImage?, title: String, label: String, tag: String)
    case toggle(id: Int32, section: Int32, icon: UIImage?, title: String, value: Bool, tag: String)
    case header(id: Int32, section: Int32, text: String)

    var section: ItemListSectionId {
        switch self {
        case let .info(_, s, _), let .action(_, s, _, _, _), let .disclosure(_, s, _, _, _, _),
             let .toggle(_, s, _, _, _, _), let .header(_, s, _):
            return s
        }
    }

    var stableId: Int32 {
        switch self {
        case let .info(id, _, _), let .action(id, _, _, _, _), let .disclosure(id, _, _, _, _, _),
             let .toggle(id, _, _, _, _, _), let .header(id, _, _):
            return id
        }
    }

    static func <(lhs: EncryptionEntry, rhs: EncryptionEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! EncryptionArguments
        switch self {
        case let .info(_, section, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .action(_, section, title, destructive, tag):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : .generic, alignment: .natural, sectionId: section, style: .blocks, action: {
                args.performAction(tag)
            })
        case let .disclosure(_, section, icon, title, label, tag):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: label, sectionId: section, style: .blocks, action: {
                args.performAction(tag)
            })
        case let .toggle(_, section, icon, title, value, tag):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, value: value, sectionId: section, style: .blocks, updated: { newValue in
                args.toggle(tag, newValue)
            })
        case let .header(_, section, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        }
    }
}

private final class EncryptionArguments {
    let performAction: (String) -> Void
    let toggle: (String, Bool) -> Void

    init(performAction: @escaping (String) -> Void, toggle: @escaping (String, Bool) -> Void) {
        self.performAction = performAction
        self.toggle = toggle
    }
}

private func unlockMethodLabel(_ mode: YougramVaultUnlockMode, strings: PresentationStrings) -> String {
    switch mode {
    case let .dedicated(kind):
        switch kind {
        case .password:
            return strings.Yougram_Encryption_MethodPassword
        case .digits6:
            return strings.Yougram_Encryption_MethodPin6
        case .digits4:
            return strings.Yougram_Encryption_MethodPin4
        }
    case .appPasscode:
        return strings.Yougram_Encryption_MethodAppPasscode
    }
}

private func autoLockLabel(_ timeout: Int32?, strings: PresentationStrings) -> String {
    guard let timeout else {
        return strings.Yougram_Encryption_AutoLockDisabled
    }
    switch timeout {
    case 0:
        return strings.Yougram_Encryption_AutoLockImmediately
    case 60:
        return strings.Yougram_Encryption_AutoLock1Min
    case 300:
        return strings.Yougram_Encryption_AutoLock5Min
    case 900:
        return strings.Yougram_Encryption_AutoLock15Min
    case 3600:
        return strings.Yougram_Encryption_AutoLock1Hour
    default:
        return "\(timeout)s"
    }
}

private func buildEncryptionEntries(manifest: YougramVaultManifest?, theme: PresentationTheme, strings: PresentationStrings) -> [EncryptionEntry] {
    var entries: [EncryptionEntry] = []
    var nextId: Int32 = 1
    var section: Int32 = 0
    func next() -> Int32 {
        let v = nextId
        nextId += 1
        return v
    }

    guard let manifest else {
        entries.append(.action(id: next(), section: section, title: strings.Yougram_Encryption_Enable, destructive: false, tag: "enable"))
        entries.append(.info(id: next(), section: section, text: strings.Yougram_Encryption_StatusInfo))
        return entries
    }

    entries.append(.info(id: next(), section: section, text: strings.Yougram_Encryption_StatusInfo))

    section += 1
    entries.append(.disclosure(id: next(), section: section, icon: yougramIcon("key", theme: theme), title: strings.Yougram_Encryption_UnlockMethod, label: unlockMethodLabel(manifest.unlockMode, strings: strings), tag: "unlockMethod"))
    if case .dedicated = manifest.unlockMode {
        entries.append(.action(id: next(), section: section, title: strings.Yougram_Encryption_ChangeSecret, destructive: false, tag: "changeSecret"))
        entries.append(.toggle(id: next(), section: section, icon: yougramIcon("faceid", theme: theme), title: strings.Yougram_Encryption_FaceId, value: manifest.biometricsEnabled, tag: "biometrics"))
        entries.append(.disclosure(id: next(), section: section, icon: yougramIcon("timer", theme: theme), title: strings.Yougram_Encryption_AutoLock, label: autoLockLabel(manifest.autoLockTimeout, strings: strings), tag: "autoLock"))
        entries.append(.toggle(id: next(), section: section, icon: yougramIcon("circle.grid.3x3", theme: theme), title: strings.Yougram_Encryption_ScrambleKeypad, value: manifest.scrambledKeypad, tag: "scrambleKeypad"))
        let duressLabel = (manifest.duressHash != nil) ? strings.Yougram_Encryption_DuressSet : strings.Yougram_Encryption_DuressOff
        entries.append(.disclosure(id: next(), section: section, icon: yougramIcon("flame", theme: theme, destructive: true), title: strings.Yougram_Encryption_DedicatedDuress, label: duressLabel, tag: "duress"))
        entries.append(.info(id: next(), section: section, text: strings.Yougram_Encryption_DuressInfo))

        section += 1
        entries.append(.action(id: next(), section: section, title: strings.Yougram_Encryption_LockNow, destructive: false, tag: "lockNow"))
    }

    section += 1
    entries.append(.header(id: next(), section: section, text: strings.Yougram_Encryption_BackgroundExtensionsSection))
    entries.append(.toggle(id: next(), section: section, icon: yougramIcon("bell.badge", theme: theme), title: strings.Yougram_Encryption_AllowBackgroundExtensions, value: manifest.allowBackgroundExtensions, tag: "allowExtensions"))
    entries.append(.info(id: next(), section: section, text: strings.Yougram_Encryption_ExtensionsInfo))

    section += 1
    entries.append(.action(id: next(), section: section, title: strings.Yougram_Encryption_Disable, destructive: true, tag: "disable"))

    return entries
}

/// Settings ▸ Yougram ▸ Privacy ▸ Local Encryption.
public func yougramLocalEncryptionController(context: AccountContext) -> ViewController {
    let rootPath = YougramLocalEncryptionHooks.currentRootPath?() ?? (context.sharedContext.applicationBindings.containerPath + "/telegram-data")

    var pushControllerImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var presentNativeAlertImpl: ((UIAlertController) -> Void)?

    let showToast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    let showAlert: (String?, String) -> Void = { title, text in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        presentImpl?(textAlertController(context: context, title: title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})
        ]))
    }

    let promptSingleDedicatedSecret: (String, YougramDedicatedSecretKind, @escaping (String) -> Void) -> Void = { title, kind, completion in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.isSecureTextEntry = true
            tf.keyboardType = (kind == .password) ? .default : .numberPad
            tf.placeholder = (kind == .digits4) ? "4 digits" : ((kind == .digits6) ? "6 digits" : "Password")
        }
        alert.addAction(UIAlertAction(title: strings.Common_Cancel, style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: strings.Common_OK, style: .default, handler: { [weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            completion(text)
        }))
        presentNativeAlertImpl?(alert)
    }

    let promptNewDedicatedSecret: (String, YougramDedicatedSecretKind, @escaping (String) -> Void) -> Void = { title, kind, completion in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.isSecureTextEntry = true
            tf.keyboardType = (kind == .password) ? .default : .numberPad
            tf.placeholder = (kind == .digits4) ? "4 digits" : ((kind == .digits6) ? "6 digits" : "Password")
        }
        alert.addTextField { tf in
            tf.isSecureTextEntry = true
            tf.keyboardType = (kind == .password) ? .default : .numberPad
            tf.placeholder = "Confirm"
        }
        alert.addAction(UIAlertAction(title: strings.Common_Cancel, style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: strings.Common_OK, style: .default, handler: { [weak alert] _ in
            let first = alert?.textFields?[0].text ?? ""
            let second = alert?.textFields?[1].text ?? ""
            guard first == second, kind.isValidFormat(first) else {
                showAlert(nil, strings.Yougram_Encryption_InvalidSecret)
                return
            }
            completion(first)
        }))
        presentNativeAlertImpl?(alert)
    }

    let chooseSecretKind: (@escaping (YougramDedicatedSecretKind) -> Void) -> Void = { completion in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let sheet = ActionSheetController(presentationData: presentationData)
        sheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: strings.Yougram_Encryption_ChooseSecretKind),
                ActionSheetButtonItem(title: strings.Yougram_Encryption_KindPin6, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    completion(.digits6)
                }),
                ActionSheetButtonItem(title: strings.Yougram_Encryption_KindPin4, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    completion(.digits4)
                }),
                ActionSheetButtonItem(title: strings.Yougram_Encryption_KindPassword, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    completion(.password)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })
            ])
        ])
        presentImpl?(sheet)
    }

    let chooseExtensionsMode: (@escaping (Bool) -> Void) -> Void = { completion in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let sheet = ActionSheetController(presentationData: presentationData)
        sheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: strings.Yougram_Encryption_ChooseExtensionsMode),
                ActionSheetButtonItem(title: strings.Yougram_Encryption_ExtensionsModeStrict, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    completion(false)
                }),
                ActionSheetButtonItem(title: strings.Yougram_Encryption_ExtensionsModeAllow, color: .accent, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                    let confirm = textAlertController(
                        context: context,
                        title: strings.Yougram_Encryption_ExtensionsWarningTitle,
                        text: strings.Yougram_Encryption_ExtensionsWarningText,
                        actions: [
                            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {
                                completion(true)
                            })
                        ]
                    )
                    presentImpl?(confirm)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })
            ])
        ])
        presentImpl?(sheet)
    }

    let promptAppPasscodeSession: (@escaping (PasscodeSession) -> Void) -> Void = { completion in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        guard (try? PasscodeCredentialStore.shared.protectionSettings())?.passcode != nil else {
            showAlert(nil, strings.Yougram_Encryption_NeedsAppPasscode)
            return
        }
        weak var authVC: ViewController?
        if let authController = settingsPasscodeSessionController(context: context, completion: { result in
            if let authVC, let navigation = authVC.navigationController as? NavigationController, navigation.topViewController === authVC {
                let _ = navigation.popViewController(animated: true)
            }
            if case let .success(session) = result {
                completion(session)
            }
        }) {
            authVC = authController
            pushControllerImpl?(authController)
        }
    }

    let verifyCurrentDedicated: (YougramVaultManifest, @escaping (_ secret: String, _ masterKey: Data) -> Void) -> Void = { manifest, completion in
        guard case let .dedicated(kind) = manifest.unlockMode else { return }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        promptSingleDedicatedSecret(strings.Yougram_Encryption_EnterCurrentSecret, kind) { secret in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let masterKey = try YougramVaultStore.shared.unlockWithDedicatedSecret(secret, rootPath: rootPath)
                    DispatchQueue.main.async {
                        completion(secret, masterKey)
                    }
                } catch {
                    DispatchQueue.main.async {
                        showAlert(nil, strings.Yougram_Encryption_InvalidSecret)
                    }
                }
            }
        }
    }

    let startEnableMigration: (Data, YougramVaultManifest, PasscodeSession?) -> Void = { masterKey, manifest, passcodeSession in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let holder = passcodeSession.map(YougramSettingsPasscodeHolder.init)
        do {
            try YougramVaultStore.shared.saveManifest(manifest, rootPath: rootPath)
        } catch {
            showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
            return
        }
        guard let performEnable = YougramLocalEncryptionHooks.performLiveEnable else {
            let _ = try? FileManager.default.removeItem(atPath: YougramLocalEncryptionBridge.vaultManifestPath(rootPath: rootPath))
            showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
            return
        }
        performEnable(masterKey) { result in
            switch result {
            case .success:
                do {
                    try YougramVaultStore.shared.commitVault(
                        manifest: manifest,
                        masterKey: masterKey,
                        passcodeSession: holder?.session,
                        rootPath: rootPath
                    )
                    showToast(strings.Yougram_Encryption_EnabledToast)
                } catch {
                    showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
                }
            case .failure:
                showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
            }
        }
    }

    let startDisableMigration: (Data, YougramVaultManifest, PasscodeSession?) -> Void = { masterKey, manifest, passcodeSession in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let holder = passcodeSession.map(YougramSettingsPasscodeHolder.init)
        do {
            try YougramVaultStore.shared.recordMigrationState(.disabling, manifest: manifest, rootPath: rootPath)
        } catch {
            showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
            return
        }
        guard let performDisable = YougramLocalEncryptionHooks.performLiveDisable else {
            try? YougramVaultStore.shared.recordMigrationState(.none, manifest: manifest, rootPath: rootPath)
            showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
            return
        }
        performDisable(masterKey) { result in
            switch result {
            case .success:
                YougramVaultStore.shared.clearVault(rootPath: rootPath, passcodeSession: holder?.session)
                showToast(strings.Yougram_Encryption_DisabledToast)
            case .failure:
                try? YougramVaultStore.shared.recordMigrationState(.none, manifest: manifest, rootPath: rootPath)
                showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
            }
        }
    }

    let arguments = EncryptionArguments(
        performAction: { tag in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let strings = presentationData.strings
            let currentManifest = YougramVaultStore.shared.loadManifest(rootPath: rootPath)

            switch tag {
            case "enable":
                let sheet = ActionSheetController(presentationData: presentationData)
                sheet.setItemGroups([
                    ActionSheetItemGroup(items: [
                        ActionSheetTextItem(title: strings.Yougram_Encryption_ChooseUnlockMethod),
                        ActionSheetButtonItem(title: strings.Yougram_Encryption_DedicatedMethod, color: .accent, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                            chooseSecretKind { kind in
                                chooseExtensionsMode { allowExtensions in
                                    promptNewDedicatedSecret(strings.Yougram_Encryption_EnterNewSecret, kind) { secret in
                                        DispatchQueue.global(qos: .userInitiated).async {
                                            do {
                                                let scramble = YougramSettings.current.scramblePasscodeKeypad
                                                let prepared = try YougramVaultStore.shared.prepareDedicatedVault(
                                                    secret: secret,
                                                    kind: kind,
                                                    allowBackgroundExtensions: allowExtensions,
                                                    biometricsEnabled: false,
                                                    autoLockTimeout: 300,
                                                    scrambledKeypad: scramble
                                                )
                                                DispatchQueue.main.async {
                                                    startEnableMigration(prepared.masterKey, prepared.manifest, nil)
                                                }
                                            } catch {
                                                DispatchQueue.main.async {
                                                    showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }),
                        ActionSheetButtonItem(title: strings.Yougram_Encryption_AppPasscodeMethod, color: .accent, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                            guard (try? PasscodeCredentialStore.shared.protectionSettings())?.passcode != nil else {
                                showAlert(nil, strings.Yougram_Encryption_NeedsAppPasscode)
                                return
                            }
                            chooseExtensionsMode { allowExtensions in
                                promptAppPasscodeSession { session in
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        do {
                                            let prepared = try YougramVaultStore.shared.prepareAppPasscodeVault(
                                                session: session,
                                                allowBackgroundExtensions: allowExtensions,
                                                scrambledKeypad: YougramSettings.current.scramblePasscodeKeypad
                                            )
                                            DispatchQueue.main.async {
                                                startEnableMigration(prepared.masterKey, prepared.manifest, session)
                                            }
                                        } catch {
                                            session.invalidate()
                                            DispatchQueue.main.async {
                                                showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
                                            }
                                        }
                                    }
                                }
                            }
                        })
                    ]),
                    ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                        })
                    ])
                ])
                presentImpl?(sheet)

            case "unlockMethod":
                guard let manifest = currentManifest else { return }
                let sheet = ActionSheetController(presentationData: presentationData)
                sheet.setItemGroups([
                    ActionSheetItemGroup(items: [
                        ActionSheetTextItem(title: strings.Yougram_Encryption_ChooseUnlockMethod),
                        ActionSheetButtonItem(title: strings.Yougram_Encryption_DedicatedMethod, color: .accent, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                            switch manifest.unlockMode {
                            case .dedicated:
                                verifyCurrentDedicated(manifest) { _, masterKey in
                                    chooseSecretKind { newKind in
                                        promptNewDedicatedSecret(strings.Yougram_Encryption_EnterNewSecret, newKind) { newSecret in
                                            try? YougramVaultStore.shared.changeDedicatedSecret(currentMasterKey: masterKey, newSecret: newSecret, newKind: newKind, rootPath: rootPath)
                                            showToast(strings.Yougram_Encryption_UpdatedToast)
                                        }
                                    }
                                }
                            case .appPasscode:
                                promptAppPasscodeSession { session in
                                    let holder = YougramSettingsPasscodeHolder(session)
                                    if let masterKey = try? YougramVaultStore.shared.unlockWithAppPasscodeSession(holder.session, rootPath: rootPath) {
                                        chooseSecretKind { newKind in
                                            promptNewDedicatedSecret(strings.Yougram_Encryption_EnterNewSecret, newKind) { newSecret in
                                                try? YougramVaultStore.shared.switchToDedicated(currentMasterKey: masterKey, newSecret: newSecret, newKind: newKind, passcodeSession: holder.session, rootPath: rootPath)
                                                showToast(strings.Yougram_Encryption_UpdatedToast)
                                            }
                                        }
                                    }
                                }
                            }
                        }),
                        ActionSheetButtonItem(title: strings.Yougram_Encryption_AppPasscodeMethod, color: .accent, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                            guard case .dedicated = manifest.unlockMode else { return }
                            guard (try? PasscodeCredentialStore.shared.protectionSettings())?.passcode != nil else {
                                showAlert(nil, strings.Yougram_Encryption_NeedsAppPasscode)
                                return
                            }
                            verifyCurrentDedicated(manifest) { _, masterKey in
                                promptAppPasscodeSession { session in
                                    let holder = YougramSettingsPasscodeHolder(session)
                                    do {
                                        try YougramVaultStore.shared.switchToAppPasscode(currentMasterKey: masterKey, session: holder.session, scrambledKeypad: YougramSettings.current.scramblePasscodeKeypad, rootPath: rootPath)
                                        showToast(strings.Yougram_Encryption_UpdatedToast)
                                    } catch {
                                        showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
                                    }
                                }
                            }
                        })
                    ]),
                    ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                        })
                    ])
                ])
                presentImpl?(sheet)

            case "changeSecret":
                guard let manifest = currentManifest, case let .dedicated(kind) = manifest.unlockMode else { return }
                verifyCurrentDedicated(manifest) { _, masterKey in
                    promptNewDedicatedSecret(strings.Yougram_Encryption_EnterNewSecret, kind) { newSecret in
                        do {
                            try YougramVaultStore.shared.changeDedicatedSecret(currentMasterKey: masterKey, newSecret: newSecret, newKind: kind, rootPath: rootPath)
                            showToast(strings.Yougram_Encryption_UpdatedToast)
                        } catch YougramVaultError.matchesPasscode {
                            showAlert(nil, strings.Yougram_Encryption_SameAsUnlockSecret)
                        } catch {
                            showAlert(nil, strings.Yougram_Encryption_InvalidSecret)
                        }
                    }
                }

            case "autoLock":
                let options: [(String, Int32?)] = [
                    (strings.Yougram_Encryption_AutoLockImmediately, 0),
                    (strings.Yougram_Encryption_AutoLock1Min, 60),
                    (strings.Yougram_Encryption_AutoLock5Min, 300),
                    (strings.Yougram_Encryption_AutoLock15Min, 900),
                    (strings.Yougram_Encryption_AutoLock1Hour, 3600),
                    (strings.Yougram_Encryption_AutoLockDisabled, nil)
                ]
                let sheet = ActionSheetController(presentationData: presentationData)
                sheet.setItemGroups([
                    ActionSheetItemGroup(items: options.map { title, value in
                        ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                            try? YougramVaultStore.shared.setAutoLockTimeout(value, rootPath: rootPath)
                        })
                    }),
                    ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                        })
                    ])
                ])
                presentImpl?(sheet)

            case "duress":
                guard let manifest = currentManifest, case let .dedicated(kind) = manifest.unlockMode else { return }
                let sheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = [
                    ActionSheetButtonItem(title: strings.Yougram_Encryption_DedicatedDuress, color: .accent, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        verifyCurrentDedicated(manifest) { currentSecret, _ in
                            promptNewDedicatedSecret(strings.Yougram_Encryption_EnterDuressSecret, kind) { duressSecret in
                                do {
                                    try YougramVaultStore.shared.setDedicatedDuressCode(duressSecret, currentSecret: currentSecret, rootPath: rootPath)
                                    showToast(strings.Yougram_Encryption_UpdatedToast)
                                } catch YougramVaultError.matchesPasscode {
                                    showAlert(nil, strings.Yougram_Encryption_SameAsUnlockSecret)
                                } catch {
                                    showAlert(nil, strings.Yougram_Encryption_InvalidSecret)
                                }
                            }
                        }
                    })
                ]
                if manifest.duressHash != nil {
                    items.append(ActionSheetButtonItem(title: strings.Yougram_Encryption_DuressRemove, color: .destructive, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        try? YougramVaultStore.shared.setDedicatedDuressCode(nil, rootPath: rootPath)
                        showToast(strings.Yougram_Encryption_UpdatedToast)
                    }))
                }
                sheet.setItemGroups([
                    ActionSheetItemGroup(items: items),
                    ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in
                            sheet?.dismissAnimated()
                        })
                    ])
                ])
                presentImpl?(sheet)

            case "lockNow":
                YougramLocalEncryptionHooks.lockNow?()

            case "disable":
                guard let manifest = currentManifest else { return }
                let confirmAndVerify = {
                    let confirmAlert = textAlertController(
                        context: context,
                        title: strings.Yougram_Encryption_Disable,
                        text: strings.Yougram_Encryption_DisableConfirm,
                        actions: [
                            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                            TextAlertAction(type: .destructiveAction, title: strings.Yougram_Encryption_Disable, action: {
                                switch manifest.unlockMode {
                                case .dedicated:
                                    verifyCurrentDedicated(manifest) { _, masterKey in
                                        startDisableMigration(masterKey, manifest, nil)
                                    }
                                case .appPasscode:
                                    promptAppPasscodeSession { session in
                                        if let masterKey = try? YougramVaultStore.shared.unlockWithAppPasscodeSession(session, rootPath: rootPath) {
                                            startDisableMigration(masterKey, manifest, session)
                                        } else {
                                            session.invalidate()
                                            showAlert(nil, strings.Yougram_Encryption_InvalidSecret)
                                        }
                                    }
                                }
                            })
                        ]
                    )
                    presentImpl?(confirmAlert)
                }
                confirmAndVerify()

            default:
                break
            }
        },
        toggle: { tag, newValue in
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            switch tag {
            case "biometrics":
                let applyBiometrics: (Data) -> Void = { key in
                    do {
                        try YougramVaultStore.shared.setBiometricsEnabled(newValue, masterKey: key, rootPath: rootPath)
                    } catch {
                        showAlert(nil, strings.Yougram_Encryption_MigrationFailed)
                    }
                }
                if YougramVaultStore.shared.isUnlocked() {
                    let _ = try? YougramVaultStore.shared.withUnlockedMasterKey { applyBiometrics($0) }
                } else if let manifest = YougramVaultStore.shared.loadManifest(rootPath: rootPath) {
                    verifyCurrentDedicated(manifest) { _, masterKey in
                        applyBiometrics(masterKey)
                    }
                }
            case "scrambleKeypad":
                try? YougramVaultStore.shared.setScrambledKeypad(newValue, rootPath: rootPath)
            case "allowExtensions":
                let applyExtensions: (Data) -> Void = { key in
                    try? YougramVaultStore.shared.setAllowBackgroundExtensions(newValue, masterKey: key, rootPath: rootPath)
                }
                let runWithMasterKey: (@escaping (Data) -> Void) -> Void = { work in
                    if YougramVaultStore.shared.isUnlocked() {
                        let _ = try? YougramVaultStore.shared.withUnlockedMasterKey { work($0) }
                    } else if let manifest = YougramVaultStore.shared.loadManifest(rootPath: rootPath) {
                        switch manifest.unlockMode {
                        case .dedicated:
                            verifyCurrentDedicated(manifest) { _, masterKey in
                                work(masterKey)
                            }
                        case .appPasscode:
                            promptAppPasscodeSession { session in
                                let holder = YougramSettingsPasscodeHolder(session)
                                if var key = try? YougramVaultStore.shared.unlockWithAppPasscodeSession(holder.session, rootPath: rootPath) {
                                    defer {
                                        if !key.isEmpty {
                                            key.resetBytes(in: 0 ..< key.count)
                                        }
                                    }
                                    work(key)
                                }
                            }
                        }
                    }
                }
                if newValue {
                    let warning = textAlertController(
                        context: context,
                        title: strings.Yougram_Encryption_ExtensionsWarningTitle,
                        text: strings.Yougram_Encryption_ExtensionsWarningText,
                        actions: [
                            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {
                                runWithMasterKey(applyExtensions)
                            })
                        ]
                    )
                    presentImpl?(warning)
                } else {
                    runWithMasterKey(applyExtensions)
                }
            default:
                break
            }
        }
    )

    let stateSignal: Signal<(PresentationData, YougramVaultManifest?), NoError> = combineLatest(
        context.sharedContext.presentationData,
        .single(()) |> then(YougramVaultStore.shared.stateChanges)
    )
    |> map { presentationData, _ -> (PresentationData, YougramVaultManifest?) in
        return (presentationData, YougramVaultStore.shared.loadManifest(rootPath: rootPath))
    }

    let signal = stateSignal
    |> deliverOnMainQueue
    |> map { presentationData, manifest -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let itemPresentation = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(
            presentationData: itemPresentation,
            title: .text(presentationData.strings.Yougram_Encryption_Title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: itemPresentation,
            entries: buildEncryptionEntries(manifest: manifest, theme: presentationData.theme, strings: presentationData.strings),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    presentNativeAlertImpl = { [weak controller] alert in
        controller?.present(alert, animated: true, completion: nil)
    }
    return controller
}
