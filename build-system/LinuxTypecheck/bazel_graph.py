"""Read the repo's BUILD files without Bazel and return the target graph.

BUILD files are Starlark, which for these files is a subset of Python, so each one is
executed with stub implementations of the rules it calls. Every rule call is recorded
with its attributes; glob() is evaluated against the file system with Bazel's package
boundary rule; select() takes its //conditions:default branch (the iOS device build
this checker models has no other config_setting active).

Only what a Swift typecheck needs is modelled. Anything else is recorded generically
and ignored by the checker.
"""
import fnmatch
import os
import re

SKIP_DIRS = {
    ".git", "bazel-out", "bazel-bin", "bazel-testlogs", "build-input", "node_modules",
    # Large vendored trees whose BUILD files are only reached through their wrappers.
    "third-party/webrtc/webrtc", "third-party/td/td", "submodules/TgVoipWebrtc/tgcalls",
    "Telegram/WatchApp",
}


class Select:
    """select({...}): resolves to the default branch, and survives `+` with lists."""

    def __init__(self, branches):
        self.branches = branches

    def resolve(self):
        if "//conditions:default" in self.branches:
            return self.branches["//conditions:default"]
        # No default: take the first branch (the BUILD file then only builds on that config).
        return next(iter(self.branches.values()))

    def __add__(self, other):
        return _resolve(self) + _resolve(other)

    def __radd__(self, other):
        return _resolve(other) + _resolve(self)


def _resolve(value):
    return value.resolve() if isinstance(value, Select) else value


class Target:
    def __init__(self, kind, package, attrs):
        self.kind = kind
        self.package = package
        self.attrs = {k: _resolve(v) for k, v in attrs.items()}
        self.name = self.attrs.get("name")

    @property
    def label(self):
        return "//%s:%s" % (self.package, self.name)

    def __repr__(self):
        return "<%s %s>" % (self.kind, self.label)


class _Struct:
    def __init__(self, **kw):
        self.__dict__.update(kw)


class _Anything:
    """Stands in for Starlark builtins a .bzl file uses to define rules (attr, cc_common, ...)."""

    def __call__(self, *a, **k):
        return _Anything()

    def __getattr__(self, name):
        return _Anything()

    def __iter__(self):
        return iter(())


def _exec_tolerant(source, path, ns, max_retries=40):
    """exec(), stubbing each undefined name it trips over. Returns the last error or None."""
    code = compile(source, path, "exec")
    error = None
    for _ in range(max_retries):
        try:
            exec(code, ns)
            return None
        except NameError as e:
            m = re.search(r"name '(\w+)' is not defined", str(e))
            if not m or m.group(1) in ns:
                return e
            ns[m.group(1)] = _Anything()
            error = e
        except Exception as e:
            return e
    return error


def _find_packages(root):
    packages = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root).replace(os.sep, "/")
        rel = "" if rel == "." else rel
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and (rel + "/" + d).lstrip("/") not in SKIP_DIRS
                       and not d.startswith("bazel-")]
        if "BUILD" in filenames or "BUILD.bazel" in filenames:
            packages.append(rel)
    return packages


def _glob_to_regex(pattern):
    out = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile("^" + out + "$")


class Graph:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.targets = {}
        self.errors = []
        self.packages = set(_find_packages(self.root))
        self._files_cache = {}
        for package in sorted(self.packages):
            self._load_package(package)

    # ---- glob ----------------------------------------------------------------

    def _package_files(self, package):
        """Files of a package: everything below it that is not inside a subpackage."""
        if package in self._files_cache:
            return self._files_cache[package]
        base = os.path.join(self.root, package)
        files = []
        for dirpath, dirnames, filenames in os.walk(base):
            rel_dir = os.path.relpath(dirpath, base).replace(os.sep, "/")
            rel_dir = "" if rel_dir == "." else rel_dir
            keep = []
            for d in dirnames:
                sub = (package + "/" + rel_dir + "/" + d).replace("//", "/").strip("/")
                if sub in self.packages or d.startswith(".") or d.startswith("bazel-"):
                    continue
                keep.append(d)
            dirnames[:] = keep
            for f in filenames:
                files.append((rel_dir + "/" + f).lstrip("/"))
        self._files_cache[package] = files
        return files

    def _glob(self, package, include, exclude=(), **_):
        files = self._package_files(package)
        inc = [_glob_to_regex(p) for p in include]
        exc = [_glob_to_regex(p) for p in exclude]
        return sorted(f for f in files
                      if any(r.match(f) for r in inc) and not any(r.match(f) for r in exc))

    # ---- evaluation ----------------------------------------------------------

    def _load_package(self, package):
        build = os.path.join(self.root, package, "BUILD")
        if not os.path.exists(build):
            build = os.path.join(self.root, package, "BUILD.bazel")
        with open(build, encoding="utf-8") as f:
            source = f.read()

        ns = {}

        def recorder(kind):
            def record(*args, **kwargs):
                if "name" in kwargs:
                    t = Target(kind, package, kwargs)
                    self.targets[t.label] = t
                    return t.name
                return None
            record._rule_kind = kind
            return record

        def load(bzl, *symbols, **aliases):
            # In-repo .bzl files are run, so the variables and helper functions they
            # export are real. External ones (@rules_swift, ...) only export rules.
            loaded = self._exec_bzl(package, bzl, ns) if not bzl.startswith("@") else {}
            for s in symbols:
                ns[s] = loaded[s] if s in loaded else ns.get(s) or recorder(s)
            for alias, s in aliases.items():
                ns[alias] = loaded[s] if s in loaded else recorder(s)

        native = _Struct(**{k: recorder(k) for k in (
            "genrule", "filegroup", "alias", "cc_library", "objc_library", "config_setting",
            "exports_files", "sh_binary", "py_binary", "cc_binary", "cc_test")})
        native.glob = lambda include, exclude=(), **kw: self._glob(package, include, exclude, **kw)
        native.package_name = lambda: package
        native.existing_rule = lambda name: None

        ns.update({
            "__recorder__": recorder,
            "load": load,
            "glob": native.glob,
            "select": lambda d, **_: Select(d),
            "package": lambda **_: None,
            "licenses": lambda *_, **__: None,
            "exports_files": lambda *_, **__: None,
            "package_name": native.package_name,
            "native": native,
            "struct": _Struct,
            "Label": lambda s: s,
            "fail": lambda *a, **_: None,
            "print": lambda *a, **_: None,
            "selects": _Struct(config_setting_group=recorder("config_setting_group"),
                               with_or=lambda d, **_: Select({k if isinstance(k, str) else k[0]: v
                                                              for k, v in d.items()})),
            "True": True, "False": False, "None": None,
        })
        for kind in ("genrule", "filegroup", "alias", "config_setting", "cc_library",
                     "objc_library", "sh_binary", "py_binary", "cc_binary", "cc_test"):
            ns.setdefault(kind, recorder(kind))
        # Any other rule a BUILD file calls at top level (package_group, test_suite,
        # toolchain, ...) is recorded generically.
        for name in set(re.findall(r"^([A-Za-z_]\w*)\(", source, re.M)):
            ns.setdefault(name, recorder(name))

        error = _exec_tolerant(source, build, ns)
        if error is not None:  # a BUILD file using Starlark this stub can't run
            self.errors.append("%s: %s: %s" % (package, type(error).__name__, error))

    def _exec_bzl(self, package, bzl, build_ns):
        """Run an in-repo .bzl file in a copy of the loading BUILD file's namespace."""
        label = self.resolve_label(package, bzl)
        pkg, name = label[2:].split(":", 1)
        path = os.path.join(self.root, pkg, name)
        if not os.path.exists(path):
            return {}
        with open(path, encoding="utf-8") as f:
            source = f.read()
        ns = dict(build_ns)
        recorder = build_ns["__recorder__"]
        # A rule defined here becomes a recorder named after the symbol it is bound to.
        ns["rule"] = lambda *a, **k: recorder("rule")
        for name in set(re.findall(r"^([A-Za-z_]\w*)\(", source, re.M)):
            ns.setdefault(name, lambda *a, **k: None)
        error = _exec_tolerant(source, path, ns)
        if error is not None:
            self.errors.append("%s (loading %s): %s: %s" % (package, bzl, type(error).__name__, error))
        for sym, value in ns.items():
            if callable(value) and getattr(value, "_rule_kind", None) == "rule":
                ns[sym] = recorder(sym)
        return ns

    # ---- labels --------------------------------------------------------------

    def resolve_label(self, package, label):
        """Normalize a dep label to //pkg:name; external repos come back unchanged."""
        if label.startswith("@"):
            return label
        if label.startswith(":"):
            return "//%s:%s" % (package, label[1:])
        if label.startswith("//"):
            if ":" in label:
                return label
            return "%s:%s" % (label, label.rsplit("/", 1)[-1])
        return "//%s:%s" % (package, label)

    def source_path(self, target, src):
        """A srcs/hdrs entry as a repo-relative path, or None if it names a rule."""
        if src.startswith(":") or src.startswith("//") or src.startswith("@"):
            label = self.resolve_label(target.package, src)
            if label in self.targets:
                return None
            pkg, name = label[2:].split(":", 1)
            return (pkg + "/" + name).strip("/")
        return (target.package + "/" + src).strip("/")


# ---------------------------------------------------------------------------
# Export: the module model the typechecker needs, with file hashes.
#
# typecheck.py runs inside WSL, where every file access to the Windows checkout
# (/mnt/c, a 9P mount) costs milliseconds: walking the tree there takes minutes, here a
# second. So under WSL it runs this export with the Windows Python and only hands the
# compiler's work to Linux.

GENERATED_PREFIX = "@gen/"  # files Bazel generates; typecheck.py makes them under its cache

# Packages whose genrule outputs typecheck.py knows how to produce (see its GENERATORS).
GENERATED_PACKAGES = (
    "Telegram",                                   # PresentationStrings (GenerateStrings.py)
    "submodules/TelegramApi",                     # Api*.swift from swift_scheme.tl (SwiftTL)
    "submodules/TelegramCore/FlatSerialization",  # flatc --swift
    "third-party/wallet-engine",                  # uniffi Swift bindings
)


def _derive_module_name(label):
    pkg, name = label[2:].split(":", 1)
    return "".join(c if c.isalnum() else "_" for c in (pkg + "_" + name)).strip("_")


class _HashCache:
    def __init__(self, path):
        import json
        self.path = path
        try:
            with open(path) as f:
                self.db = json.load(f)
        except (OSError, ValueError):
            self.db = {}
        self.dirty = False

    def hash(self, abs_path):
        import hashlib
        try:
            st = os.stat(abs_path)
        except OSError:
            return "missing"
        key = "%d:%d" % (st.st_mtime_ns, st.st_size)
        entry = self.db.get(abs_path)
        if entry and entry[0] == key:
            return entry[1]
        with open(abs_path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()[:24]
        self.db[abs_path] = [key, digest]
        self.dirty = True
        return digest

    def save(self):
        import json
        if self.dirty:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.db, f)
            os.replace(tmp, self.path)


def export_modules(root, hash_cache_path, with_changes=False):
    import subprocess
    g = Graph(root)
    hashes = _HashCache(hash_cache_path)
    files_by_package = {}
    genrule_outs = {}  # repo-relative output path -> package of the genrule making it
    for t in g.targets.values():
        if t.kind == "genrule":
            for out in t.attrs.get("outs") or []:
                if isinstance(out, str):
                    genrule_outs[(t.package + "/" + out).strip("/")] = t.package

    def find_in_package(package, base):
        if package not in files_by_package:
            index = {}
            for dirpath, _, names in os.walk(os.path.join(g.root, package)):
                for n in names:
                    index.setdefault(n, os.path.relpath(os.path.join(dirpath, n), g.root).replace(os.sep, "/"))
            files_by_package[package] = index
        return files_by_package[package].get(base)

    def files(target, entries, exts=None):
        out = []
        for e in entries or []:
            if not isinstance(e, str):
                continue
            path = g.source_path(target, e)
            if path is None:  # a rule: expand filegroups, skip the rest
                rule = g.targets.get(g.resolve_label(target.package, e))
                if rule is not None and rule.kind == "filegroup":
                    out += files(rule, rule.attrs.get("srcs"), exts)
                continue
            if exts and os.path.splitext(path)[1] not in exts:
                continue
            if not os.path.exists(os.path.join(g.root, path)):
                if path in genrule_outs and genrule_outs[path] in GENERATED_PACKAGES:
                    path = GENERATED_PREFIX + path
                else:
                    # Headers a genrule copies out of a vendored tree (third-party/*/Public/...)
                    # exist under the package in the source tree.
                    # Anything else generated (prebuilt libraries' headers) is left out: no
                    # Swift module imports those, and leaving them out mirrors a module map
                    # that never names them.
                    found = find_in_package(target.package, os.path.basename(path))
                    if found is None:
                        continue
                    path = found
            out.append(path)
        return out

    modules = {}
    for t in g.targets.values():
        a = t.attrs
        if t.kind in ("apple_static_xcframework_import", "apple_dynamic_xcframework_import"):
            # A prebuilt framework: Swift finds it with -F on its iOS device slice, which ships
            # .swiftinterface files and/or headers with a module map.
            paths = [p for p in files(t, a.get("xcframework_imports"))
                     if re.search(r"/ios-arm64[^/]*/", p) and "simulator" not in p]
            slices = sorted({re.match(r"(.*/ios-arm64[^/]*)/", p).group(1) for p in paths})
            names = sorted({m.group(1) for p in paths for m in [re.search(r"/([^/]+)\.framework/", p)] if m})
            if slices and names:
                modules[t.label] = {"name": names[0], "kind": "framework", "package": t.package, "deps": [],
                                    "defines": [], "framework_dirs": slices,
                                    "hdrs": [p for p in paths if p.endswith((".swiftinterface", ".h", ".modulemap"))]}
            continue
        if t.kind == "swift_intent_library":
            # Xcode generates it from an .intentdefinition; generators.py writes the declarations.
            name = a.get("module_name") or t.name
            modules[t.label] = {"name": name, "kind": "swift", "package": t.package, "deps": [], "defines": [],
                                "srcs": [GENERATED_PREFIX + "%s/%s/%s.swift" % (t.package, t.name, name)], "copts": []}
            continue
        if t.kind == "swift_library":
            kind, name = "swift", a.get("module_name") or t.name
        elif t.kind in ("objc_library", "cc_library"):
            kind, name = "clang", a.get("module_name") or _derive_module_name(t.label)
        else:
            continue
        m = {"name": name, "kind": kind, "package": t.package,
             "deps": [g.resolve_label(t.package, d) for d in a.get("deps") or [] if isinstance(d, str)],
             "defines": list(a.get("defines") or [])}
        if kind == "swift":
            m["srcs"] = files(t, a.get("srcs"), (".swift",))
            m["copts"] = [c for c in a.get("copts") or [] if isinstance(c, str)]
        else:
            m["hdrs"] = files(t, a.get("hdrs"), (".h", ".hh", ".hpp", ".inc", ""))
            m["textual_hdrs"] = files(t, a.get("textual_hdrs"))
            m["includes"] = [os.path.normpath(os.path.join(t.package, i)).replace(os.sep, "/")
                             for i in a.get("includes") or []]
        modules[t.label] = m

    for m in modules.values():
        m["deps"] = [d for d in m["deps"] if d in modules]
    file_hashes = {}
    for m in modules.values():
        for key in ("srcs", "hdrs", "textual_hdrs"):
            for p in m.get(key, []):
                if not p.startswith(GENERATED_PREFIX) and p not in file_hashes:
                    file_hashes[p] = hashes.hash(os.path.join(g.root, p))
    hashes.save()

    result = {"modules": modules, "hashes": file_hashes, "errors": g.errors}
    if with_changes:
        def git(*args):
            p = subprocess.run(["git", "-C", g.root] + list(args), capture_output=True, text=True)
            return [l for l in p.stdout.split("\n") if l]
        changed = set(git("diff", "--name-only", "HEAD")) | set(git("ls-files", "--others", "--exclude-standard"))
        base = os.environ.get("YOUGRAM_TYPECHECK_BASE")
        if base:
            changed |= set(git("diff", "--name-only", base + "...HEAD"))
        result["changed"] = sorted(changed)
    return result


if __name__ == "__main__":
    import argparse
    import collections
    import json
    import sys
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    ap.add_argument("--export", action="store_true", help="print the module model as JSON")
    ap.add_argument("--changes", action="store_true", help="include files changed against HEAD")
    ap.add_argument("--hash-cache", default=os.path.join(
        os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.cache"), "yougram-typecheck", "file-hashes.json"))
    args = ap.parse_args()
    if args.export:
        json.dump(export_modules(os.path.abspath(args.root), args.hash_cache, args.changes), sys.stdout)
        sys.exit(0)
    g = Graph(args.root)
    kinds = collections.Counter(t.kind for t in g.targets.values())
    print("packages:", len(g.packages), "targets:", len(g.targets))
    for k, n in kinds.most_common(20):
        print("%6d %s" % (n, k))
    print("errors:", len(g.errors))
    for e in g.errors[:40]:
        print("  ", e)
