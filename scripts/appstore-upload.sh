#!/bin/zsh
# Archives the sandboxed "Arbor App Store" target and uploads it to App Store Connect.
#
#   VERSION=0.3.0 BUILD=12 scripts/appstore-upload.sh
#
# Needs: the team's Apple Distribution and Mac Installer Distribution certificates in the keychain,
# a Mac App Store provisioning profile for io.github.iebb.arbor, an app record in App Store Connect,
# and an App Store Connect API key (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER).
set -euo pipefail
: "${VERSION:?}" "${BUILD:?}" "${TEAM_ID:=7P8CLHDH5G}" "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER:?}"
ARCHIVE=build/ArborAppStore.xcarchive

xcodegen generate
xcodebuild archive \
  -project Arbor.xcodeproj -scheme "Arbor App Store" -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Apple Distribution" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER"

cat > build/ExportOptions-AppStore.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions-AppStore.plist \
  -exportPath build/AppStoreExport -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER"
echo "Uploaded Arbor $VERSION ($BUILD) to App Store Connect."
