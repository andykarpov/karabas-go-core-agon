/* VDP firmware: newlib system calls (from core-doom). Console = MMIO, heap up to __heap_end,
   time from the microsecond counter. No files. */
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include "mmio.h"

extern char __heap_start[], __heap_end[];
static char *brk_ptr = __heap_start;

void *_sbrk(ptrdiff_t incr) {
    char *old = brk_ptr;
    if (brk_ptr + incr > __heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    brk_ptr += incr;
    return old;
}

int _write(int fd, const char *buf, int len) {
    if (fd != 1 && fd != 2) { errno = EBADF; return -1; }
    for (int i = 0; i < len; i++) MMIO_CON = (uint8_t)buf[i];
    return len;
}
int _read(int fd, char *buf, int len) { (void)fd; (void)buf; (void)len; return 0; }
int _open(const char *name, int flags, int mode) { (void)name; (void)flags; (void)mode; errno = ENOENT; return -1; }
int _close(int fd) { (void)fd; return -1; }
int _fstat(int fd, struct stat *st) { (void)fd; memset(st, 0, sizeof *st); st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _lseek(int fd, int off, int whence) { (void)fd; (void)off; (void)whence; return 0; }
int _unlink(const char *name) { (void)name; errno = ENOENT; return -1; }
int _link(const char *a, const char *b) { (void)a; (void)b; errno = EMLINK; return -1; }
int _stat(const char *name, struct stat *st) { (void)name; memset(st, 0, sizeof *st); errno = ENOENT; return -1; }
int _getpid(void) { return 1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
clock_t _times(struct tms *t) { (void)t; return (clock_t)MMIO_MS; }
int _gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    uint32_t hi, lo;
    do { hi = MMIO_US_HI; lo = MMIO_US_LO; } while (hi != MMIO_US_HI);
    uint64_t us = ((uint64_t)hi << 32) | lo;
    tv->tv_sec = (time_t)(us / 1000000u);
    tv->tv_usec = (suseconds_t)(us % 1000000u);
    return 0;
}
void _exit(int code) {
    MMIO_EXIT = (uint32_t)code;
    for (;;) {}
}

/* -nostartfiles leaves out crtbegin: the handle for __cxa_atexit of static C++ objects */
void *__dso_handle = &__dso_handle;

/* rv32im has no A extension and libatomic is not in the toolchain: one core, cooperative tasks,
   so a plain read-compare-write is atomic enough (no interrupt handler touches these objects) */
_Bool __atomic_compare_exchange_1(volatile void *p, void *expected, unsigned char desired, _Bool weak, int s, int f) {
    (void)weak; (void)s; (void)f;
    volatile unsigned char *v = p;
    unsigned char *e = expected;
    if (*v == *e) { *v = desired; return 1; }
    *e = *v;
    return 0;
}
