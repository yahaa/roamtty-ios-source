# Privacy architecture

This source snapshot is provided for inspection; it is not a security certification.

- Saved SSH passwords and private keys use device-only Keychain items, with synchronization disabled. Key passphrases are held in memory.
- Host profiles, settings and session metadata are stored locally. The app database directory is excluded from backup.
- Desktop previews are saved as local JPEG thumbnails. Deleting a host removes its thumbnail.
- Agent integration installs hooks on the chosen host. tmux session options include up to 200 characters of the latest prompt and up to 400 characters of the latest reply. Other processes with access to that user account may read them.
- Connections use the hosts configured by the user. Desktop plugin installation may fetch binaries from GitHub and OpenH264 binaries from Cisco; these services receive ordinary network request metadata.
- AI tools and their providers have their own data handling and account policies. This app does not prevent account bans or override provider requirements.

Implementation pointers: SecretVault.swift, AppStore.swift, DesktopThumbnails.swift, agent-hook.sh, DesktopPluginInstaller.swift and UdpWire.swift.
