#!/usr/bin/env bash
# Run DesktopGestureUITests on the simulator against a live desktop host (Ubuntu, Windows or macOS
# with roamtty-desktop): real touches on the page, their input read back, the host's picture checked.
#   scripts/test-desktop-gestures.sh host.json [testName ...]
# host.json holds "host", "port", "username" and "password" of a disposable desktop host. Without test
# names it runs the whole class. ROAMTTY_TAP_POINTS="x,y;dx,y" (fractions of the host's screen, "d" for a
# double tap) is where testTapHostPoints taps. Builds for testing first unless ROAMTTY_SKIP_BUILD=1.
# Some tests drive the host itself (Show Desktop, ⌃⌘F, typing its password at the lock screen): see each
# test's comment before running one against a machine in use.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOST_JSON="${1:?usage: scripts/test-desktop-gestures.sh host.json [testName ...]}"
shift
[ -f "$HOST_JSON" ] || { echo "No such host file: $HOST_JSON" >&2; exit 1; }
SIMULATOR="${ROAMTTY_TEST_SIMULATOR:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next((d["udid"] for group in devices.values() for d in group if d["name"] == "Roamtty Validation"), ""))
')}"
[ -n "$SIMULATOR" ] || { echo "Create the 'Roamtty Validation' simulator (scripts/test-simulator.sh does) or set ROAMTTY_TEST_SIMULATOR" >&2; exit 1; }
xcrun simctl boot "$SIMULATOR" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR" -b >/dev/null
mkdir -p TestResults
RUN="TestResults/DesktopGestures-$(basename "$HOST_JSON" .json)-$(date -u +%Y%m%d-%H%M%S)"
if [ "${ROAMTTY_SKIP_BUILD:-0}" != 1 ]; then
  python3 scripts/generate-project.py >/dev/null
  xcodebuild -project Roamtty.xcodeproj -scheme Roamtty -destination "id=$SIMULATOR" -derivedDataPath DerivedData \
    build-for-testing CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- > "$RUN-build.log" 2>&1
fi
BUILT="$(python3 -c 'from pathlib import Path; print(max(Path("DerivedData/Build/Products").glob("Roamtty_iphonesimulator*.xctestrun"), key=lambda p: p.stat().st_mtime))')"
# __TESTROOT__ is the xctestrun's own folder: the configured copy stays beside it.
TEST_RUN="DerivedData/Build/Products/desktop-gestures.xctestrun"
cp "$BUILT" "$TEST_RUN"
EXTRA="$(mktemp)"
trap 'rm -f "$EXTRA" "$TEST_RUN"' EXIT
python3 - "$EXTRA" <<'PY'
import json, os, sys
extra = {"ROAMTTY_DESKTOP_GESTURE_HOST": "1"}
if os.environ.get("ROAMTTY_TAP_POINTS"):
    extra["ROAMTTY_TAP_POINTS"] = os.environ["ROAMTTY_TAP_POINTS"]
open(sys.argv[1], "w").write(json.dumps(extra))
PY
python3 scripts/configure-ui-fixture.py "$TEST_RUN" "$HOST_JSON" "$EXTRA" >/dev/null
ONLY=(-only-testing:RoamttyUITests/DesktopGestureUITests)
if [ $# -gt 0 ]; then
  ONLY=()
  for test in "$@"; do ONLY+=("-only-testing:RoamttyUITests/DesktopGestureUITests/$test"); done
fi
STATUS=0
xcodebuild test-without-building -xctestrun "$TEST_RUN" -destination "id=$SIMULATOR" -resultBundlePath "$RUN.xcresult" \
  "${ONLY[@]}" > "$RUN-ui.log" 2>&1 || STATUS=$?
echo "Results: $RUN.xcresult"
grep -E "^Test Case .*(passed|failed|skipped)|error: |^\s+Executed " "$RUN-ui.log" | sort -u || true
exit "$STATUS"
