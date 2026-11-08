# Roamtty iOS implementation

Baseline: yahaa/roamtty main bee299d82249e255be7169d7c9f1d60c4c5f5609, tree 56e205d2f82ee509431bf3a36dab69ccd5656445.

Goal: Swift iOS application matching the Android baseline's user-visible features and design. iOS 16+, SwiftUI + UIKit/SwiftTerm, libssh2/OpenSSL, SQLite and device-only Keychain. No telemetry, cloud account or local shell. Android source remains untouched.

1. Establish standalone repository, native dependencies, core tests and Xcode app/share-extension/UI-test targets.
2. Host editing, authentication/trust, system metrics, independent shell/tmux sessions and reconnect.
3. Native terminal, gestures/IME/fonts, history, toolbox ghost, agent launch/shortcuts.
4. SFTP browser/preview/transfer queue, Files destinations and share extension.
5. Appearance/localization/lifecycle, integration tests, visual and physical-device checks.

All settings and behavior follow Android source and tests. SQLite owns metadata/trust/journal; secrets are separate, device-only Keychain values; private-key passphrases and terminal text never persist. Input is bounded and never replayed after reconnect. iOS suspension is handled through limited background execution and tmux reattachment, not indefinite keepalive.

Acceptance: unit and live OpenSSH/mosh tests, native Xcode builds, UI screenshots and full simulator workflows. A paired iPhone is used where its system permissions permit; the user explicitly authorized creating a simulator when physical automation is unavailable. Unavailable checks must be reported as unverified, never passed.
