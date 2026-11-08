#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d "$ROOT/NativeBuild/libssh2/.git" ]; then
  git clone --depth 1 --branch libssh2-1.11.1 https://github.com/libssh2/libssh2.git "$ROOT/NativeBuild/libssh2"
fi
revision=$(git -C "$ROOT/NativeBuild/libssh2" rev-parse HEAD)
[ "$revision" = a312b43325e3383c865a87bb1d26cb52e3292641 ] || { echo 'Unexpected libssh2 revision' >&2; exit 1; }
cmake -S "$ROOT/NativeBuild/libssh2" -B "$ROOT/NativeBuild/libssh2-build" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DCRYPTO_BACKEND=OpenSSL \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX="$ROOT/Vendor/linux"
cmake --build "$ROOT/NativeBuild/libssh2-build" --parallel 6
cmake --install "$ROOT/NativeBuild/libssh2-build"
