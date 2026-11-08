# Memory and performance review fixes

**Goal:** Fix all eight primary findings and four additional findings from the 2026-10-25 review of `ed1ac19`, validate on the connected iPhone, and explain the causes and verification in a PR.

**Architecture:** Keep current app boundaries. Make ownership explicit, separate cancellation from native destruction, bound work at its real queue, and preserve user intent independently of connection phases. Carry the two SwiftTerm patches in the user's fork, pinned to an exact commit with documented provenance. Use testable core components for scheduling and byte budgets where appropriate.

**Dependency plan amendment:** After the initial implementation, the user requested a GitHub fork to remove the large source import from the app PR. Task 3's historical vendoring steps below are superseded by [the fork dependency](../../dependencies/swiftterm.md); the two library patches remain byte-identical.

**Tech stack:** Swift 5 mode / Swift tools 6, SwiftUI/UIKit, libssh2, CoreMedia/VideoToolbox, SwiftTerm 1.13.0, SwiftPM and generated Xcode project.

**Spec:** The user-approved findings and fix recommendations are recorded in `REVIEW-2026-10-25.md` (local review artifact). The numbered scope below is the durable specification.

## Global Constraints

- Work only in the isolated worktree. Preserve the original checkout and its uncommitted changes.
- Preserve SSH/SFTP/terminal/desktop functionality and public protocol compatibility. Do not change credentials, production hosts, stored user data, or release publicly.
- Every regression test must exercise production logic or native APIs, not a copied implementation. Record a baseline failure or existing repro, then passing behavior.
- Keep temporary fixtures, credentials, traces, build outputs, the Vendor symlink, and local planning artifacts out of commits. Commit durable source/tests and human-readable verification documentation only.
- No subagent may spawn another agent. Implementation tasks run sequentially; controller owns review, integration, device work, PR, and OTA delivery.
- Report measured facts separately from inferred risk. Enqueue latency is not actual screen presentation latency.

## Review Focus

Correct object/native ownership; teardown under cancellation; queue count and byte bounds; ordering and generation invalidation; no lock held across reentrant external callbacks; cancellation and UI lifetime; security-scoped URL lifetime; reproducible dependency provenance; phone memory and functional evidence.

## Task 1: Desktop ownership, ordering, backpressure, and pause intent

**Files:** `Sources/RoamttyDesktopCore/DesktopVideoDecoder.swift`, `DesktopSession.swift`, relevant desktop core helpers/tests; `App/Roamtty/Features/Desktop/VideoToolboxDisplay.swift`, `DesktopPage.swift`; optional focused native regression harness under `scripts/`. Do not modify project generator or terminal files.

**Requirements:**
1. Replace the borrowed Swift AVCC pointer with memory owned by the CMBlockBuffer (copy is acceptable). Remove unrelated holder retention heuristics. Snapshot path must use the same safe ownership.
2. Serialize frame conversion and display submission, including concurrent SSH/UDP input, reset/detach/flush. Define generation behavior so queued stale frames cannot reappear after flush/close. Avoid deadlocks from reentrant display/session callbacks.
3. Bound the actual queue before main-thread enqueue and respect AVSampleBufferDisplayLayer readiness. Use a small documented frame limit plus a byte bound; overload must drop a dependent GOP safely and request a new keyframe (or retain a newest complete keyframe chain). Do not enqueue one main closure per incoming frame. Prevent upstream conversion from becoming an unbounded alternate queue.
4. Remove the premature `session.rendered` fallback for real displays. Record decoded before its actual enqueue callback; name/document enqueue approximation accurately. Cover delayed display callbacks in tests.
5. Break DesktopGestureView's CADisplayLink target cycle. Include explicit dismantle/reattach lifecycle where needed; even a view constructed and dropped without attaching must release. Preserve gestures.
6. Store desired pause independently of DesktopSession phase. Pause during connection and during recovery must apply to each new stream and suppress audio/video work while hidden; resume must recover by requesting a keyframe. Concurrent pause/open must not lose the latest intent.

**Steps / validation:** Add focused DesktopCore regressions for blocked concurrent conversion (ordered output), overloaded pending frames, reset/detach generation, late render callback, pause during connect and pause through recovery. Run them RED against baseline, then implement and run GREEN plus all DesktopCore tests. Existing `review-artifacts/desktop-repro/` holds baseline ordering/pause and CoreMedia ASan repros. Add a production-linked CoreMedia regression if feasible without app test target; report iOS-only checks for controller to run. The known manifest test baseline mismatch is not part of this task and must be reported separately. Build concerns must be explicit. Commit only scoped files and write report with commands, outcomes, changed interfaces, and concerns.

## Task 2: Bounded transport memory and unconditional native cleanup

**Files:** `Sources/RoamttyTransport/SSH/SFTP.swift`, `SSHConnection.swift`, `SSHExecStream.swift`, related CNative adapter if necessary, transport tests; `App/Shared/ShareInboxStore.swift`; focused native regression script/test.

**Requirements:**
1. Drain autoreleased file-read buffers each upload chunk, covering the entire read/write iteration and errors/cancellation, so large upload memory does not scale with file size. Apply same fix to ShareInboxStore's copy loop. Preserve 64 KiB transfer chunks, progress, partial write handling, atomic destination semantics, and limits.
2. Native SFTP handles and sessions must be destroyed even after `isStopped`, including the cancelled-result path in `openSFTP`. Separate cancellable I/O retry from mandatory cleanup. Serialize native operations under existing library ownership locks; handle EAGAIN and a shut socket without infinite waits or blocking close. Avoid skipping the destructor because business I/O is cancelled. Preserve session safety when transfers race disconnect.
3. Enforce SSHExecStream's 4 MiB cap in the inner stdout/stderr drain; remaining read size and closed state must be checked within the loop. Reader wakeup and close must still complete.

**Steps / validation:** Add regressions exercising actual cleanup path and capped stream behavior. Existing native allocation repro and actual upload/stream scripts are in `review-artifacts/transport/`; credentials are in original checkout `.private/container-fixture.json`, never print/commit them. RED baseline evidence exists for allocation leak, stream overshoot, and phone upload; convert suitable checks into durable production-linked tests. Run focused tests, live SSH transport tests against existing dedicated fixture (`127.0.0.1:22993`), and native allocation counter where possible. Do not restart fixture or touch saved hosts. Commit scoped files and write detailed report. Controller owns phone upload comparison.

## Task 3: SwiftTerm reset lifecycle and bounded accessibility extraction

**Files:** `ThirdParty/SwiftTerm/` new pinned library source, license/provenance/patch notes; `scripts/generate-project.py`, generated `Roamtty.xcodeproj` package references/resolution; `scripts/test-terminal-url.sh`, `scripts/terminal-url/Package.swift` and regression executable; `App/Roamtty/Features/Terminal/Rendering/TerminalViews.swift`; README/THIRD_PARTY_NOTICES entries describing this dependency.

**Requirements:**
1. Vendor the SwiftTerm library source at exact upstream revision `8e7a1e154f470e19c709a00a8768df348ba5fc43` (v1.13.0). Source checkout is `/Users/developer/work/roamtty-ios/build/SourcePackages/checkouts/SwiftTerm`. Preserve upstream copyright/license and document provenance plus minimal downstream patches. Use a small local Package.swift exposing the library and needed resources/platform exclusions, no benchmark/executable dependencies. Do not edit shared cache or original checkout.
2. Patch `Terminal.resetNormalBuffer()` scroll closure to weak capture, matching initialization. Regression must check weak Terminal after ESC c, with ordinary terminal as control, populated scrollback and repeated resets.
3. Add a bounded tail extraction API inside SwiftTerm or equivalent app-facing helper that visits only needed rows and returns the same last 16 KiB as the existing full UTF-8 export followed by suffix, including newline/trimming/multibyte edge cases. Update accessibility call site without changing its update cadence or displayed semantics.
4. Generator, committed project, and terminal harness must resolve the same patched local package. Remove obsolete remote dependency resolution pins if no longer needed. Preserve iOS/macOS/Linux compilation support of relevant harnesses.

**Steps / validation:** Add failing lifecycle and tail equivalence checks to the real SwiftTerm harness, observe RED, apply minimal patches, run new checks plus existing URL/wide-cell/scrollback checks GREEN. Inspect vendor diff against upstream to document every change. Regenerate project with DEVELOPMENT_TEAM=8LN388NLF4 but avoid unrelated generated changes. Controller builds/install phone after all tasks. Commit scoped files and report provenance, commands, outputs, changed APIs.

## Task 4: Aggregate Markdown image budget

**Files:** `App/Roamtty/Features/Files/FilePreviewScreen.swift`, focused app image pipeline helper; shared testable scheduler/cache component only if needed in RoamttyCore, corresponding tests.

**Requirements:**
1. Lazy Markdown rows and visibility-scoped image demand: offscreen rows release decoded images and cancel their demand. Per-row @State must not keep an unbounded second copy of cached images.
2. A shared pipeline must deduplicate identical requests, bound active fetch/decode concurrency (choose/document a small limit, e.g. 2), retain at most a documented aggregate decoded byte budget (e.g. 32 MiB), and keep existing single-response 8 MiB/2048 px safety limits. Account real decoded bytes and active consumers so cache eviction alone cannot silently leave unlimited live images. Full-screen preview must share the pipeline and release demand on dismissal.
3. Cancellation/error paths release permits; host/remote path identity must be correct, stale completion must not update a reused row, no credentials in cache keys/logs, and no blocking decode/network on MainActor. Existing authorization and image behavior must remain.

**Steps / validation:** Add production-linked tests for aggregate budget, eviction/release, duplicate requests, concurrency, cancellation and failures; baseline missing-bound evidence from review is acceptable for UI-only paths but pure components must fail before implementing. Run focused tests and relevant app compile diagnostics if possible; controller does final device/UI build. Keep design small and avoid a new general networking framework. Commit scoped files and report memory bound including any one-frame/active-decode overhead.

## Task 5: Background serialized share import

**Files:** `App/Roamtty/Services/SharedInbox.swift`, `App/Roamtty/Application/RoamttyApp.swift`, AppModel lifecycle files, ShareInboxStore if needed (coordinate with completed Task 2); shared tests/harness.

**Requirements:**
1. Move URL import copy, keychain/file I/O, receipt/fsync and inbox consumption off MainActor to one serialized background worker. UI publication stays on MainActor. Keep current transaction recovery and shared-container semantics.
2. Security-scoped URL access must span the entire copy on background worker and be balanced on success/error/cancel. Do not pass an invalidated security scope into an asynchronous task.
3. Repeated foreground/openURL requests must not race duplicate consumption or publish stale host/import state. Serialize `acknowledge` with consumption as well, preserving successful-upload acknowledgement semantics; do not let an in-flight consume re-publish a just-acknowledged URL. Errors and completion must reach existing UI behavior; do not silently discard failed imports. Avoid retaining app/view state forever.

**Steps / validation:** Add production-linked checks for serialized operations, background execution, deduplicated/repeated consumption and failure cleanup where test seams allow. Baseline `swiftc App/Shared/ShareInboxStore.swift scripts/test-share-inbox.swift` fails rediscovery equality on this Mac because commit returns `/var/...` while enumeration returns `/private/var/...`; preserve one canonical URL identity across commit/pending/acknowledgement and add an alias regression, rather than weakening assertions. Existing ShareInboxStore transaction tests must pass; run share inbox harness and focused core tests. Controller verifies device integration. Commit scoped files with report.

## Integration and delivery (controller)

Verify official desktop-plugin release artifact hash/size before correcting stale manifest expectations. Run all core/transport/terminal/share tests, build and run phone diagnostics, compare weak model/view counts and 128 MiB upload peak against baseline, and test new native buffer ownership. Perform a fresh whole-branch review and address findings. Record precise evidence and remaining limits in durable docs. Create a Chinese PR explaining each trigger, root cause, correction and regression evidence. Build uniquely versioned installable development IPA, publish through the existing dev OTA catalog preserving history, verify local/server/download hashes, install same commit on phone, and report PR/build links. Do not merge or release to public stores.
