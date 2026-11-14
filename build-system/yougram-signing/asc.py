#!/usr/bin/env python3
"""Yougram's App Store signing through the App Store Connect API (TestFlight builds).

  setup    Register the app's App IDs (the app and its 6 extensions) and enable the capabilities
           they need. Idempotent. Run once (the "App Store setup" workflow does).
  prepare  Create a fresh Apple Distribution certificate (key and CSR made here) and an App Store
           profile per App ID, and write what Make.py's --codesigningInformationPath expects:
           <out>/profiles/*.mobileprovision, <out>/certs/Signing.p12 (password P12_PASSWORD), and
           <out>/state.json with the team id and what to delete afterwards.
  cleanup  Revoke that certificate and delete those profiles (always run after a build).
  wait-build  Poll an uploaded build until Apple has processed it (VALID), and fail if Apple
           rejects it (INVALID); Apple emails the reasons, the API doesn't give them.

TestFlight builds are re-signed by Apple, so revoking the certificate once the upload is done
does not affect them. Nothing here touches certificates or profiles it did not create.

The App Store Connect API cannot create an App Group or assign one to an App ID (only the
developer website can), so that part is manual, once: see `setup`'s output.

Auth: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the .p8's contents) in the environment.
Only python3 and openssl are needed (the ES256 token is signed with openssl).
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
HERE = os.path.dirname(os.path.abspath(__file__))

# Bundle id suffix -> (profile file name Make.py expects, App ID name, capabilities)
TARGETS = {
    "": ("Telegram", "Yougram", ["APP_GROUPS", "PUSH_NOTIFICATIONS", "SIRIKIT"]),
    ".Share": ("Share", "Yougram Share", ["APP_GROUPS"]),
    ".Widget": ("Widget", "Yougram Widget", ["APP_GROUPS"]),
    ".NotificationService": ("NotificationService", "Yougram Notification Service", ["APP_GROUPS"]),
    ".NotificationContent": ("NotificationContent", "Yougram Notification Content", ["APP_GROUPS"]),
    ".SiriIntents": ("Intents", "Yougram Siri Intents", ["APP_GROUPS"]),
    ".BroadcastUpload": ("BroadcastUpload", "Yougram Broadcast Upload", ["APP_GROUPS"]),
}


def die(message):
    print("error: " + message, file=sys.stderr)
    sys.exit(1)


# ---- auth --------------------------------------------------------------------

def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_signature_to_raw(der):
    """ECDSA DER SEQUENCE{INTEGER r, INTEGER s} -> r || s, 32 bytes each (JWS ES256)."""
    if der[0] != 0x30:
        die("unexpected signature encoding")
    index = 2 + (der[1] & 0x7F if der[1] & 0x80 else 0)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            die("unexpected signature encoding")
        length = der[index + 1]
        parts.append(der[index + 2:index + 2 + length].lstrip(b"\x00").rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


class Client:
    def __init__(self):
        self.key_id = os.environ.get("ASC_KEY_ID", "").strip()
        self.issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
        private_key = os.environ.get("ASC_PRIVATE_KEY", "").strip()
        if not (self.key_id and self.issuer_id and private_key):
            die("set the ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY repository secrets")
        self.key_file = tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False)
        self.key_file.write(private_key + "\n")
        self.key_file.close()
        self.token = None
        self.token_time = 0

    def _bearer(self):
        now = int(time.time())
        if self.token is None or now - self.token_time > 600:
            header = _b64url(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
            payload = _b64url(json.dumps({"iss": self.issuer_id, "iat": now, "exp": now + 1100,
                                          "aud": "appstoreconnect-v1"}).encode())
            signing_input = (header + "." + payload).encode()
            p = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.key_file.name, "-binary"],
                               input=signing_input, capture_output=True)
            if p.returncode != 0:
                die("couldn't sign the API token with ASC_PRIVATE_KEY: " + p.stderr.decode())
            self.token = header + "." + payload + "." + _b64url(_der_signature_to_raw(p.stdout))
            self.token_time = now
        return self.token

    def request(self, method, path, body=None, allow_missing=False):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self._bearer(),
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if allow_missing and e.code == 404:
                return None
            detail = e.read().decode(errors="replace")
            try:
                detail = "; ".join("%s: %s" % (x.get("title"), x.get("detail")) for x in json.loads(detail)["errors"])
            except (ValueError, KeyError, TypeError):
                pass
            die("%s %s -> HTTP %d: %s" % (method, path.split("?")[0], e.code, detail))


# ---- App IDs -------------------------------------------------------------------

def bundle_id_base():
    with open(os.path.join(HERE, "..", "yougram-configuration.json")) as f:
        return json.load(f)["bundle_id"]


def find_bundle(client, identifier):
    query = urllib.parse.urlencode({"filter[identifier]": identifier, "filter[platform]": "IOS", "limit": 200})
    for item in client.request("GET", "/bundleIds?" + query).get("data", []):
        if item["attributes"]["identifier"] == identifier:
            return item
    return None


def cmd_setup(client, _args):
    base = bundle_id_base()
    for suffix, (_, name, capabilities) in TARGETS.items():
        identifier = base + suffix
        bundle = find_bundle(client, identifier)
        if bundle is None:
            bundle = client.request("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
                "identifier": identifier, "name": name, "platform": "IOS"}}})["data"]
            print("registered App ID %s" % identifier)
        else:
            print("App ID %s exists" % identifier)
        # This relationship takes no `limit` (HTTP 400); an App ID has only a few capabilities.
        existing = client.request("GET", "/bundleIds/%s/bundleIdCapabilities" % bundle["id"]).get("data", [])
        enabled = {c["attributes"]["capabilityType"] for c in existing}
        for capability in capabilities:
            if capability in enabled:
                continue
            client.request("POST", "/bundleIdCapabilities", {"data": {
                "type": "bundleIdCapabilities", "attributes": {"capabilityType": capability},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}}}}})
            print("  enabled %s" % capability)
    print("""
Done. Two steps the App Store Connect API can't do, once, on developer.apple.com:
  1. Certificates, Identifiers & Profiles > Identifiers > + > App Groups:
     register  group.{base}
  2. For each of these App IDs: open it > App Groups > Configure > tick group.{base} > Save:
     {ids}
And for TestFlight: App Store Connect > Apps > + > New App, bundle ID {base}.""".format(
        base=base, ids="\n     ".join(base + s for s in TARGETS)))


# ---- signing ---------------------------------------------------------------------

def _run(*args):
    p = subprocess.run(list(args), capture_output=True, text=True)
    if p.returncode != 0:
        die("%s failed: %s" % (" ".join(args[:3]), p.stderr.strip()))
    return p.stdout


# The .p12 only lives on the runner for one build. It has a password because macOS `security
# import` silently imports nothing from an empty-password PKCS#12 (run 43637857707: the build then
# failed at set-key-partition-list, "The specified item could not be found in the keychain").
P12_PASSWORD = "yougram-ci"


def _make_p12(key_pem, cert_pem, out_path):
    """A PKCS#12 macOS `security import` reads: SHA1/3DES, as Keychain Access writes them.

    OpenSSL 3's defaults (AES, PBKDF2, a SHA-256 MAC) are not readable on every macOS, and the
    `openssl` on PATH may be OpenSSL 3 (Homebrew) or LibreSSL (/usr/bin), which lacks -macalg
    and -legacy, so the variants are tried in order.
    """
    base = ["openssl", "pkcs12", "-export", "-inkey", key_pem, "-in", cert_pem, "-out", out_path,
            "-name", "Yougram CI", "-passout", "pass:" + P12_PASSWORD]
    pbe = ["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES"]
    errors = []
    for extra in (pbe + ["-macalg", "sha1"], pbe, ["-legacy"]):
        p = subprocess.run(base + extra, capture_output=True, text=True)
        if p.returncode == 0:
            return
        errors.append(p.stderr.strip())
    die("openssl pkcs12 -export failed:\n" + "\n".join(errors))


def cmd_prepare(client, args):
    base = bundle_id_base()
    out = args.out
    os.makedirs(os.path.join(out, "profiles"), exist_ok=True)
    os.makedirs(os.path.join(out, "certs"), exist_ok=True)
    state_path = os.path.join(out, "state.json")
    state = {"certificate": None, "profiles": [], "team_id": None}

    def save_state():
        with open(state_path, "w") as f:
            json.dump(state, f)

    bundles = {}
    for suffix in TARGETS:
        bundle = find_bundle(client, base + suffix)
        if bundle is None:
            die("App ID %s isn't registered: run the \"App Store setup\" workflow first" % (base + suffix))
        bundles[suffix] = bundle
    state["team_id"] = bundles[""]["attributes"]["seedId"]
    save_state()

    # Certificate: key and CSR made here; the key never leaves the runner.
    work = tempfile.mkdtemp()
    key_pem, csr_pem, cert_pem = (os.path.join(work, n) for n in ("key.pem", "csr.pem", "cert.pem"))
    _run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key_pem,
         "-subj", "/CN=Yougram CI/O=Yougram", "-out", csr_pem)
    with open(csr_pem) as f:
        csr = f.read()
    certificate = client.request("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr}}})["data"]
    state["certificate"] = certificate["id"]
    save_state()
    der = base64.b64decode(certificate["attributes"]["certificateContent"])
    with open(cert_pem, "w") as f:
        f.write("-----BEGIN CERTIFICATE-----\n")
        encoded = base64.b64encode(der).decode()
        f.write("\n".join(encoded[i:i + 64] for i in range(0, len(encoded), 64)) + "\n")
        f.write("-----END CERTIFICATE-----\n")
    _make_p12(key_pem, cert_pem, os.path.join(out, "certs", "Signing.p12"))
    for path in (key_pem, csr_pem, cert_pem):
        os.remove(path)
    os.rmdir(work)
    print("created certificate %s (%s)" % (certificate["id"], certificate["attributes"].get("name", "")))

    # One App Store profile per App ID, named so a leftover is recognisable.
    for suffix, (file_name, _, _) in TARGETS.items():
        profile = client.request("POST", "/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": "Yougram CI %s %s" % (args.label, file_name), "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundles[suffix]["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
            }}})["data"]
        state["profiles"].append(profile["id"])
        save_state()
        with open(os.path.join(out, "profiles", file_name + ".mobileprovision"), "wb") as f:
            f.write(base64.b64decode(profile["attributes"]["profileContent"]))
        print("created profile for %s" % (base + suffix))
    print("team id %s" % state["team_id"])


def cmd_cleanup(client, args):
    try:
        with open(os.path.join(args.out, "state.json")) as f:
            state = json.load(f)
    except OSError:
        print("nothing to clean up")
        return
    for profile_id in state.get("profiles", []):
        client.request("DELETE", "/profiles/" + profile_id, allow_missing=True)
        print("deleted profile %s" % profile_id)
    if state.get("certificate"):
        client.request("DELETE", "/certificates/" + state["certificate"], allow_missing=True)
        print("revoked certificate %s" % state["certificate"])


# ---- TestFlight ------------------------------------------------------------------

def cmd_wait_build(client, args):
    base = bundle_id_base()
    apps = client.request("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": base})).get("data", [])
    app = next((a for a in apps if a["attributes"]["bundleId"] == base), None)
    if app is None:
        die("no App Store Connect app for %s (Apps > + > New App)" % base)
    query = urllib.parse.urlencode({"filter[app]": app["id"], "filter[version]": args.build_number, "limit": 1})
    deadline = time.time() + args.minutes * 60
    last = None
    while True:
        builds = client.request("GET", "/builds?" + query).get("data", [])
        state = builds[0]["attributes"]["processingState"] if builds else "NOT YET LISTED"
        if state != last:
            print("%s build %s: %s" % (time.strftime("%H:%M:%S"), args.build_number, state), flush=True)
            last = state
        if state == "VALID":
            print("Build %s is processed and ready in TestFlight." % args.build_number)
            return
        if state in ("INVALID", "FAILED"):
            die("Apple rejected build %s while processing it. The reasons are emailed to the account "
                "holder (subject \"App Store Connect: ... has one or more issues\")." % args.build_number)
        if time.time() > deadline:
            print("::warning title=TestFlight::Build %s is still %s after %d minutes; check App Store Connect."
                  % (args.build_number, state, args.minutes))
            return
        time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("setup")
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--out", required=True)
    prepare.add_argument("--label", default=str(int(time.time())), help="goes into the profile names")
    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--out", required=True)
    wait_build = sub.add_parser("wait-build")
    wait_build.add_argument("--build-number", required=True, help="CFBundleVersion of the upload")
    wait_build.add_argument("--minutes", type=int, default=40)
    args = parser.parse_args()
    client = Client()
    {"setup": cmd_setup, "prepare": cmd_prepare, "cleanup": cmd_cleanup,
     "wait-build": cmd_wait_build}[args.command](client, args)


if __name__ == "__main__":
    main()
