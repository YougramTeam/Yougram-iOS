import Foundation
import Security
import LocalAuthentication
import Darwin
import SwiftSignalKit

public struct PasscodeConfiguration: Equatable, Sendable {
    public enum ProcessRole: Equatable, Sendable {
        case mainApp
        case appExtension
    }

    public let appGroupIdentifier: String
    public let processRole: ProcessRole
    public let biometricKeychainService: String?
    public let keychainScope: String?

    public init(appGroupIdentifier: String, processRole: ProcessRole, biometricKeychainService: String? = nil, keychainScope: String? = nil) {
        self.appGroupIdentifier = appGroupIdentifier
        self.processRole = processRole
        self.biometricKeychainService = biometricKeychainService
        self.keychainScope = keychainScope
    }
}

public final class PasscodeEnvironment: @unchecked Sendable {
    public static let shared = PasscodeEnvironment()

    private let mutex = NSLock()
    private var configuration: PasscodeConfiguration?
    private var resolvePrivateAccessGroup: (() -> String?)?
    private var resolvedPrivateAccessGroup: String?

    init() {
        
    }

    public func configure(_ configuration: PasscodeConfiguration, privateAccessGroup: (() -> String?)? = nil) throws {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        #if os(macOS)
        guard !configuration.appGroupIdentifier.isEmpty, configuration.appGroupIdentifier.contains(".") else {
            throw PasscodeError.unavailable
        }
        #else
        guard configuration.appGroupIdentifier.hasPrefix("group."), configuration.appGroupIdentifier.count > "group.".count else {
            throw PasscodeError.unavailable
        }
        #endif
        if let current = self.configuration {
            guard current == configuration else { throw PasscodeError.unavailable }
            return
        }
        guard configuration.processRole != .mainApp || privateAccessGroup != nil else { throw PasscodeError.unavailable }
        self.configuration = configuration
        self.resolvePrivateAccessGroup = privateAccessGroup
    }

    public var keychainScope: String? {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let scope = self.configuration?.keychainScope, !scope.isEmpty else { return nil }
        return scope
    }

    public var isMainApp: Bool {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        return self.configuration?.processRole == .mainApp
    }

    public func sharedAccessGroup() throws -> String {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let configuration = self.configuration else { throw PasscodeError.unavailable }
        return configuration.appGroupIdentifier
    }

    func biometricKeychainService() throws -> String {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let configuration = self.configuration, configuration.processRole == .mainApp,
              let service = configuration.biometricKeychainService, !service.isEmpty else {
            throw PasscodeError.unavailable
        }
        return service
    }

    public func privateAccessGroup() throws -> String {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let configuration = self.configuration, configuration.processRole == .mainApp else { throw PasscodeError.unavailable }
        if let group = self.resolvedPrivateAccessGroup { return group }
        guard let group = self.resolvePrivateAccessGroup?(), !group.isEmpty else {
            throw PasscodeError.unavailable
        }
        #if !os(macOS)
        guard !group.hasPrefix("group.") else {
            throw PasscodeError.unavailable
        }
        #endif
        self.resolvedPrivateAccessGroup = group
        return group
    }
}

protocol PasscodeStorage {
    func read(_ account: String, context: LAContext?) throws -> Data?
    func write(_ data: Data, account: String, biometric: Bool) throws
    func remove(_ account: String) throws
}

@available(macOS 10.15, *)
final class PasscodeKeychain: PasscodeStorage {
    private let environment: PasscodeEnvironment
    init(environment: PasscodeEnvironment = .shared) { self.environment = environment }

    private func baseQuery(_ account: String) throws -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: try self.service(account),
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func runKeychain(_ query: [String: Any], operation: ([String: Any]) -> OSStatus) -> OSStatus {
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

    func query(_ account: String) throws -> [String: Any] {
        var query = try self.baseQuery(account)
        #if !os(macOS)
        if let accessGroup = try? (account.hasPrefix("biometric.") ? self.environment.privateAccessGroup() : self.environment.sharedAccessGroup()) {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #endif
        return query
    }

    private func service(_ account: String) throws -> String {
        let service = try account.hasPrefix("biometric.") ? self.environment.biometricKeychainService() : "org.telegram.passcode.v1"
        #if os(macOS)
        return PasscodeKeychainScope.service(service, environment: self.environment)
        #else
        return service
        #endif
    }

    func read(_ account: String, context: LAContext? = nil) throws -> Data? {
        if let value = try self.rawRead(account, context: context) {
            return value
        }
        #if os(macOS)
        if !account.hasPrefix("biometric."), self.environment.keychainScope == nil {
            return self.adoptGroupedItem(account)
        }
        #endif
        return nil
    }

    private func rawRead(_ account: String, context: LAContext?) throws -> Data? {
        var query = try self.query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = self.runKeychain(query) { candidate in
            result = nil
            return SecItemCopyMatching(candidate as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        if status == errSecUserCanceled { throw PasscodeError.cancelled }
        guard status == errSecSuccess, let data = result as? Data else { throw PasscodeError.keychain(status) }
        return data
    }

    #if os(macOS)
    private func adoptGroupedItem(_ account: String) -> Data? {
        guard let group = try? self.environment.sharedAccessGroup(),
              var query = try? self.query(account) else {
            return nil
        }
        query[kSecAttrAccessGroup as String] = group
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        try? self.write(data, account: account)
        return data
    }
    #endif

    func write(_ data: Data, account: String, biometric: Bool = false) throws {
        let query = try self.query(account)
        if !biometric {
            let status = self.runKeychain(query) { candidate in
                SecItemUpdate(candidate as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw PasscodeError.keychain(status) }
        }
        var insert = query
        insert[kSecValueData as String] = data
        if biometric {
            var error: Unmanaged<CFError>?
            guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
                _ = error?.takeRetainedValue()
                throw PasscodeError.biometricsUnavailable
            }
            insert[kSecAttrAccessControl as String] = acl
        } else {
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = self.runKeychain(insert) { candidate in
            SecItemAdd(candidate as CFDictionary, nil)
        }
        if biometric, status == errSecMissingEntitlement {
            throw PasscodeError.biometricsUnavailable
        }
        guard status == errSecSuccess else { throw PasscodeError.keychain(status) }
    }

    func remove(_ account: String) throws {
        let query = try self.query(account)
        let status = self.runKeychain(query) { candidate in
            SecItemDelete(candidate as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PasscodeError.keychain(status) }
    }
}

public enum PasscodeKind: String, Codable, Sendable {
    case digits4, digits6, alphanumeric

    public func normalize(_ code: String) -> String {
        guard self != .alphanumeric else { return code.precomposedStringWithCanonicalMapping }
        return String(code.map { character in
            if let value = character.wholeNumberValue, value < 10 { return Character(String(value)) }
            return character
        })
    }
}

public struct PasscodeCredentialReference: Codable, Equatable, Sendable {
    public let id: String
    public let kind: PasscodeKind
    
    public init(id: String, kind: PasscodeKind) {
        self.id = id
        self.kind = kind
    }
}

public struct PasscodeProtectionSettings: Equatable, Sendable {
    public let passcode: PasscodeCredentialReference?
    public let enabled: Bool
    public let biometricsEnabled: Bool
}

@available(macOS 10.15, *)
public final class PasscodeCredentialStore: @unchecked Sendable {
    public static let shared = PasscodeCredentialStore(storage: PasscodeKeychain())

    public var changes: Signal<Void, NoError> {
        return self.changesPipe.signal()
    }

    struct Record: Codable {
        var version = 1
        var id: String
        var revision: UInt64 = 1
        var managedPasscode = false
        var kind: PasscodeKind?
        var salt: Data?
        var iterations: Int?
        var wrappedKey: Data?
        var unprotectedKey: Data?
        var protectionEnabled = false
        var vaultProtectionEnabled = false
        var biometricAccount: String?
        var pendingBiometricAccount: String?
        var biometricCleanup: [String] = []

        enum CodingKeys: String, CodingKey {
            case version, id, revision, managedPasscode, kind, salt, iterations
            case wrappedKey, unprotectedKey, biometricAccount, pendingBiometricAccount, biometricCleanup
            case protectionEnabled = "walletProtection"
            case vaultProtectionEnabled = "yougramVaultProtection"
        }

        init(id: String, managedPasscode: Bool = false, unprotectedKey: Data? = nil) {
            self.id = id
            self.managedPasscode = managedPasscode
            self.unprotectedKey = unprotectedKey
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            self.id = try container.decode(String.self, forKey: .id)
            self.revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 1
            self.managedPasscode = try container.decodeIfPresent(Bool.self, forKey: .managedPasscode) ?? false
            self.kind = try container.decodeIfPresent(PasscodeKind.self, forKey: .kind)
            self.salt = try container.decodeIfPresent(Data.self, forKey: .salt)
            self.iterations = try container.decodeIfPresent(Int.self, forKey: .iterations)
            self.wrappedKey = try container.decodeIfPresent(Data.self, forKey: .wrappedKey)
            self.unprotectedKey = try container.decodeIfPresent(Data.self, forKey: .unprotectedKey)
            self.protectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .protectionEnabled) ?? false
            self.vaultProtectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .vaultProtectionEnabled) ?? false
            self.biometricAccount = try container.decodeIfPresent(String.self, forKey: .biometricAccount)
            self.pendingBiometricAccount = try container.decodeIfPresent(String.self, forKey: .pendingBiometricAccount)
            self.biometricCleanup = try container.decodeIfPresent([String].self, forKey: .biometricCleanup) ?? []
        }
    }

    private struct Attempts: Codable {
        var count = 0
        var boot: Int64
        var deadline: TimeInterval = 0
    }

    private let storage: PasscodeStorage
    private let changesPipe = ValuePipe<Void>()
    private let mutex = NSRecursiveLock()
    private var lockPath: String?
    private var expectsCredential = false
    private let iterationCount: () -> Int
    private let clock: () -> (boot: Int64, uptime: TimeInterval)

    init(storage: PasscodeStorage, iterations: @escaping () -> Int = PasscodeCrypto.iterations,
         clock: @escaping () -> (Int64, TimeInterval) = {
             var time = timeval()
             var size = MemoryLayout<timeval>.size
             guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return (0, ProcessInfo.processInfo.systemUptime) }
             return (Int64(time.tv_sec), ProcessInfo.processInfo.systemUptime)
         }) {
        self.storage = storage
        self.iterationCount = iterations
        self.clock = clock
    }

    /// The AccountManager directory is shared with extensions. All credential and
    /// attempt changes hold this cross-process lock, including read-modify-write.
    public func configureLock(directory: String) {
        self.mutex.lock()
        self.lockPath = directory + "/passcode-v1.lock"
        self.mutex.unlock()
    }

    /// Whether a credential record is present. Answering this must not depend on
    /// `requireExistingCredential`, since the caller asks precisely to decide
    /// whether requiring one can be honoured.
    public func hasStoredCredential() throws -> Bool {
        try self.serialized {
            guard let data = try self.storage.read("credential", context: nil) else { return false }
            return (try? JSONDecoder().decode(Record.self, from: data)) != nil
        }
    }

    public func requireExistingCredential() {
        self.mutex.lock()
        self.expectsCredential = true
        self.mutex.unlock()
    }

    /// Destructive credential reset. The owner must remove all protected data
    /// before the access key is replaced. Cleanup runs under the credential lock;
    /// it must not reenter this store. A cleanup failure leaves persisted keys intact.
    public func resetCredential(removingProtectedData: () throws -> Void) throws {
        try self.serialized {
            PasscodeSession.invalidateAll()
            try removingProtectedData()
            try self.storage.remove("attempts")
            try self.storage.write(PasscodeCrypto.random(32), account: "device", biometric: false)
            let record = Record(id: UUID().uuidString, managedPasscode: true, unprotectedKey: try PasscodeCrypto.random(32))
            try self.save(record)
            try? self.storage.remove(Self.duressAccount)
            self.expectsCredential = false
        }
    }

    /// Removes credential authority so the next launch can migrate legacy metadata.
    /// Both closures run under the credential lock and must not reenter this store.
    /// The continuation must commit the legacy state and terminate the process.
    public func _internalResetForPasscodeMigrationTest(removingProtectedData: () throws -> Void, then: () throws -> Never) throws -> Never {
        try self.serialized { () throws -> Never in
            PasscodeSession.invalidateAll()
            try removingProtectedData()
            try self.storage.remove("attempts")
            try self.storage.remove("device")
            try self.storage.remove("credential")
            try? self.storage.remove(Self.duressAccount)
            self.expectsCredential = false
            try then()
        }
    }

    private func serialized<T>(_ body: () throws -> T) throws -> T {
        self.mutex.lock()
        defer {
            self.mutex.unlock()
        }
        var fd: Int32 = -1
        if let lockPath {
            fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                throw PasscodeError.unavailable
            }
            guard flock(fd, LOCK_EX) == 0 else {
                close(fd)
                throw PasscodeError.unavailable
            }
        }
        defer {
            if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
        }
        return try body()
    }

    private func load() throws -> Record? {
        guard let data = try self.storage.read("credential", context: nil) else {
            if self.expectsCredential {
                throw PasscodeError.unavailable
            }
            return nil
        }
        guard let value = try? JSONDecoder().decode(Record.self, from: data), value.version == 1, !value.id.isEmpty,
              value.revision > 0,
              value.kind == nil || (value.salt?.count == 16 && value.iterations != nil && value.wrappedKey?.count == 60) else {
            throw PasscodeError.corrupted
        }
        let requiresPasscode = value.protectionEnabled || value.vaultProtectionEnabled
        guard !requiresPasscode || (value.kind != nil && value.unprotectedKey == nil),
              requiresPasscode || value.unprotectedKey?.count == 32 else {
            throw PasscodeError.corrupted
        }
        return value
    }

    private func save(_ record: Record, notify: Bool = true) throws {
        try self.storage.write(JSONEncoder().encode(record), account: "credential", biometric: false)
        if notify {
            Queue.mainQueue().async {
                self.changesPipe.putNext(())
            }
        }
    }

    private func existingOrCreate() throws -> Record {
        if let record = try self.load() { return record }
        if try self.storage.read("device", context: nil) == nil {
            try self.storage.write(PasscodeCrypto.random(32), account: "device", biometric: false)
        }
        let record = Record(id: UUID().uuidString, unprotectedKey: try PasscodeCrypto.random(32))
        try self.save(record, notify: false)
        return record
    }

    private func deviceSecret() throws -> Data {
        guard let value = try self.storage.read("device", context: nil), value.count == 32 else { throw PasscodeError.unavailable }
        return value
    }

    private func reference(_ record: Record) -> PasscodeCredentialReference? {
        record.kind.map { PasscodeCredentialReference(id: record.id, kind: $0) }
    }

    public func protectionSettings() throws -> PasscodeProtectionSettings {
        try self.serialized {
            guard let record = try self.load() else { return PasscodeProtectionSettings(passcode: nil, enabled: false, biometricsEnabled: false) }
            return PasscodeProtectionSettings(passcode: self.reference(record), enabled: record.protectionEnabled, biometricsEnabled: record.biometricAccount != nil)
        }
    }

    public func managedReference() throws -> PasscodeCredentialReference?? {
        try self.serialized {
            guard let record = try self.load(), record.managedPasscode else { return nil }
            return .some(self.reference(record))
        }
    }

    public func migrateLegacy(code: String, kind: PasscodeKind) throws -> PasscodeCredentialReference? {
        try self.serialized {
            var record = try self.existingOrCreate()
            if record.managedPasscode { return self.reference(record) }
            guard let key = record.unprotectedKey else { throw PasscodeError.corrupted }
            try self.wrap(code: code, kind: kind, key: key, record: &record)
            record.managedPasscode = true
            record.revision &+= 1
            try self.save(record)
            PasscodeSession.invalidateAll()
            return self.reference(record)
        }
    }

    private func wrap(code: String, kind: PasscodeKind, key: Data, record: inout Record) throws {
        let code = kind.normalize(code)
        guard !code.isEmpty,
              kind == .alphanumeric || (code.allSatisfy { $0.isASCII && $0.isNumber } && code.count == (kind == .digits6 ? 6 : 4)) else { throw PasscodeError.invalidCode }
        let salt = try PasscodeCrypto.random(16)
        let iterations = self.iterationCount()
        var kek = try PasscodeCrypto.derive(code: code, deviceSecret: self.deviceSecret(), salt: salt, iterations: iterations)
        defer { kek.resetBytes(in: 0 ..< kek.count) }
        let wrapped = try PasscodeCrypto.seal(key, key: kek, context: "credential.v1:\(record.id):\(kind.rawValue)")
        guard try PasscodeCrypto.open(wrapped, key: kek, context: "credential.v1:\(record.id):\(kind.rawValue)") == key else { throw PasscodeError.corrupted }
        record.kind = kind
        record.salt = salt
        record.iterations = iterations
        record.wrappedKey = wrapped
    }

    private func attempts() throws -> Attempts {
        let time = self.clock()
        guard let data = try self.storage.read("attempts", context: nil) else { return Attempts(boot: time.boot) }
        guard var value = try? JSONDecoder().decode(Attempts.self, from: data), (0 ... 1_000_000).contains(value.count),
              value.deadline.isFinite, value.deadline >= 0 else { throw PasscodeError.corrupted }
        if value.boot == time.boot, value.deadline > time.uptime + 60 { throw PasscodeError.corrupted }
        if value.boot != time.boot {
            value.boot = time.boot
            value.deadline = value.count >= 6 ? time.uptime + 60 : 0
            try self.storage.write(JSONEncoder().encode(value), account: "attempts", biometric: false)
        }
        return value
    }

    public func cooldownRemaining() throws -> Int {
        try self.serialized { Int(max(0, min(60, ceil(try self.attempts().deadline - self.clock().uptime)))) }
    }

    public func verify(_ code: String, reference: PasscodeCredentialReference? = nil, scope: PasscodeSession.Scope, lifetime: PasscodeSession.Lifetime = .standard) throws -> PasscodeSession {
        if case let .resource(namespace) = scope, namespace.isEmpty { throw PasscodeError.authenticationRequired }
        if lifetime == .ownerManaged {
            guard case .resource = scope else { throw PasscodeError.authenticationRequired }
        }
        return try self.serialized {
            guard let record = try self.load(), let kind = record.kind, let salt = record.salt,
                  let iterations = record.iterations, let wrapped = record.wrappedKey else { throw PasscodeError.authenticationRequired }
            if let reference, reference.id != record.id { throw PasscodeError.staleAuthorization }
            var attempts = try self.attempts()
            let remaining = Int(max(0, min(60, ceil(attempts.deadline - self.clock().uptime))))
            guard remaining == 0 else { throw PasscodeError.cooldown(remaining) }
            var kek = try PasscodeCrypto.derive(code: kind.normalize(code), deviceSecret: self.deviceSecret(), salt: salt, iterations: iterations)
            defer { kek.resetBytes(in: 0 ..< kek.count) }
            let key: Data
            do { key = try PasscodeCrypto.open(wrapped, key: kek, context: "credential.v1:\(record.id):\(kind.rawValue)") }
            catch {
                attempts.count = min(1_000_000, attempts.count + 1)
                attempts.deadline = attempts.count >= 6 ? self.clock().uptime + 60 : 0
                try self.storage.write(JSONEncoder().encode(attempts), account: "attempts", biometric: false)
                throw PasscodeError.invalidCode
            }
            try self.storage.remove("attempts")
            return PasscodeSession(credentialId: record.id, revision: record.revision, key: key, scope: scope, authentication: .passcode, lifetime: lifetime)
        }
    }

    public func validate(_ session: PasscodeSession, scope: PasscodeSession.Scope? = nil, requireAvailable: Bool = true) throws {
        try self.serialized {
            if let scope { try session.require(scope: scope) }
            _ = try self.validatedRecord(session, requireAvailable: requireAvailable)
        }
    }

    private func commit(_ record: Record, retaining session: PasscodeSession) throws {
        try self.save(record)
        PasscodeSession.invalidateAll(except: session)
        try session.advance(to: record.revision)
    }

    private func validatedRecord(_ session: PasscodeSession, requireAvailable: Bool = true) throws -> Record {
        guard let record = try self.load(), record.id == session.credentialId, record.revision == session.revision, session.isValid else { throw PasscodeError.staleAuthorization }
        if requireAvailable { try session.withKey { _ in } }
        return record
    }

    public func unprotectedSession(namespace: String, lifetime: PasscodeSession.Lifetime = .standard) throws -> PasscodeSession {
        guard !namespace.isEmpty else { throw PasscodeError.authenticationRequired }
        return try self.serialized {
            let record = try self.existingOrCreate()
            guard !record.protectionEnabled, !record.vaultProtectionEnabled, let key = record.unprotectedKey else { throw PasscodeError.authenticationRequired }
            return PasscodeSession(credentialId: record.id, revision: record.revision, key: key, scope: .resource(namespace: namespace), lifetime: lifetime)
        }
    }

    public func setPasscode(_ code: String, kind: PasscodeKind, session: PasscodeSession?) throws -> PasscodeCredentialReference {
        try self.serialized { try self.updatePasscode(code, kind: kind, access: session, createSession: false).reference }
    }

    public func setPasscodeWithSettingsSession(_ code: String, kind: PasscodeKind, session: PasscodeSession?) throws -> (reference: PasscodeCredentialReference, session: PasscodeSession) {
        try self.serialized {
            let result = try self.updatePasscode(code, kind: kind, access: session, createSession: true)
            guard let session = result.session else { throw PasscodeError.unavailable }
            return (result.reference, session)
        }
    }

    private func requirePasscodeManagement(_ session: PasscodeSession) throws {
        switch session.scope {
        case .managePasscode, .settings:
            try session.require(scope: session.scope, passcode: true)
        default:
            throw PasscodeError.authenticationRequired
        }
    }

    private func updatePasscode(_ code: String, kind: PasscodeKind, access: PasscodeSession?, createSession: Bool) throws -> (reference: PasscodeCredentialReference, session: PasscodeSession?) {
        guard !Task.isCancelled else { throw PasscodeError.cancelled }
        if let access { try self.requirePasscodeManagement(access) }
        var record = try self.existingOrCreate()
        let isInitialSetup = record.kind == nil
        var key: Data
        if record.kind != nil {
            guard let access else { throw PasscodeError.authenticationRequired }
            record = try self.validatedRecord(access)
            key = try access.withKey { $0 }
        } else {
            guard let value = record.unprotectedKey else { throw PasscodeError.corrupted }
            key = value
        }
        defer { key.resetBytes(in: 0 ..< key.count) }
        // Register before wrapping so a concurrent global revocation reaches the new session.
        let session = createSession ? PasscodeSession(credentialId: record.id, revision: record.revision &+ 1, key: key, scope: .settings, authentication: .passcode) : nil
        var committed = false
        defer { if !committed { session?.invalidate() } }
        try self.wrap(code: code, kind: kind, key: key, record: &record)
        if isInitialSetup {
            record.protectionEnabled = true
            record.unprotectedKey = nil
        }
        record.managedPasscode = true
        record.revision &+= 1
        if let access { _ = try self.validatedRecord(access) }
        if let session { try session.withKey { _ in } }
        guard !Task.isCancelled else { throw PasscodeError.cancelled }
        // Once writing begins, preserve the committed result so AccountManager can catch up.
        try self.storage.remove("attempts")
        try self.save(record)
        committed = true
        // A new passcode drops the duress code: it may be of another kind now, or equal to it.
        try? self.storage.remove(Self.duressAccount)
        if let access, (try? access.withKey { _ in true }) != true { session?.invalidate() }
        PasscodeSession.invalidateAll(except: session)
        if Task.isCancelled { session?.invalidate() }
        return (PasscodeCredentialReference(id: record.id, kind: kind), session)
    }

    public func setProtectionEnabled(_ enabled: Bool, session: PasscodeSession) throws {
        try session.require(scope: .settings, passcode: true)
        try self.serialized {
            var record = try self.validatedRecord(session)
            guard record.kind != nil else {
                throw PasscodeError.authenticationRequired
            }
            record.unprotectedKey = (enabled || record.vaultProtectionEnabled) ? nil : try session.withKey { $0 }
            record.protectionEnabled = enabled
            if !enabled, !record.vaultProtectionEnabled, let account = record.biometricAccount {
                record.biometricCleanup.append(account)
                record.biometricAccount = nil
            }
            record.revision &+= 1
            try self.commit(record, retaining: session)
            try self.cleanupBiometrics(record: &record)
        }
    }

    // Yougram: bind App Passcode Lock so it cannot be disabled or store unprotectedKey while Local Encryption relies on it.
    public func isVaultProtectionEnabled() -> Bool {
        return (try? self.serialized {
            return (try self.load())?.vaultProtectionEnabled ?? false
        }) ?? false
    }

    public func currentPasscodeKind() -> PasscodeKind? {
        return (try? self.serialized {
            return (try self.load())?.kind
        }) ?? nil
    }

    public func setVaultProtectionEnabled(_ enabled: Bool, session: PasscodeSession) throws {
        guard session.authentication == .passcode else {
            throw PasscodeError.authenticationRequired
        }
        try self.serialized {
            var record = try self.validatedRecord(session)
            if enabled {
                guard record.kind != nil else {
                    throw PasscodeError.authenticationRequired
                }
                record.vaultProtectionEnabled = true
                record.unprotectedKey = nil
            } else {
                record.vaultProtectionEnabled = false
                if !record.protectionEnabled {
                    record.unprotectedKey = try session.withKey { $0 }
                }
            }
            record.revision &+= 1
            try self.commit(record, retaining: session)
        }
    }

    public func withVaultKey<T>(session: PasscodeSession, domain: String, _ body: (Data) throws -> T) throws -> T {
        guard !domain.isEmpty else {
            throw PasscodeError.authenticationRequired
        }
        guard session.authentication == .passcode || session.authentication == .biometrics else {
            throw PasscodeError.authenticationRequired
        }
        try self.serialized {
            _ = try self.validatedRecord(session, requireAvailable: false)
        }
        return try session.withKey { accessKey in
            var derived = PasscodeCrypto.deriveVaultKey(from: accessKey, domain: domain)
            defer {
                if !derived.isEmpty {
                    derived.resetBytes(in: 0 ..< derived.count)
                }
            }
            return try body(derived)
        }
    }

    public func disablePasscode(session: PasscodeSession) throws {
        try self.requirePasscodeManagement(session)
        try self.serialized {
            var record = try self.validatedRecord(session)
            guard !record.vaultProtectionEnabled else {
                throw PasscodeError.vaultProtectionActive
            }
            record.unprotectedKey = try session.withKey { $0 }
            record.kind = nil
            record.salt = nil
            record.iterations = nil
            record.wrappedKey = nil
            record.protectionEnabled = false
            record.managedPasscode = true
            if let account = record.biometricAccount {
                record.biometricCleanup.append(account)
            }
            record.biometricAccount = nil
            record.revision &+= 1
            try self.storage.remove("attempts")
            try self.save(record)
            try? self.storage.remove(Self.duressAccount)
            PasscodeSession.invalidateAll()
            try self.cleanupBiometrics(record: &record)
        }
    }

    private func cleanupBiometrics(record: inout Record) throws {
        if let pending = record.pendingBiometricAccount { record.biometricCleanup.append(pending); record.pendingBiometricAccount = nil }
        for account in record.biometricCleanup { try self.storage.remove(account) }
        if !record.biometricCleanup.isEmpty {
            record.biometricCleanup = []
            try self.save(record, notify: false)
        }
    }

    public func resumeCleanup() throws {
        try self.serialized {
            guard var record = try self.load() else { return }
            try self.cleanupBiometrics(record: &record)
        }
    }

    public func disableBiometrics(session: PasscodeSession) throws {
        try session.require(scope: .settings, passcode: true)
        try self.serialized {
            var record = try self.validatedRecord(session)
            if let account = record.biometricAccount { record.biometricCleanup.append(account) }
            record.biometricAccount = nil
            record.revision &+= 1
            try self.commit(record, retaining: session)
            try self.cleanupBiometrics(record: &record)
        }
    }

    public func enableBiometrics(session: PasscodeSession, context: LAContext) throws {
        try session.require(scope: .settings, passcode: true)
        let account = "biometric." + UUID().uuidString
        try self.serialized {
            var record = try self.validatedRecord(session)
            guard record.protectionEnabled || record.vaultProtectionEnabled else { throw PasscodeError.authenticationRequired }
            try self.cleanupBiometrics(record: &record)
            record.pendingBiometricAccount = account
            try self.save(record, notify: false)
            try session.withKey { try self.storage.write($0, account: account, biometric: true) }
        }
        var committed = false
        do {
            guard let result = try self.storage.read(account, context: context),
                  try session.withKey({ $0 == result }) else { throw PasscodeError.biometricsUnavailable }
            try self.serialized {
                var record = try self.validatedRecord(session)
                guard record.pendingBiometricAccount == account else { throw PasscodeError.staleAuthorization }
                if let previous = record.biometricAccount { record.biometricCleanup.append(previous) }
                record.pendingBiometricAccount = nil
                record.biometricAccount = account
                record.revision &+= 1
                try self.save(record)
                committed = true
                PasscodeSession.invalidateAll(except: session)
                try session.advance(to: record.revision)
                try self.cleanupBiometrics(record: &record)
            }
        } catch {
            // Once the credential points to this key, only obsolete entries may
            // be removed. Failed cleanup remains journaled for resumeCleanup().
            if !committed { try? self.storage.remove(account) }
            throw error
        }
    }

    public func authenticateBiometrics(context: LAContext, scope: PasscodeSession.Scope, lifetime: PasscodeSession.Lifetime = .standard) throws -> PasscodeSession {
        guard case let .resource(namespace) = scope, !namespace.isEmpty else { throw PasscodeError.authenticationRequired }
        let record = try self.serialized { () throws -> Record in
            guard let record = try self.load(), record.protectionEnabled || record.vaultProtectionEnabled, record.biometricAccount != nil else { throw PasscodeError.biometricsUnavailable }
            return record
        }
        guard let key = try self.storage.read(record.biometricAccount!, context: context), key.count == 32 else { throw PasscodeError.biometricsUnavailable }
        let access = PasscodeSession(credentialId: record.id, revision: record.revision, key: key, scope: scope, authentication: .biometrics, lifetime: lifetime)
        do {
            try self.validate(access)
            return access
        } catch {
            access.invalidate()
            throw error
        }
    }
}

// MARK: - Yougram duress code

public enum PasscodeDuressError: Error, Equatable {
    /// The code is the passcode itself.
    case matchesPasscode
}

/// Yougram's duress code: a second code for the app lock screen, where entering it runs
/// `AppLockContext.duressCodeHandler` instead of unlocking. The lock screen checks it only after
/// the passcode was rejected, so the passcode always unlocks.
///
/// Stored as its own keychain item (`duress`) next to the credential: a salted PBKDF2 key,
/// derived like the passcode's with the device secret, that opens a fixed payload. It is bound to
/// the credential record and its kind, and setting a new passcode, disabling it or resetting the
/// credential removes it.
@available(macOS 10.15, *)
extension PasscodeCredentialStore {
    fileprivate static let duressAccount = "duress"
    private static let duressPayload = Data("yougram.duress.v1".utf8)

    private struct DuressRecord: Codable {
        var credentialId: String
        var kind: PasscodeKind
        var salt: Data
        var iterations: Int
        var verifier: Data
    }

    private static func duressContext(credentialId: String, kind: PasscodeKind) -> String {
        return "duress.v1:\(credentialId):\(kind.rawValue)"
    }

    /// The stored duress code, when it still belongs to the current passcode.
    private func currentDuressRecord(credential: Record) -> DuressRecord? {
        guard let kind = credential.kind,
              let data = try? self.storage.read(Self.duressAccount, context: nil),
              let duress = try? JSONDecoder().decode(DuressRecord.self, from: data),
              duress.credentialId == credential.id, duress.kind == kind else {
            return nil
        }
        return duress
    }

    /// Whether a duress code is set for the current passcode.
    public func hasDuressCode() -> Bool {
        return (try? self.serialized { () throws -> Bool in
            guard let record = try self.load() else { return false }
            return self.currentDuressRecord(credential: record) != nil
        }) ?? false
    }

    /// Sets the duress code, which must be of the passcode's kind and differ from it. Needs a
    /// session from entering the passcode in settings.
    public func setDuressCode(_ code: String, session: PasscodeSession) throws {
        try self.requirePasscodeManagement(session)
        try self.serialized {
            let record = try self.validatedRecord(session)
            guard let kind = record.kind, let salt = record.salt, let iterations = record.iterations, let wrapped = record.wrappedKey else {
                throw PasscodeError.authenticationRequired
            }
            let code = kind.normalize(code)
            guard !code.isEmpty,
                  kind == .alphanumeric || (code.allSatisfy { $0.isASCII && $0.isNumber } && code.count == (kind == .digits6 ? 6 : 4)) else {
                throw PasscodeError.invalidCode
            }
            let deviceSecret = try self.deviceSecret()
            // The passcode's own key opens the credential: then this code is the passcode.
            var passcodeKey = try PasscodeCrypto.derive(code: code, deviceSecret: deviceSecret, salt: salt, iterations: iterations)
            defer { passcodeKey.resetBytes(in: 0 ..< passcodeKey.count) }
            if (try? PasscodeCrypto.open(wrapped, key: passcodeKey, context: "credential.v1:\(record.id):\(kind.rawValue)")) != nil {
                throw PasscodeDuressError.matchesPasscode
            }
            let duressSalt = try PasscodeCrypto.random(16)
            let duressIterations = self.iterationCount()
            var key = try PasscodeCrypto.derive(code: code, deviceSecret: deviceSecret, salt: duressSalt, iterations: duressIterations)
            defer { key.resetBytes(in: 0 ..< key.count) }
            let verifier = try PasscodeCrypto.seal(Self.duressPayload, key: key, context: Self.duressContext(credentialId: record.id, kind: kind))
            let duress = DuressRecord(credentialId: record.id, kind: kind, salt: duressSalt, iterations: duressIterations, verifier: verifier)
            try self.storage.write(JSONEncoder().encode(duress), account: Self.duressAccount, biometric: false)
        }
    }

    public func removeDuressCode() throws {
        try self.serialized {
            try self.storage.remove(Self.duressAccount)
        }
    }

    /// Whether `code` is the duress code. Never counts as a failed passcode attempt.
    public func matchesDuressCode(_ code: String) -> Bool {
        return (try? self.serialized { () throws -> Bool in
            guard let record = try self.load(), let duress = self.currentDuressRecord(credential: record) else {
                return false
            }
            var key = try PasscodeCrypto.derive(code: duress.kind.normalize(code), deviceSecret: self.deviceSecret(), salt: duress.salt, iterations: duress.iterations)
            defer { key.resetBytes(in: 0 ..< key.count) }
            return (try? PasscodeCrypto.open(duress.verifier, key: key, context: Self.duressContext(credentialId: record.id, kind: duress.kind))) == Self.duressPayload
        }) ?? false
    }
}
