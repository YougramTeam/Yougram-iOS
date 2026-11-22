import Foundation
import SwiftSignalKit
import Postbox

public protocol AccountManagerTypes {
    associatedtype Attribute: AccountRecordAttribute
}

public typealias SharedPreferencesEntry = PreferencesEntry

private enum AccountManagerPasscodeMigrationTestError: LocalizedError {
    case unsupportedAccountManager
    case invalidAccessChallenge

    var errorDescription: String? {
        switch self {
        case .unsupportedAccountManager:
            return "Passcode migration tests require a writable, persistent account manager."
        case .invalidAccessChallenge:
            return "Passcode migration tests require a legacy passcode."
        }
    }
}

public struct AccountManagerAccessChallenge {
    public let prepare: (Bool) throws -> Void
    public let resolve: (PostboxAccessChallengeData?, Bool) throws -> PostboxAccessChallengeData?
    public let finishInitialization: () throws -> Void

    public init(
        prepare: @escaping (Bool) throws -> Void,
        resolve: @escaping (PostboxAccessChallengeData?, Bool) throws -> PostboxAccessChallengeData?,
        finishInitialization: @escaping () throws -> Void
    ) {
        self.prepare = prepare
        self.resolve = resolve
        self.finishInitialization = finishInitialization
    }
}

public struct AccountManagerModifier<Types: AccountManagerTypes> {
    public let getRecords: () -> [AccountRecord<Types.Attribute>]
    public let updateRecord: (AccountRecordId, (AccountRecord<Types.Attribute>?) -> (AccountRecord<Types.Attribute>?)) -> Void
    public let getCurrent: () -> (AccountRecordId, [Types.Attribute])?
    public let setCurrentId: (AccountRecordId) -> Void
    public let getCurrentAuth: () -> AuthAccountRecord<Types.Attribute>?
    public let createAuth: ([Types.Attribute]) -> AuthAccountRecord<Types.Attribute>?
    public let removeAuth: () -> Void
    public let createRecord: ([Types.Attribute]) -> AccountRecordId
    public let getSharedData: (ValueBoxKey) -> PreferencesEntry?
    public let updateSharedData: (ValueBoxKey, (PreferencesEntry?) -> PreferencesEntry?) -> Void
    public let getAccessChallengeData: () -> PostboxAccessChallengeData
    public let setAccessChallengeData: (PostboxAccessChallengeData) -> Void
    public let getVersion: () -> Int32?
    public let setVersion: (Int32) -> Void
    public let getNotice: (NoticeEntryKey) -> CodableEntry?
    public let setNotice: (NoticeEntryKey, CodableEntry?) -> Void
    public let clearNotices: () -> Void
    public let getStoredLoginTokens: () -> [Data]
    public let setStoredLoginTokens: ([Data]) -> Void
}

final class AccountManagerImpl<Types: AccountManagerTypes> {
    private let queue: Queue
    private let basePath: String
    private let atomicStatePath: String
    private let loginTokensPath: String
    private let temporarySessionId: Int64
    private let guardValueBox: ValueBox?
    private let valueBox: ValueBox
    private let canCleanPasscodeMetadata: Bool
    private let resolveAccessChallenge: (PostboxAccessChallengeData?, Bool) throws -> PostboxAccessChallengeData?
    
    private var tables: [Table] = []
    
    private var currentAtomicState: AccountManagerAtomicState<Types>
    private var currentAtomicStateUpdated = false
    
    private let legacyMetadataTable: AccountManagerMetadataTable<Types.Attribute>
    private let legacyRecordTable: AccountManagerRecordTable<Types.Attribute>
    
    let sharedDataTable: AccountManagerSharedDataTable
    let noticeTable: NoticeTable
    
    private var currentRecordOperations: [AccountManagerRecordOperation<Types.Attribute>] = []
    private var currentMetadataOperations: [AccountManagerMetadataOperation<Types.Attribute>] = []
    
    private var currentUpdatedSharedDataKeys = Set<ValueBoxKey>()
    private var currentUpdatedNoticeEntryKeys = Set<NoticeEntryKey>()
    private var currentUpdatedAccessChallengeData: PostboxAccessChallengeData?
    
    private var recordsViews = Bag<(MutableAccountRecordsView<Types>, ValuePipe<AccountRecordsView<Types>>)>()
    
    private var sharedDataViews = Bag<(MutableAccountSharedDataView<Types>, ValuePipe<AccountSharedDataView<Types>>)>()
    private var noticeEntryViews = Bag<(MutableNoticeEntryView<Types>, ValuePipe<NoticeEntryView<Types>>)>()
    private var accessChallengeDataViews = Bag<(MutableAccessChallengeDataView, ValuePipe<AccessChallengeDataView>)>()
    private let canBeginTransactionsValue = Atomic<Bool>(value: true)
    private var queuedTransactions = Atomic<[() -> Void]>(value: [])

    // Yougram: seal/open atomic-state JSON when local encryption is active.
    private static func readAtomicStateData(fromPath path: String, explicitKeys: YougramVaultKeyMaterial? = PostboxLocalEncryption.current) throws -> Data {
        let rawData = try Data(contentsOf: URL(fileURLWithPath: path))
        if let keys = explicitKeys {
            return try YougramEncryptedBlob.open(rawData, key: keys.atomicStateKey, aad: "ygas1")
        } else if YougramEncryptedBlob.isEncrypted(rawData) {
            throw YougramLocalEncryptionError.invalidKey
        }
        return rawData
    }
    
    static func getCurrentRecords(basePath: String) -> (records: [AccountRecord<Types.Attribute>], currentId: AccountRecordId?) {
        let atomicStatePath = "\(basePath)/atomic-state"
        do {
            let data = try Self.readAtomicStateData(fromPath: atomicStatePath)
            let atomicState = try JSONDecoder().decode(AccountManagerAtomicState<Types>.self, from: data)
            return (atomicState.records.sorted(by: { $0.key.int64 < $1.key.int64 }).map({ $1 }), atomicState.currentRecordId)
        } catch let e {
            postboxLog("decode atomic state error: \(e)")
            postboxLogSync()
            preconditionFailure()
        }
    }
    
    fileprivate init?(queue: Queue, basePath: String, isTemporary: Bool, isReadOnly: Bool, useCaches: Bool, removeDatabaseOnError: Bool, temporarySessionId: Int64, accessChallenge: AccountManagerAccessChallenge) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        self.queue = queue
        self.basePath = basePath
        self.atomicStatePath = "\(basePath)/atomic-state"
        self.loginTokensPath = "\(basePath)/login-tokens"
        self.temporarySessionId = temporarySessionId
        self.canCleanPasscodeMetadata = !isReadOnly && !isTemporary
        self.resolveAccessChallenge = accessChallenge.resolve
        let _ = try? FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true, attributes: nil)
        // Yougram: encrypt AccountManager guard_db and db with vault SQLCipher keys when local encryption is active.
        let activeEncryption = PostboxLocalEncryption.current
        let guardEncryptionParams = activeEncryption?.accountManagerGuardDatabaseParameters
        let mainEncryptionParams = activeEncryption?.accountManagerDatabaseParameters
        guard let guardValueBox = SqliteValueBox(basePath: basePath + "/guard_db", queue: queue, isTemporary: isTemporary, isReadOnly: false, useCaches: useCaches, removeDatabaseOnError: removeDatabaseOnError, encryptionParameters: guardEncryptionParams, upgradeProgress: { _ in }) else {
            postboxLog("Could not open guard value box at \(basePath + "/guard_db")")
            postboxLogSync()
            preconditionFailure()
            return nil
        }
        self.guardValueBox = guardValueBox
        
        var valueBox: SqliteValueBox?
        for i in 0 ..< 3 {
            if let valueBoxValue = SqliteValueBox(basePath: basePath + "/db", queue: queue, isTemporary: isTemporary, isReadOnly: isReadOnly, useCaches: useCaches, removeDatabaseOnError: removeDatabaseOnError, encryptionParameters: mainEncryptionParams, upgradeProgress: { _ in }) {
                valueBox = valueBoxValue
                break
            } else {
                postboxLog("Could not open value box at \(basePath + "/db") (try \(i))")
                postboxLogSync()
                
                Thread.sleep(forTimeInterval: 0.1 + 0.5 * Double(i))
            }
        }
        guard let valueBox = valueBox else {
            postboxLog("Giving up on opening value box at \(basePath + "/db")")
            postboxLogSync()
            preconditionFailure()
        }
        self.valueBox = valueBox
        
        self.legacyMetadataTable = AccountManagerMetadataTable<Types.Attribute>(valueBox: self.valueBox, table: AccountManagerMetadataTable<Types.Attribute>.tableSpec(0), useCaches: useCaches)
        self.legacyRecordTable = AccountManagerRecordTable<Types.Attribute>(valueBox: self.valueBox, table: AccountManagerRecordTable<Types.Attribute>.tableSpec(1), useCaches: useCaches)
        self.sharedDataTable = AccountManagerSharedDataTable(valueBox: self.valueBox, table: AccountManagerSharedDataTable.tableSpec(2), useCaches: useCaches)
        self.noticeTable = NoticeTable(valueBox: self.valueBox, table: NoticeTable.tableSpec(3), useCaches: useCaches)

        let isFreshInstallation = !FileManager.default.fileExists(atPath: self.atomicStatePath)
            && self.legacyRecordTable.getRecords().isEmpty
            && self.legacyMetadataTable.getAccessChallengeData() == .none
        do {
            try accessChallenge.prepare(isFreshInstallation)
        } catch {
            postboxLog("Access challenge installation initialization deferred")
        }
        
        do {
            let data = try Self.readAtomicStateData(fromPath: self.atomicStatePath, explicitKeys: activeEncryption)
            do {
                let atomicState = try JSONDecoder().decode(AccountManagerAtomicState<Types>.self, from: data)
                self.currentAtomicState = atomicState
            } catch let e {
                postboxLog("decode atomic state error: \(e)")
                postboxLogSync()
                
                if removeDatabaseOnError && !PostboxLocalEncryption.isActive {
                    let _ = try? FileManager.default.removeItem(atPath: self.atomicStatePath)
                }
                preconditionFailure()
            }
        } catch let e {
            postboxLog("load atomic state error: \(e)")
            postboxLogSync()
            
            if removeDatabaseOnError && (!PostboxLocalEncryption.isActive || !FileManager.default.fileExists(atPath: self.atomicStatePath)) {
                var legacyRecordDict: [AccountRecordId: AccountRecord<Types.Attribute>] = [:]
                for record in self.legacyRecordTable.getRecords() {
                    legacyRecordDict[record.id] = record
                }
                self.currentAtomicState = AccountManagerAtomicState(records: legacyRecordDict, currentRecordId: self.legacyMetadataTable.getCurrentAccountId(), currentAuthRecord: self.legacyMetadataTable.getCurrentAuthAccount(), accessChallengeData: self.legacyMetadataTable.getAccessChallengeData())
                self.syncAtomicStateToFile()
            } else {
                preconditionFailure()
            }
        }
        
        let tableAccessChallengeData = self.legacyMetadataTable.getAccessChallengeData()
        if self.currentAtomicState.accessChallengeData != .none {
            if tableAccessChallengeData == .none {
                self.legacyMetadataTable.setAccessChallengeData(self.currentAtomicState.accessChallengeData)
            }
        } else if tableAccessChallengeData != .none {
            self.currentAtomicState.accessChallengeData = tableAccessChallengeData
            self.syncAtomicStateToFile()
        }
        
        do {
            let allowMigration = !isReadOnly && !isTemporary
            let migrated = try self.resolveAccessChallenge(self.currentAtomicState.accessChallengeData, allowMigration)
            if allowMigration {
                if let migrated, migrated != self.currentAtomicState.accessChallengeData || migrated != self.legacyMetadataTable.getAccessChallengeData() {
                    self.valueBox.begin()
                    self.legacyMetadataTable.setAccessChallengeData(migrated)
                    self.valueBox.commit()
                    self.currentAtomicState.accessChallengeData = migrated
                    self.syncAtomicStateToFile()
                }
                self.cleanPasscodeMetadataIfNeeded()
                try accessChallenge.finishInitialization()
            }
        } catch {
            // An unavailable credential must not remove the existing lock.
            postboxLog("AccountManager: access challenge credential migration deferred")
        }

        postboxLog("AccountManager: currentAccountId = \(String(describing: currentAtomicState.currentRecordId))")
        
        self.tables.append(self.legacyMetadataTable)
        self.tables.append(self.legacyRecordTable)
        self.tables.append(self.sharedDataTable)
        self.tables.append(self.noticeTable)
        
        postboxLog("AccountManager initialization took \((CFAbsoluteTimeGetCurrent() - startTime) * 1000.0) ms")
    }
    
    deinit {
        assert(self.queue.isCurrent())
    }

    fileprivate func transactionSync<T>(ignoreDisabled: Bool, _ f: (AccountManagerModifier<Types>) -> T) -> T {
        self.valueBox.begin()

        let transaction = AccountManagerModifier<Types>(getRecords: {
            return self.currentAtomicState.records.map { $0.1 }
        }, updateRecord: { id, update in
            let current = self.currentAtomicState.records[id]
            let updated = update(current)
            if updated != current {
                if let updated = updated {
                    self.currentAtomicState.records[id] = updated
                } else {
                    self.currentAtomicState.records.removeValue(forKey: id)
                }
                self.currentAtomicStateUpdated = true
                self.currentRecordOperations.append(.set(id: id, record: updated))
            }
        }, getCurrent: {
            if let id = self.currentAtomicState.currentRecordId, let record = self.currentAtomicState.records[id] {
                return (record.id, record.attributes)
            } else {
                return nil
            }
        }, setCurrentId: { id in
            self.currentAtomicState.currentRecordId = id
            self.currentMetadataOperations.append(.updateCurrentAccountId(id))
            self.currentAtomicStateUpdated = true
        }, getCurrentAuth: {
            if let record = self.currentAtomicState.currentAuthRecord {
                return record
            } else {
                return nil
            }
        }, createAuth: { attributes in
            let record = AuthAccountRecord<Types.Attribute>(id: generateAccountRecordId(), attributes: attributes)
            self.currentAtomicState.currentAuthRecord = record
            self.currentAtomicStateUpdated = true
            self.currentMetadataOperations.append(.updateCurrentAuthAccountRecord(record))
            return record
        }, removeAuth: {
            self.currentAtomicState.currentAuthRecord = nil
            self.currentMetadataOperations.append(.updateCurrentAuthAccountRecord(nil))
            self.currentAtomicStateUpdated = true
        }, createRecord: { attributes in
            let id = generateAccountRecordId()
            let record = AccountRecord<Types.Attribute>(id: id, attributes: attributes, temporarySessionId: nil)
            self.currentAtomicState.records[id] = record
            self.currentRecordOperations.append(.set(id: id, record: record))
            self.currentAtomicStateUpdated = true
            return id
        }, getSharedData: { key in
            return self.sharedDataTable.get(key: key)
        }, updateSharedData: { key, f in
            let updated = f(self.sharedDataTable.get(key: key))
            self.sharedDataTable.set(key: key, value: updated, updatedKeys: &self.currentUpdatedSharedDataKeys)
        }, getAccessChallengeData: {
            let current = self.legacyMetadataTable.getAccessChallengeData()
            if let migrated = try? self.resolveAccessChallenge(current, true), migrated != current {
                self.legacyMetadataTable.setAccessChallengeData(migrated)
                self.currentAtomicState.accessChallengeData = migrated
                self.currentAtomicStateUpdated = true
                self.currentUpdatedAccessChallengeData = migrated
                return migrated
            }
            return current
        }, setAccessChallengeData: { proposed in
            guard let data = try? self.resolveAccessChallenge(nil, false) else {
                return
            }
            guard data == proposed else {
                return
            }
            self.currentUpdatedAccessChallengeData = data
            self.currentAtomicStateUpdated = true
            self.legacyMetadataTable.setAccessChallengeData(data)
            self.currentAtomicState.accessChallengeData = data
        }, getVersion: {
            return self.legacyMetadataTable.getVersion()
        }, setVersion: { version in
            self.legacyMetadataTable.setVersion(version)
        }, getNotice: { key in
            self.noticeTable.get(key: key)
        }, setNotice: { key, value in
            self.noticeTable.set(key: key, value: value)
            self.currentUpdatedNoticeEntryKeys.insert(key)
        }, clearNotices: {
            self.noticeTable.clear()
        }, getStoredLoginTokens: {
            return self.getLoginTokens()
        }, setStoredLoginTokens: { list in
            self.setLoginTokens(list: list)
        })

        let result = f(transaction)

        self.beforeCommit()

        self.valueBox.commit()

        return result
    }
    
    fileprivate func setCanBeginTransactions(_ value: Bool, afterTransactionIfRunning: @escaping () -> Void) {
        self.queue.async {
            let previous = self.canBeginTransactionsValue.swap(value)
            if previous != value && value {
                let fs = self.queuedTransactions.swap([])
                for f in fs {
                    f()
                }
            }
            afterTransactionIfRunning()
        }
    }

    fileprivate func transaction<T>(ignoreDisabled: Bool, _ f: @escaping (AccountManagerModifier<Types>) -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            self.queue.justDispatch {
                let run = {
                    let result = self.transactionSync(ignoreDisabled: ignoreDisabled, f)
                    
                    subscriber.putNext(result)
                    subscriber.putCompletion()
                }
                if ignoreDisabled || self.canBeginTransactionsValue.with({ $0 }) {
                    run()
                } else {
                    let _ = self.queuedTransactions.modify { fs in
                        var fs = fs
                        fs.append(run)
                        return fs
                    }
                }
            }
            return EmptyDisposable
        }
    }

    fileprivate func testPasscodeMigration(
        _ legacy: PostboxAccessChallengeData,
        prepare: (_ commitAndCrash: () throws -> Never) throws -> Never,
        crash: @escaping () throws -> Never
    ) throws -> Never {
        assert(self.queue.isCurrent())
        guard self.canCleanPasscodeMetadata else {
            throw AccountManagerPasscodeMigrationTestError.unsupportedAccountManager
        }
        switch legacy {
        case .numericalPassword, .plaintextPassword:
            break
        case .none, .secured:
            throw AccountManagerPasscodeMigrationTestError.invalidAccessChallenge
        }

        let atomicState = AccountManagerAtomicState<Types>(
            records: self.currentAtomicState.records,
            currentRecordId: self.currentAtomicState.currentRecordId,
            currentAuthRecord: self.currentAtomicState.currentAuthRecord,
            accessChallengeData: legacy
        )
        let atomicStateData = try JSONEncoder().encode(atomicState)

        self.valueBox.begin()
        var transactionOpen = true
        defer {
            if transactionOpen {
                self.valueBox.commit()
            }
        }

        return try prepare {
            precondition(transactionOpen)
            do {
                try FileManager.default.removeItem(atPath: self.basePath + "/passcode-v1-metadata-clean")
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            }

            try atomicStateData.write(to: URL(fileURLWithPath: self.atomicStatePath), options: .atomic)
            self.legacyMetadataTable.setAccessChallengeData(legacy)
            self.currentAtomicState = atomicState
            self.valueBox.commit()
            transactionOpen = false

            return try crash()
        }
    }
    
    private func cleanPasscodeMetadataIfNeeded() {
        guard self.canCleanPasscodeMetadata else { return }
        let marker = self.basePath + "/passcode-v1-metadata-clean"
        guard !FileManager.default.fileExists(atPath: marker) else {
            return
        }
        switch self.currentAtomicState.accessChallengeData {
        case .numericalPassword, .plaintextPassword:
            return
        case .none, .secured:
            break
        }
        guard let _ = try? self.resolveAccessChallenge(nil, false) else {
            return
        }

        (self.valueBox as? SqliteValueBox)?.vacuum()
        try? Data([1]).write(to: URL(fileURLWithPath: marker), options: .atomic)
    }

    private func syncAtomicStateToFile(explicitKeys: YougramVaultKeyMaterial? = PostboxLocalEncryption.current) {
        if let data = try? JSONEncoder().encode(self.currentAtomicState) {
            let outputData: Data
            if let keys = explicitKeys {
                guard let sealed = try? YougramEncryptedBlob.seal(data, key: keys.atomicStateKey, aad: "ygas1") else {
                    postboxLogSync()
                    preconditionFailure()
                }
                outputData = sealed
            } else {
                outputData = data
            }
            if let _ = try? outputData.write(to: URL(fileURLWithPath: self.atomicStatePath), options: [.atomic]) {
            } else {
                postboxLogSync()
                preconditionFailure()
            }
        } else {
            postboxLogSync()
            preconditionFailure()
        }
    }
    
    private func getLoginTokens(explicitKeys: YougramVaultKeyMaterial? = PostboxLocalEncryption.current) -> [Data] {
        guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: self.loginTokensPath)) else {
            return []
        }
        let plainData: Data
        if let keys = explicitKeys {
            guard let opened = try? YougramEncryptedBlob.open(rawData, key: keys.loginTokensKey, aad: "yglt1") else {
                return []
            }
            plainData = opened
        } else if YougramEncryptedBlob.isEncrypted(rawData) {
            return []
        } else {
            plainData = rawData
        }
        guard let list = try? JSONDecoder().decode([Data].self, from: plainData) else {
            return []
        }
        return list
    }
    
    private func setLoginTokens(list: [Data], explicitKeys: YougramVaultKeyMaterial? = PostboxLocalEncryption.current) {
        if let data = try? JSONEncoder().encode(list) {
            let outputData: Data
            if let keys = explicitKeys {
                guard let sealed = try? YougramEncryptedBlob.seal(data, key: keys.loginTokensKey, aad: "yglt1") else {
                    return
                }
                outputData = sealed
            } else {
                outputData = data
            }
            if let _ = try? outputData.write(to: URL(fileURLWithPath: self.loginTokensPath), options: [.atomic]) {
            }
        }
    }

    fileprivate func rekeyEncryption(encrypt: Bool, keys: YougramVaultKeyMaterial) throws {
        assert(self.queue.isCurrent())
        let guardParams = encrypt ? keys.accountManagerGuardDatabaseParameters : nil
        let mainParams = encrypt ? keys.accountManagerDatabaseParameters : nil
        try (self.guardValueBox as? SqliteValueBox)?.rekey(to: guardParams)
        try (self.valueBox as? SqliteValueBox)?.rekey(to: mainParams)

        let targetKeys: YougramVaultKeyMaterial? = encrypt ? keys : nil
        self.syncAtomicStateToFile(explicitKeys: targetKeys)
        if FileManager.default.fileExists(atPath: self.loginTokensPath) {
            let readKeys: YougramVaultKeyMaterial? = encrypt ? nil : keys
            let tokens = self.getLoginTokens(explicitKeys: readKeys)
            self.setLoginTokens(list: tokens, explicitKeys: targetKeys)
        }
    }

    fileprivate func checkpointAndClearCachesNow() {
        assert(self.queue.isCurrent())
        for table in self.tables {
            table.clearMemoryCache()
        }
        (self.guardValueBox as? SqliteValueBox)?.checkpointAndPurgeMemory()
        (self.valueBox as? SqliteValueBox)?.checkpointAndPurgeMemory()
    }

    private static func migrateSealedFileStandalone(path: String, encrypt: Bool, key: Data, aad: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        let rawData = try Data(contentsOf: URL(fileURLWithPath: path))
        if encrypt {
            if YougramEncryptedBlob.isEncrypted(rawData) {
                _ = try YougramEncryptedBlob.open(rawData, key: key, aad: aad)
            } else {
                let sealed = try YougramEncryptedBlob.seal(rawData, key: key, aad: aad)
                try sealed.write(to: URL(fileURLWithPath: path), options: [.atomic])
            }
        } else {
            if YougramEncryptedBlob.isEncrypted(rawData) {
                let plain = try YougramEncryptedBlob.open(rawData, key: key, aad: aad)
                try plain.write(to: URL(fileURLWithPath: path), options: [.atomic])
            }
        }
    }

    static func rekeyStandalone(basePath: String, encrypt: Bool, keys: YougramVaultKeyMaterial, progress: ((Float) -> Void)? = nil) throws {
        try SqliteValueBox.rekeyStandaloneDatabase(
            basePath: basePath + "/guard_db",
            from: encrypt ? nil : keys.accountManagerGuardDatabaseParameters,
            to: encrypt ? keys.accountManagerGuardDatabaseParameters : nil
        )
        try SqliteValueBox.rekeyStandaloneDatabase(
            basePath: basePath + "/db",
            from: encrypt ? nil : keys.accountManagerDatabaseParameters,
            to: encrypt ? keys.accountManagerDatabaseParameters : nil
        )
        try Self.migrateSealedFileStandalone(
            path: basePath + "/atomic-state",
            encrypt: encrypt,
            key: keys.atomicStateKey,
            aad: "ygas1"
        )
        try Self.migrateSealedFileStandalone(
            path: basePath + "/login-tokens",
            encrypt: encrypt,
            key: keys.loginTokensKey,
            aad: "yglt1"
        )
        try MediaBox.migrateMediaDirectoryStandalone(basePath: basePath + "/media", encrypt: encrypt, keys: keys) { p in
            progress?(p * 0.85)
        }
        try SqliteValueBox.rekeyStandaloneDatabase(
            basePath: basePath + "/media/storage/db",
            from: encrypt ? nil : keys.storageBoxDatabaseParameters,
            to: encrypt ? keys.storageBoxDatabaseParameters : nil
        )
        try SqliteValueBox.rekeyStandaloneDatabase(
            basePath: basePath + "/media/cache-storage/db",
            from: encrypt ? nil : keys.storageBoxDatabaseParameters,
            to: encrypt ? keys.storageBoxDatabaseParameters : nil
        )
        progress?(1.0)
    }
    
    private func beforeCommit() {
        if self.currentAtomicStateUpdated {
            self.syncAtomicStateToFile()
        }
        
        if !self.currentRecordOperations.isEmpty || !self.currentMetadataOperations.isEmpty {
            for (view, pipe) in self.recordsViews.copyItems() {
                if view.replay(operations: self.currentRecordOperations, metadataOperations: self.currentMetadataOperations) {
                    pipe.putNext(AccountRecordsView<Types>(view))
                }
            }
        }
        
        if !self.currentUpdatedSharedDataKeys.isEmpty {
            for (view, pipe) in self.sharedDataViews.copyItems() {
                if view.replay(accountManagerImpl: self, updatedKeys: self.currentUpdatedSharedDataKeys) {
                    pipe.putNext(AccountSharedDataView<Types>(view))
                }
            }
        }
        
        if !self.currentUpdatedNoticeEntryKeys.isEmpty {
            for (view, pipe) in self.noticeEntryViews.copyItems() {
                if view.replay(accountManagerImpl: self, updatedKeys: self.currentUpdatedNoticeEntryKeys) {
                    pipe.putNext(NoticeEntryView(view))
                }
            }
        }
        
        if let data = self.currentUpdatedAccessChallengeData {
            for (view, pipe) in self.accessChallengeDataViews.copyItems() {
                if view.replay(updatedData: data) {
                    pipe.putNext(AccessChallengeDataView(view))
                }
            }
        }
        
        self.currentRecordOperations.removeAll()
        self.currentMetadataOperations.removeAll()
        self.currentUpdatedSharedDataKeys.removeAll()
        self.currentUpdatedNoticeEntryKeys.removeAll()
        self.currentUpdatedAccessChallengeData = nil
        self.currentAtomicStateUpdated = false
        
        for table in self.tables {
            table.beforeCommit()
        }
    }
    
    fileprivate func accountRecords() -> Signal<AccountRecordsView<Types>, NoError> {
        return self.transaction(ignoreDisabled: false, { transaction -> Signal<AccountRecordsView<Types>, NoError> in
            return self.accountRecordsInternal(transaction: transaction)
        })
        |> switchToLatest
    }

    fileprivate func _internalAccountRecordsSync() -> AccountRecordsView<Types> {
        let mutableView = MutableAccountRecordsView<Types>(getRecords: {
            return self.currentAtomicState.records.map { $0.1 }
        }, currentId: self.currentAtomicState.currentRecordId, currentAuth: self.currentAtomicState.currentAuthRecord)
        return AccountRecordsView<Types>(mutableView)
    }
    
    fileprivate func sharedData(keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView<Types>, NoError> {
        return self.transaction(ignoreDisabled: false, { transaction -> Signal<AccountSharedDataView<Types>, NoError> in
            return self.sharedDataInternal(transaction: transaction, keys: keys)
        })
        |> switchToLatest
    }
    
    fileprivate func noticeEntry(key: NoticeEntryKey) -> Signal<NoticeEntryView<Types>, NoError> {
        return self.transaction(ignoreDisabled: false, { transaction -> Signal<NoticeEntryView<Types>, NoError> in
            return self.noticeEntryInternal(transaction: transaction, key: key)
        })
        |> switchToLatest
    }
    
    fileprivate func accessChallengeData() -> Signal<AccessChallengeDataView, NoError> {
        return self.transaction(ignoreDisabled: false, { transaction -> Signal<AccessChallengeDataView, NoError> in
            return self.accessChallengeDataInternal(transaction: transaction)
        })
        |> switchToLatest
    }
    
    private func accountRecordsInternal(transaction: AccountManagerModifier<Types>) -> Signal<AccountRecordsView<Types>, NoError> {
        assert(self.queue.isCurrent())
        let mutableView = MutableAccountRecordsView<Types>(getRecords: {
            return self.currentAtomicState.records.map { $0.1 }
        }, currentId: self.currentAtomicState.currentRecordId, currentAuth: self.currentAtomicState.currentAuthRecord)
        
        let queue = self.queue
        return Signal { [weak self] subscriber in
            guard let strongSelf = self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let pipe = ValuePipe<AccountRecordsView<Types>>()
            let index = strongSelf.recordsViews.add((mutableView, pipe))
            
            subscriber.putNext(AccountRecordsView<Types>(mutableView))
            let pipeDisposable = pipe.signal().start(next: { next in
                subscriber.putNext(next)
            })
            
            return ActionDisposable {
                pipeDisposable.dispose()
                queue.async {
                    if let strongSelf = self {
                        strongSelf.recordsViews.remove(index)
                    }
                }
            }
        }
    }
    
    private func sharedDataInternal(transaction: AccountManagerModifier<Types>, keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView<Types>, NoError> {
        let mutableView = MutableAccountSharedDataView<Types>(accountManagerImpl: self, keys: keys)

        let queue = self.queue
        return Signal { [weak self] subscriber in
            guard let strongSelf = self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let pipe = ValuePipe<AccountSharedDataView<Types>>()
            let index = strongSelf.sharedDataViews.add((mutableView, pipe))

            subscriber.putNext(AccountSharedDataView<Types>(mutableView))
            let pipeDisposable = pipe.signal().start(next: { next in
                subscriber.putNext(next)
            })

            return ActionDisposable {
                pipeDisposable.dispose()
                queue.async {
                    if let strongSelf = self {
                        strongSelf.sharedDataViews.remove(index)
                    }
                }
            }
        }
    }
    
    private func noticeEntryInternal(transaction: AccountManagerModifier<Types>, key: NoticeEntryKey) -> Signal<NoticeEntryView<Types>, NoError> {
        let mutableView = MutableNoticeEntryView<Types>(accountManagerImpl: self, key: key)
        
        let queue = self.queue
        return Signal { [weak self] subscriber in
            guard let strongSelf = self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let pipe = ValuePipe<NoticeEntryView<Types>>()
            let index = strongSelf.noticeEntryViews.add((mutableView, pipe))
            
            subscriber.putNext(NoticeEntryView(mutableView))
            let pipeDisposable = pipe.signal().start(next: { next in
                subscriber.putNext(next)
            })
            
            return ActionDisposable {
                pipeDisposable.dispose()
                queue.async {
                    if let strongSelf = self {
                        strongSelf.noticeEntryViews.remove(index)
                    }
                }
            }
        }
    }
    
    private func accessChallengeDataInternal(transaction: AccountManagerModifier<Types>) -> Signal<AccessChallengeDataView, NoError> {
        let mutableView = MutableAccessChallengeDataView(data: transaction.getAccessChallengeData())
        
        let queue = self.queue
        return Signal { [weak self] subscriber in
            guard let strongSelf = self else {
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let pipe = ValuePipe<AccessChallengeDataView>()
            let index = strongSelf.accessChallengeDataViews.add((mutableView, pipe))
            
            subscriber.putNext(AccessChallengeDataView(mutableView))
            let pipeDisposable = pipe.signal().start(next: { next in
                subscriber.putNext(next)
            })
            
            return ActionDisposable {
                pipeDisposable.dispose()
                queue.async {
                    if let strongSelf = self {
                        strongSelf.accessChallengeDataViews.remove(index)
                    }
                }
            }
        }
    }
    
    fileprivate func currentAccountRecord(allocateIfNotExists: Bool) -> Signal<(AccountRecordId, [Types.Attribute])?, NoError> {
        return self.transaction(ignoreDisabled: false, { transaction -> Signal<(AccountRecordId, [Types.Attribute])?, NoError> in
            let current = transaction.getCurrent()
            if let _ = current {
            } else if allocateIfNotExists {
                let id = generateAccountRecordId()
                transaction.setCurrentId(id)
                transaction.updateRecord(id, { _ in
                    return AccountRecord(id: id, attributes: [], temporarySessionId: nil)
                })
            } else {
                return .single(nil)
            }
            
            let signal = self.accountRecordsInternal(transaction: transaction)
            |> map { view -> (AccountRecordId, [Types.Attribute])? in
                if let currentRecord = view.currentRecord {
                    return (currentRecord.id, currentRecord.attributes)
                } else {
                    return nil
                }
            }
            
            return signal
        })
        |> switchToLatest
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            if let lhs = lhs, let rhs = rhs {
                if lhs.0 != rhs.0 {
                    return false
                }
                if lhs.1.count != rhs.1.count {
                    return false
                }
                for i in 0 ..< lhs.1.count {
                    if !lhs.1[i].isEqual(to: rhs.1[i]) {
                        return false
                    }
                }
                return true
            } else if (lhs != nil) != (rhs != nil) {
                return false
            } else {
                return true
            }
        })
    }
    
    func allocatedTemporaryAccountId() -> Signal<AccountRecordId, NoError> {
        let temporarySessionId = self.temporarySessionId
        return self.transaction(ignoreDisabled: false, { transaction -> Signal<AccountRecordId, NoError> in
            
            let id = generateAccountRecordId()
            transaction.updateRecord(id, { _ in
                return AccountRecord(id: id, attributes: [], temporarySessionId: temporarySessionId)
            })
            
            return .single(id)
        })
        |> switchToLatest
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            return lhs == rhs
        })
    }
}

private let sharedQueue = Queue()

public final class AccountManager<Types: AccountManagerTypes> {
    public let basePath: String
    public let mediaBox: MediaBox
    private let queue: Queue
    private let impl: QueueLocalObject<AccountManagerImpl<Types>>
    public let temporarySessionId: Int64
    
    public static func getCurrentRecords(basePath: String) -> (records: [AccountRecord<Types.Attribute>], currentId: AccountRecordId?) {
        return AccountManagerImpl<Types>.getCurrentRecords(basePath: basePath)
    }
    
    public init(basePath: String, isTemporary: Bool, isReadOnly: Bool, useCaches: Bool, removeDatabaseOnError: Bool, accessChallenge: AccountManagerAccessChallenge) {
        self.queue = sharedQueue
        self.basePath = basePath
        var temporarySessionId: Int64 = 0
        arc4random_buf(&temporarySessionId, 8)
        self.temporarySessionId = temporarySessionId
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            if let value = AccountManagerImpl<Types>(queue: queue, basePath: basePath, isTemporary: isTemporary, isReadOnly: isReadOnly, useCaches: useCaches, removeDatabaseOnError: removeDatabaseOnError, temporarySessionId: temporarySessionId, accessChallenge: accessChallenge) {
                return value
            } else {
                postboxLogSync()
                preconditionFailure()
            }
        })
        self.mediaBox = MediaBox(basePath: basePath + "/media", isMainProcess: removeDatabaseOnError)
    }
    
    public func transaction<T>(ignoreDisabled: Bool = false, _ f: @escaping (AccountManagerModifier<Types>) -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.transaction(ignoreDisabled: ignoreDisabled, f).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }

    public func _internalTestPasscodeMigration(
        _ legacy: PostboxAccessChallengeData,
        prepare: @escaping (_ commitAndCrash: () throws -> Never) throws -> Never,
        crash: @escaping () throws -> Never
    ) -> Signal<Never, Error> {
        return Signal { subscriber in
            self.impl.with { impl in
                do {
                    try impl.testPasscodeMigration(legacy, prepare: prepare, crash: crash)
                } catch {
                    subscriber.putError(error)
                }
            }
            return EmptyDisposable
        }
    }
    
    public func accountRecords() -> Signal<AccountRecordsView<Types>, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.accountRecords().start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }

    public func _internalAccountRecordsSync() -> AccountRecordsView<Types> {
        var result: AccountRecordsView<Types>?
        self.impl.syncWith { impl in
            result = impl._internalAccountRecordsSync()
        }
        return result!
    }
    
    public func sharedData(keys: Set<ValueBoxKey>) -> Signal<AccountSharedDataView<Types>, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.sharedData(keys: keys).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func noticeEntry(key: NoticeEntryKey) -> Signal<NoticeEntryView<Types>, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.noticeEntry(key: key).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func accessChallengeData() -> Signal<AccessChallengeDataView, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.accessChallengeData().start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func currentAccountRecord(allocateIfNotExists: Bool) -> Signal<(AccountRecordId, [Types.Attribute])?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.currentAccountRecord(allocateIfNotExists: allocateIfNotExists).start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }
    
    public func allocatedTemporaryAccountId() -> Signal<AccountRecordId, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.allocatedTemporaryAccountId().start(next: { next in
                    subscriber.putNext(next)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            return disposable
        }
    }

    // Yougram: pause/resume AccountManager transactions and rekey AccountManager databases, files, and mediaBox.
    public func setCanBeginTransactions(_ value: Bool, afterTransactionIfRunning: @escaping () -> Void = {}) {
        self.impl.with { impl in
            impl.setCanBeginTransactions(value, afterTransactionIfRunning: afterTransactionIfRunning)
        }
    }

    public func rekeyEncryption(encrypt: Bool, keys: YougramVaultKeyMaterial, progress: ((Float) -> Void)? = nil) throws {
        var rekeyError: Error?
        self.impl.syncWith { impl in
            do {
                try impl.rekeyEncryption(encrypt: encrypt, keys: keys)
            } catch {
                rekeyError = error
            }
        }
        if let rekeyError {
            throw rekeyError
        }
        progress?(0.2)
        try self.mediaBox.migrateMediaFiles(encrypt: encrypt, keys: keys) { p in
            progress?(0.2 + p * 0.8)
        }
    }

    public func checkpointAndClearCaches(completion: @escaping () -> Void = {}) {
        let mediaBox = self.mediaBox
        self.impl.with { impl in
            impl.checkpointAndClearCachesNow()
            mediaBox.storageBox.checkpointAndClearCaches {
                mediaBox.cacheStorageBox.checkpointAndClearCaches {
                    completion()
                }
            }
        }
    }

    public static func rekeyStandalone(basePath: String, encrypt: Bool, keys: YougramVaultKeyMaterial, progress: ((Float) -> Void)? = nil) throws {
        try AccountManagerImpl<Types>.rekeyStandalone(basePath: basePath, encrypt: encrypt, keys: keys, progress: progress)
    }
}
