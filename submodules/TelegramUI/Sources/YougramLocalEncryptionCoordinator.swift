import UIKit
import Foundation
import WebKit
import CoreSpotlight
import Intents
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import BuildConfig
import PasscodeCore
import AccountContext
import MtProtoKit
import AppLock
import AppBundle
import SettingsUI
import YougramSettingsUI

final class YougramLocalEncryptionCoordinator {
    static let shared = YougramLocalEncryptionCoordinator()

    private var rootPath: String = ""
    private var appGroupPath: String?
    private var baseAppBundleId: String = ""
    private weak var window: UIWindow?
    private weak var sharedContext: SharedAccountContextImpl?

    private var lastInactiveUptime: TimeInterval?
    private var didEnterBackgroundSinceActive: Bool = false
    private var privacyCoverWindow: UIWindow?
    private var relockWindow: UIWindow?
    private var migrationWindow: UIWindow?

    private var isSealingInProgress = false
    private var isUnlockingInProgress = false
    private var suppressExternalLockUntil: CFAbsoluteTime = 0
    private var didSyncInitialScramble = false
    private var didReconcileInitialTimeout = false

    private var pausedAccountManager: AccountManager<TelegramAccountManagerTypes>?
    private var pausedAccounts: [Account] = []
    private var pausedAuthAccount: UnauthorizedAccount?

    private var passcodeTimeoutDisposable: Disposable?
    private var settingsSyncDisposable: Disposable?

    private var isLockingOrLocked: Bool {
        return self.relockWindow != nil || self.isSealingInProgress || self.isUnlockingInProgress
    }

    private init() {
    }

    func configure(
        rootPath: String,
        appGroupPath: String?,
        baseAppBundleId: String,
        window: UIWindow?,
        sharedContext: SharedAccountContextImpl?
    ) {
        self.rootPath = rootPath
        self.appGroupPath = appGroupPath
        self.baseAppBundleId = baseAppBundleId
        if let window {
            self.window = window
        }
        if let sharedContext {
            self.sharedContext = sharedContext
        }

        YougramLocalEncryptionHooks.currentRootPath = { [weak self] in
            return self?.rootPath
        }
        YougramLocalEncryptionHooks.performLiveEnable = { [weak self] masterKey, completion in
            guard let self else {
                completion(.failure(YougramVaultError.unavailable))
                return
            }
            self.performLiveMigration(encrypt: true, masterKey: masterKey, completion: completion)
        }
        YougramLocalEncryptionHooks.performLiveDisable = { [weak self] masterKey, completion in
            guard let self else {
                completion(.failure(YougramVaultError.unavailable))
                return
            }
            self.performLiveMigration(encrypt: false, masterKey: masterKey, completion: completion)
        }
        YougramLocalEncryptionHooks.lockNow = { [weak self] in
            self?.beginVaultLockSequence()
        }
        YougramLocalEncryptionHooks.handleAppLockTriggered = { [weak self] isManual in
            guard let self else {
                return false
            }
            return self.handleExternalAppLock(isManualLock: isManual)
        }
        YougramLocalEncryptionHooks.makeLocalEncryptionController = { contextObj in
            guard let context = contextObj as? AccountContext else {
                return nil
            }
            return yougramLocalEncryptionController(context: context)
        }
        YougramLocalEncryptionHooks.openPasscodeOptions = { contextObj, navigate in
            guard let context = contextObj as? AccountContext else {
                return
            }
            let _ = passcodeOptionsAccessController(context: context, replaceController: { controller in
                navigate(controller, true)
            }, authorizationCompleted: { result in
                guard case let .success(session) = result else { return }
                navigate(passcodeOptionsController(context: context, settingsSession: session), true)
            }).start(next: { controller in
                if let controller {
                    navigate(controller, false)
                }
            })
        }

        self.passcodeTimeoutDisposable?.dispose()
        self.settingsSyncDisposable?.dispose()

        if let sharedContext {
            self.passcodeTimeoutDisposable = (sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]))
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] sharedData in
                guard let self, !self.didReconcileInitialTimeout, !self.rootPath.isEmpty else {
                    return
                }
                self.didReconcileInitialTimeout = true
                guard let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath) else {
                    return
                }
                let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]?.get(PresentationPasscodeSettings.self) ?? .defaultSettings
                if manifest.autoLockTimeout == nil, manifest.unlockMode == .appPasscode, settings.autolockTimeout != nil {
                    try? YougramVaultStore.shared.setAutoLockTimeout(settings.autolockTimeout, rootPath: self.rootPath)
                } else if settings.autolockTimeout != manifest.autoLockTimeout {
                    let targetTimeout = manifest.autoLockTimeout
                    let _ = updatePresentationPasscodeSettingsInteractively(accountManager: sharedContext.accountManager, { current in
                        return current.withUpdatedAutolockTimeout(targetTimeout)
                    }).start()
                }
            })

            self.settingsSyncDisposable = (sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.yougramSettings]))
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] sharedData in
                guard let self, !self.didSyncInitialScramble, !self.rootPath.isEmpty else {
                    return
                }
                self.didSyncInitialScramble = true
                if let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.yougramSettings]?.get(YougramSettings.self),
                   settings.scramblePasscodeKeypad,
                   let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath),
                   !manifest.scrambledKeypad {
                    try? YougramVaultStore.shared.setScrambledKeypad(true, rootPath: self.rootPath)
                }
            })
        }
    }

    func completePendingMigrationIfNeeded(
        rootPath: String,
        masterKey: Data,
        baseAppBundleId: String,
        window: UIWindow?,
        unlockController: YougramVaultUnlockController? = nil,
        completion: @escaping () -> Void
    ) {
        guard let manifest = YougramVaultStore.shared.loadManifest(rootPath: rootPath) else {
            completion()
            return
        }
        switch manifest.migrationState {
        case .none:
            completion()
        case .enabling, .disabling:
            let encrypting = manifest.migrationState == .enabling
            let progressController: YougramMigrationProgressController?
            if unlockController == nil {
                let controller = YougramMigrationProgressController(encrypting: encrypting)
                if let rootViewController = window?.rootViewController {
                    rootViewController.addChild(controller)
                    controller.view.frame = rootViewController.view.bounds
                    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    rootViewController.view.addSubview(controller.view)
                    controller.didMove(toParent: rootViewController)
                }
                progressController = controller
            } else {
                progressController = nil
            }
            UIApplication.shared.isIdleTimerDisabled = true

            DispatchQueue.global(qos: .userInitiated).async {
                let deviceParams = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
                do {
                    try YougramLocalEncryptionBridge.migrateStandaloneWithDeviceKey(
                        rootPath: rootPath,
                        encrypt: encrypting,
                        masterKey: masterKey,
                        vaultVersion: manifest.version,
                        deviceKeyData: deviceParams.key,
                        deviceSaltData: deviceParams.salt
                    ) { progress in
                        DispatchQueue.main.async {
                            progressController?.updateProgress(progress)
                            unlockController?.updateDecryptionProgress(0.15 + progress * 0.55)
                        }
                    }
                    if encrypting {
                        var updated = manifest
                        updated.migrationState = .none
                        try? YougramVaultStore.shared.saveManifest(updated, rootPath: rootPath)
                        YougramLocalEncryptionBridge.activate(masterKey: masterKey, version: manifest.version)
                        Self.purgeSystemCachesAndIndexes()
                    } else {
                        YougramVaultStore.shared.clearVault(rootPath: rootPath, passcodeSession: nil)
                        YougramLocalEncryptionBridge.deactivate()
                        YougramLocalEncryptionBridge.reconfigureSharedTempBox(basePath: rootPath)
                    }
                } catch {
                    Logger.shared.log("Yougram", "Resumed standalone migration error: \(error)")
                }
                DispatchQueue.main.async {
                    if let progressController {
                        progressController.willMove(toParent: nil)
                        progressController.view.removeFromSuperview()
                        progressController.removeFromParent()
                    }
                    UIApplication.shared.isIdleTimerDisabled = false
                    completion()
                }
            }
        }
    }

    private func effectiveAutoLockTimeout(manifest: YougramVaultManifest) -> Int32? {
        return manifest.autoLockTimeout
    }

    func handleWillResignActive() {
        guard !self.isLockingOrLocked, !self.rootPath.isEmpty else {
            return
        }
        guard let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath) else {
            return
        }
        if self.effectiveAutoLockTimeout(manifest: manifest) != nil {
            if self.lastInactiveUptime == nil {
                self.lastInactiveUptime = ProcessInfo.processInfo.systemUptime
            }
            self.showPrivacyCover()
        }
    }

    func handleDidEnterBackground() {
        self.didEnterBackgroundSinceActive = true
        if self.lastInactiveUptime == nil {
            self.lastInactiveUptime = ProcessInfo.processInfo.systemUptime
        }
        if YougramLocalEncryptionBridge.isActive {
            YougramLocalEncryptionBridge.purgeEphemeralCache()
        }
        if !self.isLockingOrLocked, !self.rootPath.isEmpty,
           let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath),
           self.effectiveAutoLockTimeout(manifest: manifest) != nil {
            self.showPrivacyCover()
        }
    }

    func handleWillEnterForegroundOrBecomeActive() {
        if self.isLockingOrLocked {
            self.hidePrivacyCover()
            self.lastInactiveUptime = nil
            self.didEnterBackgroundSinceActive = false
            return
        }
        guard !self.rootPath.isEmpty, let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath) else {
            self.hidePrivacyCover()
            self.lastInactiveUptime = nil
            self.didEnterBackgroundSinceActive = false
            return
        }

        let effectiveTimeout = self.effectiveAutoLockTimeout(manifest: manifest)
        let inactiveSince = self.lastInactiveUptime
        let wasBackgrounded = self.didEnterBackgroundSinceActive
        self.lastInactiveUptime = nil
        self.didEnterBackgroundSinceActive = false

        var shouldLock = false
        if let timeout = effectiveTimeout {
            if timeout == 0 {
                if wasBackgrounded {
                    shouldLock = true
                }
            } else if let inactiveSince {
                let elapsed = max(0.0, ProcessInfo.processInfo.systemUptime - inactiveSince)
                if elapsed >= TimeInterval(timeout) {
                    shouldLock = true
                }
            }
        }

        if shouldLock {
            self.beginVaultLockSequence()
        } else {
            self.hidePrivacyCover()
        }
    }

    func handleWillTerminate() {
        if YougramLocalEncryptionBridge.isActive {
            YougramLocalEncryptionBridge.purgeEphemeralCache()
        }
    }

    private func handleExternalAppLock(isManualLock: Bool) -> Bool {
        if self.isLockingOrLocked {
            return true
        }
        if !isManualLock && CFAbsoluteTimeGetCurrent() < self.suppressExternalLockUntil {
            return false
        }
        guard !self.rootPath.isEmpty, YougramVaultStore.shared.isEnabled(rootPath: self.rootPath) else {
            return false
        }
        self.beginVaultLockSequence()
        return true
    }

    private func showPrivacyCover() {
        guard self.privacyCoverWindow == nil, self.relockWindow == nil else {
            return
        }
        let coverWindow: UIWindow
        if #available(iOS 13.0, *), let scene = self.window?.windowScene {
            coverWindow = UIWindow(windowScene: scene)
        } else {
            coverWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        coverWindow.windowLevel = .statusBar + 5.0

        let vc = UIViewController()
        let blurStyle: UIBlurEffect.Style
        if #available(iOS 13.0, *) {
            blurStyle = .systemMaterial
        } else {
            blurStyle = .light
        }
        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
        blurView.frame = vc.view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(blurView)

        let iconName = UIApplication.shared.alternateIconName ?? "Purple"
        let bundle = getAppBundle()
        if let iconImage = UIImage(named: iconName, in: bundle, compatibleWith: nil) ?? UIImage(named: "Purple", in: bundle, compatibleWith: nil) {
            let imageView = UIImageView(image: iconImage)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 18.0
            if #available(iOS 13.0, *) {
                imageView.layer.cornerCurve = .continuous
            }
            imageView.translatesAutoresizingMaskIntoConstraints = false
            vc.view.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 80.0),
                imageView.heightAnchor.constraint(equalToConstant: 80.0)
            ])
        }

        coverWindow.rootViewController = vc
        coverWindow.isHidden = false
        self.privacyCoverWindow = coverWindow
    }

    private func hidePrivacyCover() {
        self.privacyCoverWindow?.isHidden = true
        self.privacyCoverWindow?.rootViewController = nil
        self.privacyCoverWindow = nil
    }

    private func beginVaultLockSequence() {
        guard !self.isLockingOrLocked else {
            return
        }
        guard !self.rootPath.isEmpty, let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath) else {
            return
        }
        self.isSealingInProgress = true

        let overlayWindow: UIWindow
        if #available(iOS 13.0, *), let scene = self.window?.windowScene {
            overlayWindow = UIWindow(windowScene: scene)
        } else {
            overlayWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        overlayWindow.windowLevel = .statusBar + 10.0

        let rootPath = self.rootPath
        let appGroupPath = self.appGroupPath
        let unlockController = YougramVaultUnlockController(
            rootPath: rootPath,
            appGroupPath: appGroupPath,
            manifest: manifest,
            initialPhase: .sealing,
            onUnlocked: { [weak self] masterKey, controller in
                self?.handleRelockAuthenticated(masterKey: masterKey, manifest: manifest, unlockController: controller)
            },
            onWipedAndReset: {
                exit(0)
            }
        )
        overlayWindow.rootViewController = unlockController
        overlayWindow.makeKeyAndVisible()
        self.relockWindow = overlayWindow
        self.hidePrivacyCover()

        let startTime = CFAbsoluteTimeGetCurrent()
        let finishSealing: () -> Void = { [weak self, weak unlockController] in
            YougramVaultStore.shared.lockSession()
            YougramLocalEncryptionBridge.wipeAuxiliaryPlaintextArtifacts(
                rootPath: rootPath,
                appGroupPath: appGroupPath,
                preserveExtensionMetadata: manifest.allowBackgroundExtensions
            )
            Self.purgeSystemCachesAndIndexes()
            unlockController?.updateSealingProgress(1.0)

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let minSealDelay = max(0.0, 0.70 - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + minSealDelay) {
                guard let self else { return }
                self.isSealingInProgress = false
                unlockController?.finishSealingAndShowUnlock()
            }
        }

        if let sharedContext = self.sharedContext {
            let _ = (sharedContext.activeAccountContexts
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self, weak unlockController] _, accounts, currentAuth in
                guard let self else {
                    finishSealing()
                    return
                }
                let activeAccounts = accounts.map { $0.1.account }
                for account in activeAccounts {
                    account.shouldBeServiceTaskMaster.set(.single(.never))
                    account.shouldKeepOnlinePresence.set(.single(false))
                }
                if let currentAuth {
                    currentAuth.shouldBeServiceTaskMaster.set(.single(.never))
                }

                self.pausedAccountManager = sharedContext.accountManager
                self.pausedAccounts = activeAccounts
                self.pausedAuthAccount = currentAuth
                unlockController?.updateSealingProgress(0.32)

                YougramLocalEncryptionBridge.checkpointAndClearLiveDatabases(
                    accountManager: sharedContext.accountManager,
                    accounts: activeAccounts,
                    unauthorizedAccount: currentAuth
                ) {
                    unlockController?.updateSealingProgress(0.75)
                    finishSealing()
                }
            })
        } else {
            unlockController.updateSealingProgress(0.45)
            finishSealing()
        }
    }

    private func handleRelockAuthenticated(
        masterKey: Data,
        manifest: YougramVaultManifest,
        unlockController: YougramVaultUnlockController
    ) {
        self.isUnlockingInProgress = true
        self.suppressExternalLockUntil = CFAbsoluteTimeGetCurrent() + 3.0

        YougramLocalEncryptionBridge.activate(masterKey: masterKey, version: manifest.version)
        unlockController.updateDecryptionProgress(0.42)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak unlockController] in
            guard let self, let unlockController else {
                return
            }
            if let manager = self.pausedAccountManager {
                YougramLocalEncryptionBridge.resumeLiveDatabases(
                    accountManager: manager,
                    accounts: self.pausedAccounts,
                    unauthorizedAccount: self.pausedAuthAccount
                )
            }
            for account in self.pausedAccounts {
                account.shouldBeServiceTaskMaster.set(.single(.always))
            }
            self.pausedAuthAccount?.shouldBeServiceTaskMaster.set(.single(.always))
            self.pausedAccountManager = nil
            self.pausedAccounts = []
            self.pausedAuthAccount = nil

            unlockController.updateDecryptionProgress(0.78)
            AppLockContextImpl.markUnlockedFromVault(rootPath: self.rootPath)
            YougramLocalEncryptionHooks.didUnlockFromVault?()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self, weak unlockController] in
                guard let self, let unlockController else {
                    return
                }
                unlockController.updateDecryptionProgress(1.0)
                unlockController.completeDecryptionAndDismiss { [weak self] in
                    self?.dismissRelockOverlay()
                }
            }
        }
    }

    private func dismissRelockOverlay() {
        self.isUnlockingInProgress = false
        self.suppressExternalLockUntil = CFAbsoluteTimeGetCurrent() + 2.5
        if let relockWindow = self.relockWindow {
            UIView.animate(withDuration: 0.22, animations: {
                relockWindow.alpha = 0.0
            }, completion: { _ in
                relockWindow.isHidden = true
                relockWindow.rootViewController = nil
            })
            self.relockWindow = nil
        }
        self.window?.makeKeyAndVisible()
    }

    private func performLiveMigration(
        encrypt: Bool,
        masterKey: Data,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !self.rootPath.isEmpty, let sharedContext = self.sharedContext else {
            completion(.failure(YougramVaultError.unavailable))
            return
        }

        let rootPath = self.rootPath
        let appGroupPath = self.appGroupPath
        let baseAppBundleId = self.baseAppBundleId
        let manifest = YougramVaultStore.shared.loadManifest(rootPath: rootPath)
        let vaultVersion = manifest?.version ?? YougramVaultStore.defaultVersion
        let preserveExtensionMetadata = manifest?.allowBackgroundExtensions ?? false

        let progressController = YougramMigrationProgressController(encrypting: encrypt)
        let progressWindow: UIWindow
        if #available(iOS 13.0, *), let scene = self.window?.windowScene {
            progressWindow = UIWindow(windowScene: scene)
        } else {
            progressWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        progressWindow.windowLevel = .alert + 10.0
        progressWindow.rootViewController = progressController
        progressWindow.makeKeyAndVisible()
        self.migrationWindow = progressWindow
        UIApplication.shared.isIdleTimerDisabled = true

        let _ = (sharedContext.activeAccountContexts
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] _, accounts, currentAuth in
            guard let self else { return }

            let activeAccounts = accounts.map { $0.1.account }

            for account in activeAccounts {
                account.shouldBeServiceTaskMaster.set(.single(.never))
                account.shouldKeepOnlinePresence.set(.single(false))
            }
            if let currentAuth {
                currentAuth.shouldBeServiceTaskMaster.set(.single(.never))
            }

            let deviceParams = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
            YougramLocalEncryptionBridge.migrateLiveAccounts(
                rootPath: rootPath,
                accountManager: sharedContext.accountManager,
                accounts: activeAccounts,
                unauthorizedAccount: currentAuth,
                encrypt: encrypt,
                masterKey: masterKey,
                vaultVersion: vaultVersion,
                deviceKeyData: deviceParams.key,
                deviceSaltData: deviceParams.salt,
                progress: { progress in
                    DispatchQueue.main.async {
                        progressController.updateProgress(progress)
                    }
                },
                completion: { [weak self] migrationResult in
                    guard let self else { return }
                    if encrypt, case .success = migrationResult {
                        YougramLocalEncryptionBridge.wipeAuxiliaryPlaintextArtifacts(
                            rootPath: rootPath,
                            appGroupPath: appGroupPath,
                            preserveExtensionMetadata: preserveExtensionMetadata
                        )
                        Self.purgeSystemCachesAndIndexes()
                    }
                    for account in activeAccounts {
                        account.shouldBeServiceTaskMaster.set(.single(.always))
                    }
                    if let currentAuth {
                        currentAuth.shouldBeServiceTaskMaster.set(.single(.always))
                    }

                    UIApplication.shared.isIdleTimerDisabled = false
                    self.migrationWindow?.isHidden = true
                    self.migrationWindow?.rootViewController = nil
                    self.migrationWindow = nil
                    self.window?.makeKeyAndVisible()
                    completion(migrationResult)
                }
            )
        })
    }

    static func purgeSystemCachesAndIndexes() {
        Logger.shared.logToFile = false
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "yougram.settings.v1")
        defaults.removeObject(forKey: "yougram.sendHDPhotos")
        defaults.removeObject(forKey: "yougram.hdPhotosFromClipboard")
        defaults.removeObject(forKey: "TelegramWebStoreMainAccountId")
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasPrefix("yougram.chatList.lastFolder.") || key.hasPrefix("TelegramWebStoreUUID_") {
                defaults.removeObject(forKey: key)
            }
        }
        URLCache.shared.removeAllCachedResponses()
        CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: nil)
        if #available(iOS 10.0, *) {
            INInteraction.deleteAll(completion: nil)
        }
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: {})
        }
    }
}
