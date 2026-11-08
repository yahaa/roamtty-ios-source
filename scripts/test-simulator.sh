#!/usr/bin/env bash
# Run the native UI suite against a real, explicitly configured SSH fixture.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FIXTURE_JSON="${ROAMTTY_FIXTURE_JSON:-$ROOT/.private/device-fixture.json}"
RECOVERY_JSON="${ROAMTTY_RECOVERY_JSON:-$ROOT/.private/recovery-environment.json}"
PLUGIN_JSON="${ROAMTTY_PLUGIN_JSON:-$ROOT/.private/plugin-environment.json}"
TEST_KEY="${ROAMTTY_TEST_ENCRYPTED_KEY:-$ROOT/../roamtty/ssh-core/src/test/resources/keys/ed25519}"
TEST_FONT="${ROAMTTY_TEST_FONT:-/System/Library/Fonts/Supplemental/Andale Mono.ttf}"
for required in "$FIXTURE_JSON" "$TEST_KEY" "$TEST_FONT"; do
  if [ ! -f "$required" ]; then
    echo "Required fixture file is missing: $required" >&2
    exit 1
  fi
done

SIMULATOR="${ROAMTTY_TEST_SIMULATOR:-}"
if [ -z "$SIMULATOR" ]; then
  SIMULATOR="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next((d["udid"] for group in devices.values() for d in group if d["name"] == "Roamtty Validation"), ""))
')"
fi
if [ -z "$SIMULATOR" ]; then
  RUNTIME="${ROAMTTY_SIM_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
print(max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"])
')}"
  SIMULATOR="$(xcrun simctl create 'Roamtty Validation' "${ROAMTTY_SIM_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}" "$RUNTIME")"
fi
# Start from a fresh boot: a long-running simulator can stop rotating the app window
# (the device reports landscape, the window stays portrait), failing every landscape test.
xcrun simctl shutdown "$SIMULATOR" >/dev/null 2>&1 || true
xcrun simctl boot "$SIMULATOR" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR" -b
python3 scripts/generate-project.py
mkdir -p TestResults
RUN="TestResults/Simulator-$(date -u +%Y%m%d-%H%M%S)"
echo "Building and testing on $SIMULATOR. Logs and results: $RUN"
xcodebuild -project Roamtty.xcodeproj -scheme Roamtty \
  -destination "id=$SIMULATOR" -derivedDataPath DerivedData \
  build-for-testing CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- > "$RUN-build.log" 2>&1
xcrun simctl install "$SIMULATOR" DerivedData/Build/Products/Debug-iphonesimulator/Roamtty.app
CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR" com.roamtty.app.ios data)"
mkdir -p "$CONTAINER/Documents"
cp "$TEST_KEY" "$CONTAINER/Documents/roamtty-ui-encrypted-key.txt"
cp "$TEST_FONT" "$CONTAINER/Documents/roamtty-ui-custom-font.ttf"
python3 - "$CONTAINER/Documents" <<'PY'
from pathlib import Path
import sys
documents = Path(sys.argv[1])
fixture = documents / "roamtty-ui-folder"
(fixture / "nested").mkdir(parents=True, exist_ok=True)
(fixture / "readme.txt").write_text("Roamtty native folder fixture\n")
(fixture / "nested" / "bytes.bin").write_bytes(bytes(range(256)))
(documents / "roamtty-ui-downloads").mkdir(exist_ok=True)
(documents / "roamtty-ui-invalid-font.ttf").write_text("This is an intentionally invalid font fixture.\n")
PY
xcrun simctl addmedia "$SIMULATOR" App/Roamtty/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
TEST_RUN="$(python3 -c 'from pathlib import Path; print(max(Path("DerivedData/Build/Products").glob("Roamtty_iphonesimulator*.xctestrun"), key=lambda p: p.stat().st_mtime))')"
EXTRA_FIXTURES=()
for fixture in "$RECOVERY_JSON" "$PLUGIN_JSON"; do
  if [ -f "$fixture" ]; then EXTRA_FIXTURES+=("$fixture"); fi
done
# Focused classes can run independently. Recovery and plugin tests fail clearly
# when their real service fixtures are absent; they never silently skip.
python3 scripts/configure-ui-fixture.py "$TEST_RUN" "$FIXTURE_JSON" ${EXTRA_FIXTURES[@]+"${EXTRA_FIXTURES[@]}"}
# XCTest records typed passwords. Keep the full log private instead of echoing it.
umask 077
STATUS=0
xcodebuild test-without-building -xctestrun "$TEST_RUN" \
  -destination "id=$SIMULATOR" -resultBundlePath "$RUN.xcresult" \
  -parallel-testing-enabled NO "$@" > "$RUN-ui.log" 2>&1 || STATUS=$?
python3 - "$RUN-ui.log" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if line.startswith("Test Case ") or line.lstrip().startswith("Executed ") or line.startswith("** TEST"):
        print(line)
PY
exit "$STATUS"
