# libssh2 and the per-session heap

- iOS: `apotocki/libssh2-iosx` 1.11.1.0 (`scripts/bootstrap-native.sh`, SHA-256 pinned)
- Linux tests: built from `NativeBuild/libssh2`

## AES-GCM key-exchange leak (libssh2 #1951)

Under `aes256-gcm@openssh.com` / `aes128-gcm@openssh.com`, which the app prefers, libssh2 1.11.1 derives the
client and server MAC keys on every key exchange and hands them to the GCM stub `mac_method_none_init`, which
neither keeps them nor sets `free_key`. Two 48-byte buffers are lost per connection and per rekey. Upstream fixed
it on 2026-05-26 (`91b0d46`, #1952); no release carries the fix yet.

Instruments Leaks on the iPhone 13 (`MallocStackLogging=1`, shell and tmux session cycles) found 26 leaks for
13 connections, all in `kex_method_curve25519_key_exchange` (the inlined key derivation).

Rather than patch the prebuilt library or move the cipher preference off GCM, `Sources/CNative/ssh_heap.c` gives
each session made by `SSHConnection.connect()` its own allocator. Every block is linked into the session's list,
and once `libssh2_session_free` returns, `roam_ssh_heap_destroy` wipes and frees whatever libssh2 left behind. The
same run then reports 0 leaks, and `SSHConnection.reclaimedNativeBlocks` counts the 26 blocks the heap released.

Consequences for code that touches the session:

- The session's abstract is the heap. Callbacks read their own pointer with `roam_ssh_user(abstract)`; tests that
  swap it use `roam_ssh_set_user`.
- Memory libssh2 frees itself (keyboard-interactive answers) must come from `roam_ssh_alloc`.

Drop the heap once a libssh2 release with the fix is pinned, or keep it as a guard against later per-session leaks.
