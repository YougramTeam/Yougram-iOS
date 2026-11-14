# Yougram settings (Settings ▸ Yougram)

Yougram's own options. The model is `YougramSettings` in
`submodules/TelegramUIPreferences/Sources/YougramSettings.swift`; this module is the screens.

## The model

- **One AccountManager shared-data entry** (`ApplicationSpecificSharedDataKeys.yougramSettings`, raw key 1000, far
  from upstream's range so a key Telegram adds can't collide). Extensions read it like any shared data:
  `sharedData.entries[...yougramSettings]?.get(YougramSettings.self)` (the Notification Service extension does).
- **Layout code reads `YougramSettings.current`**: synchronous, lock-protected, safe off the main thread. It is
  mirrored to `UserDefaults.standard` so it is right from the first frame after launch, before shared data loads.
  `SharedAccountContextImpl` keeps it in step with the entry (`yougramSettingsDisposable`). **In an extension
  `current` is not kept in sync**: read the entry.
- **Write with `updateYougramSettingsInteractively(accountManager:_:)`**, which updates the entry and `current`.
- **Observe with `YougramSettings.updates`** (current value, then every change) where a screen should react live.
- **Every field decodes with a default** (`decodeIfPresent`), so a blob from another build never fails to decode;
  failing would reset every setting. Adding a field: add it to the struct, `defaultSettings`, the memberwise init,
  `CodingKeys`, `init(from:)` and `encode(to:)`, then a row in `YougramSettingsController.swift`.
- **Changing `YougramSettings` (or anything in TelegramUIPreferences) changes an interface ~700 modules import**:
  expect the next Linux typecheck to rebuild most interfaces. Batch such changes.
- `YougramContextMenuAction` lists the message-menu actions a user can switch off; its raw values are stored, never
  rename a case.

## Screens

`YougramSettingsController.swift` builds every list screen from one entry type (`YougramSettingsEntries.swift`,
`YougramEntriesBuilder`): main screen (header, Categories, Links), General, Appearance, Chats, Privacy, Message Menu.
Toggles bind to a `WritableKeyPath<YougramSettings, Bool>`; `requiresRestart: true` shows a restart notice.

## Accounts backup (`YougramAccountsBackup.swift`)

- Each signed-in account's `AccountBackupData` (master DC id and auth key, notification key, other DC keys) is a
  keychain generic password: service `<bundle id>.yougram.accounts`, account = peer id, `WhenUnlocked`. It survives
  deleting the app. **These are full session credentials.**
- "Sync with iCloud Keychain" re-saves the items `kSecAttrSynchronizable` (queries use `kSecAttrSynchronizableAny`).
- **The keychain blob is Yougram's own `YougramAccountBackup`, never `TelegramAccountRecordAttribute`**: that
  attribute's decoder `preconditionFailure()`s on input it doesn't recognise.
- Restore creates an account record (`.backupData`, `.environment`, `.sortOrder`) for each backup whose peer isn't
  signed in; `SharedAccountContextImpl` brings it up through `accountWithId(... backupData:)`. A session revoked on the
  server comes back logged out. Read `submodules/MTProtoRustEngine/CLAUDE.md` before touching anything that decides
  logout.
