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

/// Invalidates a settings passcode session once nothing holds it, so a duress setup screen that is
/// closed without finishing doesn't keep the session alive.
private final class PasscodeSessionHolder {
    let session: PasscodeSession

    init(_ session: PasscodeSession) {
        self.session = session
    }

    deinit {
        self.session.invalidate()
    }
}

private func duressEntries(isSet: Bool, settings: YougramSettings, theme: PresentationTheme, strings: PresentationStrings) -> [YougramSettingsEntry] {
    var b = YougramEntriesBuilder()
    if isSet {
        b.action(strings.Yougram_Duress_Change, tag: "set")
        b.action(strings.Yougram_Duress_Remove, destructive: true, tag: "remove")
    } else {
        b.action(strings.Yougram_Duress_Set, tag: "set")
    }
    b.info(strings.Yougram_Duress_Info)
    b.newSection()
    b.header(strings.Yougram_Duress_Options)
    b.toggle(strings.Yougram_Duress_DeleteBackup, settings, \.duressDeleteBackup, icon: yougramIcon("externaldrive", theme: theme))
    b.toggle(strings.Yougram_Duress_TerminateSessions, settings, \.duressTerminateSessions, icon: yougramIcon("person.crop.circle.badge.xmark", theme: theme))
    b.info(strings.Yougram_Duress_OptionsInfo)
    return b.entries
}

/// Settings ▸ Yougram ▸ Privacy ▸ Duress Code. What entering the code does is
/// `yougramPerformDuressWipe` (TelegramUI), which the app installs as
/// `AppLockContext.duressCodeHandler`.
///
/// Returns nil, after showing an alert, when Passcode Lock is off: the duress code is entered on
/// the passcode screen and stored against the passcode.
func yougramDuressCodeController(context: AccountContext, present: @escaping (ViewController) -> Void) -> ViewController? {
    let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
    guard (try? PasscodeCredentialStore.shared.protectionSettings())?.passcode != nil else {
        present(textAlertController(context: context, title: nil, text: strings.Yougram_Duress_NeedsPasscode, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]))
        return nil
    }

    let isSet = ValuePromise<Bool>(false, ignoreRepeated: true)
    let refresh: () -> Void = {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = PasscodeCredentialStore.shared.hasDuressCode()
            DispatchQueue.main.async {
                isSet.set(value)
            }
        }
    }
    refresh()

    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?

    let showToast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }
    let showAlert: (String) -> Void = { text in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        presentControllerImpl?(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})]))
    }

    // The passcode first, then the new code twice on the passcode setup screen, which is kept to
    // the passcode's kind so the lock screen accepts it.
    let setDuressCode: () -> Void = {
        weak var authenticationController: ViewController?
        let controller = settingsPasscodeSessionController(context: context, completion: { result in
            guard case let .success(session) = result else {
                return
            }
            let holder = PasscodeSessionHolder(session)
            guard let source = authenticationController, let navigation = source.navigationController as? NavigationController, navigation.topViewController === source,
                  let kind = (try? PasscodeCredentialStore.shared.protectionSettings())?.passcode?.kind else {
                return
            }
            let fieldType: PasscodeEntryFieldType
            switch kind {
            case .digits4:
                fieldType = .digits4
            case .digits6:
                fieldType = .digits6
            case .alphanumeric:
                fieldType = .alphanumeric
            }
            let setup = PasscodeSetupController(context: context, mode: .setup(change: false, fieldType))
            setup.allowsPasscodeTypeChange = false
            setup.title = strings.Yougram_Duress_Title
            setup.complete = { [weak setup] code, _ in
                setup?.view.isUserInteractionEnabled = false
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try PasscodeCredentialStore.shared.setDuressCode(code, session: holder.session) }
                    DispatchQueue.main.async {
                        if let setup, let navigation = setup.navigationController as? NavigationController, navigation.topViewController === setup {
                            let _ = navigation.popViewController(animated: true)
                        }
                        refresh()
                        switch result {
                        case .success:
                            showToast(strings.Yougram_Duress_Saved)
                        case let .failure(error):
                            if (error as? PasscodeDuressError) == .matchesPasscode {
                                showAlert(strings.Yougram_Duress_SameAsPasscode)
                            } else {
                                showAlert(strings.Yougram_Duress_Failed)
                            }
                        }
                    }
                }
            }
            navigation.replaceTopController(setup, animated: true)
        })
        if let controller {
            authenticationController = controller
            pushControllerImpl?(controller)
        }
    }

    let removeDuressCode: () -> Void = {
        presentControllerImpl?(textAlertController(context: context, title: nil, text: strings.Yougram_Duress_RemoveConfirm, actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: strings.Yougram_Duress_Remove, action: {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try PasscodeCredentialStore.shared.removeDuressCode() }
                    DispatchQueue.main.async {
                        refresh()
                        if case .success = result {
                            showToast(strings.Yougram_Duress_Removed)
                        } else {
                            showAlert(strings.Yougram_Duress_Failed)
                        }
                    }
                }
            })
        ]))
    }

    let arguments = YougramSettingsArguments(updateToggle: { key, value, _ in
        let _ = updateYougramSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            settings[keyPath: key] = value
            return settings
        }).start()
    }, performAction: { tag in
        switch tag {
        case "set":
            setDuressCode()
        case "remove":
            removeDuressCode()
        default:
            break
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, YougramSettings.updates, isSet.get())
    |> deliverOnMainQueue
    |> map { presentationData, settings, isSet -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.Yougram_Duress_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: duressEntries(isSet: isSet, settings: settings, theme: presentationData.theme, strings: presentationData.strings), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
