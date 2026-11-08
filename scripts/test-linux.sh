#!/usr/bin/env bash
# Isolated loopback sshd, reusing only the Android fixture's dedicated test account.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${ROAMTTY_FIXTURE_ROOT:-/tmp/roamtty-ios-ssh-$(id -u)}"
ANDROID="${ROAMTTY_ANDROID_ROOT:-$ROOT/../roamtty}"
SWIFT="${ROAMTTY_SWIFT:-swift}"
PORT="${ROAMTTY_TEST_PORT:-22992}"
BIND="${ROAMTTY_TEST_BIND:-127.0.0.1}"
mkdir -p "$FIXTURE"
if ! id itermux_test >/dev/null 2>&1; then
  echo 'Create the dedicated Android OpenSSH fixture before running live tests.' >&2; exit 1
fi
if [ ! -f "$FIXTURE/host" ]; then ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE/host"; fi
cat > "$FIXTURE/config" <<CONFIG
Port $PORT
ListenAddress $BIND
HostKey $FIXTURE/host
PidFile $FIXTURE/pid
AuthorizedKeysFile $ANDROID/ssh-core/src/test/resources/keys/authorized_keys
StrictModes no
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
AllowUsers itermux_test
AllowTcpForwarding no
X11Forwarding no
PrintMotd no
PrintLastLog no
Subsystem sftp internal-sftp
LogLevel ERROR
CONFIG
# Do not write into the Android repository. Public fixture keys are copied into this private workspace.
cat "$ANDROID"/ssh-core/src/test/resources/keys/*.pub > "$FIXTURE/authorized_keys"
python3 - "$FIXTURE/config" "$FIXTURE/authorized_keys" <<'PY'
import sys
p,keys=sys.argv[1:]
s=open(p).read().splitlines()
open(p,'w').write('\n'.join('AuthorizedKeysFile '+keys if x.startswith('AuthorizedKeysFile ') else x for x in s)+'\n')
PY
chmod 755 "$FIXTURE"
chmod 644 "$FIXTURE/authorized_keys"
sudo -n /usr/sbin/sshd -t -f "$FIXTURE/config"
sudo -n /usr/sbin/sshd -f "$FIXTURE/config" -E "$FIXTURE/log"
cleanup() { if [ -f "$FIXTURE/pid" ]; then sudo -n kill "$(cat "$FIXTURE/pid")" 2>/dev/null || true; fi; }
trap cleanup EXIT
export ROAMTTY_TEST_PASSWORD_FILE="$ANDROID/.private/test-password"
export ROAMTTY_TEST_PORT="$PORT"
export ROAMTTY_TEST_KEYS="$ANDROID/ssh-core/src/test/resources/keys"
if [ "${1:-}" = --serve ]; then
  DURATION="${ROAMTTY_FIXTURE_SECONDS:-3600}"
  [[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION > 0 && DURATION <= 14400 )) || { echo 'Fixture lifetime must be 1–14400 seconds.' >&2; exit 1; }
  echo "Dedicated test-account fixture ready on $BIND:$PORT (expires after $DURATION seconds)."
  sleep "$DURATION"
  exit 0
fi
"$SWIFT" test "$@"
