# Third-party notices

Roamtty iOS is copyright 2026 Roamtty contributors, licensed under Apache-2.0. The Android implementation at `yahaa/roamtty` commit `bee299d82249e255be7169d7c9f1d60c4c5f5609` supplies the design, artwork, metrics script, and behavior adapted into Swift. See LICENSE.

| Component | Version | License |
| --- | --- | --- |
| SwiftTerm, Miguel de Icaza and contributors | 1.13.0 + [fork patches at `0a311223`](https://github.com/yahaa/SwiftTerm/commit/0a311223749cf1b96294772a2c5478be67915572); [provenance](docs/dependencies/swiftterm.md) | MIT, `licenses/SwiftTerm-MIT.txt` |
| libssh2 | 1.11.1 | BSD, `licenses/libssh2-BSD.txt` |
| OpenSSL | 3.5.9 (Apple build) | Apache-2.0, `licenses/OpenSSL-Apache-2.0.txt` |
| zlib and SQLite | Apple system libraries | zlib license / public domain |
| JetBrains Mono 2.304, Fira Code 6.2, Source Code Pro 2.042, IBM Plex Mono 1.1.0, Cascadia Mono 2404.23 | Android bundled fonts | SIL OFL 1.1, full texts in `licenses/fonts/` |
| Noto Sans Symbols 2 2.008 | Android bundled fallback font | SIL OFL 1.1 |
| Symbols Nerd Font Mono 3.5.1 | Android bundled fallback font | MIT |

Native Apple archives are pinned by SHA-256 in `scripts/bootstrap-native.sh`, from apotocki/libssh2-iosx and apotocki/openssl-iosx. The mosh protocol implementation is original Swift code implementing the published protocol; no mosh executable or GPL mosh source is shipped. OpenSSL provides its AES-OCB primitive.

Host system artwork inherited from Android includes Devicon vectors (copyright 2015 konpa, MIT), Larry Ewing's Tux, Canonical's Ubuntu Circle of Friends, Debian's swirl (copyright 1999 Software in the Public Interest, design by Raul Silva, CC BY-SA 3.0), and the CentOS symbol (copyright 2022 Alain Reguera Delgado, CC BY-SA 4.0). Artwork identifies remote systems. Associated trademarks remain their owners' property. Full texts are under `licenses/`; original source/provenance is retained in Android's `artwork/host-icons/` and `THIRD_PARTY_NOTICES.md`.

Roamtty is independent and is not affiliated with Termux, Termius, or iTerm2.
