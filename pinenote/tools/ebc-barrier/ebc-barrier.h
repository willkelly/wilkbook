#ifndef PINENOTE_EBC_BARRIER_H
#define PINENOTE_EBC_BARRIER_H

#include <stddef.h>
#include <stdint.h>

#define EBC_BARRIER_VERSION 1U
#define EBC_BARRIER_SUBMIT 1U
#define EBC_BARRIER_WAIT 2U
#define EBC_BARRIER_TIMEOUT_MS 10000U

struct ebc_barrier_fb_info {
    uint32_t line_length;
    uint32_t smem_len;
    uint32_t xres;
    uint32_t yres;
    uint32_t xres_virtual;
    uint32_t yres_virtual;
    uint32_t xoffset;
    uint32_t yoffset;
    uint32_t bits_per_pixel;
    uint32_t visual;
    uint32_t type;
};

struct ebc_barrier_request {
    uint32_t version;
    uint32_t op;
    uint64_t request_id;
    uint32_t timeout_ms;
    int32_t result;
    uint32_t reserved[4];
};

struct ebc_barrier_ops {
    int (*reader_running)(void *context);
    int (*cancelled)(void *context);
    int (*tty_open)(void *context);
    int (*fb_open)(void *context);
    int (*fb_info)(void *context, int fd, struct ebc_barrier_fb_info *info);
    void *(*map)(void *context, int fd, size_t length);
    int (*unmap)(void *context, void *address, size_t length);
    void *(*alloc)(void *context, size_t length);
    void (*free)(void *context, void *address);
    void (*copy)(void *context, void *destination, const void *source,
                 size_t length, int restore);
    int (*paint)(void *context, uint8_t *pixels,
                 const struct ebc_barrier_fb_info *info, size_t length);
    int (*fsync)(void *context, int fd);
    int (*card_open)(void *context);
    int (*barrier)(void *context, int fd, struct ebc_barrier_request *request);
    int (*ack)(void *context, int tty_fd);
    void (*message)(void *context, const char *message, uint64_t request_id);
    int (*close)(void *context, int fd);
};

enum ebc_barrier_result {
    EBC_BARRIER_OK = 0,
    EBC_BARRIER_REFUSED_READER,
    EBC_BARRIER_REFUSED_TTY,
    EBC_BARRIER_INITIAL_FAILURE,
    EBC_BARRIER_ACK_FAILURE_RESTORED,
    EBC_BARRIER_RESTORE_FAILURE,
    EBC_BARRIER_CLEANUP_FAILURE,
};

struct ebc_barrier_outcome {
    enum ebc_barrier_result result;
    int error;
    int restore_error;
    int cleanup_error;
    uint64_t initial_request_id;
    uint64_t restore_request_id;
};

int ebc_barrier_validate_geometry(const struct ebc_barrier_fb_info *info,
                                  size_t *snapshot_length);
void ebc_barrier_paint_card(uint8_t *pixels,
                            const struct ebc_barrier_fb_info *info,
                            size_t snapshot_length);
struct ebc_barrier_outcome ebc_barrier_run(const struct ebc_barrier_ops *ops,
                                           void *context);

#endif
