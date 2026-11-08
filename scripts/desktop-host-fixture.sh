#!/usr/bin/env bash
# Loopback desktop host for iOS RoamttyDesktopCore / SSHDesktopHost tests.
# Pins roamtty-desktop 0.8.2 (same as Sources/RoamttyDesktopCore/Resources/desktop-plugin.json).
#
# Usage:
#   scripts/desktop-host-fixture.sh start|stop|status|env
#
# After `start`, source the printed env (or run `eval "$(scripts/desktop-host-fixture.sh env)"`)
# then `swift test --filter UdpPluginIntegrationTests` / `DesktopSessionPluginTests`,
# or with SSH: `scripts/test-linux.sh --filter SSHDesktopHostTests` and ROAMTTY_TEST_DESKTOP_SSH=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="${ROAMTTY_DESKTOP_DIR:-/workspace/desktop-plugin}"
BIN="${ROAMTTY_DESKTOP_BIN:-$PLUGIN_DIR/roamtty-desktop}"
HOME_DIR="${ROAMTTY_DESKTOP_HOME:-$PLUGIN_DIR/home}"
DISPLAY_N="${ROAMTTY_DESKTOP_DISPLAY:-91}"
DISPLAY_VAL=":$DISPLAY_N"
PID_DIR="${ROAMTTY_DESKTOP_PIDDIR:-/tmp/roamtty-ios-desktop-fixture}"
XVFB_PID="$PID_DIR/xvfb.pid"
XTERM_PID="$PID_DIR/typing.pid"
HTTP_PID="$PID_DIR/http.pid"
MANIFEST="$ROOT/Sources/RoamttyDesktopCore/Resources/desktop-plugin.json"
EXPECTED_SHA="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['targets']['linux-x86_64']['sha256'])")"
EXPECTED_VER="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['version'])")"

need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }

verify_pin() {
  need sha256sum
  [ -x "$BIN" ] || { echo "plugin binary missing: $BIN" >&2; exit 1; }
  local ver sha
  ver="$("$BIN" --version 2>/dev/null | head -n1)"
  sha="$(sha256sum "$BIN" | awk '{print $1}')"
  echo "plugin: $ver"
  echo "sha256: $sha (manifest linux-x86_64 expects $EXPECTED_SHA)"
  case "$ver" in
    *" $EXPECTED_VER "*) ;;
    *) echo "WARN: version string '$ver' does not contain $EXPECTED_VER" >&2 ;;
  esac
  [ "$sha" = "$EXPECTED_SHA" ] || { echo "ERROR: binary sha256 mismatch vs PluginManifest" >&2; exit 1; }
}

ensure_home() {
  mkdir -p "$HOME_DIR/.roamtty/bin" "$HOME_DIR/.roamtty/desktop/lib" "$PID_DIR"
  # Installer / LocalShellHost look under $HOME/.roamtty/bin/roamtty-desktop
  if ! cmp -s "$BIN" "$HOME_DIR/.roamtty/bin/roamtty-desktop" 2>/dev/null; then
    cp -f "$BIN" "$HOME_DIR/.roamtty/bin/roamtty-desktop"
    chmod 755 "$HOME_DIR/.roamtty/bin/roamtty-desktop"
  fi
  # OpenH264 2.6.0 (plugin pin): keep whatever is already under desktop/lib; do not redownload here.
  if ! ls "$HOME_DIR/.roamtty/desktop/lib"/libopenh264*.so >/dev/null 2>&1; then
    echo "WARN: no OpenH264 under $HOME_DIR/.roamtty/desktop/lib — serve may fail until installed" >&2
  fi
}

start_xvfb() {
  if [ -S "/tmp/.X11-unix/X$DISPLAY_N" ]; then
    echo "Xvfb already on $DISPLAY_VAL"
    return
  fi
  need Xvfb
  # Match Android e2e size; -ac so LocalShellHost / SSH clients can attach without xauth.
  setsid Xvfb "$DISPLAY_VAL" -screen 0 1280x800x24 -ac +extension GLX +render -noreset \
    >/tmp/roamtty-ios-xvfb.log 2>&1 < /dev/null &
  echo $! > "$XVFB_PID"
  for _ in $(seq 1 40); do [ -S "/tmp/.X11-unix/X$DISPLAY_N" ] && break; sleep 0.1; done
  [ -S "/tmp/.X11-unix/X$DISPLAY_N" ] || { echo "Xvfb failed to start on $DISPLAY_VAL" >&2; exit 1; }
  echo "Xvfb $DISPLAY_VAL pid $(cat "$XVFB_PID")"
}

start_typing_target() {
  # Something to type into so UDP loss / fallback tests keep getting frames (Android CI had a WM + xterm).
  if [ -f "$XTERM_PID" ] && kill -0 "$(cat "$XTERM_PID")" 2>/dev/null; then return; fi
  local term=""
  if [ -x /usr/bin/xterm ]; then term=/usr/bin/xterm
  elif [ -x /usr/bin/xfce4-terminal ]; then term=/usr/bin/xfce4-terminal
  elif [ -x /usr/bin/x-terminal-emulator ]; then term=/usr/bin/x-terminal-emulator
  else echo "no terminal emulator; UDP loss tests may starve for frames"; return; fi
  if [ "$term" = /usr/bin/xterm ]; then
    setsid env DISPLAY="$DISPLAY_VAL" HOME="$HOME_DIR" "$term" -geometry 100x30+0+0 -e cat \
      >/dev/null 2>&1 < /dev/null &
  else
    setsid env DISPLAY="$DISPLAY_VAL" HOME="$HOME_DIR" "$term" --disable-server --geometry=100x30+0+0 -e cat \
      >/dev/null 2>&1 < /dev/null &
  fi
  echo $! > "$XTERM_PID"
  echo "typing target: $term pid $(cat "$XTERM_PID")"
}

start_plugin_http() {
  # Optional: serve the local .gz so host-download install can hit loopback instead of GitHub.
  local gz="$PLUGIN_DIR/linux-x86_64.gz"
  [ -f "$gz" ] || return 0
  if [ -f "$HTTP_PID" ] && kill -0 "$(cat "$HTTP_PID")" 2>/dev/null; then return; fi
  (cd "$PLUGIN_DIR" && setsid python3 -m http.server 8797 --bind 127.0.0.1 >/tmp/roamtty-ios-plugin-http.log 2>&1 < /dev/null &)
  echo $! > "$HTTP_PID"
  echo "plugin HTTP: http://127.0.0.1:8797/linux-x86_64.gz"
}

print_env() {
  cat <<ENV
export ROAMTTY_DESKTOP_BIN='$BIN'
export ROAMTTY_DESKTOP_HOME='$HOME_DIR'
export ROAMTTY_DESKTOP_GZ='$PLUGIN_DIR/linux-x86_64.gz'
export DISPLAY='$DISPLAY_VAL'
# Do not export HOME=… (breaks the Swift toolchain). Tests set HOME per process.
# SSH E2E: itermux_test@127.0.0.1:22228 with Xvfb owned by that user (start-ssh-display), then:
#   export ROAMTTY_TEST_PASSWORD_FILE=/workspace/roamtty/.private/test-password
#   export ROAMTTY_TEST_PORT=22228 ROAMTTY_TEST_HOST=127.0.0.1 ROAMTTY_TEST_DESKTOP_SSH=1
ENV
}

start() {
  verify_pin
  ensure_home
  start_xvfb
  start_typing_target
  start_plugin_http
  echo
  echo "Desktop host fixture ready."
  echo "  display:  $DISPLAY_VAL"
  echo "  plugin:   $BIN ($EXPECTED_VER)"
  echo "  home:     $HOME_DIR"
  echo "  start:    eval \"\$( $ROOT/scripts/desktop-host-fixture.sh env )\""
  echo "  stop:     $ROOT/scripts/desktop-host-fixture.sh stop"
  echo "  smoke:    env HOME=\$ROAMTTY_DESKTOP_HOME DISPLAY=\$DISPLAY \$ROAMTTY_DESKTOP_BIN serve --proto 1 --client 640x360@160"
  echo
  print_env
}

stop() {
  for f in "$XTERM_PID" "$HTTP_PID" "$XVFB_PID"; do
    if [ -f "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; fi
  done
  # Extra Xvfb we may have started without recording (best-effort).
  pkill -f "Xvfb $DISPLAY_VAL " 2>/dev/null || true
  pkill -f "http.server 8797 --bind 127.0.0.1" 2>/dev/null || true
  echo "Desktop host fixture stopped ($DISPLAY_VAL)."
}

status() {
  if [ -S "/tmp/.X11-unix/X$DISPLAY_N" ]; then
    echo "Xvfb $DISPLAY_VAL up"
    verify_pin
    print_env
  else
    echo "stopped"; exit 1
  fi
}

# Xvfb owned by itermux_test so DesktopProbeScript's [ -O socket ] succeeds over SSH.
start_ssh_display() {
  local user=itermux_test home=/tmp/itermux-ssh-test/home n="${ROAMTTY_SSH_DESKTOP_DISPLAY:-92}"
  id "$user" >/dev/null 2>&1 || { echo "create itermux_test first (Android prepare-openssh-test / manual)" >&2; exit 1; }
  sudo -n mkdir -p "$home"
  if [ ! -S "/tmp/.X11-unix/X$n" ]; then
    sudo -n -u "$user" env HOME="$home" setsid Xvfb ":$n" -screen 0 1280x800x24 -ac +extension GLX +render -noreset       >/tmp/roamtty-ios-ssh-xvfb.log 2>&1 < /dev/null &
    for _ in $(seq 1 40); do [ -S "/tmp/.X11-unix/X$n" ] && break; sleep 0.1; done
  fi
  ls -la "/tmp/.X11-unix/X$n"
  echo "SSH desktop display :$n owned by $user — set sshd SetEnv DISPLAY=:$n"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  env) print_env ;;
  verify) verify_pin ;;
  start-ssh-display) start_ssh_display ;;
  *) echo "Usage: $0 start|stop|status|env|verify|start-ssh-display" >&2; exit 2 ;;
esac
