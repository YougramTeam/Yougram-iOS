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

## Ghost Mode (Privacy ▸ Ghost Mode)

- **Settings**: a master switch (`ghostModeEnabled`, off by default) and one field per part, most on by default (Go
  Offline Automatically, Send as Scheduled and Ask Before Opening Stories are off). `ghostCoreOptions` combines them into
  `YougramCoreOptions.ghostMode`, so TelegramCore sees a part as on only while the master switch is too. Extensions and
  tests see every part off.
- **TelegramCore** (`State/YougramGhostMode.swift` holds the helpers; each hook carries a `// Yougram:` comment):
  - Read receipts: `synchronizePeerReadState` holds the read instead of pushing it. **Held chats are listed in the
    preferences entry `YougramGhostHeldReads`, and that list is what stops validation from retrying in a tight
    loop**: `docs/state-sync.md` invariant 31 has the rule. Forum-topic and monoforum reads are skipped
    (`ReplyThreadHistory`, `ApplyMaxReadIndexInteractively`).
  - Voice and video messages: `_internal_markMessageContentAsConsumedInteractively` marks them played locally only.
    Self-destructing media still reports (`yougramGhostKeepsContentConsumptionLocal`).
  - Stories: `_internal_markStoryAsSeen` moves the local `maxReadId` and queues no `readStories`; no
    `incrementStoryViews`.
  - Online status: `AccountPresenceManagerImpl.updatePresence`. Hidden means nothing is sent at all (an offline status
    would show "last seen just now"); one online status already sent is ended once. Go Offline Automatically sends
    online once, then offline, per foreground, and offline after every sent message (`applySentMessage`,
    `applySentGroupMessages`).
  - Activity indicators: `requestActivity` (`yougramGhostHidesActivity`); speaking in a voice chat is never hidden.
  - Read on Interact: `enqueueMessages(account:)` and `updateMessageReactionsInteractively` push the chat's held read
    (`yougramPushHeldReadState`), or a forum topic's or monoforum thread's mark.
  - Send as Scheduled: `enqueueMessages(account:)` adds `OutgoingScheduleInfoMessageAttribute` 12 s ahead
    (`yougramGhostScheduledMessages`, which lists what it leaves alone).
- **Ask Before Opening Stories**: `StoryContainerScreen` holds every `markAsSeen` while its alert is up
  (`yougramGhostStoryWarningHolds`); "Turn On Ghost Mode" marks the waiting stories only after the setting has reached
  TelegramCore.
- **Limits**: reads stay on this device, so other devices and the sender's count still show them unread. A forum
  topic's or monoforum thread's read can come back from the server.

## Passcode: scrambled keypad and duress code

- **Scrambled keypad** (`scramblePasscodeKeypad`): the lock screen's `PasscodeEntryKeyboardNode.setScrambled` reorders
  its slots (layout, entry animation and VoiceOver order follow `slotOrder`), dealt again each time the app returns to
  the foreground and after a wrong code. The settings passcode prompt (`PasscodeSetupController` in `.entry` mode)
  passes one shuffled `digitOrder` to `WalletSendKeyboardComponent` for the screen's lifetime; nil there is the phone
  layout, so the wallet is unchanged.
- **Duress code**: stored by `PasscodeCredentialStore` (`Passcode.swift`, "Yougram duress code") as keychain item
  `duress` beside the credential, bound to the credential id and kind. Setting a passcode, disabling it or resetting the
  credential removes it. **The lock screen checks it only after `verify` rejected the code**
  (`PasscodeEntryController.verifyCode`), and only for the main app's own unlock (`.appUnlock`, no `authenticated` /
  `completed` caller), so the passcode always unlocks and settings, wallet and share-extension prompts never trigger it.
  A match calls `AppLockContext.duressCodeHandler`, which `AppDelegate` sets to `yougramPerformDuressWipe`
  (`TelegramUI/Sources/YougramDuressWipe.swift`): accounts backup (optional), every account record removed, or marked
  logged out with "Log Out on Telegram's Servers", then, once no account is active, `resetWalletLocalSecrets()` turns
  the passcode off and the lock screen dismisses itself onto the login screen.
- The duress screen (`YougramDuressCodeController.swift`) asks for the passcode, then takes the new code on
  `PasscodeSetupController` with `allowsPasscodeTypeChange = false`, since the lock screen only accepts codes of the
  passcode's kind.

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


## Local Encryption (`YougramVaultStore.swift`, `YougramLocalEncryption.swift`)

- When off, zero `.yougram-vault.json` is written and upstream behaviour (`.tempkey`, SQLite, media, logging, extensions)
  is untouched.
- Enabling generates a random 256-bit Master Vault Key (`VMK`) wrapped in `.yougram-vault.json` under either a Dedicated
  secret (PBKDF2-HMAC-SHA256 310k + hardware Secure Enclave / fallback pepper) or the user's App Passcode Lock session
  (`PasscodeCredentialStore.setVaultProtectionEnabled(true)`, clearing `unprotectedKey` and blocking "Turn Passcode Off"
  until Local Encryption is disabled or switched).
- Domain-separated HKDF-SHA256 subkeys of `VMK` encrypt every SQLCipher database (`postbox`, `accounts-metadata`,
  `guard_db`, `StorageBox`), seal `atomic-state` and `login-tokens` (`YGE1`), encrypt complete media (`YGCF` v1 chunked
  AES-256-GCM with sealed trailer) and sparse partial downloads (`YGPR` AES-256-CTR + `YGE1` `.meta`) under `enc_*`
  obfuscated filenames, and keep decrypted temp files strictly in an ephemeral session folder under `NSTemporaryDirectory()`
  purged synchronously on launch, lock, background, termination, and extension exit.
- Background Notifications & Extensions defaults to **Strict** (no unwrapped `VMK` in shared Keychain; extensions stay locked
  and pushes show `"You have a new message"`). Switching it on writes `VMK` to the shared app-group Keychain with
  `WhenUnlockedThisDeviceOnly` after explicit disclosure.


## Local History DB (`YougramMessageHistory.swift`, `YougramLocalHistoryController.swift`)

- Anti-Recall (`saveDeletedMessages`) and Edit History (`saveEditHistory`) snapshot pre-delete/pre-edit message payloads in
  `StateReplay+Messages.swift` into Postbox `Namespaces.CachedItemCollection.yougramMessageHistory` (keyed by peer id,
  capped at 500 deleted / 200 edited records per peer, 30 versions per message) plus `PreferencesKeys.yougramMessageHistoryIndex`.
- Service messages (`TelegramMediaAction` / `TelegramMediaExpiredContent`) and self-destructing/autoremove messages
  (`AutoremoveTimeoutMessageAttribute` / `AutoclearTimeoutMessageAttribute`) are excluded.
- Because both tables live inside `Postbox`, enabling Local Encryption automatically encrypts saved history at rest under SQLCipher.


## Blocked Users Local Filter (`YougramBlockedPeers.swift`)

- `PreferencesKeys.yougramBlockedPeerIds` (`YougramBlockedPeersStore`) caches the account's messaging-blocked `PeerId`s,
  kept in sync by `StateReplay+Peers.swift`, `BlockedPeers.swift`, `BlockedPeersContext.swift`, and paginated
  `contacts.getBlocked` refreshes (`TelegramEngine.Privacy.yougramBlockedPeerIds()` / `yougramRefreshBlockedPeers()`).
- `ChatHistoryEntriesForView.swift` hides messages only where `authorId != context.account.peerId && authorId != location.peerId`
  so direct 1-on-1 chats remain intact while blocked users' messages in shared groups, channels, and threads are filtered out.
