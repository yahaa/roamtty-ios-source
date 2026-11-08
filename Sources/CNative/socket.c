#include "CNative.h"
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <time.h>

int roam_socket_poll(int fd, int rd, int wr, int timeout_ms) {
    struct pollfd p = { .fd = fd, .events = (rd ? POLLIN : 0) | (wr ? POLLOUT : 0) };
    return poll(&p, 1, timeout_ms);
}
int roam_tcp_connect(const char *host, int port, int timeout_ms) {
    char service[8]; snprintf(service, sizeof(service), "%d", port);
    struct addrinfo hints = {0}, *list = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, service, &hints, &list) != 0) return -1;
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
    int fd = -1;
    for (struct addrinfo *a = list; a; a = a->ai_next) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        int remaining = timeout_ms - (int)((now.tv_sec-start.tv_sec)*1000 + (now.tv_nsec-start.tv_nsec)/1000000);
        if (remaining <= 0) break;
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        int yes = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if (rc == 0) break;
        if (errno == EINPROGRESS && roam_socket_poll(fd, 0, 1, remaining) > 0) {
            int error = 0; socklen_t len = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0) break;
        }
        close(fd); fd = -1;
    }
    freeaddrinfo(list); return fd;
}
void roam_socket_shutdown(int fd) { if (fd >= 0) shutdown(fd, SHUT_RDWR); }
void roam_socket_close(int fd) { if (fd >= 0) close(fd); }
int roam_socket_peer(int fd, char *host, int length) {
    struct sockaddr_storage address; socklen_t size = sizeof(address);
    if (fd < 0 || length <= 0 || getpeername(fd, (struct sockaddr *)&address, &size) != 0) return -1;
    return getnameinfo((struct sockaddr *)&address, size, host, (socklen_t)length, NULL, 0, NI_NUMERICHOST) == 0 ? 0 : -1;
}

static int roam_bind_loopback(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons((unsigned short)port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 50) != 0) { close(fd); return -1; }
    return fd;
}
int roam_listen_loopback(int preferred, int *port) {
    int fd = preferred >= 1024 && preferred <= 65535 ? roam_bind_loopback(preferred) : -1;
    if (fd < 0) fd = roam_bind_loopback(0);
    if (fd < 0) return -1;
    struct sockaddr_in address; socklen_t size = sizeof(address);
    if (getsockname(fd, (struct sockaddr *)&address, &size) != 0) { close(fd); return -1; }
    if (port) *port = ntohs(address.sin_port);
    return fd;
}
int roam_socket_accept(int listener, int timeout_ms) {
    int ready = roam_socket_poll(listener, 1, 0, timeout_ms);
    if (ready == 0 || (ready < 0 && errno == EINTR)) return -2;
    if (ready < 0) return -1;
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return errno == EINTR || errno == EAGAIN || errno == ECONNABORTED ? -2 : -1;
    int yes = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}
long roam_socket_recv(int fd, void *buffer, size_t length) {
    for (;;) {
        ssize_t count = recv(fd, buffer, length, 0);
        if (count >= 0) return (long)count;
        if (errno != EINTR) return -1;
    }
}
int roam_socket_send_all(int fd, const void *buffer, size_t length) {
#ifdef MSG_NOSIGNAL
    int flags = MSG_NOSIGNAL;
#else
    int flags = 0;
#endif
    const char *bytes = buffer;
    while (length > 0) {
        ssize_t sent = send(fd, bytes, length, flags);
        if (sent < 0) { if (errno == EINTR) continue; return -1; }
        bytes += sent; length -= (size_t)sent;
    }
    return 0;
}
void roam_socket_shutdown_write(int fd) { if (fd >= 0) shutdown(fd, SHUT_WR); }
