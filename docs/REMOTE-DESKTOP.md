# Remote desktop (iOS port of roamtty #218)

Scope: everything in [yahaa/roamtty#218](https://github.com/yahaa/roamtty/pull/218) ("Remote desktop: SSH + UDP, Linux, macOS,
Windows and Wayland hosts"), item by item, with copy and interactions from roamtty `docs/design/remote-desktop/`
(`index.html`, `keyboard.html`, `shots/`). Android reference: #218 head `a4731b4` (branch `feat/remote-desktop-platforms`).

Plugin pin: `Sources/RoamttyDesktopCore/Resources/desktop-plugin.json` is Android's `app/src/main/assets/desktop-plugin.json`
byte for byte. At `a4731b4` that is **roamtty-desktop 0.8.0** (the PR title/body still mention 0.7.0 for the Windows
service; #218 has since moved the pin to 0.8.0 in a53f9a3). Re-copy the file whenever Android re-pins.

Status legend: **done** = implemented and tested on Linux with `swift test`; **done (unverified)** = implemented but needs
Xcode / a device; **todo** = not implemented yet; **n/a** = Android-only, iOS equivalent noted.

## Phases

| Phase | Content | Verifiable on Linux |
|---|---|---|
| 1 (done) | `RoamttyDesktopCore`: protocol, state, UDP wire/crypto/FEC/reassembly, UDP link + BSD socket transport, HID + modifier latch, gestures/viewport, latency meter, plugin manifest + SHA-256 pin; golden fixtures; Xcode target | yes (all) |
| 2 (done) | Plugin install / probe / serve over the existing SSH (`RoamttyTransport`) and SFTP layers; UDP upgrade/fallback; resume token (30 s); take-over | yes (fake host, local shell, real 0.8.0 plugin on Xvfb, OpenSSH fixture) |
| 3 (done in source) | H.264 Annex-B helpers, `DesktopVideoDecoder` (queue / keyframe gating / AVCC), `DesktopStatsText` + LatencyMeter plumbing; VideoToolbox `AVSampleBufferDisplayLayer` path in the app | pure logic yes; **VT path unverified on Linux / needs Xcode + device** |
| 4 (done in source) | Desktop page UI (SwiftUI): rail / tab bar, 操作 / 键盘 panels, virtual mouse, local cursor, stats overlay, status card, gestures via `DesktopGestures`, hardware keyboard | `DesktopPageModel` yes; UIKit/SwiftUI **unverified** (compile-guarded / app target) |
| 5 (done in source) | Pause-and-keep 5/10/30 min, `NWPathMonitor` → `networkChanged`, resume on foreground; entry points; Settings › 远程桌面 (keep-alive, stats; always on since 2026-10-26); probe storage on `Host` | session keep-alive / button derive yes; scene + UIKit hooks **unverified on device** |

## Android ↔ iOS parity

### Protocol and transport (desktop-core)

| Android (#218) | iOS | Status |
|---|---|---|
| `DesktopProtocol` … (all client/server messages) | `DesktopProtocol` + `FrameParser` | done |
| `Hello`, `Start.Failed` | `Hello`, `Start` | done |
| `DesktopState` / `DesktopButton.derive` | `DesktopState.swift` | done |
| `UdpWire` AES-GCM, replay, FEC, fragments, reassembler | `UdpCrypto`, `ReplayWindow`, `Fec`, `UdpWire`, `Reassembler` | done |
| `UdpLink` | `UdpLink` + `UdpSocketTransport` | done |
| 3 s silence → SSH fallback | `DesktopSession.send` | done |
| `HidUsage` + `ModifierLatch` | same | done |
| `DesktopGestures` / `Viewport` | same | done |
| `LatencyMeter` | same | done |
| `PluginManifest` | same + `bundled()` | done |
| Real plugin on loopback | `UdpPluginIntegrationTests` (env-gated) | done |

### Plugin install / start

| Android | iOS | Status |
|---|---|---|
| Read-only probe | `DesktopProbeScript` + `SSHDesktopHost` | done |
| Probe cached 7 days on host / session card | `Host.desktop` / `desktopProbedAt` + `DesktopButton.derive`; refreshed from host page | done (unverified on device) |
| Install (host/phone download, SHA-256, OpenH264, macOS/Windows scripts) | `DesktopPluginInstaller` | done (scripts + fake/real fixture; macOS/Windows hosts not run) |
| Needs / Windows service hint / start errors / serve / UDP / resume 30 s / take-over | `DesktopSession` | done |
| Pause / resume / network change | `DesktopSession` + app `suspend`/`resume` + `NWPathMonitor` | done (unverified on device) |

### Video

| Android | iOS | Status |
|---|---|---|
| MediaCodec H.264, render callback for 手机端 | `H264` (Annex-B → AVCC, SPS/PPS) + `DesktopVideoDecoder` (Linux-testable queue) + app `VideoToolboxDisplay` (`AVSampleBufferDisplayLayer`) | **done (unverified)** — VT path is **not compiled or verified on Linux**; render time ≈ enqueue stamp (no per-frame VT callback on older iOS) |

### Sound (plugin 0.9.0, roamtty #224)

| Android | iOS | Status |
|---|---|---|
| AUDIO 0x85 (20 ms Opus, 48 kHz stereo), hello `audio`, CONFIG `audio`, STATE `audio: unavailable` | `DesktopProtocol` `.audio`, `DesktopSession.audio` sink, `setAudio`, `onAudioAvailable` | done, `DesktopSessionTests` |
| `AudioJitter` (desktop-core): target = p95 arrival jitter (drift removed) + 40 ms, 60–300 ms; cushion only after the host's silence; drops past target + 120 ms; PI drift control on the playback rate (±3%) | `AudioJitter` (same rules, `AudioJitterTests`) | done |
| MediaCodec Opus → low-latency AudioTrack (`setPlaybackRate`, start threshold one packet) | `DesktopAudioPlayer`: `AVAudioConverter` (Opus) → `AVAudioPlayerNode` → Varispeed; backlog from the node's render position; session `.playback` + `.mixWithOthers` | done; live `testLiveDesktopPlaysTheHostsSound` on the simulator ↔ Ubuntu VM over Wi-Fi: 440 Hz decoded, backlog ≈ target (~120 ms), one cushion, 0–7 drops per run |
| 操作 › 声音 (per host, on by default), stats line 声音 缓冲 N ms | same, `DesktopHostSettings.audio` (decodes old settings) | done |

### Desktop page (DesktopPage.kt, design D1–D11)

| Android | iOS | Status |
|---|---|---|
| Right rail: 操作 · 键盘 · 显示桌面 · 所有窗口; portrait tab bar | `DesktopPage` SwiftUI | done (unverified) |
| 操作 panel (退出 / 文件 / 剪贴板 / 仅观看 / 触控·指针 / 虚拟鼠标 / 帧率 / 画质 / 显示器 / 锁定 / 网络状态 / 断开) | same via `DesktopController` + `DesktopPageModel` | done (unverified) |
| Keyboard: 输入法 + 电脑键盘 (modifiers, combos, F-keys) | `DesktopPageModel` + panels | done (unverified) |
| Local cursor, pinch, two-finger scroll, drag, hardware keyboard | `DesktopGestures` overlay + HID from `UIKey`; full gesture set in [DESKTOP-GESTURES.md](DESKTOP-GESTURES.md) | done (live UI tests on the simulator against Ubuntu, Windows and macOS) |
| Stats overlay / 网络较差 · 恢复中 | `DesktopStatsText` + overlay | done (logic verified; UI unverified) |
| Connecting / needs / failed / recovering card | `DesktopPage` status card | done (unverified) |

### Lifecycle, entry points, settings

| Android | iOS | Status |
|---|---|---|
| Leaving pauses and keeps the link 5/10/30 min | `DesktopSession.pause` keep-alive + Settings picker; page `onDisappear` → pause | done (unverified on device) |
| Drop → 30 s token resume; network change → rebind | session (phase 2) + `NWPathMonitor` / scene resume | done (unverified on device) |
| Second device take-over | `DesktopSession` → failed 已在另一台设备上打开 | done (logic); UI card phase 4 |
| Session card desktop button (IconTag / rightmost after 追问) | `DesktopCardButton` + `SessionRow` + `DesktopButton.derive` | done (unverified) |
| Host list desktop IconTag (`sessionConnected: true`) | `HostCard` + `DesktopCardButton` | done (unverified) |
| Host page 「桌面」 | `HostDetailScreen` | done (unverified) |
| Terminal dock 「打开桌面」 (before files; sticky clear + hide keyboard; menu item removed) | `TerminalScreen` dock `terminal-desktop` | done (unverified) |
| Floating dock 5 s auto-hide + collapse countdown ring | `TerminalToolboxState.dockHideSeconds` + collapse ring | done (unverified) |
| 设置 › 远程桌面 (no switch: on for everyone since 2026-10-26) | `SettingsScreen` | done |
| Per-host prefs (mode/quality/fps/lock); global showStats | `DesktopHostSettings` in `AppSettings.desktopHosts` | done |
| Android notification row | Live Activity optional | n/a |
| Back gesture excluded over the picture | Swipe-back works from the black bars and is kept off over the picture (as Android); the system's top/bottom edge gestures are deferred; 操作 › 返回 keeps the link | done |

## Launch crash fix (post phases 3–5)

Cold launch does not construct `DesktopStore` or start `NWPathMonitor`; both wait for the first desktop opened.
`AppSettings` desktop keys decode best-effort so a corrupt value cannot fail the whole settings blob.
Session cards skip desktop work entirely while the flag is off. Regenerated `Roamtty.xcodeproj` includes the new App/DesktopCore sources.

## Phase 3–5 notes and deviations

- VideoToolbox lives only under `App/Roamtty/Features/Desktop/` behind `#if canImport(UIKit) && canImport(VideoToolbox) && canImport(CoreMedia)`. `RoamttyDesktopCore` stays Linux-clean: NAL/AVCC, decoder queue, stats text, page model.
- Render latency for `LatencyMeter` uses enqueue time when no VT render callback is available.
- Desktop login opens a **dedicated** SSH connection (`makeConnection` + `connect`), not the host's shared monitor connection, matching Android's page login.
- Experimental flag defaults **off**; session / host / terminal entry points stay hidden until enabled and `DesktopButton.derive` / `desktopSupported` allow them.

## Verification

Linux (this box, Swift 6.0.3, swift-crypto 4.3.1), `swift test --filter RoamttyDesktopCoreTests`:

- `RoamttyDesktopCoreTests`: **112** tests, **4** skipped (plugin fixture unset), **0** failures.
  - Phase 1–2: ~100 (protocol, UDP, session, installer, Windows, gestures, …).
  - Phase 3–4 pure logic: H.264 / stats text / video decoder routing / `DesktopPageModel` (IME, modifiers, combos) among them.
- VideoToolbox, SwiftUI desktop page, Settings/entry UI, and scene/path-monitor behaviour are **not** exercised on Linux.

Not verified (needs Xcode on a Mac, a simulator/device, or real hosts):

- Generated Xcode project build of new App sources and assets (`ic_desktop`, rail icons, …).
- VideoToolbox decode/display on a device; real end-to-end latency numbers.
- Desktop page layout vs design shots; hardware keyboard / pointer.
- macOS / Windows / Wayland hosts beyond scripted tests.
- Wi-Fi ↔ cellular roaming with `NWPathMonitor` on a phone.
- Keep-alive timer actually tearing down after 5/10/30 minutes in the background.

Suggested check on a Mac: `python3 scripts/generate-project.py && xcodebuild -scheme Roamtty -destination 'generic/platform=iOS Simulator' build`,
then open a desktop from a session card / host list / host page / terminal dock.

## Remaining gaps vs #218 (source-complete with caveats)

Nothing large remains to claim **complete in source** for the #218 surface area, with these caveats:

1. VT / SwiftUI / UIKit paths are **unverified** (no device/simulator run in this environment).
2. Edge swipes over the picture belong to the desktop; swiping back works from the black bars (see DESKTOP-GESTURES.md).
3. Live Activity / persistent notification is explicitly n/a.
4. Real macOS permission polling UI and Windows service “复制命令” affordances rely on `DesktopText` / needs card; polish may differ from Android screenshots until device QA.
5. Do **not** claim device testing until someone runs the Mac/simulator checklist above.

## Linux desktop host fixture (this box)

Script: [`scripts/desktop-host-fixture.sh`](../scripts/desktop-host-fixture.sh).

| Item | Value |
|---|---|
| Plugin pin | **roamtty-desktop 0.8.0** (`desktop-plugin.json`; binary sha256 matches `linux-x86_64`) |
| Binary / archive | `/workspace/desktop-plugin/roamtty-desktop`, `linux-x86_64.gz` |
| Plugin HOME (OpenH264 2.6.0) | `/workspace/desktop-plugin/home` (`$HOME/.roamtty/…`) |
| LocalLoopback display | **`:91`** (Xvfb, started by the script; typing target via xfce4-terminal) |
| SSH desktop display | **`:92`** owned by `itermux_test` (`start-ssh-display`) so probe `[ -O socket ]` succeeds |
| SSH reachability | `itermux_test@127.0.0.1:22228` (password in `/workspace/roamtty/.private/test-password`; SFTP on) |
| Optional plugin HTTP | `http://127.0.0.1:8797/linux-x86_64.gz` |

```bash
./scripts/desktop-host-fixture.sh start          # :91 + pin check + typing target
./scripts/desktop-host-fixture.sh start-ssh-display   # :92 as itermux_test
eval "$(./scripts/desktop-host-fixture.sh env)"
# LocalShell / UDP (set HOME only for the test process):
ROAMTTY_DESKTOP_HOME=… DISPLAY=:91 swift test --filter 'UdpPluginIntegrationTests|DesktopSessionPluginTests'
# Over SSH (sshd must SetEnv DISPLAY=:92):
ROAMTTY_TEST_PORT=22228 ROAMTTY_TEST_DESKTOP_SSH=1 swift test --filter SSHDesktopHostTests
./scripts/desktop-host-fixture.sh stop
```

Smoke: `env HOME=$ROAMTTY_DESKTOP_HOME DISPLAY=:91 $ROAMTTY_DESKTOP_BIN serve --proto 1 --client 640x360@160` prints a Hello JSON with `ver":"0.8.0"` and a UDP port.

### Alignment run (2026-10-23 Asia/Shanghai)

**iOS core against this host** (no UIKit / no device):

| Check | Result |
|---|---|
| `DesktopSessionPluginTests.testRealPluginEndToEnd` | **pass** — UDP upgrade; SSH fallback ~2773 ms; resume `--resume`/`--token` keeps session id |
| `UdpPluginIntegrationTests` video+loss+fallback+roam | **pass** — loss frames≥30, fallback ~2795 ms, roam ≤1 s |
| `UdpPluginIntegrationTests` pointer / no-NACK | **pass** (xfce4-terminal fallback when xterm absent) |
| `SSHDesktopHostTests` scripts / SFTP phone-install / streams | **pass** |
| `SSHDesktopHostTests.testDesktopEndToEndOverSSH` | **pass** on `:92` owned by `itermux_test` |

**Android #218 desktop-core on the same box** (`./gradlew :desktop-core:test` filtered): 32/33 — `videoOverUdpWithLossFallbackAndRoaming` + `pointerMovesOverUdp` **pass**; `noNacksWithoutLoss` **fail** only because Android still hard-requires `/usr/bin/xterm` (not installed). No AVD → **E2eDesktopTest / UI entry points / keyboard page / 操作 panel not run on emulator**.

**Still UI-only / unverified on iOS device:** DesktopPage rail/panels, VideoToolbox picture, Settings toggles, session/host/terminal entry chrome (source aligned in `3cc8e5e`; not exercised under UIKit here).
