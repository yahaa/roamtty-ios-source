# Native iOS UI parity

The UI reference is the current reachable Android UI in `../roamtty`, especially `ItermuxScreen.kt`, `HostDetailPage.kt`, `TerminalPane.kt`, `LaunchSheet.kt`, `RemoteFileBrowser.kt`, `ItermuxTheme.kt`, and `DesignSystem.kt`. The older iTermux iOS prototype is not the source of truth.

## Navigation and design

- Home has 会话 and 主机 tabs in its toolbar (`HomeTabs`), sessions first; swiping moves between them and the search filters the tab in view. Each tab has a "会话 · N" / "主机 · N" line with its + on the right. The host detail page no longer lists sessions.
- The sessions tab (`Features/Home/HomeSessionsTab.swift`, Android `HomeSessions.kt`) groups sessions by agent state — 待确认, 运行中, 已完成, then 终端/其它 — with filter chips when there are two groups or more. A row shows the agent tile and badge, a scrolling title (the folder, else `sessionListTitle`), elapsed time, the last prompt, the command the agent runs or the start of its last reply, the status (Claude-style spinner, ✻ worked time), tmux/mosh tags, and 允许 / 追问 actions. Long press offers 关闭 (ends the remote tmux session without asking) and, for a disconnected tmux card, 强制删除.
- + on the sessions tab picks the agent (or a plain terminal), then the host, or fills in a new host (titled 新建会话, 下一步, password saved by default, blank name falls back to the address), then the launch sheet titled 选择工作目录.
- A terminal opened from the home page returns there; one launched from a host page returns to it. The terminal has no navigation bar; the session menu returns to the host detail, closes or restarts the session, or switches sessions. iOS-only: the disconnect notice has a 返回 button, since there is no system Back.
- Dropped or restored sessions reconnect when their terminal opens, and from the sessions list (hosts with a saved password or an unencrypted key only, once a fresh probe finds sshd answering), at most once per 10 s.
- Terminal-initiated file browsing carries the initiating session ID and working directory. Inserting a path or an uploaded file targets that session only.
- The drawer matches Android: brand header with close, Hosts as a plain row with a count chip (it opens the hosts tab), every session with its agent or terminal tile, then Settings and Help (About is kept last for the third-party notices). Forms, launchers, plugins, previews, and transfers use native sheets.
- The palette follows Android's warm charcoal/cream/peach tokens. Grouped panels use 16-point corners; row/control corners are 10–12; notices and sheets use 20–28. The layout uses a 4-point grid with 16-point page gutters.
- Chinese and English switch immediately. Dark, light, and system appearance apply to sheets, terminal, and file previews.
- App icon, home logo, and ghost artwork are rendered from Android's `scripts/render-launcher-icon.py` vector geometry. Fonts are copied from Android's bundled font assets. SwiftTerm uses the actual PostScript font names, with Symbols Nerd Font and Noto Symbols fallback descriptors.

## Terminal (mirrors `TerminalPane.kt`)

- Edge to edge: the terminal colour runs under the status bar and home indicator; text sits inside 10 / 6 / 6-point insets. No header, status strip or toolbar buttons.
- Collapsed state: the toolbox ghost on the upper golden section, fading after 5 s idle; holding it opens the shortcut ring (accent labels, spring unfold, caption beside the ring, Fn sub-ring).
- Dock (tap the ghost): close, session switcher (dot = connection state; menu: 返回主机详情 / 关闭当前会话 / 重启当前会话, then every open session with its phase), upload, download, insert image, 常用命令, terminal settings (编辑文本 / 固定·取消固定操作栏 / 隐藏操作栏 / 粘贴 / 增大·减小字号). Restart respawns a tmux pane in its folder and types its program again; a plain shell reconnects. Pinning reserves a 48-point column (96 in roomy landscape).
- 编辑文本 opens Android's bottom prompt editor: ← → ⌫ (hold to clear), 收起, ↵, 发送文本. 粘贴 stages the clipboard there instead of typing it.
- Connection states float over the preserved grid on the golden section: the animated-logo progress card with cancel, or the notice card (手动重连 / 改用普通 SSH / 重新核验…). Input warnings use the 提示 / 知道了 card.
- 常用命令 is the shell-history sheet: title, 点按即执行, refresh, close, search, `❯` rows in the terminal font; a tap closes the sheet and runs the command.
- Cursor-row keys (Esc / Enter), tap-on-cursor-line keyboard, triple tap paste, swipes and swipe-hold, pinch font size (persisted) are unchanged. A double tap sends Tab and brings ↑ above the pet, ↓ below and ← to its left for 4 s; a line starting with `/` keeps them up. The Enter/Esc key slides left of them when the cursor row falls within their span. After Enter the keyboard hides after 15 s without typing.
- Tapping a URL opens it (`TerminalUrl`, a port of Android's `TerminalUrl.java`): soft wraps, TUI hard wraps (including a full-width row redrawn by tmux and URLs glued to a label like "PR："), underlined "label (url)" links and scrollback. iOS routes GitHub and other universal links to their app. SwiftTerm does not publish its wrap flag; `SwiftTermTextGrid` reads it through `getText`. `scripts/test-terminal-url.sh` runs Android's URL cases against SwiftTerm 1.13.0. iOS-only: a reading tap away from the cursor line hides the keyboard, since iPhone keyboards have no dismiss key and there is no Back button.
- Icons are Android's vector drawables, converted by `scripts/import-android-icons.py` into `Assets.xcassets/Icons`. File icons use the generated port of `FileIconTheme.kt` (`Features/Files/FileIcons.swift`).
- UI tests read the phase from an invisible `terminal-phase` element (value: mode and transport). The launch sheet's tmux/SSH, mosh and typed-path controls exist only in Debug UI-test runs; Android has none.

## Feature map

| Android feature | iOS implementation |
| --- | --- |
| Host-only home, search, drawer | `Features/Home/HomeScreen.swift`, `Navigation/DrawerScreen.swift` |
| Password, private key and interactive host editor | `Features/Hosts/HostEditorScreen.swift` |
| First-use fingerprint approval, keyboard-interactive fields | `Model/AppModel+Connections.swift`, `Features/Authentication/AuthenticationOverlay.swift` |
| Changed fingerprint blocks connection | Transport pin store plus explicit `FingerprintReview`; as on Android, 移除旧记录并重连 reconnects at once and shows the new fingerprint |
| mosh first-contact timeout falls back to SSH | `SessionRuntime` shows Android's 提示 card ("mosh 无法连接（可能未放行 UDP 60000–61000），已改用 SSH。") once the fallback connects |
| Host online state and latency | `Services/ReachabilityProbe.swift`: online only once sshd's identification arrives (our own goes first); latency is DNS + TCP connect |
| AI agent state on the session list (Claude Code, Codex, Grok hooks) | Core `AgentStatus`/`AgentHooks` (hook script, Claude settings, Codex/Grok launchers in `~/.roamtty`), `SessionRuntime` status poll, approve and follow-up |
| Passphrase prompts only for encrypted keys | Core `PrivateKeys.needsPassphrase` |
| CPU/memory/disk gauges, 40-sample CPU/memory/GPU charts, network throughput, swap, load, processes and GPU details | `Features/Hosts/HostDetailScreen.swift`, `MetricsPanel.swift`, Core `HostMetricSeries`, real `HostMetrics.script` results |
| Monitor connection state, retry and bounded reconnection | `AppModel.monitorStates`, `HostMonitorRetry`, host monitor status panel |
| Close (ends tmux on the server), force delete, restart sessions | `AppModel.closeSession`, `forceDeleteSession`, `restartSession` |
| SSH-only remote folder picker, recent folders, detected default session mode, Claude/Codex/Grok permission hints and command previews | `Features/Sessions/LaunchScreen.swift`, Core `RemoteFolders` and `HostLaunchPolicy` |
| tmux/mosh detection and explicit installation | `Features/Hosts/PluginsScreen.swift` |
| Native terminal rendering and keyboard input | `Features/Terminal/Runtime/SessionRuntime.swift`, `Features/Terminal/Rendering/TerminalViews.swift`, SwiftTerm 1.13.0 |
| Ctrl, arrows, Esc, Tab, function keys, ghost shortcuts and toolbox | `TerminalScreen.swift`, `GhostShortcuts.swift`, Core `TerminalShortcuts` |
| Cursor-row keyboard tap, double-tap Tab, triple-tap paste, floating Enter/Esc/slash arrows | `SessionRuntime+Gestures.swift`, `SessionRuntime+Input.swift`, `TerminalInteraction.swift`, `CursorRowButtons.swift` |
| Scrollback, text selection/copy, paste, pinch font size | Native SwiftTerm/UIKit |
| Common commands and remote bash/zsh history | `CommandSheet`, Core `ShellHistoryCommands` |
| Path-aware fuzzy file search, new folder, persistent Name/Size/Modified/Type sorting, hidden files and batch download | `Features/Files/FileBrowserScreen.swift` |
| Syntax highlighting, counted search with wrapping navigation, saved preview font/wrap, Markdown and text fullscreen | `Features/Files/FilePreviewScreen.swift`, Core Syntax/Markdown parsers |
| Image zoom and full-screen image preview | `ZoomableImage` |
| File/folder upload and download with progress/cancel | `Features/Files/FileTransferModel.swift` |
| Direct terminal upload/download and selected-image attachment | `Features/Files/TerminalFileActions.swift`, native Files/Photos pickers, initiating-runtime insertion |
| Upload destination folder browsing and editable remote filenames | `UploadFilesSheet`, canonical SFTP validation and batch collision checks |
| Download location, Files import/export and activity sharing | Settings, `ExportDocuments`, `ShareActivity` |
| Share extension import queue | `ShareExtension/ShareViewController.swift`, `SharedInbox` and shared storage |
| Bundled, system and imported terminal fonts, custom slot reselect/clear | `Features/Settings/Fonts/FontCatalog.swift`, `CustomFontStore.swift`, Settings |

## Lifecycle and data handling

`AppModel` owns session runtimes and transfer jobs independently of view lifetime. Popping a screen does not stop its terminal or transfers. Closing a session ends it without asking: a connected tmux session is killed over its live connection, a disconnected one is killed over a fresh login (a failure points to 强制删除, which forgets the card without logging in).

Every terminal connection has a generation. Closing or replacing it invalidates callbacks and cancels its pending credential/trust prompts. Durable host and prompt-owner generations also reject late queued prompts, authentication results, phase callbacks, and cache writes after editing credentials or deleting a host. Late credentials cannot restart a closed runtime. Authentication failures invalidate cached credentials so retry can request a correction. Passwords are saved only when selected; private keys use the `key` Keychain purpose. Private-key passphrases remain in memory. An explicit per-session mosh choice survives reconnects and app relaunch; records without one follow current plugin detection, including newly installed mosh. Normal authenticated host connections probe system and plugin metadata with the same generation guards. Returning to a visible host page restarts its suspended metrics monitor.

Session file tools, photo uploads, previews (including relative Markdown images), remote command history and connected tmux termination capture the initiating runtime and its SSH connection. Editing the saved host cannot redirect these operations to another server or user. Closing or replacing that runtime or connection rejects queued work without falling back to the saved host. A disconnected runtime whose login identity differs from the saved host cannot remotely terminate its old tmux session; unchanged disconnected or restored cards can reconnect for termination. Host-only tools use the current saved host. Name and display-only edits preserve live connections; endpoint, authentication and credential changes invalidate the shared host connection while existing connected terminals retain their original connection.

Terminal output uses synchronous main-queue delivery from the transport worker, providing bounded renderer backpressure. Failed input enqueue remains visible to the user. Startup directory/agent input is sent once; a connection fallback does not replay accepted input. OSC 52 requests from the server are ignored; user-initiated native selection copying still works.

tmux startup waits for rendered output and a newly attached client absent from the pre-connect PID/TTY snapshot. This avoids sending `cd` or an agent command while the tmux client is still attaching. The cancellable readiness probe runs away from the renderer, times out after eight seconds, and distinguishes each Mosh/SSH attempt. Mosh's no-response fallback still starts after its first-contact timeout; a readiness wait begins only after contact.

Normal terminal taps open the keyboard only within two rows of the cursor (a minimum 64-point touch band). Double tap sends Tab, triple tap pastes; native long-press selection and copying remain available. Horizontal swipes of at least 32 points send Left/Right on the live terminal, preserving an armed Ctrl/Shift modifier; vertical or diagonal scrolling does not send Left/Right. Holding the swipe still for 500 ms sends Ctrl+A/Ctrl+E once, without a second arrow on release. The floating cursor control shows Enter after a 700 ms typing pause and returns to Esc after three seconds. Slash-command arrows follow the rendered cursor row, with double tap temporarily dismissing them for completion. Controls follow SwiftTerm's caret frame and disappear when that row is scrolled away. There is no persistent bottom key strip.

Vertical drags follow Android's scroll routing: mouse-tracked programs such as tmux receive wheel events, alternate-screen programs without mouse tracking receive Up/Down, and other terminals use local SwiftTerm scrollback. Wheel protocol encoding uses SwiftTerm's public `encodeButton`/`sendEvent` APIs. Only vertical gestures report mouse input; taps and selection stay local. Partial-row movement is accumulated, and a pinch cancels pending gesture input so its final lift cannot send a cursor key.

The toolbox is centered on the upper golden section (38.2%) of the current safe viewport, clamped four points from its top/bottom and eight points from its trailing edge. The collapsed ghost moves away from the cursor-row button when necessary. It fades after five seconds and wakes on an initial workspace touch without consuming that touch. A native 48-point button owns tap/hold and accessibility activation; its decorative image floats independently of the hit target. A floating dock collapses on outside touch; an explicitly pinned dock reserves a 48-point terminal column, or 96 points in landscape without a software keyboard when at least 320 points of control height remain.

Holding the ghost reads the current cursor-local terminal rows to detect Claude, Codex, Grok, Gemini or a shell. The exact Android shortcut tables and left-facing arc geometry live in Core. Releasing between items pins the ring for taps; four seconds of inactivity hides both the ring and ghost. An outside tap dismisses a pinned ring without sending input. Fn opens its submenu after a 350 ms hover or a tap, and returning over the ghost returns to the main ring.

Native, toolbox, triple-tap and command-editor text paste share one guarded path. A multiline paste into a program without bracketed paste prompts before sending. Paste is limited to 128 KiB, removes terminal control bytes while preserving Tab and line endings, converts CRLF/LF to CR, and enqueues the entire text with its bracket delimiters atomically. Confirmation holds the chosen text rather than rereading a changed clipboard.

Each transfer has its own cancellation token, checked before opening the connection and at recursive boundaries. Download names are reserved across concurrent jobs, and failed or cancelled recursive downloads remove the partially created local directory. Symlink directories are not followed recursively. Security-scoped URLs remain open throughout their transfer. Transfers can continue when their screen closes; iOS may suspend the process after backgrounding.

The host monitor samples the real remote metrics script, waits three seconds between successful samples, and bounds each sampling command to ten seconds. CPU, memory and per-GPU histories retain the most recent 40 available readings. Network rates use monotonic elapsed time between counter samples; a reconnect resets the counter baseline while retaining the last displayed charts and rate. Connection failures retry after 2, 4, 8, 16 and 30 seconds, stopping after five retries. Successful sampling resets that retry budget. Authentication rejection, untrusted/changed host keys, user cancellation and keyboard-interactive logins do not retry automatically. The host page retains status, error detail and a reconnect action alongside cached readings; late cancelled samples do not update the page or emit global notices.

Uploads selected in Files or received through the share extension use the same confirmation form. Users can type or browse the destination directory and change each remote filename. The app resolves that directory through SFTP and checks the whole batch for existing or duplicate names before starting; SFTP exclusive creation still protects against files appearing after validation. Recursive downloads stage into a privately owned directory and publish with an exclusive rename. Cancellation removes only that job's stage, never a completed destination or a concurrent job's files.

The terminal dock exposes upload, download and image attachment directly. Download opens the remote browser with multiple selection enabled. Photo access uses the system picker only after the image action, with up to nine explicitly selected images. Photos convert sequentially to PNG, upload to unique `/tmp/roamtty-img-UUID.png` paths, and paste the paths without Enter into the exact runtime that initiated the action. Closing or replacing that runtime prevents automatic insertion; completed transfers retain a copyable path and an explicit Insert retry when the original runtime is still connected.

Incoming shares wait until a currently open preview, transfer, or command sheet closes. App Group storage is used when provisioned. The containing app and extension also support the shared Keychain queue configured by the signing entitlements; consult the main README for signing details and its size bound.

## Platform adaptations

Native iOS navigation bars, safe areas, document pickers, permission handling, keyboards, and share sheets replace Android equivalents. SwiftTerm is a UIKit terminal view, with no WebView. Readable terminal output is exposed to accessibility from the emulator's actual buffer.

Photo attachment conversion accepts sources up to 64 MiB and limits the PNG's longest side to 4096 pixels to bound mobile memory use. The picker screen states that limit; temporary image copies are removed after completion, failure or cancellation.

The current Android app deliberately removed unreachable standalone output-history/tmux-history screens. They are not reintroduced here. Terminal scrollback, tmux recovery, and the reachable common-command history remain available.

Remote Markdown images are loaded over the same authenticated SFTP connection. Paths normalize `.` and `..` and remove query/fragment metadata while preserving encoded filename bytes, matching Android. Web and mail image references are explicit links and are not fetched automatically; data references remain placeholders. Other URI-like text is interpreted only as a remote-host path. Relative inline links receive link styling without opening another application. Rendered images use rounded corners and a 480-point height limit. Text previews read at most 256 KiB and image previews read at most 8 MiB, matching Android. Images are decoded as thumbnails with a maximum dimension of 2048 pixels; the original image dimensions remain visible. Preview controls provide independently saved 9–22 point text sizing, counted source-text search with previous/next wrapping, line wrapping, fullscreen, copy path, retry, and a complete download.

The launcher enumerates at most 500 visible directories through SSH exec, including on servers without SFTP. It preserves literal path names, validates control characters and displays home-relative paths. New sessions use tmux when the probe detects it; an explicit picker choice is retained while metadata updates. Agent choices retain their permission mode, show the exact command and use Android's initial Codex/YOLO default. Launching from a terminal's file sheet dismisses that sheet before presenting the launcher.

Font imports validate at most 16 MiB with CoreText and publish one custom slot atomically. The original filename and font survive relaunch and bundled-font selection. Reimporting a font with an existing PostScript name uses the selected file's own font data. Invalid imports preserve the last valid font; clearing the custom slot falls back only when it was selected. System monospace and bundled faces remain available. Browser and Settings import failures appear within their active screen, and native picker cancellation preserves the prior selection.

## Verification

`App/UITests/RoamttyUITests.swift` covers host editor validation, host-only navigation, language/theme changes, and optional live flows. The live flow accepts the real trust dialog, starts tmux, sends a command through the command UI, asserts the marker in SwiftTerm's actual buffer, then reads and previews a file over SFTP. A separate test downloads the fixture file and exercises the Roamtty share activity when offered by the destination. Test credentials are supplied through the test runner environment and are never checked in.

The UI sources can be parsed on Linux with:

```sh
/home/v/sdk/swift/usr/bin/swiftc -frontend -parse $(find App -name '*.swift')
```

Generate the Xcode project with `python3 scripts/generate-project.py`. Device build and XCTest results belong in the main progress report; syntax parsing alone is not proof of a successful iOS build or a passing UI test.

Focused cursor, startup, toolbox timing/placement, paste sanitization and arrow/function-key encoding checks run without UIKit. Core tests separately cover Android agent detection, exact shortcut tables and adaptive arc geometry:

```sh
/home/v/sdk/swift/usr/bin/swiftc App/Roamtty/Features/Terminal/Input/TerminalInteraction.swift scripts/test-terminal-interaction.swift -o /tmp/roamtty-terminal-interaction-checks
/tmp/roamtty-terminal-interaction-checks
```

Core monitor and file-action regressions cover retry classification/backoff, chart windows, network counter resets, attachment framing, upload collision rejection, and exclusive directory publication:

```sh
/home/v/sdk/swift/usr/bin/swift test --filter 'HostMonitorRetryTests|HostMetricSeriesTests|TerminalAttachmentTests|LocalDownloadDirectoryTests'
```

## Not ported

Android's native Windows support (psmux sessions, PowerShell folder listing and Windows metrics) and Android-only work (IME connection handling, Compose leak fixes, the emulator e2e/perf suite) are not part of the iOS app.
