#!/bin/bash
# Import the App Store signing identity made by build-system/yougram-signing/asc.py into a
# temporary keychain that codesign can use without a prompt, and fail unless it is there.
#
# Usage: import_signing_identity.sh <Signing.p12> <p12 password>
#
# build-system/Make/ImportCertificates.py does the same for the placeholder certificates, but
# with an empty p12 password and without checking that `security import` worked, so a p12 it
# cannot read only shows up later as an unrelated-looking set-key-partition-list error.
set -euo pipefail

P12="$1"
P12_PASSWORD="$2"
KEYCHAIN=temp.keychain   # the name ImportCertificates.py and the cleanup step use
KEYCHAIN_PASSWORD=secret

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# No auto-lock: the build signs hours after this step.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# shellcheck disable=SC2046 # one word per keychain path
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
# The intermediate that issues Apple Distribution certificates, so codesign embeds the chain.
security import build-system/AppleWWDRCAG3.cer -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "Signing identities in $KEYCHAIN:"
security find-identity -p codesigning "$KEYCHAIN"
if ! security find-identity -p codesigning "$KEYCHAIN" | grep -q 'Apple Distribution'; then
  echo "::error title=Signing::No Apple Distribution identity in $KEYCHAIN after importing $P12"
  exit 1
fi
