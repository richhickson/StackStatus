#!/bin/bash
# Notarise and staple build/export/StackStatus.app, then zip it to dist/.
#
# Credentials, one of:
#   NOTARY_PROFILE      a keychain profile made with `xcrun notarytool store-credentials`
#                       (default: StackStatus)
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID   an App Store Connect API key
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/export/StackStatus.app
test -d "$APP" || { echo "run Scripts/build.sh first" >&2; exit 1; }

mkdir -p dist
UPLOAD=build/StackStatus-notarize.zip
rm -f "$UPLOAD"
ditto -c -k --keepParent "$APP" "$UPLOAD"

if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-StackStatus}")
fi

xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f dist/StackStatus.zip
ditto -c -k --keepParent "$APP" dist/StackStatus.zip
shasum -a 256 dist/StackStatus.zip | tee dist/StackStatus.zip.sha256
echo "Notarised and stapled: dist/StackStatus.zip"
