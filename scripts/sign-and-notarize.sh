#!/bin/zsh
# Signs Arbor.app with a Developer ID certificate, notarizes it, staples the ticket and zips it.
#
#   scripts/sign-and-notarize.sh path/to/Arbor.app path/to/Arbor-x.y.z.zip
#
# Needs, in the environment:
#   SIGN_IDENTITY     e.g. "Developer ID Application: Kitta Ltd (7P8CLHDH5G)" (in an unlocked keychain)
#   NOTARY_KEY_PATH   App Store Connect API key (.p8) used by notarytool
#   NOTARY_KEY_ID     its key ID
#   NOTARY_ISSUER     its issuer ID
set -euo pipefail

APP="$1"
ZIP="$2"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}"

sign() {
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"
}

# Sparkle's helpers first (inside out), keeping the XPC services' own entitlements, as Sparkle documents.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
    sign --preserve-metadata=entitlements "$xpc"
  done
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
fi
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# The final zip carries the stapled app.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Signed${NOTARY_KEY_PATH:+ and notarized}: $ZIP"
