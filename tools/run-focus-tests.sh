#!/usr/bin/env bash
# App-hosted tvOS focus tests. Package logic tests do not have an application scene.
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"

source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "plozz/focus-tests"
install_apple_build_lease_traps
source tools/lib/swift-package-storage.sh
configure_plozz_package_resolution "${PLOZZ_FOCUS_PACKAGES:-$PWD/.build/package-workspaces/focus-tests}"

if [[ ! -f Plozz.xcodeproj/project.pbxproj ]]; then
  tools/generate-project.sh
fi
if [[ -z "${PLOZZ_SIM_ID:-}" ]]; then
  PLOZZ_SIM_ID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devices=[d for runtime,items in json.load(sys.stdin)["devices"].items()
         if "tvOS" in runtime for d in items if d.get("isAvailable")]
devices.sort(key=lambda d: d.get("state") != "Booted")
if not devices: sys.exit("No available tvOS simulator")
print(devices[0]["udid"])
')"
fi
python3 tools/run-bounded.py 300 "focus simulator startup" -- \
  xcrun simctl bootstatus "$PLOZZ_SIM_ID" -b

RESULTS="${PLOZZ_FOCUS_RESULTS:-$PWD/.build/focus-test-results}"
mkdir -p "$RESULTS"
RUN_DIR="$(mktemp -d "$RESULTS/Run-XXXXXXXX")"
set +e
python3 tools/run-bounded.py "${PLOZZ_FOCUS_TEST_TIMEOUT:-1200}" "hosted focus tests" -- \
  xcodebuild test -quiet -project Plozz.xcodeproj -scheme PlozzFocusTests \
  -destination "platform=tvOS Simulator,id=$PLOZZ_SIM_ID" \
  -parallel-testing-enabled NO \
  -derivedDataPath "${PLOZZ_FOCUS_DERIVED_DATA:-$PWD/.build/focus-test-derived-data}" \
  -resultBundlePath "$RUN_DIR/Test.xcresult" \
  "${PACKAGE_RESOLUTION_ARGS[@]}" CODE_SIGNING_ALLOWED=NO
STATUS=$?
set -e
echo "Focus result bundle: $RUN_DIR/Test.xcresult"
python3 tools/run-bounded.py 30 "focus result summary" -- \
  xcrun xcresulttool get test-results summary --path "$RUN_DIR/Test.xcresult" > "$RUN_DIR/summary.json"
python3 tools/xcresult-summary.py verdict "$RUN_DIR/summary.json"
exit "$STATUS"
