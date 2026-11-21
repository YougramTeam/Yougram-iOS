import UIKit
import Foundation
import CoreSpotlight
import Intents
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import BuildConfig
import PasscodeCore
import AccountContext
import MtProtoKit

final class YougramLocalEncryptionCoordinator {
    static let shared = YougramLocalEncryptionCoordinator()

    private var rootPath: String = ""
    private var appGroupPath: String?
    private var baseAppBundleId: String = ""
    private weak var window: UIWindow?
    private weak var sharedContext: SharedAccountContextImpl?

    private var lastBackgroundTimestamp: TimeInterval?
    private var relockWindow: UIWindow?
    private var migrationWindow: UIWindow?

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
            self?.presentRelockOverlayIfNeeded(force: true)
        }
    }

    func completePendingMigrationIfNeeded(
        rootPath: String,
        masterKey: Data,
        baseAppBundleId: String,
        window: UIWindow?,
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
            let progressController = YougramMigrationProgressController(encrypting: encrypting)
            if let rootViewController = window?.rootViewController {
                rootViewController.addChild(progressController)
                progressController.view.frame = rootViewController.view.bounds
                progressController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                rootViewController.view.addSubview(progressController.view)
                progressController.didMove(toParent: rootViewController)
            }
            UIApplication.shared.isIdleTimerDisabled = true

            DispatchQueue.global(qos: .userInitiated).async {
                let deviceParams = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
                do {
                    try YougramLocalEncryptionBridge.migrateStandaloneWithDeviceKey(
                        rootPath: rootPath,
                        encrypt: encrypting,
                        masterKey: masterKey,
                        deviceKeyData: deviceParams.key,
                        deviceSaltData: deviceParams.salt
                    ) { progress in
                        DispatchQueue.main.async {
                            progressController.updateProgress(progress)
                        }
                    }
                    if encrypting {
                        var updated = manifest
                        updated.migrationState = .none
                        try? YougramVaultStore.shared.saveManifest(updated, rootPath: rootPath)
                        YougramLocalEncryptionBridge.activate(masterKey: masterKey)
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
                    progressController.willMove(toParent: nil)
                    progressController.view.removeFromSuperview()
                    progressController.removeFromParent()
                    UIApplication.shared.isIdleTimerDisabled = false
                    completion()
                }
            }
        }
    }

    func handleDidEnterBackground() {
        guard YougramLocalEncryptionBridge.isActive else {
            return
        }
        YougramLocalEncryptionBridge.purgeEphemeralCache()
        self.lastBackgroundTimestamp = CFAbsoluteTimeGetCurrent()
    }

    func handleWillEnterForegroundOrBecomeActive() {
        self.presentRelockOverlayIfNeeded(force: false)
    }

    func handleWillTerminate() {
        if YougramLocalEncryptionBridge.isActive {
            YougramLocalEncryptionBridge.purgeEphemeralCache()
        }
    }

    private func presentRelockOverlayIfNeeded(force: Bool) {
        guard self.relockWindow == nil else {
            return
        }
        guard !self.rootPath.isEmpty, let manifest = YougramVaultStore.shared.loadManifest(rootPath: self.rootPath) else {
            return
        }
        guard case .dedicated = manifest.unlockMode else {
            return
        }
        var shouldLock = force
        if !shouldLock, let timeout = manifest.autoLockTimeout, let bgTime = self.lastBackgroundTimestamp {
            let elapsed = CFAbsoluteTimeGetCurrent() - bgTime
            if timeout == 0 || elapsed >= TimeInterval(timeout) {
                shouldLock = true
            }
        }
        self.lastBackgroundTimestamp = nil
        guard shouldLock else {
            return
        }

        YougramVaultStore.shared.lockSession()
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
            onUnlocked: { [weak self] _ in
                self?.dismissRelockOverlay()
            },
            onWipedAndReset: {
                exit(0)
            }
        )
        overlayWindow.rootViewController = unlockController
        overlayWindow.makeKeyAndVisible()
        self.relockWindow = overlayWindow
    }

    private func dismissRelockOverlay() {
        self.relockWindow?.isHidden = true
        self.relockWindow?.rootViewController = nil
        self.relockWindow = nil
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
                        YougramLocalEncryptionBridge.wipeAuxiliaryPlaintextArtifacts(rootPath: rootPath, appGroupPath: appGroupPath)
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
        UserDefaults.standard.removeObject(forKey: "yougram.settings.v1")
        URLCache.shared.removeAllCachedResponses()
        CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: nil)
        if #available(iOS 10.0, *) {
            INInteraction.deleteAll(completion: nil)
        }
    }
}
