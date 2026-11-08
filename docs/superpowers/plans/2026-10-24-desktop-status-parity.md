# Desktop connection status parity

> **For agentic workers:** Use superpowers:executing-plans for this small, sequential UI change.

**Goal:** Match Android PR 218's connection messages and card UI in iOS PR 47.
**Architecture:** Reuse `DesktopText` and the existing `DesktopPhase`; replace the old status card with a focused SwiftUI overlay. Preserve session lifecycle, manual retry, and the headless-host fix.
**Tech Stack:** SwiftUI, RoamttyDesktopCore, XCTest/XCUITest.
**Spec:** User request, Android `DesktopPage.kt` and `AppLocale.kt` at `72500724035f8c2108bf9c48eb95dcb902056280`.

## Constraints and review focus

- Android geometry: 296 by 244, corner radius 20, inset 20 horizontal / 18 top / 14 bottom; host name above title, scrollable body, fixed footer. Bound the card to the viewport and support larger text.
- Connecting: 登录主机 / 安装桌面插件 or 启动桌面插件 / 等待画面; current spinner, completed check, pending dot. One latest log line.
- Needs: translated action instructions and automatic-connect footer; Windows login needs include service-install command and copy action.
- Failed: 无法打开桌面, error body, horizontal 重试 / 关闭; no spinner or automatic retry.
- Recovering with a picture: preserve last frame; delay the recovery card until two seconds; remove it when the state changes. No status card over a healthy picture.
- Check long permission copy, English titles, long logs, portrait/landscape, no-picture states, and failure after a prior picture.
- Continue in the existing clean PR 47 worktree; publish a signed IPA through dev port 18780, verify manifest and download hash.

## Work

- [x] Add isolated status fixtures and UI regression coverage; observe the old UI fail the Android expectations.
- [x] Implement the shared status overlay and connect it to the live desktop page.
- [x] Run core suite, simulator UI regressions including real headless SSH, and inspect screenshots.
- [x] Review implementation and prepare signed IPA. Deliver via PR 47 and the existing dev catalog; artifact metadata records the resulting commit, build and SHA-256.

## Evidence

- Baseline: PR 47 and local HEAD both `fe72fd6`; worktree clean. Android PR 218 fetched and compared live.

- RED: old UI failed opening-title/step assertions in `/tmp/roamtty-desktop-status/Red.xcresult`.
- GREEN: three status UI tests passed (opening, bilingual needs, failure/recovery); full `swift test`: 347 tests, 45 fixture-dependent skips, zero failures.
- Review: no blocking findings; added in-place recovery timing/cancellation coverage for the reviewer's validation gap. Screenshots inspected; compact accessibility layout and real headless SSH checks are running.

- Final verification: 6 unique UI regressions passed across iPhone 17 Pro and iPhone SE (3rd generation), including two-second recovery delay/cancellation, real headless SSH, and maximum accessibility type in portrait/landscape. Review validation gap is covered.
- Signed Release build `1.0.0 (2026102401)` and strict codesign validation passed.
