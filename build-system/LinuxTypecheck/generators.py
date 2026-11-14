"""Linux stand-ins for the genrules whose outputs Swift modules compile.

Each generator writes into <cache>/generated/<package>/..., the same relative paths the
genrule declares, and skips the work when its inputs are unchanged (a stamp of their
hashes). Host tools (flatc, SwiftTL, the wallet bindgen) are built once under
<cache>/tools, never inside the checkout.

Every generator mirrors its genrule's command line; when a genrule changes, change
the generator here too.
"""
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile


def _hash_files(paths):
    h = hashlib.sha256()
    for p in sorted(paths):
        h.update(p.encode())
        with open(p, "rb") as f:
            h.update(hashlib.sha256(f.read()).digest())
    return h.hexdigest()[:24]


def _run(cmd, cwd=None, env=None, what=None):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if p.returncode != 0:
        raise GeneratorError("%s failed:\n$ %s\n%s%s" % (what or cmd[0], " ".join(cmd), p.stdout[-4000:], p.stderr[-4000:]))
    return p.stdout


class GeneratorError(Exception):
    pass


class Generators:
    def __init__(self, repo, cache, log):
        self.repo = repo
        self.cache = cache
        self.gen = os.path.join(cache, "generated")
        self.tools = os.path.join(cache, "tools")
        self.log = log
        os.makedirs(self.tools, exist_ok=True)

    def run(self, package):
        fn = {
            "Telegram": self.telegram_package,
            "submodules/TelegramApi": self.telegram_api,
            "submodules/TelegramCore/FlatSerialization": self.flat_serialization,
            "third-party/wallet-engine": self.wallet_engine,
        }.get(package)
        if fn is None:
            raise GeneratorError("no generator for %s" % package)
        fn()

    def _stamped(self, out_dir, key, make):
        stamp = os.path.join(out_dir, ".stamp")
        if os.path.exists(stamp) and open(stamp).read() == key:
            return
        make()
        os.makedirs(out_dir, exist_ok=True)
        with open(stamp, "w") as f:
            f.write(key)

    def telegram_package(self):
        self.presentation_strings()
        self.intents()

    # ---- //Telegram:GeneratedSources (swift_intent_library) -------------------------

    def intents(self):
        """Swift declarations for the Siri intent definition, as Xcode's intent code generator makes them.

        Only declarations (classes, @NSManaged properties, enums): enough to typecheck the code that uses
        them. The real generator also emits responses and handling protocols, used only by the Siri
        Intents extension.
        """
        import plistlib
        with open(os.path.join(self.repo, "Telegram", "BUILD")) as f:
            build = f.read()
        block = re.search(r'swift_intent_library\((.*?)\)', build, re.S).group(1)
        src = os.path.join(self.repo, "Telegram", re.search(r'src\s*=\s*"([^"]+)"', block).group(1))
        name = re.search(r'module_name\s*=\s*"([^"]+)"', block).group(1)
        out = os.path.join(self.gen, "Telegram", name)

        def make():
            with open(src, "rb") as f:
                definition = plistlib.load(f)
            inherited = {"identifier", "displayString", "pronunciationHint", "alternativeSpeakableMatches",
                         "subtitleString", "displayImage"}
            scalar = {"String": "String", "Integer": "NSNumber", "Boolean": "NSNumber", "Decimal": "NSNumber",
                      "URL": "URL", "Date": "DateComponents"}

            def swift_type(kind, object_type, multiple):
                base = object_type if kind == "Object" else scalar.get(kind)
                if base is None:
                    return None
                return "[%s]" % base if multiple else base

            lines = ["import Foundation", "import Intents", ""]
            for enum in definition.get("INEnums", []):
                lines.append("@objc public enum %s: Int {" % enum["INEnumName"])
                for value in enum.get("INEnumValues", []):
                    lines.append("    case %s = %d" % (value["INEnumValueName"], value.get("INEnumValueIndex", 0)))
                lines.append("}")
            for t in definition.get("INTypes", []):
                lines.append("@objc(%s) public class %s: INObject {" % (t["INTypeName"], t["INTypeName"]))
                for p in t.get("INTypeProperties", []):
                    if p.get("INTypePropertyName") in inherited:
                        continue
                    ty = swift_type(p.get("INTypePropertyType"), p.get("INTypePropertyObjectType"),
                                    p.get("INTypePropertySupportsMultipleValues", False))
                    if ty:
                        lines.append("    @NSManaged public var %s: %s?" % (p["INTypePropertyName"], ty))
                lines.append("}")
            for intent in definition.get("INIntents", []):
                class_name = intent["INIntentName"] + "Intent"
                lines.append("@objc(%s) public class %s: INIntent {" % (class_name, class_name))
                for p in intent.get("INIntentParameters", []):
                    ty = swift_type(p.get("INIntentParameterType"), p.get("INIntentParameterObjectType"),
                                    p.get("INIntentParameterSupportsMultipleValues", False))
                    if ty:
                        lines.append("    @NSManaged public var %s: %s?" % (p["INIntentParameterName"], ty))
                lines.append("}")
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, name + ".swift"), "w") as f:
                f.write("\n".join(lines) + "\n")
        self._stamped(out, _hash_files([src, __file__]), make)

    # ---- //Telegram:GeneratedPresentationStrings --------------------------------

    def presentation_strings(self):
        out = os.path.join(self.gen, "Telegram", "GeneratedPresentationStrings")
        source = os.path.join(self.repo, "Telegram/Telegram-iOS/en.lproj/Localizable.strings")
        script = os.path.join(self.repo, "build-system/GenerateStrings/GenerateStrings.py")

        def make():
            for sub in ("Sources", "PublicHeaders/PresentationStrings", "Resources"):
                os.makedirs(os.path.join(out, sub), exist_ok=True)
            _run([sys.executable, "-W", "ignore", script, "--source=" + source,
                  "--outImplementation=" + os.path.join(out, "Sources/PresentationStrings.m"),
                  "--outHeader=" + os.path.join(out, "PublicHeaders/PresentationStrings/PresentationStrings.h"),
                  "--outData=" + os.path.join(out, "Resources/PresentationStrings.data")],
                 what="GenerateStrings.py")
        self._stamped(out, _hash_files([source, script]), make)

    # ---- //submodules/TelegramApi:TelegramApiGenerated ---------------------------

    def telegram_api(self):
        package = os.path.join(self.repo, "submodules/TelegramApi")
        out = os.path.join(self.gen, "submodules/TelegramApi/Generated")
        tool_src = os.path.join(self.repo, "build-system/SwiftTL")
        tool_inputs = [p for p in glob.glob(os.path.join(tool_src, "Sources/**/*.swift"), recursive=True)]
        tool_inputs.append(os.path.join(tool_src, "Package.swift"))
        with open(os.path.join(package, "BUILD")) as f:
            file_count = re.search(r"SWIFT_FILE_COUNT\s*=\s*(\d+)", f.read()).group(1)
        scheme = os.path.join(package, "swift_scheme.tl")

        def make():
            scratch = os.path.join(self.tools, "swifttl-build")
            self.log("  generating TelegramApi (building SwiftTL)")
            # SwiftTL does `import zlib`, a module only Apple's SDKs define. Provide it over the
            # system header (zlib1g-dev).
            if not os.path.exists("/usr/include/zlib.h"):
                raise GeneratorError("zlib headers are missing (apt-get install zlib1g-dev)")
            zlib_module = os.path.join(self.tools, "zlib-module")
            os.makedirs(zlib_module, exist_ok=True)
            with open(os.path.join(zlib_module, "module.modulemap"), "w") as f:
                f.write('module zlib [system] {\n    header "/usr/include/zlib.h"\n    link "z"\n    export *\n}\n')
            # SwiftPM scans the package for minutes when it sits on /mnt/c; build a local copy.
            package_copy = os.path.join(self.tools, "swifttl-src")
            _run(["rsync", "-a", "--delete", "--exclude", ".build", tool_src + "/", package_copy + "/"],
                 what="rsync SwiftTL")
            build = ["swift", "build", "-c", "release", "--package-path", package_copy, "--scratch-path", scratch,
                     "-Xswiftc", "-I", "-Xswiftc", zlib_module]
            _run(build, what="swift build SwiftTL")
            binary = os.path.join(_run(build + ["--show-bin-path"]).strip(), "SwiftTL")
            shutil.rmtree(out, ignore_errors=True)
            os.makedirs(os.path.join(out, "Tests"), exist_ok=True)
            # A Windows checkout (core.autocrlf) has CRLF line ends; SwiftTL's parser keeps the
            # \r in names and then fails to resolve types. Feed it LF, as a Mac checkout has.
            scheme_lf = os.path.join(self.tools, "swift_scheme.tl")
            with open(scheme, "rb") as f:
                data = f.read().replace(b"\r\n", b"\n")
            with open(scheme_lf, "wb") as f:
                f.write(data)
            _run([binary, scheme_lf, out, "--swift-file-count=" + file_count, "--objc-output=" + out,
                  "--fixtures-output=" + os.path.join(out, "Tests/SchemaFixtures.swift")], what="SwiftTL")
        self._stamped(out, _hash_files(tool_inputs + [scheme]) + file_count, make)

    # ---- //submodules/TelegramCore/FlatSerialization:GenerateModels --------------

    def _flatc(self):
        with open(os.path.join(self.repo, "MODULE.bazel")) as f:
            module = f.read()
        block = re.search(r'name\s*=\s*"flatbuffers_zip"(.*?)\)', module, re.S).group(1)
        sha256 = re.search(r'sha256\s*=\s*"([0-9a-f]+)"', block).group(1)
        url = re.search(r'urls\s*=\s*\[\s*"([^"]+)"', block).group(1)
        version = re.search(r"v([\d.]+)\.zip", url).group(1)
        root = os.path.join(self.tools, "flatbuffers-" + version)
        flatc = os.path.join(root, "build", "flatc")
        if os.path.exists(flatc):
            return flatc
        self.log("  building flatc %s (once)" % version)
        os.makedirs(self.tools, exist_ok=True)
        archive = os.path.join(self.tools, "flatbuffers-%s.zip" % version)
        if not os.path.exists(archive):
            urllib.request.urlretrieve(url, archive + ".part")
            os.replace(archive + ".part", archive)
        with open(archive, "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != sha256:
                os.unlink(archive)
                raise GeneratorError("flatbuffers archive checksum mismatch (MODULE.bazel pins %s)" % sha256)
        if not shutil.which("cmake"):
            raise GeneratorError("cmake is not installed (apt-get install cmake)")
        shutil.rmtree(root, ignore_errors=True)
        with zipfile.ZipFile(archive) as z:
            z.extractall(self.tools)
        build = os.path.join(root, "build")
        os.makedirs(build, exist_ok=True)
        # The genrule's cmake flags.
        _run(["cmake", "..", "-DCMAKE_BUILD_TYPE=Release", "-DFLATBUFFERS_BUILD_TESTS=0", "-DFLATBUFFERS_INSTALL=0",
              "-DFLATBUFFERS_BUILD_FLATLIB=0", "-DFLATBUFFERS_STATIC_FLATC=0"], cwd=build, what="cmake flatbuffers")
        _run(["make", "-j%d" % (os.cpu_count() or 4), "flatc"], cwd=build, what="make flatc")
        return flatc

    def flat_serialization(self):
        package = os.path.join(self.repo, "submodules/TelegramCore/FlatSerialization")
        out = os.path.join(self.gen, "submodules/TelegramCore/FlatSerialization")
        models = sorted(glob.glob(os.path.join(package, "Models", "*.fbs")))

        def make():
            flatc = self._flatc()
            tmp = os.path.join(self.tools, "flatc-out")
            shutil.rmtree(tmp, ignore_errors=True)
            os.makedirs(tmp)
            _run([flatc, "--require-explicit-ids", "--swift", "-o", tmp] + models, what="flatc")
            os.makedirs(out, exist_ok=True)
            for m in models:
                name = os.path.splitext(os.path.basename(m))[0] + "_generated.swift"
                shutil.copyfile(os.path.join(tmp, name), os.path.join(out, name))
        self._stamped(out, _hash_files(models) + "flatc", make)

    # ---- //third-party/wallet-engine:wallet_engine_swift_bindings ----------------

    def wallet_engine(self):
        package = os.path.join(self.repo, "third-party/wallet-engine")
        upstream = os.path.join(package, "wallet-engine")
        out = os.path.join(self.gen, "third-party/wallet-engine/Generated")
        inputs = [p for p in glob.glob(os.path.join(upstream, "src", "**", "*.rs"), recursive=True)]
        inputs += [os.path.join(upstream, f) for f in ("Cargo.toml", "Cargo.lock", "uniffi.toml")]
        inputs += [os.path.join(upstream, "bindgen/apple/src/main.rs"), os.path.join(upstream, "bindgen/apple/Cargo.toml"),
                   os.path.join(package, "Sources/SwiftBindingsPostprocess.rs"),
                   os.path.join(upstream, "xtask/src/bindings/swift_postprocess.rs")]
        inputs = [p for p in inputs if os.path.exists(p)]

        def make():
            cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
            if not os.path.exists(cargo):
                raise GeneratorError("cargo is not installed (https://rustup.rs)")
            self.log("  generating the wallet engine's Swift bindings (cargo; slow the first time)")
            # Work on a copy so cargo never writes into the checkout (lock files, target/).
            src = os.path.join(self.tools, "wallet-engine-src")
            _run(["rsync", "-a", "--delete", "--exclude", "target", "--exclude", "web", "--exclude", ".git",
                  upstream + "/", src + "/"], what="rsync wallet-engine")
            env = dict(os.environ, CARGO_TARGET_DIR=os.path.join(self.tools, "wallet-engine-target"),
                       CARGO_NET_OFFLINE="false")
            env["PATH"] = os.path.dirname(cargo) + ":" + env.get("PATH", "")
            _run([cargo, "build", "--release", "--lib", "--locked"], cwd=src, env=env, what="cargo build wallet-engine")
            target = env["CARGO_TARGET_DIR"]
            library = os.path.join(target, "release", "libwallet_engine.so")
            raw = os.path.join(self.tools, "wallet-engine-bindings")
            shutil.rmtree(raw, ignore_errors=True)
            os.makedirs(raw)
            bindgen = [cargo, "run", "--release", "--manifest-path", os.path.join(src, "bindgen/apple/Cargo.toml")]
            if os.path.exists(os.path.join(src, "bindgen/apple/Cargo.lock")):
                bindgen.append("--locked")
            # The genrule's bindgen flags.
            _run(bindgen + ["--", "--swift-sources", "--headers", "--modulemap", "--metadata-no-deps",
                            "--module-name", "wallet_engineFFI", "--modulemap-filename", "module.modulemap",
                            library, raw], cwd=src, env=env, what="wallet bindgen")
            # Sources/SwiftBindingsPostprocess.rs, as a tiny cargo project next to the copy.
            post = os.path.join(self.tools, "wallet-engine-postprocess")
            os.makedirs(os.path.join(post, "src"), exist_ok=True)
            with open(os.path.join(post, "Cargo.toml"), "w") as f:
                f.write('[package]\nname = "postprocess"\nversion = "0.0.0"\nedition = "2024"\n\n'
                        '[dependencies]\nanyhow = "1"\n')
            with open(os.path.join(package, "Sources/SwiftBindingsPostprocess.rs")) as f:
                main_rs = f.read().replace('"../wallet-engine/xtask/src/bindings/swift_postprocess.rs"',
                                           json.dumps(os.path.join(src, "xtask/src/bindings/swift_postprocess.rs")))
            with open(os.path.join(post, "src/main.rs"), "w") as f:
                f.write(main_rs)
            os.makedirs(out, exist_ok=True)
            _run([cargo, "run", "--release", "--quiet", "--", os.path.join(raw, "WalletEngineFFI.swift"),
                  os.path.join(out, "WalletEngineFFI.swift"), os.path.join(raw, "wallet_engineFFI.h"),
                  os.path.join(out, "wallet_engineFFI.h")], cwd=post, env=env, what="wallet bindings postprocess")
        self._stamped(out, _hash_files(inputs), make)
