# SwiftTerm fork and downstream patches

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Base: v1.13.0 / `8e7a1e154f470e19c709a00a8768df348ba5fc43`
- Fork: https://github.com/yahaa/SwiftTerm
- Patch branch: `roamtty-1.13.0-memory`
- Pinned revision: `0a311223749cf1b96294772a2c5478be67915572`
- License: MIT; upstream copyright/license retained in the fork and bundled in
  Roamtty as `licenses/SwiftTerm-MIT.txt`.

The generated Xcode project and `scripts/terminal-url/Package.swift` reference
the same full commit, not a moving branch. Both resolution files are committed.
The fork preserves the upstream package manifest, resources and repository
structure. Roamtty does not contain a vendored copy of the library sources.

Only `Sources/SwiftTerm/Terminal.swift` differs from the upstream base (+26/-1):

1. `resetNormalBuffer()` installs the same weak-self scroll callback as initial
   construction, so a full reset (`ESC c`) cannot retain the terminal model.
2. `getBufferTailAsData(maxBytes:kind:)` returns the exact UTF-8 byte suffix of
   `getBufferAsData(kind:)`, with non-positive limits returning empty data. It
   visits rows from newest to oldest until enough bytes have been collected,
   using the same right trimming and per-row newline as the full exporter. It
   preserves byte boundaries even when the suffix starts inside a UTF-8 scalar.
   Only the final needed rows are translated. Memory is bounded by the requested
   suffix plus one translated row; a full individual row can exceed the limit.

All 73 source/license files are byte-identical to the previously reviewed local
snapshot. The terminal harness sets upstream's `GITHUB_ACTIONS=true` switch to
omit its optional benchmark targets/dependencies for all four executables.
This switch does not alter the SwiftTerm library target.

For upgrades, rebase these two patches on the selected upstream revision,
inspect the upstream diff, update both exact pins, regenerate the Xcode project
and resolution files, and run `scripts/test-terminal-url.sh` plus an iOS build.
