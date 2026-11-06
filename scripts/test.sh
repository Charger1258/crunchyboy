#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for a in d["devices"].values() for v in a if v.get("isAvailable") and v["name"].startswith("iPhone")]; print(ids[0] if ids else "")')"
test -n "$DEVICE_ID" || { echo 'No available iPhone simulator runtime. Install an iOS runtime in Xcode.'; exit 1; }
mkdir -p build
RESULT="$PWD/build/Tests-$(date +%s).xcresult"
xcodebuild test -project StreamAnime.xcodeproj -scheme StreamAnime \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath build/simulator \
  -resultBundlePath "$RESULT" CODE_SIGNING_ALLOWED=NO
