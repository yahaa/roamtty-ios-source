# Implementation and verification

Updated 2026-10-08. Android reference: `origin/main` at `bee299d82249e255be7169d7c9f1d60c4c5f5609`, tree `56e205d2f82ee509431bf3a36dab69ccd5656445`. Remote main was rechecked at 07:51 UTC and remains unchanged. The Android working tree was not changed. Swift implementation lives in this standalone repository on `feat/ios-parity`.

## Implemented scope

- Host search/editing, password/private-key/interactive authentication, explicit host-key trust and mismatch rejection, Keychain credentials, TCP reachability, system/plugin detection and live host metrics with CPU/memory/GPU history, network throughput and bounded reconnect.
- Up to eight independent sessions, shell/tmux modes, reattachment, SSH and native mosh transport, terminal input/resize, cursor controls/gestures, fonts, ghost toolbox, command history and Claude/Codex/Grok launch modes.
- SFTP navigation/search/sorting, hidden files, mkdir/rename/delete, directory and file transfers with scoped cancellation and no-overwrite publication, editable upload destinations/names, Photos upload and session-specific insertion, Files destinations, text/syntax/Markdown/image preview and sharing.
- Native share extension with a durable import queue, Chinese/English settings, dark/light/system appearance, lifecycle recovery and device-only persistence.

See [UI-PARITY.md](UI-PARITY.md) for the source-to-screen mapping and iOS adaptations. Native iOS navigation, permission dialogs, keyboard and document/share pickers follow iOS conventions. UI parity is not a claim of pixel-identical platform controls.

## Verification results

| Check | Result | Evidence |
| --- | --- | --- |
| Swift Core/transport suite against real OpenSSH, mosh-server and tmux | 162 total: 160 passed, 2 sudo-fixture skips, 0 failed | Linux `/tmp/roamtty-full-live-complete-10.log`, 07:21:53 UTC |
| Privileged cancellation and exec regression in disposable Docker | 12 passed, 0 skipped, 0 failed; includes both sudo cases skipped above | `/tmp/roamtty-exec-backpressure-final-confirm.log`; real apt download, concurrent exec and temporary/permanent send backpressure |
| macOS Core/transport suite | 162 total: 131 passed, 31 service-dependent skips, 0 failed | Mac `/tmp/roamtty-macos-core-complete-09.log` |
| Real CoreText custom font validation, atomic replacement, migration and cleanup | 31 checks passed | `scripts/test-font-catalog.swift`, macOS |
| Atomic directory publication on macOS/APFS | 5 passed, 0 skipped, 0 failed | Mac `/tmp/roamtty-macos-directory-test-03.log` |
| Durable share queue recovery, partial write, acknowledgement and cancellation | Passed | `scripts/test-share-inbox.swift` |
| Cursor/startup, toolbox timing/placement, paste and terminal scroll routing checks | Passed | `scripts/test-terminal-interaction.swift` |
| Xcode Debug app, extension and UI-test build for simulator | Passed with final production source and final test query | Mac `TestResults/Simulator-20261008-075101-build.log` |
| Simulator UI suite | All 35 distinct methods passed across runs: full run 34/35; focused run 4/5; corrected Files preview 1/1. Original failures remain recorded | `TestResults/Simulator-20261008-062414.xcresult`, `Simulator-20261008-073431.xcresult`, `Simulator-20261008-075101.xcresult`; [coverage report](SIMULATOR-COVERAGE.md) |
| Physical iPhone discovery, pairing, signed Release build installation and launch | Current Release 10 passed strict codesign verification, installation and normal launch | Wired iPhone 16 Pro, iOS 26.6.2; Mac `/tmp/roamtty-device-release-10.log`; launched 07:32:23 UTC |
| Earlier physical functional diagnostics | 14 passed, 0 failed on final transport implementation, before the Markdown-only changes | `TestResults/DeviceDiagnostics-05/report.json`, 06:40:28–06:40:33 UTC |
| Final-source physical diagnostic attempts | App foreground, shared Keychain and window capture passed, but the phone could not reach the private SSH fixture; dependent network checks failed | `TestResults/DeviceDiagnostics-06/report.json` and `DeviceDiagnostics-07/report.json`, 07:23–07:26 UTC; these are not passing runs |
| Physical XCTest interactions | Retried after owner authorization; runner initialization still times out before any assertion | `TestResults/DeviceAuthorized-Core-01.xcresult`; “Timed out while enabling automation mode” |

The physical iPhone is wired, paired, and has Developer Mode enabled. After the owner authorized the device, all fourteen functional diagnostics passed against the real server. The final two attempts later failed because the phone could no longer reach the private fixture; the Mac simulator continued to reach it. Those attempts do not replace the earlier evidence with a passing claim. XCTest also times out while enabling automation mode, before any UI assertion. Following the user's instruction, a dedicated **Roamtty Validation** iPhone 17 simulator was created on iOS 26.4 (`A3A76413-476C-437B-B811-E84DCE7185C9`). A blocked or failed physical test is not counted as passed. Private physical screenshots are not included.

The simulator suite uses a real SSH server, native pickers, the actual share extension, and SwiftTerm's rendered buffer. It covers password/key/interactive authentication, trust cancellation, host management, SSH/mosh/tmux, reconnect, exact gesture/paste/shortcut bytes, PTY resizing, files and previews, PNG attachment, share/upload destination and collision checks, settings persistence, plugins, agent modes, Guide and About. See the coverage report for individual assertions and the limits of those checks.

Regression fixes include restoring file controls after search navigation, routing durable share receipts to the visible host browser, keeping file/command actions on their initiating connection, recreating the native renderer after reconnect, and reconnecting an existing session to its original endpoint after the saved host changes. Session login snapshots stay in memory; their credentials are cleared on backgrounding, deletion and final removal. They never load the edited host's credentials for the old endpoint. Expanded acceptance also caught overlapping native file importers, browser errors presented behind child sheets, and launch-sheet handoff from terminal file tools. These now use one importer per screen, local error presentation and ordered dismissal before launch.

Cancelling or timing out an exec now sends TERM to that command's channel, allows bounded cleanup and escalates to KILL. A pending libssh2 signal is completed before another signal begins; a permanently blocked send invalidates the connection. Real apt cancellation verifies that its privileged process and download workers stop while another exec on the same connection survives. Servers that ignore SSH signals or commands that deliberately detach privileged descendants remain outside that guarantee.

## Reproduction and artifacts

On Linux:

```sh
ROAMTTY_SWIFT=/home/v/sdk/swift/usr/bin/swift ./scripts/test-linux.sh
swiftc App/Shared/ShareInboxStore.swift scripts/test-share-inbox.swift -o /tmp/roamtty-share-check
/tmp/roamtty-share-check
swiftc App/Roamtty/Features/Terminal/Input/TerminalInteraction.swift scripts/test-terminal-interaction.swift -o /tmp/roamtty-terminal-check
/tmp/roamtty-terminal-check
```

`test-linux.sh` starts an isolated test-account sshd, runs the suite and cleans up the server. It reads the existing private fixture password and test keys from the adjacent Android repository. It does not write to that repository. Install `mosh-server` and `tmux` to avoid optional protocol-test skips.

The Mac checkout is `/Users/developer/work/roamtty-ios`. Build products, `.xcresult` bundles and fixture secrets remain ignored. UI-test credentials are injected with `scripts/configure-ui-fixture.py`; `scripts/run-device-validation.py` passes diagnostic credentials through the child environment. The diagnostic is compiled only in Debug, uses an isolated store and exact fixture fingerprint, and does not alter normal saved hosts or pins.

The logged-in Mac GUI session can sign with its existing unlocked development identity. `scripts/mac-gui-run.py` launches an owned, temporary build job in that security session; it does not unlock the Keychain or modify access controls. The available development profile supports shared Keychain groups but no App Group, so the verified configuration uses `App/Support/Development.entitlements`. See [README.md](../README.md) for App Group provisioning.

## Remaining verification limits

Full physical touch interaction remains unverified because XCTest automation initialization still times out. Physical transport and transfer behavior passed fourteen earlier diagnostics, but final-source network attempts failed to reach the private server. Their app-owned screenshots do not prove automated touch interaction. Final acceptance therefore uses the authorized simulator fallback. No passing claim is made for long-duration background execution, carrier/Wi-Fi handoff on this phone, arbitrary third-party Files providers, or every remote operating system. iOS may suspend background work; tmux preserves the remote process for reattachment. Mosh UDP behavior is covered by live server tests including a source-port change, but that does not substitute for a physical cellular handoff.
