#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "CNative.h"
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <linux/fs.h>
#endif

int roam_move_exclusive(const char *source, const char *destination) {
    int result;
#if defined(__APPLE__)
    result = renamex_np(source, destination, RENAME_EXCL);
#elif defined(__linux__)
    result = (int)syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE);
#else
    return ENOTSUP;
#endif
    return result == 0 ? 0 : errno;
}
