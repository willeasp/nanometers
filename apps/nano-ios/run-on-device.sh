#!/usr/bin/env bash
# Build NanoMeters and run it on a plugged-in (or same-Wi-Fi) iPhone.
# Free personal team: re-running this also refreshes the 7-day provisioning expiry.
#   ./apps/nano-ios/run-on-device.sh
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=com.willeasp.nanometers.ios
APP=build/DerivedData/Build/Products/Debug-iphoneos/NanoMeters.app

[ -d ../../crates/nano-dsp/NanoDSP.xcframework ] || ../../crates/nano-dsp/build-xcframework.sh

echo "==> Finding device"
xcrun devicectl list devices --json-output /tmp/nano-devs.json >/dev/null
UDID=$(python3 - <<'EOF'
import json, sys
devs = json.load(open('/tmp/nano-devs.json'))['result']['devices']
ok = [d for d in devs
      if d.get('connectionProperties', {}).get('tunnelState') in ('connected', 'available')]
if not ok:
    names = ', '.join(d['deviceProperties'].get('name', '?') for d in devs) or 'none paired'
    sys.exit(f"no reachable iPhone (paired: {names}) — plug it in and unlock it")
print(ok[0]['hardwareProperties']['udid'])
EOF
)
echo "    $UDID"

echo "==> Building (signed)"
xcodegen generate --quiet
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination "id=$UDID" -configuration Debug \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build/DerivedData build -quiet

echo "==> Installing + launching"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
echo "Done. If iOS says 'Untrusted Developer': Settings → General → VPN & Device Management → Trust."
