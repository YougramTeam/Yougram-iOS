#!/usr/bin/env python3
"""Print the path of the newest released Xcode 27 on a GitHub macOS runner.

versions.json pins an exact Xcode (27.1), but runner images carry whatever 27.x is
current, so the workflow builds with --overrideXcodeVersion. Betas and release
candidates are skipped; if no release is installed the newest prerelease is used.
"""
import glob
import os
import plistlib
import re
import sys

MAJOR = "27"


def version_of(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            v = plistlib.load(f).get("CFBundleShortVersionString", "")
    except OSError:
        return None
    if not v.startswith(MAJOR + "."):
        return None
    return tuple(int(p) for p in re.findall(r"\d+", v))


def main():
    candidates = {}
    for app in glob.glob("/Applications/Xcode*.app"):
        if os.path.islink(app):
            continue
        v = version_of(app)
        if v is None:
            continue
        prerelease = bool(re.search(r"beta|release_candidate|_rc", os.path.basename(app), re.I))
        candidates[app] = (not prerelease, v)
    if not candidates:
        print("No Xcode %s.x found in /Applications" % MAJOR, file=sys.stderr)
        sys.exit(1)
    print(max(candidates, key=lambda a: candidates[a]))


if __name__ == "__main__":
    main()
