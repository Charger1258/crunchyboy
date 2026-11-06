#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for a in d["devices"].values() for v in a if v.get("isAvailable") and v["name"].startswith("iPhone")))')"
mkdir -p build/artifacts/screenshots
xcodebuild build -project StreamAnime.xcodeproj -scheme StreamAnime -configuration Release -sdk iphonesimulator -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$PWD/build/simulator/Build/Products/Release-iphonesimulator/StreamAnime.app"
LAUNCH="$(xcrun simctl launch "$DEVICE_ID" com.streamanime.iphone --player-ui-test)"
PID="${LAUNCH##*: }"
sleep 8
sample "$PID" 2 -file "$PWD/build/artifacts/screenshots/player-sample.txt" || true
xcrun simctl io "$DEVICE_ID" screenshot "$PWD/build/artifacts/screenshots/player-diagnostic.png"
find "$HOME/Library/Developer/CoreSimulator/Devices" -name player-diagnostics.log -exec cat {} \; > build/artifacts/screenshots/player-diagnostics.txt
cat build/artifacts/screenshots/player-diagnostics.txt
