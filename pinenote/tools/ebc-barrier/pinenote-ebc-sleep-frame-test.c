#include "ebc-barrier.h"
#include "ack-wait.h"
#include "reader-scan.h"
#include "signal-guard.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "build/include/uapi/drm/rockchip_ebc_drm.h"

_Static_assert(sizeof(struct drm_rockchip_ebc_refresh_barrier) == 40, "barrier ABI size");
_Static_assert(sizeof(struct ebc_barrier_request) == sizeof(struct drm_rockchip_ebc_refresh_barrier), "request ABI size");
_Static_assert(offsetof(struct ebc_barrier_request, version) == offsetof(struct drm_rockchip_ebc_refresh_barrier, version), "request version offset");
_Static_assert(offsetof(struct ebc_barrier_request, op) == offsetof(struct drm_rockchip_ebc_refresh_barrier, op), "request op offset");
_Static_assert(offsetof(struct ebc_barrier_request, request_id) == offsetof(struct drm_rockchip_ebc_refresh_barrier, request_id), "request id offset");
_Static_assert(offsetof(struct ebc_barrier_request, timeout_ms) == offsetof(struct drm_rockchip_ebc_refresh_barrier, timeout_ms), "request timeout offset");
_Static_assert(offsetof(struct ebc_barrier_request, result) == offsetof(struct drm_rockchip_ebc_refresh_barrier, result), "request result offset");
_Static_assert(offsetof(struct ebc_barrier_request, reserved) == offsetof(struct drm_rockchip_ebc_refresh_barrier, reserved), "request reserved offset");
_Static_assert(offsetof(struct drm_rockchip_ebc_refresh_barrier, version) == 0, "version offset");
_Static_assert(offsetof(struct drm_rockchip_ebc_refresh_barrier, op) == 4, "op offset");
_Static_assert(offsetof(struct drm_rockchip_ebc_refresh_barrier, request_id) == 8, "id offset");
_Static_assert(offsetof(struct drm_rockchip_ebc_refresh_barrier, timeout_ms) == 16, "timeout offset");
_Static_assert(offsetof(struct drm_rockchip_ebc_refresh_barrier, result) == 20, "result offset");
_Static_assert(offsetof(struct drm_rockchip_ebc_refresh_barrier, reserved) == 24, "reserved offset");
_Static_assert(DRM_IOCTL_ROCKCHIP_EBC_REFRESH_BARRIER == 0xC0286443UL, "barrier ioctl");
_Static_assert(EBC_BARRIER_VERSION == DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION, "barrier version");
_Static_assert(EBC_BARRIER_SUBMIT == DRM_ROCKCHIP_EBC_REFRESH_BARRIER_SUBMIT, "barrier submit op");
_Static_assert(EBC_BARRIER_WAIT == DRM_ROCKCHIP_EBC_REFRESH_BARRIER_WAIT, "barrier wait op");

static volatile sig_atomic_t interrupted;
static struct ebc_signal_guard signal_guard;

static void on_signal(int signal_number)
{
    (void)signal_number;
    interrupted = 1;
}

static int negative_errno(void)
{
    return errno == 0 ? -EIO : -errno;
}

static int is_decimal_name(const char *name)
{
    const unsigned char *p = (const unsigned char *)name;
    if (*p == '\0')
        return 0;
    while (*p != '\0') {
        if (*p < '0' || *p > '9')
            return 0;
        p++;
    }
    return 1;
}

static int reader_running(void *context)
{
    DIR *proc;
    struct dirent *entry;
    int result = 0;
    (void)context;
    proc = opendir("/proc");
    if (proc == NULL)
        return negative_errno();
    for (;;) {
        char path[64];
        char buffer[4096];
        ssize_t length;
        size_t start = 0, i;
        int next = ebc_reader_scan_next(proc, readdir, &entry);
        if (next < 0) {
            result = next;
            break;
        }
        if (next == 0)
            break;
        if (!is_decimal_name(entry->d_name))
            continue;
        if (snprintf(path, sizeof(path), "/proc/%s/cmdline", entry->d_name) >= (int)sizeof(path))
            continue;
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            if (errno == ENOENT || errno == ESRCH)
                continue;
            result = negative_errno();
            break;
        }
        do {
            length = read(fd, buffer, sizeof(buffer));
        } while (length < 0 && errno == EINTR);
        if (length < 0)
            result = negative_errno();
        if (close(fd) != 0 && result == 0)
            result = negative_errno();
        if (result != 0)
            break;
        if ((size_t)length == sizeof(buffer)) {
            result = -EOVERFLOW;
            break;
        }
        for (i = 0; i <= (size_t)length; i++) {
            if (i == (size_t)length || buffer[i] == '\0') {
                if (i - start == strlen("reader.lua") &&
                    memcmp(buffer + start, "reader.lua", strlen("reader.lua")) == 0) {
                    closedir(proc);
                    return 1;
                }
                start = i + 1;
            }
        }
    }
    if (closedir(proc) != 0 && result == 0)
        result = negative_errno();
    return result;
}

static int cancellation_pending(void *context)
{
    (void)context;
    return ebc_signal_guard_pending(&signal_guard);
}

static int tty_open(void *context)
{
    int fd;
    (void)context;
    fd = open("/dev/tty", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return negative_errno();
    if (!isatty(fd)) {
        close(fd);
        return -ENOTTY;
    }
    return fd;
}

static int fb_open(void *context) { (void)context; int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC); return fd < 0 ? negative_errno() : fd; }
static int card_open(void *context) { (void)context; int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC); return fd < 0 ? negative_errno() : fd; }
static int close_fd(void *context, int fd) { (void)context; return close(fd) == 0 ? 0 : negative_errno(); }

static int fb_info(void *context, int fd, struct ebc_barrier_fb_info *info)
{
    struct fb_fix_screeninfo fixed;
    struct fb_var_screeninfo variable;
    (void)context;
    if (ioctl(fd, FBIOGET_FSCREENINFO, &fixed) != 0 ||
        ioctl(fd, FBIOGET_VSCREENINFO, &variable) != 0)
        return negative_errno();
    info->line_length = fixed.line_length;
    info->smem_len = fixed.smem_len;
    info->xres = variable.xres;
    info->yres = variable.yres;
    info->xres_virtual = variable.xres_virtual;
    info->yres_virtual = variable.yres_virtual;
    info->xoffset = variable.xoffset;
    info->yoffset = variable.yoffset;
    info->bits_per_pixel = variable.bits_per_pixel;
    info->visual = fixed.visual;
    info->type = fixed.type;
    return 0;
}

static void *map_fb(void *context, int fd, size_t length)
{
    void *address;
    (void)context;
    address = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    return address == MAP_FAILED ? NULL : address;
}
static int unmap_fb(void *context, void *address, size_t length) { (void)context; return munmap(address, length) == 0 ? 0 : negative_errno(); }
static void *allocate(void *context, size_t length) { (void)context; return malloc(length); }
static void deallocate(void *context, void *address) { (void)context; free(address); }
static void copy_memory(void *context, void *destination, const void *source, size_t length, int restore)
{ (void)context; (void)restore; memcpy(destination, source, length); }
static int paint(void *context, uint8_t *pixels, const struct ebc_barrier_fb_info *info, size_t length)
{
    (void)context;
    ebc_barrier_paint_card(pixels, info, length);
    return 0;
}
static int sync_fb(void *context, int fd) { (void)context; return fsync(fd) == 0 ? 0 : negative_errno(); }

static int barrier_ioctl(void *context, int fd, struct ebc_barrier_request *request)
{
    struct drm_rockchip_ebc_refresh_barrier abi;
    int rc;
    (void)context;
    memcpy(&abi, request, sizeof(abi));
    rc = ioctl(fd, DRM_IOCTL_ROCKCHIP_EBC_REFRESH_BARRIER, &abi);
    memcpy(request, &abi, sizeof(abi));
    return rc == 0 ? 0 : negative_errno();
}

static int ack(void *context, int tty_fd)
{
    (void)context;
    return ebc_barrier_wait_for_ack(tty_fd, &signal_guard.acknowledgement_mask,
                                    &interrupted);
}

static void message(void *context, const char *text, uint64_t request_id)
{
    (void)context;
    fprintf(stderr, "pinenote-ebc-sleep-frame-test: %s (generation %llu)\n", text,
            (unsigned long long)request_id);
}

static void usage(FILE *stream)
{
    fprintf(stream, "usage: pinenote-ebc-sleep-frame-test --help | --run\n"
            "\n"
            "--run is root-only and must be supervised on an interactive /dev/tty. It\n"
            "refuses while reader-session runs reader.lua, snapshots all fb0 virtual\n"
            "storage, paints a visible test card, waits for EBC completion, then waits\n"
            "for an explicit Enter before restoring the exact snapshot. It never\n"
            "requests suspend or writes power, firmware, partition, boot, input,\n"
            "frontlight, or network state.\n");
}

int main(int argc, char **argv)
{
    struct ebc_barrier_ops ops = {
        reader_running, cancellation_pending, tty_open, fb_open, fb_info, map_fb, unmap_fb, allocate,
        deallocate, copy_memory, paint, sync_fb, card_open, barrier_ioctl, ack, message, close_fd
    };
    struct ebc_barrier_outcome outcome;

    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        usage(stdout);
        return 0;
    }
    if (argc != 2 || strcmp(argv[1], "--run") != 0) {
        usage(stderr);
        return 2;
    }
    if (geteuid() != 0) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: --run requires root\n");
        return 1;
    }
    if (ebc_signal_guard_begin(&signal_guard, on_signal) != 0) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: could not establish signal guard\n");
        return 1;
    }
    outcome = ebc_barrier_run(&ops, NULL);
    {
        int mask_error = ebc_signal_guard_end(&signal_guard);
        if (mask_error != 0) {
            fprintf(stderr, "pinenote-ebc-sleep-frame-test: could not restore signal state\n");
        if (outcome.cleanup_error == 0)
            outcome.cleanup_error = mask_error;
        if (outcome.result == EBC_BARRIER_OK) {
            outcome.result = EBC_BARRIER_CLEANUP_FAILURE;
            outcome.error = mask_error;
        }
        }
    }
    if (outcome.result == EBC_BARRIER_REFUSED_READER) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: herd stop reader-session is required\n");
    } else if (outcome.result == EBC_BARRIER_REFUSED_TTY) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: an interactive /dev/tty is required\n");
    } else if (outcome.result == EBC_BARRIER_RESTORE_FAILURE) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: restore failed (%d; primary error %d; cleanup error %d); panel/framebuffer state is uncertain until reboot\n", outcome.restore_error, outcome.error, outcome.cleanup_error);
    } else if (outcome.result == EBC_BARRIER_ACK_FAILURE_RESTORED) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: acknowledgement interrupted (%d; cleanup error %d); exact snapshot was restored\n", outcome.error, outcome.cleanup_error);
    } else if (outcome.result == EBC_BARRIER_CLEANUP_FAILURE) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: operation completed but cleanup failed (%d)\n", outcome.cleanup_error);
    } else if (outcome.result != EBC_BARRIER_OK) {
        fprintf(stderr, "pinenote-ebc-sleep-frame-test: initial operation failed (%d; cleanup error %d); no restore or further EBC start was attempted\n", outcome.error, outcome.cleanup_error);
    }
    return outcome.result == EBC_BARRIER_OK ? 0 : 1;
}
