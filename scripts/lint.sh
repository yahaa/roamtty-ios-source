#!/usr/bin/env bash
# SwiftLint over the app, the packages, their tests and the check scripts, with .swiftlint.yml. Zero warnings expected.
# Install with `brew install swiftlint` (macOS) or the static Linux build from the SwiftLint releases.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTLINT="${SWIFTLINT:-$(command -v swiftlint || true)}"
[ -n "$SWIFTLINT" ] || { echo "swiftlint is not installed" >&2; exit 1; }
"$SWIFTLINT" lint --strict --quiet "$@"
