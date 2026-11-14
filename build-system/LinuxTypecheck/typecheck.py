#!/usr/bin/env python3
"""Typecheck the app's Swift modules on Linux (WSL) against the real iOS SDK.

The app itself only builds on macOS (rules_apple needs actool, ibtool, the Metal
compiler and codesign), but every Swift module compiles here with the Linux Swift
toolchain and the iOS SDK that `xtool sdk` extracts from Xcode.xip. That catches what a
Mac build would reject in Swift: type errors, missing imports or BUILD deps, and
warnings under -warnings-as-errors.

How it works:
  * bazel_graph.py reads the BUILD files (no Bazel) and hashes the sources. Under WSL it
    runs with the Windows Python, because file access to /mnt/c is slow from Linux.
  * Dependencies are compiled to .swiftmodule with function bodies skipped, in
    dependency order and in parallel. ObjC/C dependencies get the module maps
    rules_swift would generate.
  * The modules you ask for (or the ones containing changed files) are typechecked in
    full, with the copts from their BUILD files (-warnings-as-errors included).
  * Everything is cached by content. A module is recompiled only when its sources,
    flags or a dependency's *interface* change, so editing a function body in
    TelegramCore does not recompile its hundreds of dependents.

usage (from Windows):
  wsl -d Ubuntu -- python3 /mnt/c/<repo>/build-system/LinuxTypecheck/typecheck.py --changed
  wsl -d Ubuntu -- python3 /mnt/c/<repo>/build-system/LinuxTypecheck/typecheck.py SettingsUI TelegramUI
"""
import argparse
import concurrent.futures as futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bazel_graph  # noqa: E402
import generators  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SDK_BUNDLE = os.path.expanduser("~/.swiftpm/swift-sdks/darwin.artifactbundle")
CACHE = os.path.expanduser(os.environ.get("YOUGRAM_TYPECHECK_CACHE", "~/.cache/yougram-typecheck"))
MIN_IOS = "15.0"  # minimum_os_version in Telegram/BUILD
TOOL_VERSION = "2"
GEN = bazel_graph.GENERATED_PREFIX

USE_COLOR = sys.stdout.isatty()


def color(code, s):
    return "\033[%sm%s\033[0m" % (code, s) if USE_COLOR else s


def log(msg):
    print(msg, flush=True)


def sha(*parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(p.encode() if isinstance(p, str) else p)
        h.update(b"\0")
    return h.hexdigest()[:24]


def trim(text, limit=60):
    lines = text.strip().splitlines()
    if len(lines) > limit:
        lines = lines[:limit] + ["... (%d more lines)" % (len(lines) - limit)]
    return "\n".join(lines)


def indent(text):
    return "\n".join("    " + l for l in text.splitlines())


# ---------------------------------------------------------------------------

def load_export(with_changes):
    """The module model from bazel_graph.py, via the Windows Python when under /mnt/<drive>."""
    windows_python = shutil.which("python.exe") if REPO.startswith("/mnt/") else None
    if windows_python:
        script = subprocess.run(["wslpath", "-w", os.path.join(HERE, "bazel_graph.py")],
                                capture_output=True, text=True, check=True).stdout.strip()
        cmd = [windows_python, script, "--export"] + (["--changes"] if with_changes else [])
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit("bazel_graph.py failed:\n" + p.stderr)
        return json.loads(p.stdout)
    return bazel_graph.export_modules(REPO, os.path.join(CACHE, "file-hashes.json"), with_changes)


class Toolchain:
    def __init__(self):
        self.sdk = os.path.join(SDK_BUNDLE, "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
        self.resource_dir = os.path.join(SDK_BUNDLE, "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift")
        if not os.path.isdir(self.sdk):
            sys.exit("No iOS SDK at %s. Run `xtool sdk build <Xcode.xip>` first." % self.sdk)
        self.swiftc = shutil.which("swiftc") or sys.exit("swiftc not found")
        self.version = subprocess.run([self.swiftc, "--version"], capture_output=True, text=True).stdout.strip()
        with open(os.path.join(self.sdk, "SDKSettings.json")) as f:
            self.sdk_version = json.load(f).get("Version", "?")
        self.module_cache = os.path.join(CACHE, "module-cache")

    def base_flags(self):
        return [
            "-target", "arm64-apple-ios%s" % MIN_IOS,
            "-sdk", self.sdk,
            "-resource-dir", self.resource_dir,
            "-module-cache-path", self.module_cache,
            "-Xfrontend", "-enable-cross-import-overlays",
            "-Xcc", "-iquote", "-Xcc", REPO,
        ]


class Module:
    def __init__(self, label, record, gen_dir):
        self.label = label
        self.name = record["name"]
        self.kind = record["kind"]
        self.package = record["package"]
        self.dep_labels = record["deps"]
        self.deps = []
        self.defines = record.get("defines", [])
        self.copts = record.get("copts", [])
        self.rel_srcs = record.get("srcs", [])
        self.rel_hdrs = record.get("hdrs", [])
        self.rel_textual = record.get("textual_hdrs", [])
        resolve = lambda p: os.path.join(gen_dir, p[len(GEN):]) if p.startswith(GEN) else os.path.join(REPO, p)
        self.srcs = [resolve(p) for p in self.rel_srcs]
        self.hdrs = [resolve(p) for p in self.rel_hdrs]
        self.textual_hdrs = [resolve(p) for p in self.rel_textual]
        self.framework_dirs = [os.path.join(REPO, p) for p in record.get("framework_dirs", [])]
        self.includes = []
        for inc in record.get("includes", []):
            real = os.path.join(REPO, inc)
            self.includes.append(real if not inc.startswith("Telegram/GeneratedPresentationStrings")
                                 else os.path.join(gen_dir, inc))
        self._closure = None

    def closure(self):
        """All transitive dependencies (not including self), dependencies first."""
        if self._closure is None:
            seen, order = set(), []

            def visit(m):
                for d in m.deps:
                    if d.label not in seen:
                        seen.add(d.label)
                        visit(d)
                        order.append(d)
            visit(self)
            self._closure = order
        return self._closure


class Workspace:
    def __init__(self, export):
        self.gen_dir = os.path.join(CACHE, "generated")
        self.hashes = export["hashes"]
        self.modules = {l: Module(l, r, self.gen_dir) for l, r in export["modules"].items()}
        self.by_name = {}
        for m in self.modules.values():
            m.deps = [self.modules[d] for d in m.dep_labels if d in self.modules]
            # A swift_library and an ObjC library can share a module name; prefer Swift.
            if m.name not in self.by_name or m.kind == "swift":
                self.by_name[m.name] = m
        self.changed = {os.path.join(REPO, p) for p in export.get("changed", [])}
        self._gen_hashes = {}

    def generated_packages(self, modules):
        """Packages whose generated files these modules compile or import."""
        packages = set()
        for m in modules:
            for p in m.rel_srcs + m.rel_hdrs + m.rel_textual:
                if p.startswith(GEN):
                    packages.add(next(pkg for pkg in bazel_graph.GENERATED_PACKAGES
                                      if p[len(GEN):].startswith(pkg + "/")))
        return packages

    def file_hash(self, rel):
        if rel.startswith(GEN):
            if rel not in self._gen_hashes:
                with open(os.path.join(self.gen_dir, rel[len(GEN):]), "rb") as f:
                    self._gen_hashes[rel] = hashlib.sha256(f.read()).hexdigest()[:24]
            return self._gen_hashes[rel]
        return self.hashes.get(rel, "missing")

    def lookup(self, query):
        if query.startswith("//"):
            label = query if ":" in query else query + ":" + query.rsplit("/", 1)[-1]
            return self.modules.get(label)
        return self.by_name.get(query)


class BuildError(Exception):
    def __init__(self, module, output):
        super().__init__(module.name)
        self.module = module
        self.output = output


class Builder:
    def __init__(self, ws, tc, jobs, werror):
        self.ws = ws
        self.tc = tc
        self.jobs = jobs
        self.werror = werror
        self.fingerprints = {}  # label -> interface fingerprint
        self.store = os.path.join(CACHE, "store")
        self.modmaps = os.path.join(CACHE, "modulemaps")
        self.out = os.path.join(CACHE, "out")
        for d in (self.store, self.modmaps, os.path.join(self.out, "modules"), tc.module_cache):
            os.makedirs(d, exist_ok=True)
        self.stats = {"cached": 0, "built": 0, "failed": 0}

    # ---- clang modules -----------------------------------------------------

    def clang_fingerprint(self, m):
        if m.label not in self.fingerprints:
            parts = [m.name, json.dumps(m.includes), json.dumps(m.defines), json.dumps(m.framework_dirs)]
            parts += [p + "=" + self.ws.file_hash(p) for p in m.rel_hdrs + m.rel_textual]
            parts += [self.clang_fingerprint(d) for d in m.deps if d.kind != "swift"]
            self.fingerprints[m.label] = sha(*parts)
        return self.fingerprints[m.label]

    def modulemap(self, m):
        path = os.path.join(self.modmaps, m.label[2:].replace("/", "_").replace(":", "__") + ".modulemap")
        lines = ['module "%s" {' % m.name, "    export *"]
        lines += ['    header "%s"' % h for h in m.hdrs]
        lines += ['    textual header "%s"' % h for h in m.textual_hdrs]
        text = "\n".join(lines + ["}"]) + "\n"
        try:
            with open(path) as f:
                if f.read() == text:
                    return path
        except OSError:
            pass
        tmp = "%s.%d.%d" % (path, os.getpid(), threading.get_ident())
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)
        return path

    def framework_dir(self, m, directory):
        """A copy of a prebuilt framework slice with LF line ends.

        A Windows checkout (core.autocrlf) turns the .swiftinterface's line ends into CRLF and Swift
        then can't read its version header. Only what compiling against it needs is copied
        (headers, module maps, interfaces), not the binary.
        """
        dest = os.path.join(CACHE, "frameworks", sha(directory))
        stamp = os.path.join(dest, ".stamp")
        key = self.fingerprints[m.label]
        if os.path.exists(stamp) and open(stamp).read() == key:
            return dest
        shutil.rmtree(dest, ignore_errors=True)
        for root, _, names in os.walk(directory):
            rel = os.path.relpath(root, directory)
            if not any(part in ("Headers", "Modules", "PrivateHeaders") or part.endswith(".swiftmodule")
                       for part in rel.split(os.sep)):
                continue
            os.makedirs(os.path.join(dest, rel), exist_ok=True)
            for name in names:
                with open(os.path.join(root, name), "rb") as f:
                    data = f.read()
                if name.endswith((".swiftinterface", ".h", ".modulemap")):
                    data = data.replace(b"\r\n", b"\n")
                with open(os.path.join(dest, rel, name), "wb") as f:
                    f.write(data)
        with open(stamp, "w") as f:
            f.write(key)
        return dest

    # ---- swift modules -----------------------------------------------------

    def swift_flags(self, m):
        flags = self.tc.base_flags() + ["-module-name", m.name, "-parse-as-library", "-I", self.include_dir(m)]
        for d in m.closure():
            if d.kind == "framework":
                for directory in d.framework_dirs:
                    flags += ["-F", self.framework_dir(d, directory)]
            elif d.kind == "clang":
                if d.hdrs or d.textual_hdrs:
                    flags += ["-Xcc", "-fmodule-map-file=" + self.modulemap(d)]
                for inc in d.includes:
                    flags += ["-Xcc", "-I" + inc]
                for define in d.defines:
                    flags += ["-Xcc", "-D" + define]
            else:
                flags += ["-D" + define for define in d.defines]
        flags += ["-D" + define for define in m.defines]
        return flags + [c for c in m.copts if self.werror or c != "-warnings-as-errors"]

    def include_dir(self, m):
        """A directory exposing exactly the .swiftmodule files of m's Swift dependencies."""
        d = os.path.join(self.out, "inc", m.name)
        os.makedirs(d, exist_ok=True)
        wanted = {dep.name + ".swiftmodule": os.path.join(self.out, "modules", dep.name + ".swiftmodule")
                  for dep in m.closure() if dep.kind == "swift"}
        for name in os.listdir(d):
            if name not in wanted and ".swiftmodule." not in name:
                try:
                    os.unlink(os.path.join(d, name))
                except FileNotFoundError:
                    pass
        for name, target in wanted.items():
            link = os.path.join(d, name)
            if os.path.islink(link) and os.readlink(link) == target:
                continue
            # Replace atomically: another run may be touching the same farm.
            tmp = "%s.%d.%d" % (link, os.getpid(), threading.get_ident())
            os.symlink(target, tmp)
            os.replace(tmp, link)
        return d

    def swift_key(self, m, mode):
        parts = [TOOL_VERSION, self.tc.version, self.tc.sdk_version, mode, m.name, json.dumps(m.copts),
                 json.dumps(m.defines), str(self.werror)]
        parts += [p + "=" + self.ws.file_hash(p) for p in m.rel_srcs]
        parts += [d.name + "=" + self.fingerprints[d.label] for d in m.closure()]
        return sha(*parts)

    def emit(self, m):
        """Build m's .swiftmodule (function bodies skipped) and record its interface fingerprint."""
        key = self.swift_key(m, "emit")
        entry = os.path.join(self.store, key)
        module_file = os.path.join(entry, m.name + ".swiftmodule")
        if os.path.exists(module_file):
            self.stats["cached"] += 1
        else:
            if not m.srcs:
                raise BuildError(m, "no Swift sources")
            tmp = "%s.tmp%d.%d" % (entry, os.getpid(), threading.get_ident())
            os.makedirs(tmp, exist_ok=True)
            # -wmo: one frontend parses the module once; without it the driver runs a frontend
            # per source file and merges, several times slower for big modules.
            cmd = [self.tc.swiftc, "-emit-module", "-wmo", "-emit-module-path", os.path.join(tmp, m.name + ".swiftmodule"),
                   "-Xfrontend", "-experimental-skip-non-inlinable-function-bodies-without-types",
                   ] + self.swift_flags(m) + m.srcs
            t0 = time.time()
            p = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True)
            if p.returncode != 0:
                shutil.rmtree(tmp, ignore_errors=True)
                raise BuildError(m, p.stdout + p.stderr)
            for f in os.listdir(tmp):
                if not f.endswith((".swiftmodule", ".swiftdoc")):
                    os.unlink(os.path.join(tmp, f))
            if os.path.exists(entry):
                shutil.rmtree(tmp, ignore_errors=True)
            else:
                os.replace(tmp, entry)
            self.stats["built"] += 1
            log("  %s %s %.1fs" % (color("36", "built"), m.name, time.time() - t0))
        with open(module_file, "rb") as f:
            self.fingerprints[m.label] = hashlib.sha256(f.read()).hexdigest()[:24]
        link = os.path.join(self.out, "modules", m.name + ".swiftmodule")
        tmp_link = "%s.%d.%d" % (link, os.getpid(), threading.get_ident())
        os.symlink(module_file, tmp_link)
        os.replace(tmp_link, link)

    def typecheck(self, m):
        key = self.swift_key(m, "typecheck")
        marker = os.path.join(self.store, "tc-" + key)
        if os.path.exists(marker):
            return True, "", True
        cmd = [self.tc.swiftc, "-typecheck", "-j%d" % self.jobs] + self.swift_flags(m) + m.srcs
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
        if p.returncode == 0:
            open(marker, "w").close()
        return p.returncode == 0, p.stdout + p.stderr, False

    def build_interfaces(self, modules):
        """Emit .swiftmodule for every Swift module in `modules`, dependencies first, in parallel."""
        for m in modules:
            if m.kind != "swift":
                self.clang_fingerprint(m)
        todo = {m.label: m for m in modules if m.kind == "swift"}
        done, failed, running = set(), {}, {}
        with futures.ThreadPoolExecutor(max_workers=self.jobs) as pool:
            while todo or running:
                for label in list(todo):
                    m = todo[label]
                    swift_deps = [d for d in m.deps if d.kind == "swift"]
                    if any(d.label in failed for d in swift_deps):
                        failed[label] = "dependency failed"
                        del todo[label]
                    elif all(d.label in done for d in swift_deps) and len(running) < self.jobs:
                        running[pool.submit(self.emit, m)] = m
                        del todo[label]
                if not running:
                    for label in todo:
                        failed[label] = "unresolved dependency"
                    break
                finished, _ = futures.wait(running, return_when=futures.FIRST_COMPLETED)
                for f in finished:
                    m = running.pop(f)
                    try:
                        f.result()
                        done.add(m.label)
                    except BuildError as e:
                        failed[m.label] = e.output
                        self.stats["failed"] += 1
                        log(color("31", "  failed to build the interface of %s" % m.name))
                        log(indent(trim(e.output)))
        return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("modules", nargs="*", help="module names or //labels to typecheck in full")
    ap.add_argument("--changed", action="store_true",
                    help="typecheck the modules containing files changed against HEAD "
                         "(plus $YOUGRAM_TYPECHECK_BASE...HEAD when set)")
    ap.add_argument("--dependents", action="store_true",
                    help="also fully typecheck the direct dependents of those modules")
    ap.add_argument("--emit-only", action="store_true", help="only build interfaces (warms the cache)")
    ap.add_argument("-j", "--jobs", type=int, default=max(1, min(os.cpu_count() or 4, 6)))
    ap.add_argument("--no-werror", action="store_true", help="ignore -warnings-as-errors from BUILD copts")
    args = ap.parse_args()

    os.makedirs(CACHE, exist_ok=True)
    # One run at a time per cache: runs share the interface store and its symlinks. A second
    # run waits here (warm runs take a minute or two).
    import fcntl
    lock_file = open(os.path.join(CACHE, ".lock"), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("Waiting for another typecheck run to finish...")
        fcntl.flock(lock_file, fcntl.LOCK_EX)
    t0 = time.time()
    tc = Toolchain()
    ws = Workspace(load_export(args.changed))
    log("%s | iOS SDK %s | %d modules (graph %.1fs)" % (
        tc.version.splitlines()[0], tc.sdk_version, len(ws.modules), time.time() - t0))

    focus = []
    for q in args.modules:
        m = ws.lookup(q)
        if m is None:
            sys.exit("Unknown module: %s" % q)
        focus.append(m)
    if args.changed:
        def is_test(m):
            # Test targets `@testable import` libraries built with -enable-testing; name them
            # explicitly to check one. --changed checks what ships.
            return m.name.endswith(("Tests", "TestsLib", "TestSupport")) or "/Tests/" in "/" + m.package + "/"
        for m in ws.modules.values():
            if is_test(m):
                continue
            files = set(m.srcs) | set(m.hdrs) | set(m.textual_hdrs)
            build_changed = os.path.join(REPO, m.package, "BUILD") in ws.changed
            if m.kind == "swift" and (files & ws.changed or build_changed):
                focus.append(m)
            elif m.kind == "clang" and files & ws.changed:
                # A changed ObjC header: check the Swift modules that import it directly.
                focus += [s for s in ws.modules.values() if s.kind == "swift" and m in s.deps and not is_test(s)]
        if not focus and not args.modules:
            log("No changed Swift modules.")
            return 0
    if not focus:
        ap.error("name modules to check, or pass --changed")
    focus = list({m.label: m for m in focus if m.kind == "swift"}.values())

    checks = list(focus)
    if args.dependents:
        labels = {m.label for m in focus}
        checks += [s for s in ws.modules.values()
                   if s.kind == "swift" and s.label not in labels and any(d.label in labels for d in s.deps)]

    needed = {}
    for m in checks:
        for d in m.closure():
            needed[d.label] = d
        needed[m.label] = m
    gens = generators.Generators(REPO, CACHE, log)
    for package in sorted(ws.generated_packages(needed.values())):
        try:
            gens.run(package)
        except generators.GeneratorError as e:
            log(color("31", "Generating %s failed:" % package))
            log(indent(trim(str(e), 80)))
            return 1

    builder = Builder(ws, tc, args.jobs, werror=not args.no_werror)
    log("Interfaces: %d Swift modules" % sum(1 for m in needed.values() if m.kind == "swift"))
    failed = builder.build_interfaces(list(needed.values()))

    ok = not failed
    if not args.emit_only:
        log("Typechecking %d module(s)" % len(checks))
        for m in checks:
            if any(d.label in failed for d in m.closure()):
                log(color("33", "  skipped %s (a dependency failed to build)" % m.name))
                ok = False
                continue
            t1 = time.time()
            passed, output, cached = builder.typecheck(m)
            if passed:
                log("  %s %s%s" % (color("32", "ok"), m.name, " (cached)" if cached else " %.1fs" % (time.time() - t1)))
                if output.strip():
                    log(indent(trim(output)))
            else:
                ok = False
                log("  %s %s" % (color("31", "FAIL"), m.name))
                log(indent(trim(output, 150)))

    s = builder.stats
    log("%s in %.0fs (interfaces: %d built, %d cached, %d failed)" % (
        color("32", "PASSED") if ok else color("31", "FAILED"), time.time() - t0, s["built"], s["cached"], s["failed"]))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
