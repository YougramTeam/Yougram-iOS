# build-system/LinuxTypecheck — Swift typecheck without a Mac

The app only builds on macOS (rules_apple needs actool, ibtool, the Metal compiler and codesign). This tool typechecks
its Swift modules on Linux — in practice WSL on a Windows checkout — with the Linux Swift toolchain and the real iOS
SDK that `xtool sdk build <Xcode.xip>` extracts (`~/.swiftpm/swift-sdks/darwin.artifactbundle`). It catches what a Mac
build rejects in Swift: type errors, missing imports or BUILD deps, and warnings under `-warnings-as-errors`. It does not
compile ObjC/C/C++, link, or build resources: green here is not a green Bazel build.

```sh
# from Windows
wsl -d Ubuntu -- python3 /mnt/c/<checkout>/build-system/LinuxTypecheck/typecheck.py --changed
wsl -d Ubuntu -- python3 /mnt/c/<checkout>/build-system/LinuxTypecheck/typecheck.py SettingsUI PeerInfoScreen
```

`--changed` checks the modules holding files changed against HEAD (plus `$YOUGRAM_TYPECHECK_BASE...HEAD`),
`--dependents` also their direct dependents, `--emit-only` only builds interfaces (warms the cache), `--no-werror`
drops `-warnings-as-errors`. The cache is `~/.cache/yougram-typecheck` (`$YOUGRAM_TYPECHECK_CACHE`); one run at a time
per cache (an flock; a second run waits).

## How it works

- **`bazel_graph.py` reads the BUILD files without Bazel.** BUILD files are executed as Python with stub rules; in-repo
  `.bzl` files are executed too (their variables and helpers are real), external ones only export rule recorders;
  `glob()` honours package boundaries; `select()` takes `//conditions:default`. Under WSL it runs with the **Windows
  Python** (`python.exe` via interop): walking the checkout over `/mnt/c` (9P) takes minutes from Linux and a second
  from Windows. It also hashes every source with an mtime/size stat cache (`%LOCALAPPDATA%\yougram-typecheck`) and
  lists changed files with git.
- **Dependencies become `.swiftmodule`s with function bodies skipped**
  (`-experimental-skip-non-inlinable-function-bodies-without-types`), in dependency order, in parallel. ObjC/C
  dependencies get the module maps rules_swift would generate (every `hdrs` entry; `includes` and `defines` of the
  transitive closure). Each module sees exactly its transitive Swift dependencies (a symlink farm per module), like
  rules_swift's search paths.
- **Checked modules are typechecked in full** with their BUILD copts.
- **Everything is content-addressed.** An interface is rebuilt only when its sources, flags or a dependency's
  *interface bytes* change, so a body edit in TelegramCore rebuilds nothing downstream. A passing typecheck is
  remembered too.

## Generated sources

`GENERATED_PACKAGES` (bazel_graph.py) and `generators.py` mirror the genrules whose outputs Swift compiles; each tool is
built once under the cache, never inside the checkout. **When one of these genrules changes, change its generator.**

| Package | Genrule | Here |
|---|---|---|
| `Telegram` | `GeneratedPresentationStrings` | runs `GenerateStrings.py` |
| `submodules/TelegramApi` | `TelegramApiGenerated` (SwiftTL) | builds SwiftTL with Linux Swift |
| `submodules/TelegramCore/FlatSerialization` | `GenerateModels` (flatc) | builds flatc from the pinned zip (checksum from MODULE.bazel) |
| `third-party/wallet-engine` | `wallet_engine_swift_bindings` (uniffi) | cargo: cdylib, bindgen, postprocess |
| `Telegram` | `GeneratedSources` (`swift_intent_library`) | declarations from the `.intentdefinition` plist (classes, `@NSManaged` properties, enums; no responses or handling protocols) |

Prebuilt `apple_*_xcframework_import`s become `-F` on their iOS device slice, copied into the cache with LF line ends
(a CRLF `.swiftinterface` fails with "error extracting version from module interface").

Other genrule outputs (prebuilt libraries' `Public/` headers) resolve to the same-named header in the source tree or are
left out; no Swift module imports them directly.

Non-obvious, each found the hard way:
- **SwiftTL needs `import zlib`**, a module only Apple SDKs define; the generator writes a module map over the system
  `zlib.h` (`zlib1g-dev`).
- **A Windows checkout has CRLF line ends** (`core.autocrlf`). SwiftTL keeps the `\r` in names and crashes on a failed
  type lookup, so the schema is converted to LF first.
- **SwiftPM scans a package on `/mnt/c` for minutes** before building; SwiftTL and wallet-engine are rsynced to the
  cache and built there.
- **Tools run with stdin closed**; some wait on an inherited console otherwise.

Prerequisites in the distro: `xtool` SDK, Swift (same major as Xcode's), `cmake`, `rsync`, `zlib1g-dev`, Rust (rustup,
the version `third-party/wallet-engine/wallet-engine/rust-toolchain.toml` pins).
