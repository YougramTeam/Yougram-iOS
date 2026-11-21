import Foundation
import Security
import CryptoKit
import CommonCrypto
import LocalAuthentication
import TelegramCore
import SwiftSignalKit

public enum YougramDedicatedSecretKind: String, Codable, Equatable, Sendable {
    case digits4
    case digits6
    case password

    public func normalize(_ secret: String) -> String {
        guard self != .password else {
            return secret.precomposedStringWithCanonicalMapping
        }
        return String(secret.map { character in
            if let value = character.wholeNumberValue, value < 10 {
                return Character(String(value))
            }
            return character
        })
    }

    public func isValidFormat(_ secret: String) -> Bool {
        let normalized = self.normalize(secret)
        switch self {
        case .digits4:
            return normalized.count == 4 && normalized.allSatisfy { $0.isASCII && $0.isNumber }
        case .digits6:
            return normalized.count == 6 && normalized.allSatisfy { $0.isASCII && $0.isNumber }
        case .password:
            return !normalized.isEmpty
        }
    }
}

public enum YougramVaultUnlockMode: Codable, Equatable, Sendable {
    case dedicated(YougramDedicatedSecretKind)
    case appPasscode

    enum CodingKeys: String, CodingKey {
        case type
        case secretKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "dedicated":
            let kind = try container.decode(YougramDedicatedSecretKind.self, forKey: .secretKind)
            self = .dedicated(kind)
        case "appPasscode":
            self = .appPasscode
        default:
            throw YougramVaultError.corrupted
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .dedicated(kind):
            try container.encode("dedicated", forKey: .type)
            try container.encode(kind, forKey: .secretKind)
        case .appPasscode:
            try container.encode("appPasscode", forKey: .type)
        }
    }
}

public enum YougramVaultMigrationState: String, Codable, Equatable, Sendable {
    case none
    case enabling
    case disabling
}

public struct YougramVaultManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var unlockMode: YougramVaultUnlockMode
    public var salt: Data?
    public var iterations: Int
    public var wrappedMasterKey: Data
    public var pepperVersion: Int
    public var allowBackgroundExtensions: Bool
    public var biometricsEnabled: Bool
    public var autoLockTimeout: Int32?
    public var scrambledKeypad: Bool
    public var duressSalt: Data?
    public var duressHash: Data?
    public var failedAttempts: Int
    public var cooldownUntil: TimeInterval
    public var migrationState: YougramVaultMigrationState

    public init(
        version: Int = 1,
        unlockMode: YougramVaultUnlockMode,
        salt: Data?,
        iterations: Int,
        wrappedMasterKey: Data,
        pepperVersion: Int = 1,
        allowBackgroundExtensions: Bool = false,
        biometricsEnabled: Bool = false,
        autoLockTimeout: Int32? = nil,
        scrambledKeypad: Bool = false,
        duressSalt: Data? = nil,
        duressHash: Data? = nil,
        failedAttempts: Int = 0,
        cooldownUntil: TimeInterval = 0,
        migrationState: YougramVaultMigrationState = .none
    ) {
        self.version = version
        self.unlockMode = unlockMode
        self.salt = salt
        self.iterations = iterations
        self.wrappedMasterKey = wrappedMasterKey
        self.pepperVersion = pepperVersion
        self.allowBackgroundExtensions = allowBackgroundExtensions
        self.biometricsEnabled = biometricsEnabled
        self.autoLockTimeout = autoLockTimeout
        self.scrambledKeypad = scrambledKeypad
        self.duressSalt = duressSalt
        self.duressHash = duressHash
        self.failedAttempts = failedAttempts
        self.cooldownUntil = cooldownUntil
        self.migrationState = migrationState
    }
}

public enum YougramVaultError: Error, Equatable {
    case invalidSecret
    case invalidFormat
    case cooldown(remainingSeconds: Int)
    case duressTriggered
    case biometricsFailed
    case cancelled
    case keychainError(Int32)
    case notEnabled
    case corrupted
    case passcodeRequired
    case matchesPasscode
    case unavailable
}

/// Static hooks registered by TelegramUI's coordinator so Settings can drive live
/// migration and lock without circular module dependencies.
public enum YougramLocalEncryptionHooks {
    public static var currentRootPath: (() -> String?)?
    public static var performLiveEnable: ((_ masterKey: Data, _ completion: @escaping (Result<Void, Error>) -> Void) -> Void)?
    public static var performLiveDisable: ((_ masterKey: Data, _ completion: @escaping (Result<Void, Error>) -> Void) -> Void)?
    public static var lockNow: (() -> Void)?
}

@available(macOS 10.15, *)
public final class YougramVaultStore: @unchecked Sendable {
    public static let shared = YougramVaultStore()

    private static let pepperService = "com.yougram.vault.pepper.v1"
    private static let pepperAccount = "pepper.v1"
    private static let pepperSETag = Data("com.yougram.vault.pepper.se.v1".utf8)
    private static let biometricService = "com.yougram.vault.biometric.v1"
    private static let biometricAccount = "biometric.vmk.v1"
    private static let extensionService = "com.yougram.vault.ext.v1"
    private static let extensionAccount = "ext.vmk.v1"

    public static let defaultIterations = 310_000
    public static let vaultPasscodeDomain = "vmk.v1"

    private struct PepperRecord: Codable {
        var kind: String // "se" or "kc"
        var wrappedPepper: Data
    }

    private let lock = NSLock()
    private let statePipe = ValuePipe<Void>()
    public var stateChanges: Signal<Void, NoError> {
        return self.statePipe.signal()
    }

    private var _unlockedMasterKey: Data?
    private var _needsReunlock: Bool = false

    private init() {
    }

    public func isUnlocked() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._unlockedMasterKey != nil && !self._needsReunlock
    }

    public func withUnlockedMasterKey<T>(_ body: (Data) throws -> T) throws -> T {
        self.lock.lock()
        let copy = self._unlockedMasterKey.map { Data($0) }
        let locked = self._needsReunlock
        self.lock.unlock()
        guard var key = copy, !locked, key.count == 32 else {
            throw YougramVaultError.passcodeRequired
        }
        defer {
            Self.zeroize(&key)
        }
        return try body(key)
    }

    public func setUnlockedMasterKey(_ masterKey: Data) {
        precondition(masterKey.count == 32)
        self.lock.lock()
        if var existing = self._unlockedMasterKey {
            Self.zeroize(&existing)
        }
        self._unlockedMasterKey = Data(masterKey)
        self._needsReunlock = false
        self.lock.unlock()
        Queue.mainQueue().async {
            self.statePipe.putNext(())
        }
    }

    public func lockSession() {
        self.lock.lock()
        if var existing = self._unlockedMasterKey {
            Self.zeroize(&existing)
        }
        self._unlockedMasterKey = nil
        self._needsReunlock = true
        self.lock.unlock()
        YougramLocalEncryptionBridge.purgeEphemeralCache()
        YougramLocalEncryptionBridge.deactivate()
        Queue.mainQueue().async {
            self.statePipe.putNext(())
        }
    }

    public func isEnabled(rootPath: String) -> Bool {
        return YougramLocalEncryptionBridge.hasVaultManifest(rootPath: rootPath)
    }

    public func loadManifest(rootPath: String) -> YougramVaultManifest? {
        let path = YougramLocalEncryptionBridge.vaultManifestPath(rootPath: rootPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(YougramVaultManifest.self, from: data)
    }

    public func saveManifest(_ manifest: YougramVaultManifest, rootPath: String) throws {
        let path = YougramLocalEncryptionBridge.vaultManifestPath(rootPath: rootPath)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        Queue.mainQueue().async {
            self.statePipe.putNext(())
        }
    }

    // MARK: - Vault Setup & Re-wrapping

    public func prepareDedicatedVault(
        secret: String,
        kind: YougramDedicatedSecretKind,
        allowBackgroundExtensions: Bool,
        biometricsEnabled: Bool,
        autoLockTimeout: Int32?,
        scrambledKeypad: Bool,
        existingMasterKey: Data? = nil
    ) throws -> (masterKey: Data, manifest: YougramVaultManifest) {
        guard kind.isValidFormat(secret) else {
            throw YougramVaultError.invalidFormat
        }
        var pepper = try self.loadOrCreateHardwarePepper()
        defer { Self.zeroize(&pepper) }

        let masterKey = try existingMasterKey.map { Data($0) } ?? Self.randomBytes(32)
        let salt = try Self.randomBytes(32)
        var kek = try Self.deriveDedicatedKEK(secret: kind.normalize(secret), salt: salt, iterations: Self.defaultIterations, pepper: pepper)
        defer { Self.zeroize(&kek) }

        let wrapped = try Self.aesGcmSeal(masterKey, key: kek, aad: "yougram.vmk.dedicated.v1")
        let manifest = YougramVaultManifest(
            version: 1,
            unlockMode: .dedicated(kind),
            salt: salt,
            iterations: Self.defaultIterations,
            wrappedMasterKey: wrapped,
            pepperVersion: 1,
            allowBackgroundExtensions: allowBackgroundExtensions,
            biometricsEnabled: biometricsEnabled,
            autoLockTimeout: autoLockTimeout,
            scrambledKeypad: scrambledKeypad,
            migrationState: .enabling
        )
        return (masterKey, manifest)
    }

    public func prepareAppPasscodeVault(
        session: PasscodeSession,
        allowBackgroundExtensions: Bool,
        scrambledKeypad: Bool = false,
        existingMasterKey: Data? = nil
    ) throws -> (masterKey: Data, manifest: YougramVaultManifest) {
        var pepper = try self.loadOrCreateHardwarePepper()
        defer { Self.zeroize(&pepper) }

        let masterKey = try existingMasterKey.map { Data($0) } ?? Self.randomBytes(32)
        let wrapped = try PasscodeCredentialStore.shared.withVaultKey(session: session, domain: Self.vaultPasscodeDomain) { sessionKey in
            var kek = Self.combineSessionKey(sessionKey, pepper: pepper)
            defer { Self.zeroize(&kek) }
            return try Self.aesGcmSeal(masterKey, key: kek, aad: "yougram.vmk.passcode.v1")
        }

        let manifest = YougramVaultManifest(
            version: 1,
            unlockMode: .appPasscode,
            salt: nil,
            iterations: 0,
            wrappedMasterKey: wrapped,
            pepperVersion: 1,
            allowBackgroundExtensions: allowBackgroundExtensions,
            biometricsEnabled: false,
            autoLockTimeout: nil,
            scrambledKeypad: scrambledKeypad,
            migrationState: .enabling
        )
        return (masterKey, manifest)
    }

    public func commitVault(
        manifest: YougramVaultManifest,
        masterKey: Data,
        passcodeSession: PasscodeSession?,
        rootPath: String
    ) throws {
        var finalManifest = manifest
        finalManifest.migrationState = .none

        if case .appPasscode = finalManifest.unlockMode {
            guard let passcodeSession else {
                throw YougramVaultError.passcodeRequired
            }
            try PasscodeCredentialStore.shared.setVaultProtectionEnabled(true, session: passcodeSession)
            try? self.deleteBiometricKeychainItem()
        } else {
            if finalManifest.biometricsEnabled {
                do {
                    try self.storeBiometricKeychainItem(masterKey)
                } catch {
                    finalManifest.biometricsEnabled = false
                }
            } else {
                try? self.deleteBiometricKeychainItem()
            }
            if let passcodeSession, PasscodeCredentialStore.shared.isVaultProtectionEnabled() {
                try? PasscodeCredentialStore.shared.setVaultProtectionEnabled(false, session: passcodeSession)
            }
        }

        try self.syncExtensionKeychainItem(allow: finalManifest.allowBackgroundExtensions, masterKey: masterKey)
        try self.saveManifest(finalManifest, rootPath: rootPath)
        self.setUnlockedMasterKey(masterKey)
    }

    public func recordMigrationState(_ state: YougramVaultMigrationState, manifest: YougramVaultManifest, rootPath: String) throws {
        var updated = manifest
        updated.migrationState = state
        try self.saveManifest(updated, rootPath: rootPath)
    }

    // MARK: - Unlock

    public func cooldownRemaining(rootPath: String) -> Int {
        guard let manifest = self.loadManifest(rootPath: rootPath) else {
            return 0
        }
        let now = Date().timeIntervalSince1970
        let remaining = manifest.cooldownUntil - now
        if remaining <= 0 || !remaining.isFinite {
            return 0
        }
        return Int(min(300, ceil(remaining)))
    }

    public func unlockWithDedicatedSecret(_ secret: String, rootPath: String) throws -> Data {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard case let .dedicated(kind) = manifest.unlockMode else {
            throw YougramVaultError.passcodeRequired
        }

        let normalized = kind.normalize(secret)

        // Always check dedicated duress code before checking cooldown or recording failures.
        if let duressSalt = manifest.duressSalt, let duressHash = manifest.duressHash {
            if Self.verifyDedicatedDuressSecret(normalized, salt: duressSalt, hash: duressHash) {
                throw YougramVaultError.duressTriggered
            }
        }

        let remaining = self.cooldownRemaining(rootPath: rootPath)
        if remaining > 0 {
            throw YougramVaultError.cooldown(remainingSeconds: remaining)
        }

        guard let salt = manifest.salt, manifest.iterations > 0 else {
            throw YougramVaultError.corrupted
        }
        var pepper = try self.loadExistingHardwarePepper()
        defer { Self.zeroize(&pepper) }

        var kek = try Self.deriveDedicatedKEK(secret: normalized, salt: salt, iterations: manifest.iterations, pepper: pepper)
        defer { Self.zeroize(&kek) }

        do {
            let masterKey = try Self.aesGcmOpen(manifest.wrappedMasterKey, key: kek, aad: "yougram.vmk.dedicated.v1")
            if manifest.failedAttempts != 0 || manifest.cooldownUntil != 0 {
                manifest.failedAttempts = 0
                manifest.cooldownUntil = 0
                try self.saveManifest(manifest, rootPath: rootPath)
            }
            YougramLocalEncryptionBridge.activate(masterKey: masterKey)
            try? self.syncExtensionKeychainItem(allow: manifest.allowBackgroundExtensions, masterKey: masterKey)
            self.setUnlockedMasterKey(masterKey)
            return masterKey
        } catch {
            manifest.failedAttempts = min(1_000_000, manifest.failedAttempts + 1)
            let penalty = Self.cooldownDuration(forFailures: manifest.failedAttempts)
            manifest.cooldownUntil = penalty > 0 ? (Date().timeIntervalSince1970 + penalty) : 0
            try? self.saveManifest(manifest, rootPath: rootPath)
            if penalty > 0 {
                throw YougramVaultError.cooldown(remainingSeconds: Int(penalty))
            }
            throw YougramVaultError.invalidSecret
        }
    }

    public func unlockWithBiometrics(rootPath: String, localizedReason: String) throws -> Data {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard case .dedicated = manifest.unlockMode, manifest.biometricsEnabled else {
            throw YougramVaultError.biometricsFailed
        }
        let context = LAContext()
        context.localizedReason = localizedReason
        let masterKey = try self.readBiometricKeychainItem(context: context)
        guard masterKey.count == 32 else {
            throw YougramVaultError.biometricsFailed
        }
        if manifest.failedAttempts != 0 || manifest.cooldownUntil != 0 {
            manifest.failedAttempts = 0
            manifest.cooldownUntil = 0
            try? self.saveManifest(manifest, rootPath: rootPath)
        }
        YougramLocalEncryptionBridge.activate(masterKey: masterKey)
        try? self.syncExtensionKeychainItem(allow: manifest.allowBackgroundExtensions, masterKey: masterKey)
        self.setUnlockedMasterKey(masterKey)
        return masterKey
    }

    public func unlockWithAppPasscodeSession(_ session: PasscodeSession, rootPath: String) throws -> Data {
        guard let manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard case .appPasscode = manifest.unlockMode else {
            throw YougramVaultError.passcodeRequired
        }
        var pepper = try self.loadExistingHardwarePepper()
        defer { Self.zeroize(&pepper) }

        let masterKey = try PasscodeCredentialStore.shared.withVaultKey(session: session, domain: Self.vaultPasscodeDomain) { sessionKey in
            var kek = Self.combineSessionKey(sessionKey, pepper: pepper)
            defer { Self.zeroize(&kek) }
            return try Self.aesGcmOpen(manifest.wrappedMasterKey, key: kek, aad: "yougram.vmk.passcode.v1")
        }
        YougramLocalEncryptionBridge.activate(masterKey: masterKey)
        try? self.syncExtensionKeychainItem(allow: manifest.allowBackgroundExtensions, masterKey: masterKey)
        self.setUnlockedMasterKey(masterKey)
        return masterKey
    }

    public func unlockForExtension(rootPath: String) -> Data? {
        guard let manifest = self.loadManifest(rootPath: rootPath),
              manifest.allowBackgroundExtensions,
              manifest.migrationState == .none else {
            return nil
        }
        return try? self.readExtensionKeychainItem()
    }

    // MARK: - Settings Mutations

    public func changeDedicatedSecret(
        currentMasterKey: Data,
        newSecret: String,
        newKind: YougramDedicatedSecretKind,
        rootPath: String
    ) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard newKind.isValidFormat(newSecret) else {
            throw YougramVaultError.invalidFormat
        }
        if let duressSalt = manifest.duressSalt, let duressHash = manifest.duressHash {
            if Self.verifyDedicatedDuressSecret(newKind.normalize(newSecret), salt: duressSalt, hash: duressHash) {
                throw YougramVaultError.matchesPasscode
            }
        }
        var pepper = try self.loadOrCreateHardwarePepper()
        defer { Self.zeroize(&pepper) }

        let newSalt = try Self.randomBytes(32)
        var newKek = try Self.deriveDedicatedKEK(secret: newKind.normalize(newSecret), salt: newSalt, iterations: Self.defaultIterations, pepper: pepper)
        defer { Self.zeroize(&newKek) }

        manifest.unlockMode = .dedicated(newKind)
        manifest.salt = newSalt
        manifest.iterations = Self.defaultIterations
        manifest.wrappedMasterKey = try Self.aesGcmSeal(currentMasterKey, key: newKek, aad: "yougram.vmk.dedicated.v1")
        manifest.failedAttempts = 0
        manifest.cooldownUntil = 0
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func switchToAppPasscode(currentMasterKey: Data, session: PasscodeSession, scrambledKeypad: Bool = false, rootPath: String) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        var pepper = try self.loadOrCreateHardwarePepper()
        defer { Self.zeroize(&pepper) }

        let wrapped = try PasscodeCredentialStore.shared.withVaultKey(session: session, domain: Self.vaultPasscodeDomain) { sessionKey in
            var kek = Self.combineSessionKey(sessionKey, pepper: pepper)
            defer { Self.zeroize(&kek) }
            return try Self.aesGcmSeal(currentMasterKey, key: kek, aad: "yougram.vmk.passcode.v1")
        }
        try PasscodeCredentialStore.shared.setVaultProtectionEnabled(true, session: session)
        try? self.deleteBiometricKeychainItem()

        manifest.unlockMode = .appPasscode
        manifest.salt = nil
        manifest.iterations = 0
        manifest.wrappedMasterKey = wrapped
        manifest.biometricsEnabled = false
        manifest.autoLockTimeout = nil
        manifest.scrambledKeypad = scrambledKeypad
        manifest.duressSalt = nil
        manifest.duressHash = nil
        manifest.failedAttempts = 0
        manifest.cooldownUntil = 0
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func switchToDedicated(
        currentMasterKey: Data,
        newSecret: String,
        newKind: YougramDedicatedSecretKind,
        passcodeSession: PasscodeSession?,
        rootPath: String
    ) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard newKind.isValidFormat(newSecret) else {
            throw YougramVaultError.invalidFormat
        }
        var pepper = try self.loadOrCreateHardwarePepper()
        defer { Self.zeroize(&pepper) }

        let newSalt = try Self.randomBytes(32)
        var kek = try Self.deriveDedicatedKEK(secret: newKind.normalize(newSecret), salt: newSalt, iterations: Self.defaultIterations, pepper: pepper)
        defer { Self.zeroize(&kek) }

        manifest.unlockMode = .dedicated(newKind)
        manifest.salt = newSalt
        manifest.iterations = Self.defaultIterations
        manifest.wrappedMasterKey = try Self.aesGcmSeal(currentMasterKey, key: kek, aad: "yougram.vmk.dedicated.v1")
        manifest.failedAttempts = 0
        manifest.cooldownUntil = 0
        try self.saveManifest(manifest, rootPath: rootPath)

        if let passcodeSession, PasscodeCredentialStore.shared.isVaultProtectionEnabled() {
            try PasscodeCredentialStore.shared.setVaultProtectionEnabled(false, session: passcodeSession)
        }
    }

    public func setBiometricsEnabled(_ enabled: Bool, masterKey: Data, rootPath: String) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard case .dedicated = manifest.unlockMode else {
            throw YougramVaultError.passcodeRequired
        }
        if enabled {
            try self.storeBiometricKeychainItem(masterKey)
        } else {
            try? self.deleteBiometricKeychainItem()
        }
        manifest.biometricsEnabled = enabled
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func setAllowBackgroundExtensions(_ allow: Bool, masterKey: Data, rootPath: String) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        try self.syncExtensionKeychainItem(allow: allow, masterKey: masterKey)
        manifest.allowBackgroundExtensions = allow
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func setAutoLockTimeout(_ timeout: Int32?, rootPath: String) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        manifest.autoLockTimeout = timeout
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func setScrambledKeypad(_ enabled: Bool, rootPath: String) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        manifest.scrambledKeypad = enabled
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func setDedicatedDuressCode(_ duressSecret: String?, currentSecret: String? = nil, rootPath: String) throws {
        guard var manifest = self.loadManifest(rootPath: rootPath) else {
            throw YougramVaultError.notEnabled
        }
        guard case let .dedicated(kind) = manifest.unlockMode else {
            throw YougramVaultError.passcodeRequired
        }
        if let duressSecret {
            guard kind.isValidFormat(duressSecret) else {
                throw YougramVaultError.invalidFormat
            }
            let normalized = kind.normalize(duressSecret)
            if let currentSecret, kind.normalize(currentSecret) == normalized {
                throw YougramVaultError.matchesPasscode
            }
            // Verify against existing wrappedMasterKey so duress code can never silently match unlock secret.
            if let salt = manifest.salt, manifest.iterations > 0, var pepper = try? self.loadExistingHardwarePepper() {
                defer { Self.zeroize(&pepper) }
                if var kek = try? Self.deriveDedicatedKEK(secret: normalized, salt: salt, iterations: manifest.iterations, pepper: pepper) {
                    defer { Self.zeroize(&kek) }
                    if (try? Self.aesGcmOpen(manifest.wrappedMasterKey, key: kek, aad: "yougram.vmk.dedicated.v1")) != nil {
                        throw YougramVaultError.matchesPasscode
                    }
                }
            }
            let duressSalt = try Self.randomBytes(32)
            let duressHash = try Self.pbkdf2(password: Data(normalized.utf8), salt: duressSalt, iterations: Self.defaultIterations, count: 32)
            manifest.duressSalt = duressSalt
            manifest.duressHash = duressHash
        } else {
            manifest.duressSalt = nil
            manifest.duressHash = nil
        }
        try self.saveManifest(manifest, rootPath: rootPath)
    }

    public func clearVault(rootPath: String, passcodeSession: PasscodeSession?) {
        if let passcodeSession, PasscodeCredentialStore.shared.isVaultProtectionEnabled() {
            try? PasscodeCredentialStore.shared.setVaultProtectionEnabled(false, session: passcodeSession)
        }
        try? self.deleteBiometricKeychainItem()
        try? self.deleteExtensionKeychainItem()
        let _ = try? FileManager.default.removeItem(atPath: YougramLocalEncryptionBridge.vaultManifestPath(rootPath: rootPath))
        self.lock.lock()
        if var existing = self._unlockedMasterKey {
            Self.zeroize(&existing)
        }
        self._unlockedMasterKey = nil
        self._needsReunlock = false
        self.lock.unlock()
        Queue.mainQueue().async {
            self.statePipe.putNext(())
        }
    }

    /// Cryptographically shreds all vault keys (memory, Keychain, SE key, manifest) and deletes all container data.
    public func cryptoShredAndWipeAllData(rootPath: String, appGroupPath: String?) {
        self.lock.lock()
        if var existing = self._unlockedMasterKey {
            Self.zeroize(&existing)
        }
        self._unlockedMasterKey = nil
        self._needsReunlock = true
        self.lock.unlock()

        YougramLocalEncryptionBridge.deactivate()
        try? self.deleteBiometricKeychainItem()
        try? self.deleteExtensionKeychainItem()
        try? self.deleteHardwarePepper()
        let _ = try? FileManager.default.removeItem(atPath: YougramLocalEncryptionBridge.vaultManifestPath(rootPath: rootPath))
        YougramLocalEncryptionBridge.wipeAuxiliaryPlaintextArtifacts(rootPath: rootPath, appGroupPath: appGroupPath)

        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: rootPath) {
            for item in contents where item == "accounts-metadata" || item.hasPrefix("account-") || item.hasPrefix(".") {
                let _ = try? fm.removeItem(atPath: rootPath + "/" + item)
            }
        }
        Queue.mainQueue().async {
            self.statePipe.putNext(())
        }
    }

    // MARK: - Keychain & Hardware Pepper

    private func loadOrCreateHardwarePepper() throws -> Data {
        if let data = try self.readPrivateKeychainItem(service: Self.pepperService, account: Self.pepperAccount, context: nil) {
            return try Self.decodeHardwarePepper(data)
        }
        let pepper = try Self.randomBytes(32)
        if let seWrapped = Self.wrapPepperWithSecureEnclave(pepper) {
            let record = PepperRecord(kind: "se", wrappedPepper: seWrapped)
            let data = try JSONEncoder().encode(record)
            try self.writePrivateKeychainItem(service: Self.pepperService, account: Self.pepperAccount, data: data)
            return pepper
        } else {
            let record = PepperRecord(kind: "kc", wrappedPepper: pepper)
            let data = try JSONEncoder().encode(record)
            try self.writePrivateKeychainItem(service: Self.pepperService, account: Self.pepperAccount, data: data)
            return pepper
        }
    }

    private func loadExistingHardwarePepper() throws -> Data {
        guard let data = try self.readPrivateKeychainItem(service: Self.pepperService, account: Self.pepperAccount, context: nil) else {
            throw YougramVaultError.unavailable
        }
        return try Self.decodeHardwarePepper(data)
    }

    private static func decodeHardwarePepper(_ data: Data) throws -> Data {
        guard let record = try? JSONDecoder().decode(PepperRecord.self, from: data) else {
            throw YougramVaultError.corrupted
        }
        switch record.kind {
        case "se":
            return try Self.unwrapPepperWithSecureEnclave(record.wrappedPepper)
        case "kc":
            guard record.wrappedPepper.count == 32 else {
                throw YougramVaultError.corrupted
            }
            return record.wrappedPepper
        default:
            throw YougramVaultError.corrupted
        }
    }

    private func deleteHardwarePepper() throws {
        try self.deletePrivateKeychainItem(service: Self.pepperService, account: Self.pepperAccount)
        let seQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.pepperSETag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(seQuery as CFDictionary)
    }

    private static func wrapPepperWithSecureEnclave(_ pepper: Data) -> Data? {
        let seQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.pepperSETag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var privateKey: SecKey?
        var existingRef: CFTypeRef?
        if SecItemCopyMatching(seQuery as CFDictionary, &existingRef) == errSecSuccess, let keyRef = existingRef {
            privateKey = (keyRef as! SecKey)
        } else {
            var acError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                &acError
            ) else {
                _ = acError?.takeRetainedValue()
                return nil
            }
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: Self.pepperSETag,
                    kSecAttrAccessControl as String: accessControl
                ] as [String: Any]
            ]
            var keyError: Unmanaged<CFError>?
            guard let created = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
                _ = keyError?.takeRetainedValue()
                return nil
            }
            privateKey = created
        }

        guard let priv = privateKey,
              let pub = SecKeyCopyPublicKey(priv),
              SecKeyIsAlgorithmSupported(pub, .encrypt, .eciesEncryptionCofactorX963SHA256AESGCM) else {
            return nil
        }
        var encError: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(pub, .eciesEncryptionCofactorX963SHA256AESGCM, pepper as CFData, &encError) as Data? else {
            _ = encError?.takeRetainedValue()
            return nil
        }
        return cipher
    }

    private static func unwrapPepperWithSecureEnclave(_ wrapped: Data) throws -> Data {
        let seQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.pepperSETag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(seQuery as CFDictionary, &ref)
        guard status == errSecSuccess, let keyRef = ref else {
            throw YougramVaultError.unavailable
        }
        let priv = keyRef as! SecKey
        var decError: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(priv, .eciesEncryptionCofactorX963SHA256AESGCM, wrapped as CFData, &decError) as Data?,
              plain.count == 32 else {
            _ = decError?.takeRetainedValue()
            throw YougramVaultError.unavailable
        }
        return plain
    }

    private func privateKeychainQueryWithoutAccessGroup(service: String, account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func runPrivateKeychain(_ query: [String: Any], operation: ([String: Any]) -> OSStatus) -> OSStatus {
        let status = operation(query)
        #if !os(macOS)
        if status == errSecMissingEntitlement, query[kSecAttrAccessGroup as String] != nil {
            var copy = query
            copy.removeValue(forKey: kSecAttrAccessGroup as String)
            return operation(copy)
        }
        #endif
        return status
    }

    private func privateKeychainQuery(service: String, account: String) throws -> [String: Any] {
        var query = self.privateKeychainQueryWithoutAccessGroup(service: service, account: account)
        #if !os(macOS)
        if let group = try? PasscodeEnvironment.shared.privateAccessGroup() {
            query[kSecAttrAccessGroup as String] = group
        }
        #endif
        return query
    }

    private func sharedKeychainQuery(service: String, account: String) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        #if !os(macOS)
        query[kSecAttrAccessGroup as String] = try PasscodeEnvironment.shared.sharedAccessGroup()
        #endif
        return query
    }

    private func writePrivateKeychainItem(service: String, account: String, data: Data) throws {
        let query = try self.privateKeychainQuery(service: service, account: account)
        let updateStatus = self.runPrivateKeychain(query) { candidate in
            SecItemUpdate(candidate as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw YougramVaultError.keychainError(updateStatus)
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = self.runPrivateKeychain(insert) { candidate in
            SecItemAdd(candidate as CFDictionary, nil)
        }
        guard addStatus == errSecSuccess else {
            throw YougramVaultError.keychainError(addStatus)
        }
    }

    private func readPrivateKeychainItem(service: String, account: String, context: LAContext?) throws -> Data? {
        var query = try self.privateKeychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = self.runPrivateKeychain(query) { candidate in
            result = nil
            return SecItemCopyMatching(candidate as CFDictionary, &result)
        }
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecUserCanceled {
            throw YougramVaultError.cancelled
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw YougramVaultError.keychainError(status)
        }
        return data
    }

    private func deletePrivateKeychainItem(service: String, account: String) throws {
        let query = try self.privateKeychainQuery(service: service, account: account)
        let status = self.runPrivateKeychain(query) { candidate in
            SecItemDelete(candidate as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YougramVaultError.keychainError(status)
        }
    }

    private func storeBiometricKeychainItem(_ masterKey: Data) throws {
        try? self.deleteBiometricKeychainItem()
        var query = try self.privateKeychainQuery(service: Self.biometricService, account: Self.biometricAccount)
        var acError: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &acError
        ) else {
            _ = acError?.takeRetainedValue()
            throw YougramVaultError.biometricsFailed
        }
        query[kSecValueData as String] = masterKey
        query[kSecAttrAccessControl as String] = acl
        let status = self.runPrivateKeychain(query) { candidate in
            SecItemAdd(candidate as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw YougramVaultError.keychainError(status)
        }
    }

    private func readBiometricKeychainItem(context: LAContext) throws -> Data {
        guard let data = try self.readPrivateKeychainItem(service: Self.biometricService, account: Self.biometricAccount, context: context) else {
            throw YougramVaultError.biometricsFailed
        }
        return data
    }

    private func deleteBiometricKeychainItem() throws {
        try self.deletePrivateKeychainItem(service: Self.biometricService, account: Self.biometricAccount)
    }

    private func syncExtensionKeychainItem(allow: Bool, masterKey: Data) throws {
        guard PasscodeEnvironment.shared.isMainApp else {
            return
        }
        if allow {
            guard let query = try? self.sharedKeychainQuery(service: Self.extensionService, account: Self.extensionAccount) else {
                return
            }
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: masterKey] as CFDictionary)
            if updateStatus == errSecSuccess || updateStatus == errSecMissingEntitlement {
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw YougramVaultError.keychainError(updateStatus)
            }
            var insert = query
            insert[kSecValueData as String] = masterKey
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecMissingEntitlement else {
                throw YougramVaultError.keychainError(addStatus)
            }
        } else {
            try self.deleteExtensionKeychainItem()
        }
    }

    private func readExtensionKeychainItem() throws -> Data? {
        guard var query = try? self.sharedKeychainQuery(service: Self.extensionService, account: Self.extensionAccount) else {
            return nil
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecMissingEntitlement {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            return nil
        }
        return data
    }

    private func deleteExtensionKeychainItem() throws {
        guard PasscodeEnvironment.shared.isMainApp else {
            return
        }
        guard let query = try? self.sharedKeychainQuery(service: Self.extensionService, account: Self.extensionAccount) else {
            return
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw YougramVaultError.keychainError(status)
        }
    }

    // MARK: - Crypto Primitives

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw YougramVaultError.keychainError(status)
        }
        return data
    }

    private static func deriveDedicatedKEK(secret: String, salt: Data, iterations: Int, pepper: Data) throws -> Data {
        guard pepper.count == 32, salt.count >= 16, iterations >= 100_000 else {
            throw YougramVaultError.corrupted
        }
        let kdfSalt = Data(HMAC<SHA256>.authenticationCode(for: salt, using: SymmetricKey(data: pepper)))
        var secretData = Data(("yougram.vault.secret.v1\0" + secret).utf8)
        defer { Self.zeroize(&secretData) }
        return try Self.pbkdf2(password: secretData, salt: kdfSalt, iterations: iterations, count: 32)
    }

    private static func combineSessionKey(_ sessionKey: Data, pepper: Data) -> Data {
        var input = Data("yougram.vmk.appPasscode.v1".utf8)
        input.append(pepper)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: sessionKey)))
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, count: Int) throws -> Data {
        var derived = Data(count: count)
        let status = password.withUnsafeBytes { passBuf in
            salt.withUnsafeBytes { saltBuf in
                derived.withUnsafeMutableBytes { outBuf -> Int32 in
                    guard let passBase = passBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                          let saltBase = saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBase,
                        password.count,
                        saltBase,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outBase,
                        count
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw YougramVaultError.unavailable
        }
        return derived
    }

    private static func aesGcmSeal(_ plaintext: Data, key: Data, aad: String) throws -> Data {
        guard key.count == 32 else {
            throw YougramVaultError.corrupted
        }
        let nonce = try AES.GCM.Nonce(data: try Self.randomBytes(12))
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: Data(aad.utf8)).combined else {
            throw YougramVaultError.corrupted
        }
        return combined
    }

    private static func aesGcmOpen(_ sealed: Data, key: Data, aad: String) throws -> Data {
        guard key.count == 32, sealed.count >= 28 else {
            throw YougramVaultError.corrupted
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
        } catch {
            throw YougramVaultError.invalidSecret
        }
    }

    private static func verifyDedicatedDuressSecret(_ normalizedSecret: String, salt: Data, hash: Data) -> Bool {
        guard salt.count == 32, hash.count == 32 else {
            return false
        }
        guard let candidate = try? Self.pbkdf2(password: Data(normalizedSecret.utf8), salt: salt, iterations: Self.defaultIterations, count: 32) else {
            return false
        }
        return Self.constantTimeEqual(candidate, hash)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var diff: UInt8 = 0
        for i in 0 ..< lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    private static func cooldownDuration(forFailures count: Int) -> TimeInterval {
        switch count {
        case ..<5:
            return 0
        case 5:
            return 5
        case 6:
            return 15
        case 7:
            return 60
        default:
            return 300
        }
    }

    private static func zeroize(_ data: inout Data) {
        if !data.isEmpty {
            data.resetBytes(in: 0 ..< data.count)
        }
    }
}
