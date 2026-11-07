#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen first: brew install xcodegen'; exit 1; }
xcodegen generate --spec project.yml
xcodebuild -project StreamAnime.xcodeproj -scheme StreamAnime -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
APP="$PWD/build/device/Build/Products/Release-iphoneos/StreamAnime.app"
xcrun lipo "$APP/StreamAnime" -verify_arch arm64
rm -f "$APP/player-test.mp4"
# Preserve the shared-container entitlement in the binaries for SideStore to
# discover and re-sign with the user's provisioning profiles.
codesign --force --sign - --entitlements StreamAnime.entitlements "$APP/PlugIns/QueueWidget.appex"
codesign --force --sign - --entitlements StreamAnime.entitlements "$APP"
cp StreamAnime.entitlements "$APP/archived-expanded-entitlements.xcent"
python3 scripts/package_ipa.py "$APP" "$PWD/build/artifacts/StreamAnime-unsigned.ipa"
echo 'Unsigned device IPA is ready for SideStore. No Apple account or signing credentials were used.'
