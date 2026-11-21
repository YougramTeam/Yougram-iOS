import Foundation
import Postbox
import SwiftSignalKit

/// Yougram bridge exposing Postbox / MediaBox / AccountManager local encryption without
/// leaking `Postbox` imports into UI or App Extension modules.
public enum YougramLocalEncryptionBridge {
    public static func vaultManifestPath(rootPath: String) -> String {
        return rootPath + "/.yougram-vault.json"
    }

    public static func hasVaultManifest(rootPath: String) -> Bool {
        return FileManager.default.fileExists(atPath: self.vaultManifestPath(rootPath: rootPath))
    }

    public static var isActive: Bool {
        return PostboxLocalEncryption.isActive
    }

    public static func activate(masterKey: Data) {
        let _ = PostboxLocalEncryption.activate(masterKey: masterKey)
        YougramCoreOptions.localEncryptionEnabled = true
    }

    public static func deactivate() {
        PostboxLocalEncryption.deactivate()
        YougramCoreOptions.localEncryptionEnabled = false
    }

    public static func purgeEphemeralCache() {
        PostboxLocalEncryption.ephemeralCache.purgeAllSessions()
    }

    public static func activePostboxEncryptionParameters() -> ValueBoxEncryptionParameters? {
        return PostboxLocalEncryption.current?.postboxDatabaseParameters
    }

    public static func ephemeralTempBoxBasePath() -> String {
        return PostboxLocalEncryption.ephemeralCache.ephemeralSubdirectory("temp")
    }

    public static func ephemeralAnimationCachePath() -> String {
        return PostboxLocalEncryption.ephemeralCache.ephemeralSubdirectory("animation-cache")
    }

    public static func reconfigureSharedTempBox(basePath: String) {
        TempBox.shared.reconfigureBasePath(basePath)
    }

    public static func wipeAuxiliaryPlaintextArtifacts(rootPath: String, appGroupPath: String? = nil) {
        let fm = FileManager.default
        let rootArtifacts = [
            "logs",
            "spotlight-contacts",
            "animation-cache",
            "network-stats",
            "network-usage",
            "temp",
            ".tempkey",
            ".tempkey.lock"
        ]
        var bases: [String] = [rootPath]
        if let appGroupPath, appGroupPath != rootPath {
            bases.append(appGroupPath)
        }
        for base in bases {
            for name in rootArtifacts {
                let path = base + "/" + name
                if fm.fileExists(atPath: path) {
                    let _ = try? fm.removeItem(atPath: path)
                }
            }
        }

        if let contents = try? fm.contentsOfDirectory(atPath: rootPath) {
            for entry in contents where entry.hasPrefix("account-") {
                let accountPath = rootPath + "/" + entry
                for rel in ["notificationsKey", "network-stats", "network-usage", "logs"] {
                    let path = accountPath + "/" + rel
                    if fm.fileExists(atPath: path) {
                        let _ = try? fm.removeItem(atPath: path)
                    }
                }
            }
        }
    }

    private static func accountDirectories(in rootPath: String) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else {
            return []
        }
        return contents
            .filter { $0.hasPrefix("account-") }
            .sorted()
            .map { rootPath + "/" + $0 }
    }

    private static func migrateStandaloneAccountDirectory(
        accountPath: String,
        encrypt: Bool,
        keys: YougramVaultKeyMaterial,
        fallbackDeviceParameters: ValueBoxEncryptionParameters?,
        progress: ((Float) -> Void)? = nil
    ) throws {
        let postboxPath = accountPath + "/postbox"
        if FileManager.default.fileExists(atPath: postboxPath) {
            let dbFrom = encrypt ? fallbackDeviceParameters : keys.postboxDatabaseParameters
            let dbTo = encrypt ? keys.postboxDatabaseParameters : fallbackDeviceParameters
            try SqliteValueBox.rekeyStandaloneDatabase(
                basePath: postboxPath + "/db",
                from: dbFrom,
                to: dbTo
            )
            progress?(0.2)

            let mediaPath = postboxPath + "/media"
            try MediaBox.migrateMediaDirectoryStandalone(basePath: mediaPath, encrypt: encrypt, keys: keys) { p in
                progress?(0.2 + p * 0.6)
            }
            try SqliteValueBox.rekeyStandaloneDatabase(
                basePath: mediaPath + "/storage/db",
                from: encrypt ? nil : keys.storageBoxDatabaseParameters,
                to: encrypt ? keys.storageBoxDatabaseParameters : nil
            )
            try SqliteValueBox.rekeyStandaloneDatabase(
                basePath: mediaPath + "/cache-storage/db",
                from: encrypt ? nil : keys.storageBoxDatabaseParameters,
                to: encrypt ? keys.storageBoxDatabaseParameters : nil
            )
        }
        if encrypt {
            for rel in ["notificationsKey", "network-stats", "network-usage", "logs"] {
                let _ = try? FileManager.default.removeItem(atPath: accountPath + "/" + rel)
            }
        }
        progress?(1.0)
    }

    public static func migrateStandalone(
        rootPath: String,
        encrypt: Bool,
        masterKey: Data,
        fallbackDeviceParameters: ValueBoxEncryptionParameters?,
        progress: ((Float) -> Void)? = nil
    ) throws {
        if !encrypt && fallbackDeviceParameters == nil {
            throw YougramLocalEncryptionError.invalidKey
        }
        let keys = YougramVaultKeyMaterial(masterKey: masterKey)
        defer { keys.invalidate() }

        let accountDirs = self.accountDirectories(in: rootPath)
        let totalUnits = max(1, 1 + accountDirs.count)

        try AccountManager<TelegramAccountManagerTypes>.rekeyStandalone(
            basePath: rootPath + "/accounts-metadata",
            encrypt: encrypt,
            keys: keys
        ) { p in
            progress?(p / Float(totalUnits))
        }

        for (index, accountPath) in accountDirs.enumerated() {
            let baseOffset = Float(1 + index) / Float(totalUnits)
            let span = 1.0 / Float(totalUnits)
            try self.migrateStandaloneAccountDirectory(
                accountPath: accountPath,
                encrypt: encrypt,
                keys: keys,
                fallbackDeviceParameters: fallbackDeviceParameters
            ) { p in
                progress?(baseOffset + p * span)
            }
        }

        if encrypt {
            self.wipeAuxiliaryPlaintextArtifacts(rootPath: rootPath, appGroupPath: nil)
        }
        self.purgeEphemeralCache()
        progress?(1.0)
    }

    public static func migrateLive(
        rootPath: String,
        accountManager: AccountManager<TelegramAccountManagerTypes>,
        activePostboxes: [(basePath: String, postbox: Postbox)],
        encrypt: Bool,
        masterKey: Data,
        fallbackDeviceParameters: ValueBoxEncryptionParameters?,
        progress: ((Float) -> Void)? = nil
    ) throws {
        if !encrypt && fallbackDeviceParameters == nil {
            throw YougramLocalEncryptionError.invalidKey
        }
        let keys = YougramVaultKeyMaterial(masterKey: masterKey)
        defer { keys.invalidate() }

        let activePaths = Set(activePostboxes.map { URL(fileURLWithPath: $0.basePath).standardizedFileURL.path })
        let diskAccountDirs = self.accountDirectories(in: rootPath)
        let inactiveDirs = diskAccountDirs.filter { !activePaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }

        let totalUnits = max(1, 1 + activePostboxes.count + inactiveDirs.count)

        try accountManager.rekeyEncryption(encrypt: encrypt, keys: keys) { p in
            progress?(p / Float(totalUnits))
        }

        let targetDbParams = encrypt ? keys.postboxDatabaseParameters : fallbackDeviceParameters!
        for (index, item) in activePostboxes.enumerated() {
            let baseOffset = Float(1 + index) / Float(totalUnits)
            let span = 1.0 / Float(totalUnits)
            try item.postbox.rekey(to: targetDbParams)
            progress?(baseOffset + 0.25 * span)
            try item.postbox.mediaBox.migrateMediaFiles(encrypt: encrypt, keys: keys) { p in
                progress?(baseOffset + (0.25 + p * 0.75) * span)
            }
            if encrypt {
                for rel in ["notificationsKey", "network-stats", "network-usage", "logs"] {
                    let _ = try? FileManager.default.removeItem(atPath: item.basePath + "/" + rel)
                }
            }
        }

        for (index, accountPath) in inactiveDirs.enumerated() {
            let baseOffset = Float(1 + activePostboxes.count + index) / Float(totalUnits)
            let span = 1.0 / Float(totalUnits)
            try self.migrateStandaloneAccountDirectory(
                accountPath: accountPath,
                encrypt: encrypt,
                keys: keys,
                fallbackDeviceParameters: fallbackDeviceParameters
            ) { p in
                progress?(baseOffset + p * span)
            }
        }

        if encrypt {
            self.activate(masterKey: masterKey)
            self.reconfigureSharedTempBox(basePath: self.ephemeralTempBoxBasePath())
            self.wipeAuxiliaryPlaintextArtifacts(rootPath: rootPath, appGroupPath: nil)
        } else {
            self.deactivate()
            self.reconfigureSharedTempBox(basePath: rootPath)
        }
        progress?(1.0)
    }

    public static func makeDeviceEncryptionParameters(keyData: Data, saltData: Data) -> ValueBoxEncryptionParameters? {
        guard let key = ValueBoxEncryptionParameters.Key(data: keyData),
              let salt = ValueBoxEncryptionParameters.Salt(data: saltData) else {
            return nil
        }
        return ValueBoxEncryptionParameters(
            forceEncryptionIfNoSet: false,
            key: key,
            salt: salt
        )
    }

    public static func migrateStandaloneWithDeviceKey(
        rootPath: String,
        encrypt: Bool,
        masterKey: Data,
        deviceKeyData: Data,
        deviceSaltData: Data,
        progress: ((Float) -> Void)? = nil
    ) throws {
        let fallback = self.makeDeviceEncryptionParameters(keyData: deviceKeyData, saltData: deviceSaltData)
        try self.migrateStandalone(
            rootPath: rootPath,
            encrypt: encrypt,
            masterKey: masterKey,
            fallbackDeviceParameters: fallback,
            progress: progress
        )
    }

    public static func migrateLiveAccounts(
        rootPath: String,
        accountManager: AccountManager<TelegramAccountManagerTypes>,
        accounts: [Account],
        unauthorizedAccount: UnauthorizedAccount?,
        encrypt: Bool,
        masterKey: Data,
        deviceKeyData: Data,
        deviceSaltData: Data,
        progress: ((Float) -> Void)? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var postboxes: [(basePath: String, postbox: Postbox)] = accounts.map { ($0.basePath, $0.postbox) }
        if let unauthorizedAccount {
            postboxes.append((unauthorizedAccount.basePath, unauthorizedAccount.postbox))
        }

        let group = DispatchGroup()
        group.enter()
        accountManager.setCanBeginTransactions(false) {
            group.leave()
        }
        for item in postboxes {
            group.enter()
            item.postbox.setCanBeginTransactions(false) {
                group.leave()
            }
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            let fallback = self.makeDeviceEncryptionParameters(keyData: deviceKeyData, saltData: deviceSaltData)
            var result: Result<Void, Error> = .success(())
            do {
                try self.migrateLive(
                    rootPath: rootPath,
                    accountManager: accountManager,
                    activePostboxes: postboxes,
                    encrypt: encrypt,
                    masterKey: masterKey,
                    fallbackDeviceParameters: fallback,
                    progress: progress
                )
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                accountManager.setCanBeginTransactions(true)
                for item in postboxes {
                    item.postbox.setCanBeginTransactions(true)
                }
                completion(result)
            }
        }
    }
}
