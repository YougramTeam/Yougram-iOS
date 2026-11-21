# YOUGRAM.md

Yougram is a Telegram client built on this Telegram-iOS checkout. `CLAUDE.md` (Telegram's guide) still holds for
everything: building, tests, the refactor rules. This file is what Yougram adds on top: what has been built, where it
lives, and how to add more. It is imported at the end of `CLAUDE.md`, so it loads with it.

## Where Yougram's work is

- Repo: `github.com/YougramTeam/Yougram-iOS` (private), branch `master`. Upstream Telegram-iOS is merged in at
  `24638bc69b`; `git log --oneline 24638bc69b..HEAD` lists every Yougram commit (from the rebrand, `50b149393f`).
- Conventions: new files are named `Yougram…`; a hook in upstream code carries a `// Yougram:` comment; with a
  Yougram option off, upstream behaviour is unchanged (often byte-for-byte, and tests see the default).
- No Mac is available to agents. Verify with the Linux typecheck (below), then a CI build. Nothing here has been run on
  a device by an agent; the user installs the TestFlight builds.

## Identity, icons and CI

- **Name and icons** (commit `50b149393f`): `InfoPlist.strings` in every `.lproj`; the Liquid Glass icon
  `Telegram/Telegram-iOS/Telegram.icon` (white chat bubble with a cut-out Y on a purple gradient); alternate icons are
  `alternate_icon_folders` in `Telegram/BUILD` (`Telegram-iOS/<name>.alticon/`) and
  `getAvailableAlternateIcons` in `AppDelegate.swift`: Purple (default), Aqua, Sunset, Holo, Pixel, PremiumTurbo,
  PremiumBlack. Turbo and Black don't need Premium (`ThemeSettingsAppIconItem.swift`).
- **Bundle id `app.yougram.tg`** and signing: `CLAUDE.md`, "Yougram's identity and its CI build".
- **GitHub Actions** (all manual, `gh workflow run … -R YougramTeam/Yougram-iOS`):
  - `build-ipa.yml`: inputs `configuration` (release_arm64/debug_arm64), `use_cache`, `runner` (xcode-27, the only
    standard image with Xcode 27), `build_minutes`, `signing` (testflight/placeholder). The Bazel disk cache is saved
    in four shards, and a build stopped by `build_minutes` still saves it, so the next run resumes. TestFlight mode
    creates a certificate and profiles with `build-system/yougram-signing/asc.py`, uploads with altool, waits for
    Apple's processing on Linux, and revokes everything at the end of the run whatever happened.
  - `appstore-setup.yml`: one-time App ID registration. `testflight-status.yml`: re-check a build's processing.
  - Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `YOUGRAM_API_ID`, `YOUGRAM_API_HASH`.
  - Lessons kept in the code: the `.p12` needs a password and SHA1/3DES or macOS imports nothing
    (`asc.py _make_p12`); `timeout-minutes` needs `fromJSON()` on a dispatch input. The org is on the Free plan
    (about 190 macOS minutes a month), so prefer cached runs and don't rerun builds casually.
- **Linux typecheck** (`build-system/LinuxTypecheck/`, `CLAUDE.md` "Without a Mac"):
  `wsl -d Ubuntu -- python3 /mnt/c/Users/owo/Documents/tgram/Telegram-iOS/build-system/LinuxTypecheck/typecheck.py
  <Module> …` or `--changed`. Any change to `TelegramUIPreferences` (so to `YougramSettings`) or to TelegramCore's
  interface rebuilds ~700 module interfaces: 20+ minutes, so batch such changes.

## Adding a feature

- **Settings** are `YougramSettings` (`submodules/TelegramUIPreferences/Sources/YougramSettings.swift`) and the screens
  are `submodules/YougramSettingsUI` (Settings ▸ Yougram: header, Categories, Links). Read
  `submodules/YougramSettingsUI/CLAUDE.md`: one shared-data entry, `YougramSettings.current` for layout code, every
  field decoded with a default, the steps for a new field, and a row in `YougramSettingsController.swift`.
- **Strings**: append `"Yougram.<Area>.<Name>"` keys at the end of `Telegram/Telegram-iOS/en.lproj/Localizable.strings`
  (only English is real); code reads `strings.Yougram_<Area>_<Name>`.
- **TelegramCore can't read `YougramSettings`**: what it must follow goes in `YougramCoreOptions`
  (`submodules/TelegramCore/Sources/Utils/YougramCoreOptions.swift`), set by `YougramSettings.applyCoreOptions`
  whenever the settings load or change. Its defaults are upstream's, which is what the extensions and tests see.
- **Message-menu actions** a user can switch off: `YougramContextMenuAction` (raw values are stored, never rename a
  case), checked with `.isHidden` in `ChatInterfaceStateContextMenus.swift`.

## What's built (Settings ▸ Yougram)

**General**
- Accounts Backup to the keychain (optionally iCloud Keychain) and restore, plus "Back Up New Logins Automatically":
  `YougramAccountsBackup.swift`, `YougramAccountsBackupController.swift` (details in the YougramSettingsUI guide).
- Unlimited accounts: from 10 accounts the Settings list becomes a scrollable box with search by name, username, phone
  or id (`PeerInfo/PeerInfoScreen/Sources/ListItems/PeerInfoScreenAccountsBoxItem.swift`).
- Free voice transcription with Apple's speech recognition (`localVoiceTranscription`;
  `ChatMessageInteractiveFileNode`, `ChatMessageInteractiveInstantVideoNode`).
- Hide sponsored content (`hideAds`): channel and bot ads, video ads, search results and promoted chats, plus
  suppressing `messages.getSponsoredMessages` network/cache loads in `TelegramCore` (`AdMessages.swift`).

**Privacy**
- **Ghost Mode** (`ghostModeEnabled` and one switch per part): no read receipts, voice and video messages not marked
  played, story views not counted, no online status, no typing, upload, sticker or other activity indicators; plus Go
  Offline Automatically, Read on Interact (a sent message or reaction sends the reads held in that chat, and turning
  Ghost Mode off flushes stale held reads on interaction), Send as Scheduled (12 s ahead) and Ask Before Opening
  Stories (moved to Privacy). Sub-switches lock visually OFF while `ghostModeEnabled` is off, and disabling all
  sub-features turns Ghost Mode off; `AccountPresenceManagerImpl` reacts immediately to Ghost Mode changes and
  `TypingDraftStop`, `ManagedLocalInputActivities`, `AccountViewTracker`, `MarkAllChatsAsRead`,
  `ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations`, and `ManagedSynchronizeViewStoriesOperations` suppress
  activity/read leaks. TelegramCore follows `YougramCoreOptions.ghostMode`; the hooks, the held-reads list and its
  limits are in `submodules/YougramSettingsUI/CLAUDE.md`, "Ghost Mode", and `docs/state-sync.md` invariant 31.
- **Local History** (Settings ▸ Yougram ▸ Privacy ▸ Local History; `YougramMessageHistory.swift`,
  `YougramLocalHistoryController.swift`):
  - **Anti-Recall** (`saveDeletedMessages`, off by default): snapshots deleted Cloud messages (excluding service actions
    and self-destructing/view-once messages) before `StateReplay+Messages` deletes them; accessible via **View Deleted**
    in the chat navigation avatar menu and `PeerInfoScreen` more menu.
  - **Edit History** (`saveEditHistory`, off by default): stores previous text versions before
    `StateReplay+Messages.applyEditMessage` overwrites a message; accessible via **Edit History** in the message
    context menu.
  - Stored locally inside Postbox (`yougramMessageHistory` item cache + `yougramMessageHistoryIndex` preferences), so it
    is automatically encrypted when Local Encryption is active.
- **Allow Copy & Download** (`allowCopyProtectedContent`, off by default): removes client-side restrictions on copying,
  text selection, saving media/files, translating, speaking, and screenshots across copy-protected chats, channels, and
  stories (`MessageUtils.swift`, `PeerUtils.swift`, `PeersData.swift`, gallery, media auto-save, and
  `StoryContainerScreen`). Server-side forwarding (`Forward`) stays disabled on server copy-protected items where the
  server rejects `forwardMessages`.
- **Hide Blocked Users' Messages** (`hideBlockedUsersMessages`, off by default; `YougramBlockedPeers.swift`): maintains
  a per-account local index (`yougramBlockedPeerIds`) synchronized from `contacts.getBlocked` and block/unblock state
  changes, and locally hides messages authored by blocked users in shared groups, channels, and discussion threads
  (`ChatHistoryEntriesForView.swift`).
- Hide phone number in Settings and in your own profile (`hidePhoneInSettings`; PeerInfo header and items).
- Hide account name in notifications (`hideAccountNameInNotifications`): `Telegram/NotificationService` reads the
  shared-data entry itself.
- Scrambled passcode keypad, and the duress code (a second passcode that signs out of every account on the device):
  how both work and their invariants are in `submodules/YougramSettingsUI/CLAUDE.md`, "Passcode".
- **Local Encryption** (Settings ▸ Yougram ▸ Privacy ▸ Local Encryption): optional full at-rest encryption across
  every SQLCipher DB (`postbox`, `accounts-metadata`, `guard_db`, `StorageBox`), `atomic-state`/`login-tokens` (`YGE1`),
  and `MediaBox` files (`YGCF` chunked GCM + `YGPR` CTR sparse partials + HMAC-obfuscated `enc_*` filenames), deleting
  `.tempkey`, persistent logs, Spotlight indexes, and UserDefaults mirrors; supports Dedicated Password/PIN or App
  Passcode Lock binding and Strict vs Extensions-Allowed Keychain modes (`YougramLocalEncryption.swift`,
  `YougramCoreEncryption.swift`, `YougramVaultStore.swift`, `YougramVaultUnlockController.swift`,
  `YougramLocalEncryptionCoordinator.swift`, `YougramLocalEncryptionController.swift`). Details in
  `submodules/YougramSettingsUI/CLAUDE.md`.

**Chats**
- Quick Formatting panel above the keyboard (`YougramQuickFormattingPanel.swift`, `ChatTextInputPanelNode`).
- Hide recording hints, hide reactions, standard emoji first (`EmojiPagerContentSignals`), message-menu toggles,
  disable pull to next topic, discussion group button (`ChatChannelSubscriberInputPanelNode`).
- Send photos in HD and pasted images in HD (`MediaPickerScreen`, `MediaPickerChatMediaSend`, `ChatCameraFlow`).
- Video: AirPlay in the video menu (`GalleryUI/Sources/Items/YougramAirPlay.swift`), disable swipe to picture in
  picture, smaller video controls (`UniversalVideoGalleryItem`).
- **Save to Gallery / Save to Files** on every photo, video and file: the message menu, the photo and video gallery
  menus and profile shared media. Shared logic is in `SaveToCameraRoll/Sources/SaveMediaInteractively.swift`
  (`messageSaveableMedia`, `fetchMediaDataInteractively`) and `LegacyMediaPickerUI/Sources/ExportMediaToFiles.swift`;
  the profile items are `PeerInfoScreenSaveMedia.swift`.
  - Invariants: saving stays hidden where upstream hides it (copy-protected chats or messages unless **Allow Copy &
    Download** is enabled, secret media, paid media).
  - A streamed video's original file is saved only once it is downloaded; the gallery's quality list offers the
    original to Premium users only, as upstream does (`allowsStreamedVideoOriginal`).
  - Files go through the system export picker: the app's Documents folder holds internal data, so it can't be exposed
    as a Downloads folder.
- **Keep chats after a ban** (`keepChatsAfterBan`, on by default; `YougramCoreOptions.keepChatsAfterRemoval`): a
  channel or supergroup you're banned from, or a basic group you're removed from, stays in the chat list with the
  messages already on the device.
  - TelegramCore: the exclusion predicates and `updatePeersCustom` in `UpdatePeers.swift`, and keeping the stored
    photo and names when a forbidden stub arrives (`ApiGroupOrChannel.swift`). Reads move the kept chat's read state
    locally and send nothing (`ApplyMaxReadIndexInteractively.swift`, `docs/state-sync.md` invariant 30).
  - UI: no dismiss and no "this channel is private" screen (`ChatControllerContentData.swift`), and a banner
    (`ChatKeptAfterRemovalTitlePanelNode.swift`). "Delete and Exit" still removes the chat.
  - Limits: chats left voluntarily are still hidden; after a `differenceTooLong` reset a kept chat the server no
    longer lists can disappear.

**Appearance**
- Compact chat list (`ChatListItem`); hide "All Chats", folders at the bottom, remember last folder, compact folder
  tabs (`ChatListController`, `ChatListUI/Sources/YougramChatList.swift`, `ChatListFilterTabContainerNode`).
- Contacts tab and tab labels (`ApplicationContext`, `TabBarController`, `TabBarComponent`), search in the tab bar
  (`keepBottomSearch`).
- Hide stories, disable swipe to the story camera, hide "Repost to Story".
- Reduce Liquid Glass (`reduceGlass`: `GlassBackgroundView.useCustomGlassImpl` in `SharedAccountContext`).

**Sideloading & Unsigned IPA**
- **Resilient App Group, Keychain, and Code-Signature Parsing** (`BuildConfig.m`, `BuildConfigExtra.m`, `AppDelegate.swift`,
  `Passcode.swift`, `YougramVaultStore.swift`, `WalletSecurity.swift`, `WalletStorage.swift`, and app extensions):
  probes the embedded provisioning profile's `application-groups` entitlement and falls back cleanly to a sandbox
  `Application Support/YougramGroup` directory and ungrouped keychain queries instead of failing with `"Error 2"` or
  crashing with `errSecMissingEntitlement` / out-of-bounds Mach-O signature reads when re-signed by third-party signers
  that rename the bundle identifier or strip/omit App Group entitlements.
- **Unsigned IPA workflow** (`.github/workflows/build-ipa.yml`): defaults `signing` to `unsigned`, strips
  `_CodeSignature`, `embedded.mobileprovision`, `CodeResources`, `SC_Info`, and Mach-O signatures (`codesign --remove-signature`)
  and uploads `Yougram-<version>-<build>-<config>-unsigned.ipa` as a GitHub Actions artifact with no TestFlight upload.
