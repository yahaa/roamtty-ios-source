#!/usr/bin/env bash
# Run the UI suite's SSH fixture in a Docker container on the Mac, so the simulator does not need another machine.
# Usage: scripts/serve-container-fixture.sh [start|stop]
# start reuses the test account's password from .private/device-fixture.json and writes
# .private/container-fixture.json; run the suite with ROAMTTY_FIXTURE_JSON pointing at it.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-$(command -v docker || echo /usr/local/bin/docker)}"
NAME=roamtty-ssh-fixture
PORT="${ROAMTTY_CONTAINER_PORT:-22993}"
# mosh-server picks the first free UDP port from 60001; a small range covers the suite's sessions.
MOSH_PORTS="${ROAMTTY_CONTAINER_MOSH_PORTS:-60001-60040}"
SOURCE="${ROAMTTY_FIXTURE_SOURCE:-$ROOT/.private/device-fixture.json}"
SECRETS="$ROOT/.private/container-fixture"
OUTPUT="$ROOT/.private/container-fixture.json"

if [ "${1:-start}" = stop ]; then "$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true; exit 0; fi
"$DOCKER" info >/dev/null 2>&1 || { echo "Docker is not running; start Docker Desktop first." >&2; exit 1; }
mkdir -p "$SECRETS"
python3 - "$SOURCE" "$SECRETS/password" "$OUTPUT" "$PORT" <<'PY'
import json, sys
source, password, output, port = sys.argv[1:]
fixture = json.load(open(source))
open(password, "w").write(fixture["password"])
json.dump({"host": "127.0.0.1", "port": int(port), "username": "itermux_test", "password": fixture["password"]}, open(output, "w"))
PY
# The Android fixture's public keys, when present, let key-based tests log in too.
KEYS="${ROAMTTY_FIXTURE_KEYS:-$ROOT/../roamtty/ssh-core/src/test/resources/keys}"
cat "$KEYS"/*.pub > "$SECRETS/authorized_keys" 2>/dev/null || : > "$SECRETS/authorized_keys"
chmod 755 "$SECRETS"; chmod 644 "$SECRETS/password" "$SECRETS/authorized_keys"
"$DOCKER" build -q -t "$NAME" "$ROOT/scripts/container-fixture" >/dev/null
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
"$DOCKER" run -d --name "$NAME" -p "127.0.0.1:$PORT:22" -p "127.0.0.1:$MOSH_PORTS:$MOSH_PORTS/udp" \
  -v "$SECRETS:/run/fixture:ro" "$NAME" >/dev/null
# Docker's port proxy accepts connections even when sshd has died, so wait for the SSH banner itself.
for _ in $(seq 1 30); do nc -w 2 127.0.0.1 "$PORT" </dev/null 2>/dev/null | grep -q "^SSH-2.0" && { echo "Fixture container ready on 127.0.0.1:$PORT; settings in $OUTPUT"; exit 0; }; sleep 1; done
echo "The fixture container did not start listening:" >&2; "$DOCKER" logs "$NAME" >&2; exit 1
