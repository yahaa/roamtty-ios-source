# Simulator acceptance coverage

## 2026-11-01 (later): the remaining items

Same simulator and fixtures. Changes: `tmux -u` on attach, `LM_SKIP_METADATA_EXTRACTION`, the desktop gesture tests' own opt-in and runner (`scripts/test-desktop-gestures.sh`).

| Evidence | Result |
| --- | --- |
| Full UI run, `TestResults/Simulator-20261101-104356.xcresult` | **86 total: 67 passed, 15 skipped, 4 failed.** The 8 live-desktop tests now skip instead of failing against the SSH container. |
| The 4 failures | `HomeLandscapeUITests.testCardsShareHeightAndLandscapeBarSlides` and `TerminalSettingsUITests.testPinnedToolsReserveWidthAndFunctionShortcutsReachRemote` passed when rerun. The two TerminalGesture keyboard tests kept failing, also with `RemoteCommands.swift` from the previous round (so not `tmux -u`). The cause was simulator state left by hardware key events (XCUITest `typeKey`, used by the old ⌃⌘F test): the software keyboard stopped coming back. After `xcrun simctl erase`, TerminalGesture passed **9/9**. |
| Live desktop gestures, Ubuntu VM | `testTrackpadModeGestures`, `testTouchModeGestures`, `testSwipeBackFromOutsideThePicture` and `testLookAtHost` passed. The trackpad test now flicks back up when the page under the cursor is already at its end. |
| Live desktop gestures, the Mac | `testShowDesktopButtonEveryTap`, `testShowDesktopFromFullScreenTappedTwice` (Chrome in full screen first), `testToggleHostFullScreen`, `testTapHostPoints` and `testLookAtHost` passed. `testUnlockHost` was not run: the Mac was unlocked, and the test would type the password into the front app. |
| Unit tests (`swift test`) | **440 total: 426 passed, 14 skipped, 0 failed.** |
| Lint and build | `scripts/lint.sh` 0 warnings (Linux and Mac). A clean Debug xcodebuild prints no warnings and no AppIntents note. |

If keyboard tests fail on a simulator that had hardware key events, erase it (`xcrun simctl erase <udid>`); `scripts/test-simulator.sh` sets it up again.

## 2026-11-01: deep review refactor (`refactor/deep-review`)

Simulator: Roamtty Validation (iPhone 17, iOS 26.4), the Docker SSH fixture on the Mac, recovery and plugin fixtures on the dev box.

| Evidence | Result |
| --- | --- |
| Full UI run, `TestResults/Simulator-20261101-025207.xcresult` | **86 total: 63 passed, 7 skipped, 16 failed.** All 16 were environment or pre-existing. 8 DesktopGestureUITests need a live desktop host. The 5 recovery/plugin tests got the container's password, which no longer matched the real test account. `testPinchZoomsThePicture` and `testTapMovesTheCursorInsideAMultiLineInput` also fail on `main`. |
| Fixes | The pinch test now spreads two fingers at once: `XCUIElement.pinch` rests first, which the page takes for a two-finger hold, as on Android. The container now sets `/etc/default/locale`, so tmux draws UTF-8 (`你好` was shown as `____`). `waitForOutput` now reports what the terminal showed. |
| Reruns on the same app build | NetworkRecovery 3/3, PluginInstallation 2/2, TerminalGesture 9/9 and DesktopLaunch 10/10 passed, plus NativeFileWorkflow `testImportedFontAndChosenDownloadFolderSurviveRelaunch`. |
| Live desktop gestures on the Ubuntu VM | `testTouchModeGestures` passed. `testTrackpadModeGestures` sends the wheel and inertia as expected, but nothing under the cursor scrolled on the host; it fails the same way on `main`. The Mac-host tests were not run against the user's Mac. |
| Unit tests (`swift test`, clean build) | **440 total: 426 passed, 14 skipped (live services), 0 failed**, no warnings. |
| Lint and build | `scripts/lint.sh` passes with 0 warnings. Clean xcodebuild warnings: only Xcode's "Metadata extraction skipped. No AppIntents.framework" note. |

## 2026-10-15: Android parity to `5fc87b3`

Source: this branch's final working tree (home sessions/hosts tabs, agent status, close/force delete/restart, pet arrow keys, terminal URLs, SSH greeting probe).

| Evidence | Artifact | Result |
| --- | --- | --- |
| Full simulator UI run, all 36 methods with the recovery and plugin fixtures | `TestResults/Simulator-20261015-161729.xcresult` | **36 total: 35 passed, 1 failed.** `testAgentLauncherModesAndInstalledPluginsReflectLiveHost` failed opening a launch-sheet menu (passed in the earlier batch and twice alone). |
| TerminalSettingsUITests after the menu-retry test fix | latest `TestResults/Simulator-*.xcresult` on the Mac | **5 passed, 0 failed.** |
| Baseline check | `8ce6404` worktree, `TestResults/Simulator-20261015-160005.xcresult` | The two NetworkRecovery methods also failed on the previous commit (changed-key review had no reconnect; the mosh fallback notice was cleared on connect). Both now follow Android and pass. |
| Linux Core and live transport | `scripts/test-linux.sh` | **193 total: 191 passed, 2 sudo-fixture skips, 0 failed**, including `AgentHooksLiveTests` against real OpenSSH and tmux. |
| Terminal URL finder on SwiftTerm 1.13.0 | `scripts/test-terminal-url.sh` | **518/518** Android `TerminalUrlTest` checks. |
| Physical functional diagnostic, iPhone 16 Pro | Debug build, `Documents/Validation/report.json` | **18/18 passed**, including `agent_hooks_status_restart_kill`, `ssh_greeting_reachability` and home/host screenshots. The signed Release build was reinstalled afterwards. Physical XCTest UI automation was not attempted. |

The 36th method is the new `SessionCapacityUITests` flow (eight isolated sessions on the home list, 强制删除 keeps the remote tmux session). `TerminalSettingsUITests` replaces the rename test with `testTmuxSessionSurvivesAppRelaunchAndCloseEndsIt`.

## 2026-10-08

Updated 2026-10-08. Scope is the reachable Android UI mapped in [UI-PARITY.md](UI-PARITY.md). Build success, Core tests, functional device diagnostics and XCTest UI execution are separate evidence. Skipped tests and partially completed methods do not count as passed.

The complete 35-method simulator run passed 34 methods and failed one history-test interaction. The corrected history method and both plugin methods passed on final production source in the focused run; its preview method exposed a test-only native accessibility-role mismatch. The corrected preview query passed its complete focused rerun. **All 35 distinct UI methods now have passing execution evidence across the full run and focused reruns; this is not a single clean 35-test run.** Linux passed 160 of 162 Core/live tests, with two sudo-fixture skips and no failures; a separate isolated SSH suite passed all 12 tests, including both skipped cases. macOS passed 131 with 31 service-dependent skips and no failures. The latest signed Release 10 is installed and launched on the iPhone. Earlier physical diagnostics passed 14/14, but the two final-source attempts failed to reach the private SSH fixture; those attempts are not counted as passes.

## Latest evidence

| Evidence | Artifact | Result |
| --- | --- | --- |
| Full simulator UI run | `TestResults/Simulator-20261008-062414.xcresult`, matching `-build.log` and `-ui.log` | **35 total: 34 passed, 1 failed, 0 skipped.** The history method failed. This run preceded the final SSH pending-signal fix and Markdown relative-image refinements. |
| Final-source focused run | `TestResults/Simulator-20261008-073431.xcresult` | **5 total: 4 passed, 1 failed, 0 skipped.** Corrected history (271.520 s), both plugin installation/cancellation methods (263.347 s combined), and preview preferences (284.665 s) passed. The Files preview method passed its relative-image assertions but failed at the web-link test query: SwiftUI exposes the Link as a native Button. |
| Corrected Files preview rerun | `TestResults/Simulator-20261008-075101.xcresult` | **1 passed, 0 failed, 0 skipped (136.662 s).** The complete text/Markdown/image preview method passed with the test-only query corrected to the observed native Button role; production source is unchanged from the focused run. |
| Linux Core and live transport | `/tmp/roamtty-full-live-complete-10.log` | **162 total: 160 passed, 2 skipped, 0 failed**, completed 07:21:53 UTC. Includes real OpenSSH, tmux, mosh, Markdown path policy and pending-signal backpressure regressions. |
| Isolated sudo/installer transport | `/tmp/roamtty-exec-backpressure-final-confirm.log` | **12 passed, 0 skipped, 0 failed**, completed 06:41:22 UTC. Includes both Linux-skipped sudo cases, real apt cancellation, concurrent exec preservation and temporary/permanent send backpressure. These overlap the Linux inventory; do not add the totals. Across these runs every one of the 162 distinct Core/transport methods has passing evidence. |
| macOS Core | Mac `/tmp/roamtty-macos-core-complete-09.log` | **162 total: 131 passed, 31 service-dependent skips, 0 failed.** The skips are not macOS live-service passes. |
| Earlier physical functional diagnostic | `TestResults/DeviceDiagnostics-05/report.json` | **14/14 passed**, 06:40:28–06:40:33 UTC, after the final transport correction and before Markdown-only changes. This was a functional diagnostic, not XCTest UI automation. |
| Final-source physical diagnostics | `TestResults/DeviceDiagnostics-06/report.json` and `DeviceDiagnostics-07/report.json` | **Failed**, 07:23–07:26 UTC. Foreground readiness, shared Keychain and window capture passed, but the phone could not reach the private SSH fixture and dependent network checks failed. The simulator continued to reach the service. |
| Signed physical release | Mac `/tmp/roamtty-device-release-10.log` | **Release 10 strict codesign verification, installation and normal launch passed**, 07:32:23 UTC, on iPhone 16 Pro / iOS 26.6.2. This includes final production source. |
| Physical XCTest attempt | `TestResults/DeviceAuthorized-Core-01.xcresult` | Timed out while enabling UI automation **before assertions**; no physical XCTest pass claimed. |

Simulator: iPhone 17, iOS 26.4, UDID `A3A76413-476C-437B-B811-E84DCE7185C9`, run through [test-simulator.sh](../scripts/test-simulator.sh). Result bundles retain screenshots, actual terminal-buffer assertions and remote-byte checks. The complete native landscape display is also captured at `/tmp/roamtty-u5-landscape-display.png`; cropped XCTest attachments did not show the entire display.

The device diagnostic covers foreground readiness, durable shared-Keychain transactions, password and keyboard-interactive authentication, live metrics, PTY input/resize, SFTP binary equality/no-overwrite/truncation, upload/download cancellation cleanup with connection reuse, eight independent tmux sessions and reattachment, actual mosh UDP/resize/source-port behavior, owned fixture cleanup and an app-window snapshot. This successful earlier run is retained as historical evidence. The final-source attempts later failed to reach the fixture; their network operations have no passing claim. Final acceptance therefore uses the user's authorized simulator fallback.

## UI test inventory

There are **35 unique XCTest methods** below. This table describes their meaningful assertions; execution status comes from the completed result bundles above, not from the existence of test code.

| Suite | Method | Required interaction and assertion |
| --- | --- | --- |
| [RoamttyUITests](../App/UITests/RoamttyUITests.swift) | `testHomeContainsHostsAndEditorValidatesRequiredFields` | Host-only home and editor validation prevent an incomplete host from being saved. |
| RoamttyUITests | `testLiveTrustTerminalOutputAndSFTPPreview` | Accept the real host fingerprint, launch SSH in the chosen directory, execute a command and preview actual SFTP text. |
| RoamttyUITests | `testShareExtensionQueuesDownloadedFile` | Mosh, download/share, actual share extension and host chooser deliver an upload to the chosen directory; completion and remote content are checked. |
| RoamttyUITests | `testDrawerProvidesSettingsAndLanguageUpdatesImmediately` | Drawer navigation and immediate Chinese/English settings changes. |
| [AuthenticationUITests](../App/UITests/AuthenticationUITests.swift) | `testUnsavedPasswordCancelCorrectionAndRelaunchRequireExplicitLogin` | Cancel and reject unsaved credentials, correct the password, then require explicit login again after relaunch. |
| AuthenticationUITests | `testInteractiveHostEditorAnswersActualServerChallenge` | Select keyboard-interactive authentication and answer the real SSH server challenge. |
| AuthenticationUITests | `testEncryptedKeyImportsThroughFilesAndPromptsAgainAfterRelaunch` | Native Files import of an encrypted key, passphrase authentication and renewed prompt after relaunch. |
| AuthenticationUITests | `testCancelFirstTrustRequiresExplicitRetryAndDoesNotSavePin` | Cancelling first trust leaves no saved pin and requires an explicit retry. |
| [FilesUITests](../App/UITests/FilesUITests.swift) | `testNativePhotoPickerUploadsPNGAndInsertsWithoutEnter` | Native Photos selection, original-session upload after editing the saved host endpoint, insertion without Enter, explicit execution, remote PNG signature and reconnect to the original endpoint. |
| FilesUITests | `testRemoteManagementHiddenFuzzySearchAndBatchDownloads` | Real mkdir/rename/delete, hidden-file toggle, cross-directory fuzzy search, multi-selection, duplicate-name batch downloads and recursive folder download. |
| FilesUITests | `testTextMarkdownAndImagePreviewControls` | Actual text search/wrap/font controls, Markdown rendered/source modes, a decoded relative PNG with dot-segment/query/fragment normalization, an explicit compact web-image link, and image dimensions/zoom/fullscreen. |
| FilesUITests | `testSharedUploadRejectsCollisionAndUsesChosenDirectory` | Share upload rejects existing destinations and nonexistent directories; chosen directory/name uploads the expected bytes without changing the original. |
| [NavigationUITests](../App/UITests/NavigationUITests.swift) | `testHostSearchEditDeleteAndOfflineStatusPersist` | Create/search/edit/delete a host, show real offline status and retain changes across relaunch. |
| NavigationUITests | `testInvalidPortsKeepEditorOpenAndCancelDiscardsDraft` | Invalid ports cannot save; cancellation discards the draft. |
| NavigationUITests | `testGuideAboutAndDrawerReturnUseSelectedLanguage` | Guide/About and drawer return paths use the selected language. |
| [TerminalGestureUITests](../App/UITests/TerminalGestureUITests.swift) | `testPlainSSHKeyboardPinchAndGestureBytes` | Native keyboard, actual PTY column change after pinch, and exact Tab/swipe/Escape bytes. |
| TerminalGestureUITests | `testBracketedPasteAndReconnectAfterRemoteShellExit` | Exact bracketed-paste bytes, shell exit, reconnect and fresh terminal rendering. |
| [TerminalSettingsUITests](../App/UITests/TerminalSettingsUITests.swift) | `testTmuxRenameCloseAndAppRelaunchPreserveRemoteShell` | Rename/disconnect/relaunch preserves the remote tmux shell; explicit termination removes it. |
| TerminalSettingsUITests | `testPinnedToolsReserveWidthAndFunctionShortcutsReachRemote` | Ghost wake/hide, pinned layout, portrait/landscape behavior and actual F1/Ctrl+C bytes. |
| TerminalSettingsUITests | `testMultilinePasteRequiresConfirmationAndCancelSendsNothing` | Multiline input requires confirmation; cancellation sends no bytes and confirmation preserves normalized content. |
| TerminalSettingsUITests | `testSettingsFontSizeLanguageAndThemePersistAcrossRelaunch` | Font, size, language, theme and hidden-file preferences persist. |
| TerminalSettingsUITests | `testAgentLauncherModesAndInstalledPluginsReflectLiveHost` | Agent launch controls and mode choices reflect actual tmux/mosh probe and refresh results. |
| [CommandHistoryUITests](../App/UITests/CommandHistoryUITests.swift) | `testRemoteHistoryRefreshFilterRunAndSavedCommandSurviveRelaunch` | Append one owned remote record, Refresh/fuzzy-filter/select/Run, save it, remove only that remote record, and execute the saved copy after relaunch. |
| CommandHistoryUITests | `testNativeTerminalSelectionCopyAndClipboardPasteReachRemoteOnce` | Native selection/Copy and editor Paste expose only the owned terminal content; terminal Paste delivers the expected bytes exactly once. |
| [NativeFileWorkflowUITests](../App/UITests/NativeFileWorkflowUITests.swift) | `testNativeFolderImportUploadsNestedBytes` | Native Files folder import preserves nested text/binary bytes; opening a terminal or agent from that directory supplies the correct launch path. |
| NativeFileWorkflowUITests | `testCancelLargeDownloadKeepsSSHAliveAndDoesNotPublishFile` | Cancel an actual 1 GiB sparse-file download, preserve SSH, and verify through native Files that no final partial file was published. |
| NativeFileWorkflowUITests | `testImportedFontAndChosenDownloadFolderSurviveRelaunch` | Native custom-font import/reselection/reimport/rejection/clear, system font, persisted download-folder access and an actual download/upload byte roundtrip. |
| [SessionCapacityUITests](../App/UITests/SessionCapacityUITests.swift) | `testEightSessionsStayIsolatedAndRemovingCardPreservesRemoteTmux` | Eight simultaneous sessions retain distinct shell state, the ninth is rejected, removing a disconnected card preserves its remote tmux, and the released slot can be reused. |
| [FileSortingUITests](../App/UITests/FileSortingUITests.swift) | `testNameSizeAndModifiedSortBothDirectionsKeepDirectoriesFirst` | Actual remote name/size/modified ordering works both ways with directories first. |
| [NetworkRecoveryUITests](../App/UITests/NetworkRecoveryUITests.swift) | `testRealMoshFirstContactTimeoutFallsBackWithoutRepeatingStartup` | A real unreachable UDP server triggers the production timeout, SSH fallback, the correct directory and exactly one startup/input. |
| NetworkRecoveryUITests | `testChangedHostKeyRequiresReviewRemovalAndFreshExplicitTrust` | An actual key change blocks reconnect; cancelled review retains the old pin, and recovery requires explicit removal and approval of the new fingerprint. |
| NetworkRecoveryUITests | `testHostMonitorAutomaticallyRecoversAfterEstablishedConnectionLoss` | Close established TCP flows, retain cached gauges during retry, restore the endpoint and prove fresh metrics sampling resumes. |
| [PluginInstallationUITests](../App/UITests/PluginInstallationUITests.swift) | `testInteractiveLoginSudoRetryInstallsRealTmuxAndReprobes` | Real interactive login, apt installation, secure sudo prompt/retry, streamed logs and installed re-probe; SSH-only launch works without SFTP and verifies actual `tmux -V`. |
| PluginInstallationUITests | `testCancellingStreamingAptKeepsBothSSHConnectionsUsable` | Cancel a genuine throttled apt download; require exact remote `apt-get` absence, tmux still absent and both the cancelled host and an independent terminal usable. |
| [PreviewSettingsUITests](../App/UITests/PreviewSettingsUITests.swift) | `testSearchFullscreenAndIndependentPreviewPreferencesPersistAcrossRelaunch` | Exact source-match counts/wraparound, text/Markdown fullscreen, independent preview font/wrap persistence and visible remote mkdir failure. |

## Fixtures and audit trail

Tests use dedicated live SSH/mosh/SFTP services and isolated app storage. Runner environment supplies private fixture credentials; this document and exported evidence must not contain their values. The key case imports the encrypted Android fixture `ssh-core/src/test/resources/keys/ed25519` through native Files. The Photos case selects a PNG seeded using `simctl addmedia`. Native document cases select seeded nested files, font files and a destination folder through the actual provider UI. Seeding supplies test inputs; it does not bypass trust, authentication, picker selection or transfer execution. Missing required services, picker content or fixture configuration cannot be silently skipped and counted as acceptance.

[serve-plugin-fixture.py](../scripts/serve-plugin-fixture.py) creates UUID-labelled Debian containers with Docker `--init`, no host mounts and a maximum two-hour lifetime. The normal endpoint deliberately has no SFTP subsystem; the cancellation endpoint throttles genuine apt traffic. Passwords enter only through stdin, never image layers or process arguments. A successful install changes package state, so reruns need fresh owned containers and their new private environment JSON/fingerprints. Cleanup targets only the recorded supervisor/container/image ownership. No host package removal, global sudo change or fake installer is used.

Earlier runs exposed both product bugs and XCTest interaction problems. Corrections include session endpoint ownership, reused-browser share handoff, startup/reconnect state, search/modal handling and cancellation of the actual installer process. The last transport review found a retained TERM packet across libssh2 EAGAIN; the frozen fix completes that send before KILL and invalidates an unrecoverable connection. Real backpressure regressions passed. The full-run history failure was traced in video to a fling and an overly broad fuzzy query; its test-only correction passed the complete method on rerun. Final Markdown assertions additionally exposed a test locator mismatch, with the native Link represented by a Button; only that query was corrected. Earlier partial methods or weaker cancellation checks are not counted as later acceptance, and focused passes do not change a full run's original totals.

## Scope and limits

- Current signed installation/launch are verified. Earlier physical functional networking passed, but the latest two attempts failed to reach the private fixture. Physical XCTest touch/picker automation remains unverified because its runner stops before assertions; the simulator supplies the accepted interaction coverage.
- Neither simulator execution nor a short foreground device diagnostic establishes carrier/Wi-Fi handoff or long-duration background execution under iOS suspension. Actual mosh UDP and source-port behavior have separate live transport/device evidence.
- Native picker evidence covers the seeded local Files and Photos content. Every external provider, image format, remote operating system and hardware GPU configuration is not covered; these are test-environment bounds, not platform impossibilities.
- Relative Markdown images have a dedicated decoded-image UI assertion. Agent-specific command/shortcut tables and scroll-routing decisions have Core/source evidence; paid agent services and every third-party full-screen terminal application were not executed.
- Core/live tests and source review substantiate protocol parsing, bounds, no-overwrite rules, cancellation cleanup, stale-owner rejection, durable inbox transactions and deterministic error branches. They do not replace the primary UI interactions in the inventory. No system protection was bypassed.
