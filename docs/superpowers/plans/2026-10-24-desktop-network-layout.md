# Desktop network statistics: Android parity

**Goal:** Apply the user's correction: keep the original portrait layout and display statistics at the top left in landscape, matching Android.
**Reference:** Android PR 218, commit `e759b75380fd1a0a1bbd64cd7b130b9a0828722b`, `DesktopPage.kt` (`DesktopRail`, `DesktopStatusOverlay`, `NetworkStats`). This replaces the separate statistics strip/sidebar introduced in `0e7df0e`.
**Layout:** Restore the portrait controls and statistics presentation exactly from `d01b26d`, plus the 72-point landscape rail. Only the landscape overlay adopts Android's top-left anchor with an 8-point outer inset, 11-point monospaced text, 14-point rows, 7/4-point inner padding, a 6-point corner radius and translucent black background. Its compact poor-network/recovering badge uses the same anchor.
**Behavior:** Preserve measurements, show/hide preference, desktop viewport dimensions, keyboard behavior, input mapping and connection status cards. Landscape network information appears once a picture is available, as Android does; portrait behavior is unchanged.

- [x] Inspect current Android PR 218 and the original iOS layout.
- [x] Restore the original controls and top-left overlay; remove the separate statistics layout.
- [x] Verify portrait/landscape, both languages, show/hide without viewport changes, keyboard and warning placement; inspect screenshots.
- [x] Review and prepare the signed IPA.

Validation: iPhone 17 Pro simulator passed the four layout/keyboard scenarios (`FinalStandard.xcresult` plus the corrected switch-selector rerun in `FinalStandardToggle.xcresult`). iPhone SE (3rd generation) passed all three network layout scenarios in `FinalCompactSerial.xcresult`; its simulator needed a restart to respond to orientation changes. The existing keyboard test passed without changing its assertions. Screenshots confirm the original portrait presentation and Android-style landscape overlay. Release build `2026102403` succeeded and passed strict code-signing verification. No physical-device validation is claimed.

Delivery uses PR 47 and the existing dev OTA catalog on port 18780. Preserve historical builds and verify the HTTPS manifest and freshly downloaded IPA hash. Validation evidence lives in `/tmp/roamtty-desktop-stats-parity/`.
