#pragma once
#include <sqlite3.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <openssl/rand.h>
#include <zlib.h>
int roam_ocb(int encrypt, const unsigned char *key, const unsigned char *nonce,
             const unsigned char *input, int length, unsigned char *output, unsigned char *tag);
void roam_sha256(const unsigned char *input, size_t length, unsigned char *output);
int roam_tcp_connect(const char *host, int port, int timeout_ms);
int roam_socket_poll(int socket, int read_ready, int write_ready, int timeout_ms);
void roam_socket_shutdown(int socket);
void roam_socket_close(int socket);
// A TCP listener on 127.0.0.1: on `preferred` when that is free (1024-65535), else on any port. Returns the descriptor
// and writes the port it got, or returns -1.
int roam_listen_loopback(int preferred, int *port);
// Waits at most `timeout_ms` for a connection on a listener: the client's descriptor, -2 after the timeout, -1 on error.
int roam_socket_accept(int listener, int timeout_ms);
// Blocking reads and writes on a connected socket, never raising SIGPIPE. recv returns 0 at the end, -1 on error;
// send_all returns 0 once every byte went, -1 on error.
long roam_socket_recv(int socket, void *buffer, size_t length);
int roam_socket_send_all(int socket, const void *buffer, size_t length);
// Ends what this side sends; the peer still sends what it has.
void roam_socket_shutdown_write(int socket);
// Numeric address of a connected socket's peer, written into `host`. Returns zero on success.
int roam_socket_peer(int socket, char *host, int length);
// A libssh2 session's own allocator. libssh2 1.11.1 drops the MAC keys of every key exchange under AES-GCM
// (libssh2 #1951), so whatever a session still holds once libssh2_session_free returns is wiped and released
// by roam_ssh_heap_destroy. The session's abstract is the heap; `user` is what callbacks were given.
typedef struct roam_ssh_heap roam_ssh_heap;
roam_ssh_heap *roam_ssh_heap_create(void *user);
LIBSSH2_SESSION *roam_ssh_session_init(roam_ssh_heap *heap);
// The `user` of a session made by roam_ssh_session_init, from a libssh2 callback's abstract.
void *roam_ssh_user(void **abstract);
// Replaces the session's `user`, returning the previous one.
void *roam_ssh_set_user(LIBSSH2_SESSION *session, void *user);
// Memory libssh2 will free itself, such as keyboard-interactive responses.
void *roam_ssh_alloc(void **abstract, size_t size);
// Blocks (and their bytes) the session holds now.
size_t roam_ssh_heap_live(roam_ssh_heap *heap, size_t *bytes);
// Releases the heap after libssh2_session_free; returns how many blocks libssh2 had left behind.
size_t roam_ssh_heap_destroy(roam_ssh_heap *heap, size_t *bytes);
// Atomic, same-volume move that refuses to replace any existing destination. Returns errno or zero.
int roam_move_exclusive(const char *source, const char *destination);
