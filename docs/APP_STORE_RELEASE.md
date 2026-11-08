# App Store release configuration

The 2026-10-26 initial release uses standard encryption in libssh2/OpenSSL, mosh and the remote desktop transport. It does not implement proprietary cryptographic algorithms. France and mainland China are excluded; EU territories are also excluded pending trader-status verification.

App Store Connect’s encryption questionnaire (standard algorithms in addition to the OS; no France distribution) states that no encryption document is required. `ITSAppUsesNonExemptEncryption` is therefore `false`, indicating exemption from documentation, not absence of cryptography. The previous `true` declaration without an approved compliance code caused upload error 90592.

Re-run the questionnaire before changing encryption or enabling France. Do not expand territories automatically. Apple’s guidance: https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/
