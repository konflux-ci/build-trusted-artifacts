#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stddef.h>

int close(int fd) {
    static int (*real_close)(int) = NULL;
    if (!real_close)
        real_close = dlsym(RTLD_NEXT, "close");
    posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
    return real_close(fd);
}
