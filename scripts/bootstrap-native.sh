#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/NativeBuild/downloads"
mkdir -p "$CACHE"
fetch() {
  local name="$1" url="$2" hash="$3"
  if [ ! -f "$CACHE/$name.zip" ]; then curl --fail --location --retry 3 "$url" -o "$CACHE/$name.zip"; fi
  python3 - "$CACHE/$name.zip" "$hash" <<'PY'
import hashlib,sys
path,expected=sys.argv[1:]
with open(path,'rb') as f: actual=hashlib.file_digest(f,'sha256').hexdigest() if hasattr(hashlib,'file_digest') else hashlib.sha256(f.read()).hexdigest()
if actual != expected: raise SystemExit('Checksum mismatch: '+path)
PY
  if [ ! -d "$CACHE/$name.xcframework" ]; then unzip -q "$CACHE/$name.zip" -d "$CACHE"; fi
}
fetch ssh2 https://github.com/apotocki/libssh2-iosx/releases/download/1.11.1.0/ssh2.xcframework.zip 1f1f7032da4525f1dac254a64fae0b4f3bc4be68b3434bf58e3a641d4138daa8
fetch crypto https://github.com/apotocki/openssl-iosx/releases/download/3.5.9.1/crypto.xcframework.zip b8d0c23713c52760dca27804516e179ae16bd9bed09c50bb02fc93df023f2f18
for pair in 'iphoneos ios-arm64' 'iphonesimulator ios-arm64_x86_64-simulator' 'macosx macos-arm64_x86_64'; do
  read -r sdk slice <<< "$pair"
  mkdir -p "$ROOT/Vendor/$sdk/include" "$ROOT/Vendor/$sdk/lib"
  for name in ssh2 crypto; do
    cp -R "$CACHE/$name.xcframework/$slice/Headers/." "$ROOT/Vendor/$sdk/include/"
    cp "$CACHE/$name.xcframework/$slice/lib$name.a" "$ROOT/Vendor/$sdk/lib/"
  done
 done
printf 'Verified native libraries prepared in %s/Vendor\n' "$ROOT"
