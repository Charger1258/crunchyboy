#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for a in d["devices"].values() for v in a if v.get("isAvailable") and v["name"].startswith("iPhone")]; print(ids[0] if ids else "")')"
test -n "$DEVICE_ID" || { echo 'No available iPhone simulator runtime. Install an iOS runtime in Xcode.'; exit 1; }
mkdir -p build
RESULT="$PWD/build/Tests-$(date +%s).xcresult"
export_attachments() {
  mkdir -p build/artifacts/screenshots
  find "$HOME/Library/Developer/CoreSimulator/Devices" -name player-diagnostics.log -exec cat {} \; > build/artifacts/screenshots/player-diagnostics.txt 2>&1 || true
  if [ -d "$RESULT" ]; then
    xcrun xcresulttool export attachments --path "$RESULT" --output-path "$PWD/build/artifacts/screenshots" || true
  fi
}
trap export_attachments EXIT
# Firebase plus two simultaneous simulator architectures can exhaust the M2 builder.
# Test the selected simulator architecture and bound concurrent compiler jobs.
xcodebuild test -jobs 2 -project StreamAnime.xcodeproj -scheme StreamAnime \
  -configuration Release \
  -parallel-testing-enabled NO \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath build/simulator \
  -resultBundlePath "$RESULT" CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES
