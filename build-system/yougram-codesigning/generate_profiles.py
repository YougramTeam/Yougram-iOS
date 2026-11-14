#!/usr/bin/env python3
"""Make placeholder provisioning profiles for Yougram's bundle id.

Make.py (--codesigningInformationPath) picks the profiles whose application-identifier starts with
"<team_id>.<bundle_id>" (BuildConfiguration.copy_profiles_from_directory), so the upstream
placeholders in ../fake-codesigning/profiles only work for ph.telegra.Telegraph. This copies them
with every occurrence of that bundle id replaced by the one in ../yougram-configuration.json
(application identifier, app group, iCloud containers, names), a new UUID derived from it, and
re-signs them with ../fake-codesigning/certs/SelfSigned.p12, like GenerateProfiles.py does with
`security cms`. Like the upstream placeholders, they only make the build sign; re-sign the .ipa to
install it.

Needs python3 and openssl (macOS, Linux or WSL). Run it again after changing the bundle id:
    python3 build-system/yougram-codesigning/generate_profiles.py
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "fake-codesigning")
UPSTREAM_BUNDLE_ID = "ph.telegra.Telegraph"


def replace_strings(value, old, new):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_strings(v, old, new) for v in value]
    if isinstance(value, dict):
        return {replace_strings(k, old, new): replace_strings(v, old, new) for k, v in value.items()}
    return value


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


def main():
    with open(os.path.join(HERE, "..", "yougram-configuration.json")) as f:
        configuration = json.load(f)
    bundle_id = configuration["bundle_id"]
    team_id = configuration["team_id"]
    out_dir = os.path.join(HERE, "profiles")
    os.makedirs(out_dir, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        signer = os.path.join(tmp, "signer.pem")
        run("openssl", "pkcs12", "-in", os.path.join(SOURCE, "certs", "SelfSigned.p12"), "-passin", "pass:",
            "-nodes", "-legacy", "-out", signer)
        for name in sorted(os.listdir(os.path.join(SOURCE, "profiles"))):
            if not name.endswith(".mobileprovision"):
                continue
            plist_path = os.path.join(tmp, name + ".plist")
            run("openssl", "cms", "-verify", "-noverify", "-inform", "DER",
                "-in", os.path.join(SOURCE, "profiles", name), "-out", plist_path)
            with open(plist_path, "rb") as f:
                profile = plistlib.load(f)
            profile = replace_strings(profile, UPSTREAM_BUNDLE_ID, bundle_id)
            app_id = profile["Entitlements"]["application-identifier"]
            if not app_id.startswith(team_id + "." + bundle_id):
                sys.exit("%s: unexpected application-identifier %s" % (name, app_id))
            profile["UUID"] = str(uuid.uuid5(uuid.NAMESPACE_URL, "yougram-placeholder:" + app_id)).upper()
            profile.pop("DER-Encoded-Profile", None)
            with open(plist_path, "wb") as f:
                plistlib.dump(profile, f, fmt=plistlib.FMT_XML)
            run("openssl", "cms", "-sign", "-nodetach", "-binary", "-outform", "DER", "-signer", signer,
                "-in", plist_path, "-out", os.path.join(out_dir, name))
            print("%-36s %s  expires %s" % (name, app_id, profile.get("ExpirationDate")))


if __name__ == "__main__":
    main()
