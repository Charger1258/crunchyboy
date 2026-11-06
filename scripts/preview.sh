#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for a in d["devices"].values() for v in a if v.get("isAvailable") and v["name"].startswith("iPhone")]; print(ids[0] if ids else "")')"
test -n "$DEVICE_ID" || { echo 'No available iPhone simulator for the preview.'; exit 1; }
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$PWD/build/simulator/Build/Products/Debug-iphonesimulator/StreamAnime.app"
xcrun simctl launch "$DEVICE_ID" com.streamanime.iphone
sleep 3
mkdir -p build/artifacts
xcrun simctl io "$DEVICE_ID" screenshot "$PWD/build/artifacts/iphone-preview.png"
