import Foundation

/// Yougram options that TelegramCore itself has to follow.
///
/// TelegramCore can't read Yougram's settings (`YougramSettings` lives in TelegramUIPreferences,
/// which depends on TelegramCore), so `YougramSettings` sets these whenever its value is loaded or
/// changes. Every option defaults to upstream Telegram's behaviour, which is also what the
/// extensions and tests see.
public enum YougramCoreOptions {
    private static let lock = NSLock()
    private static var _keepChatsAfterRemoval = false

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
}
