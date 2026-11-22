import Foundation

/// Yougram options that TelegramCore itself has to follow.
///
/// TelegramCore can't read Yougram's settings (`YougramSettings` lives in TelegramUIPreferences,
/// which depends on TelegramCore), so `YougramSettings` sets these whenever its value is loaded or
/// changes. Every option defaults to upstream Telegram's behaviour, which is also what the
/// extensions and tests see.
public enum YougramCoreOptions {
    public static let ghostModeDidChangeNotification = Notification.Name("YougramCoreOptionsGhostModeDidChange")
    public static let localEncryptionDidChangeNotification = Notification.Name("YougramCoreOptionsLocalEncryptionDidChange")

    private static let lock = NSLock()
    private static var _keepChatsAfterRemoval = false
    private static var _ghostMode = GhostMode()
    private static var _localEncryptionEnabled = false
    private static var _hideAds = false
    private static var _saveDeletedMessages = false
    private static var _saveEditHistory = false
    private static var _allowCopyProtectedContent = false
    private static var _hideBlockedUsersMessages = false

    /// When true, optional Local Encryption is active (suppresses UserDefaults mirroring, file logging, etc.).
    public static var localEncryptionEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _localEncryptionEnabled
        }
        set {
            lock.lock()
            let changed = _localEncryptionEnabled != newValue
            _localEncryptionEnabled = newValue
            lock.unlock()
            if changed {
                NotificationCenter.default.post(name: Self.localEncryptionDidChangeNotification, object: nil)
            }
        }
    }

    public static var hideAds: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _hideAds
        }
        set {
            lock.lock()
            _hideAds = newValue
            lock.unlock()
        }
    }

    public static var saveDeletedMessages: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _saveDeletedMessages
        }
        set {
            lock.lock()
            _saveDeletedMessages = newValue
            lock.unlock()
        }
    }

    public static var saveEditHistory: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _saveEditHistory
        }
        set {
            lock.lock()
            _saveEditHistory = newValue
            lock.unlock()
        }
    }

    public static var allowCopyProtectedContent: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _allowCopyProtectedContent
        }
        set {
            lock.lock()
            _allowCopyProtectedContent = newValue
            lock.unlock()
        }
    }

    public static var hideBlockedUsersMessages: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _hideBlockedUsersMessages
        }
        set {
            lock.lock()
            _hideBlockedUsersMessages = newValue
            lock.unlock()
        }
    }

    /// Keep a channel or group the user was banned or removed from in the chat list, with the
    /// messages already stored on this device, instead of hiding it. A chat the user left
    /// themselves is still hidden.
    public static var keepChatsAfterRemoval: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _keepChatsAfterRemoval
        }
        set {
            lock.lock()
            _keepChatsAfterRemoval = newValue
            lock.unlock()
        }
    }

    /// What Ghost Mode keeps from the server, each already combined with the master switch: a
    /// field is true only while Ghost Mode is on and that part of it is too.
    public struct GhostMode: Equatable {
        /// Reads move this device's read state and send nothing (`YougramGhostMode.swift`).
        public var hideReadReceipts: Bool = false
        /// Playing a voice message doesn't mark it listened on the server.
        public var hideVoiceListened: Bool = false
        /// Playing a video message doesn't mark it watched on the server.
        public var hideRoundWatched: Bool = false
        /// Viewing a story marks it seen on this device only.
        public var hideStoryViews: Bool = false
        /// No online status is sent while the app is open.
        public var hideOnline: Bool = false
        /// "typing…" (and typing in secret chats).
        public var hideTyping: Bool = false
        /// Uploading a photo, video, file or video message.
        public var hideUploading: Bool = false
        /// Choosing a sticker.
        public var hideChoosingSticker: Bool = false
        /// Recording voice and video messages, playing a game, emoji interactions and watching
        /// someone else's.
        public var hideOtherActivities: Bool = false
        /// Goes offline right after appearing online: after the app's own online status and after
        /// each sent message.
        public var autoOffline: Bool = false
        /// Sending a message or reacting in a chat sends the read receipts Ghost Mode held there.
        public var readOnInteract: Bool = false
        /// Messages go out as scheduled messages a few seconds ahead
        /// (`yougramGhostScheduleDelay`), which the server delivers without the sender appearing
        /// online.
        public var sendAsScheduled: Bool = false

        public var hidesAnyActivity: Bool {
            return self.hideTyping || self.hideUploading || self.hideChoosingSticker || self.hideOtherActivities
        }

        public init() {
        }
    }

    public static var ghostMode: GhostMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _ghostMode
        }
        set {
            lock.lock()
            let changed = _ghostMode != newValue
            _ghostMode = newValue
            lock.unlock()
            if changed {
                NotificationCenter.default.post(name: ghostModeDidChangeNotification, object: nil)
            }
        }
    }
}
