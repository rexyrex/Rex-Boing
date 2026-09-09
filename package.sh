#!/bin/bash
# Builds Release, signs with Developer ID + hardened runtime, notarizes with
# Apple, staples the ticket, and produces "dist/Rex Boing.zip" ready to
# distribute. This is the maintainer's release path; to just build and run
# the app locally, ./build.sh is enough.
#
# One-time prerequisites:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates… → "+").
#   2. An App Store Connect API key, described in notarize.env — copy
#      notarize.env.example to notarize.env (gitignored) and fill it in.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f notarize.env ]; then
    cat >&2 <<'MSG'
notarize.env not found.

Notarization needs an App Store Connect API key. Copy the template and fill
in your own Key ID, Issuer ID and key path:

    cp notarize.env.example notarize.env

notarize.env is gitignored; never commit it.
MSG
    exit 1
fi
# shellcheck source=notarize.env.example
source ./notarize.env
: "${ASC_KEY_ID:?ASC_KEY_ID is not set in notarize.env}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set in notarize.env}"
: "${ASC_KEY_P8:?ASC_KEY_P8 is not set in notarize.env}"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -z "${IDENTITY}" ]; then
    cat >&2 <<'MSG'
No "Developer ID Application" certificate found in your keychain.

Create one (one time only):
  Xcode → Settings → Accounts → select your team → Manage Certificates…
  → "+" (bottom left) → "Developer ID Application"

Then re-run this script.
MSG
    exit 1
fi
echo "==> Signing as: ${IDENTITY}"

# notarytool needs the bare .p8. If only fastlane's JSON wrapper is on disk,
# extract the key from it once.
if [ ! -f "${ASC_KEY_P8}" ]; then
    if [ -n "${ASC_KEY_JSON:-}" ] && [ -f "${ASC_KEY_JSON}" ]; then
        echo "==> Extracting ${ASC_KEY_P8} from ${ASC_KEY_JSON}"
        umask 077
        jq -r '.key' "${ASC_KEY_JSON}" > "${ASC_KEY_P8}"
    else
        echo "API key not found at ${ASC_KEY_P8} (set ASC_KEY_P8 in notarize.env)" >&2
        exit 1
    fi
fi

./build.sh

APP="dist/Rex Boing.app"
ZIP="dist/Rex Boing.zip"

# A failed run must not leave an unnotarized, unstapled zip sitting at the
# exact path the success message says to send to people.
trap 'rm -f "${ZIP}"' ERR

echo "==> Codesigning"
codesign --force --options runtime --timestamp \
    --entitlements RexBoing/RexBoing.entitlements \
    --sign "${IDENTITY}" "${APP}"
codesign --verify --strict --verbose=2 "${APP}"

echo "==> Notarizing (usually takes 1-5 minutes)"
ditto -c -k --keepParent "${APP}" "${ZIP}"
xcrun notarytool submit "${ZIP}" \
    --key "${ASC_KEY_P8}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
    --wait
# If the submission comes back "Invalid", fetch details with:
#   xcrun notarytool log <submission-id> \
#     --key "$ASC_KEY_P8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"

# Stapling fails unless notarization actually succeeded, so it doubles as the gate.
echo "==> Stapling"
xcrun stapler staple "${APP}"

rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo
echo "Done: ${ZIP} — this is the file to attach to a GitHub release."
