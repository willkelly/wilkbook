#include "ebc-barrier.h"

#include <errno.h>
#include <limits.h>
#include <string.h>

#define EBC_BARRIER_MAX_SNAPSHOT (64U * 1024U * 1024U)
#define EBC_BARRIER_XRGB8888 2U
#define EBC_BARRIER_PACKED_PIXELS 0U

static int submit_and_wait(const struct ebc_barrier_ops *ops, void *context,
                           int card_fd, uint64_t *request_id)
{
    struct ebc_barrier_request request = {0};
    uint64_t id;
    int rc;

    request.version = EBC_BARRIER_VERSION;
    request.op = EBC_BARRIER_SUBMIT;
    rc = ops->barrier(context, card_fd, &request);
    if (rc != 0 || request.version != EBC_BARRIER_VERSION ||
        request.op != EBC_BARRIER_SUBMIT || request.timeout_ms != 0 ||
        request.reserved[0] != 0 || request.reserved[1] != 0 ||
        request.reserved[2] != 0 || request.reserved[3] != 0)
        return rc != 0 ? rc : -EPROTO;
    if (request.result < 0 && request.result != -EINPROGRESS)
        return request.request_id == 0 ? request.result : -EPROTO;
    if (request.request_id == 0 || request.result != -EINPROGRESS)
        return -EPROTO;

    id = request.request_id;
    *request_id = id;
    memset(&request, 0, sizeof(request));
    request.version = EBC_BARRIER_VERSION;
    request.op = EBC_BARRIER_WAIT;
    request.request_id = id;
    request.timeout_ms = EBC_BARRIER_TIMEOUT_MS;
    rc = ops->barrier(context, card_fd, &request);
    if (rc != 0 || request.version != EBC_BARRIER_VERSION ||
        request.op != EBC_BARRIER_WAIT || request.request_id != id ||
        request.timeout_ms != EBC_BARRIER_TIMEOUT_MS || request.reserved[0] != 0 ||
        request.reserved[1] != 0 || request.reserved[2] != 0 ||
        request.reserved[3] != 0)
        return rc != 0 ? rc : -EPROTO;
    if (request.result == -EINPROGRESS)
        return -ETIMEDOUT;
    if (request.result < 0)
        return request.result;
    if (request.result != 0)
        return -EPROTO;
    return 0;
}

int ebc_barrier_validate_geometry(const struct ebc_barrier_fb_info *info,
                                  size_t *snapshot_length)
{
    size_t length;
    uint64_t virtual_row_bytes = (uint64_t)info->xres_virtual * 4U;

    if (info->visual != EBC_BARRIER_XRGB8888 ||
        info->type != EBC_BARRIER_PACKED_PIXELS || info->bits_per_pixel != 32 ||
        info->line_length % sizeof(uint32_t) != 0 ||
        info->line_length == 0 || info->xres == 0 || info->yres == 0 ||
        info->xres_virtual == 0 || info->yres_virtual == 0 ||
        info->xoffset > info->xres_virtual || info->yoffset > info->yres_virtual ||
        info->xres > info->xres_virtual - info->xoffset ||
        info->yres > info->yres_virtual - info->yoffset ||
        (uint64_t)info->line_length < virtual_row_bytes)
        return -EINVAL;
    if (info->yres_virtual > SIZE_MAX / info->line_length)
        return -EOVERFLOW;
    length = (size_t)info->line_length * info->yres_virtual;
    if (length == 0 || length > EBC_BARRIER_MAX_SNAPSHOT ||
        info->smem_len == 0 || length > info->smem_len)
        return -EOVERFLOW;
    *snapshot_length = length;
    return 0;
}

void ebc_barrier_paint_card(uint8_t *pixels,
                            const struct ebc_barrier_fb_info *info,
                            size_t snapshot_length)
{
    uint32_t x, y;

    memset(pixels, 0, snapshot_length);
    for (y = 0; y < info->yres; y++) {
        uint32_t *row = (uint32_t *)(pixels +
                                     (size_t)(info->yoffset + y) * info->line_length +
                                     (size_t)info->xoffset * 4U);
        for (x = 0; x < info->xres; x++) {
            int border = x == 0 || y == 0 || x + 1 == info->xres || y + 1 == info->yres;
            int diagonal = x == y || x + y + 1 == info->xres;
            int center = x >= info->xres / 2U - 2U && x <= info->xres / 2U + 2U &&
                         y >= info->yres / 2U - 2U && y <= info->yres / 2U + 2U;
            row[x] = (border || diagonal || center) ? 0xff000000U : 0xffffffffU;
        }
    }
}

struct ebc_barrier_outcome ebc_barrier_run(const struct ebc_barrier_ops *ops,
                                           void *context)
{
    struct ebc_barrier_outcome outcome = { EBC_BARRIER_INITIAL_FAILURE, 0, 0, 0, 0, 0 };
    struct ebc_barrier_fb_info info;
    uint8_t *mapping = NULL;
    uint8_t *snapshot = NULL;
    size_t length = 0;
    int tty_fd = -1, fb_fd = -1, card_fd = -1;
    int rc;
    int armed = 0;

    rc = ops->reader_running(context);
    if (rc > 0) {
        outcome.result = EBC_BARRIER_REFUSED_READER;
        outcome.error = -EBUSY;
        return outcome;
    }
    if (rc < 0) {
        outcome.error = rc;
        return outcome;
    }
    tty_fd = ops->tty_open(context);
    if (tty_fd < 0) {
        outcome.result = EBC_BARRIER_REFUSED_TTY;
        outcome.error = tty_fd;
        return outcome;
    }
    fb_fd = ops->fb_open(context);
    if (fb_fd < 0) {
        outcome.error = fb_fd;
        goto out;
    }
    rc = ops->fb_info(context, fb_fd, &info);
    if (rc != 0 || (rc = ebc_barrier_validate_geometry(&info, &length)) != 0) {
        outcome.error = rc != 0 ? rc : -EINVAL;
        goto out;
    }
    mapping = ops->map(context, fb_fd, length);
    if (mapping == NULL) {
        outcome.error = -ENOMEM;
        goto out;
    }
    snapshot = ops->alloc(context, length);
    if (snapshot == NULL) {
        outcome.error = -ENOMEM;
        goto out;
    }
    card_fd = ops->card_open(context);
    if (card_fd < 0) {
        outcome.error = card_fd;
        goto out;
    }
    rc = ops->reader_running(context);
    if (rc > 0) {
        outcome.result = EBC_BARRIER_REFUSED_READER;
        outcome.error = -EBUSY;
        goto out;
    }
    if (rc < 0) {
        outcome.error = rc;
        goto out;
    }
    rc = ops->cancelled(context);
    if (rc > 0) {
        outcome.error = -EINTR;
        goto out;
    }
    if (rc < 0) {
        outcome.error = rc;
        goto out;
    }
    ops->copy(context, snapshot, mapping, length, 0);
    rc = ops->cancelled(context);
    if (rc > 0) {
        outcome.error = -EINTR;
        goto out;
    }
    if (rc < 0) {
        outcome.error = rc;
        goto out;
    }
    rc = ops->paint(context, mapping, &info, length);
    if (rc != 0) {
        outcome.error = rc;
        goto out;
    }
    rc = ops->fsync(context, fb_fd);
    if (rc != 0) {
        outcome.error = rc;
        goto out;
    }
    rc = submit_and_wait(ops, context, card_fd, &outcome.initial_request_id);
    if (rc != 0) {
        outcome.error = rc;
        goto out;
    }
    armed = 1;
    ops->message(context, "sleep frame is visible; press Enter on /dev/tty to restore", outcome.initial_request_id);
    rc = ops->ack(context, tty_fd);
    if (rc != 0) {
        outcome.error = rc;
        goto restore;
    }

restore:
    armed = 0;
    ops->copy(context, mapping, snapshot, length, 1);
    rc = ops->fsync(context, fb_fd);
    if (rc == 0)
        rc = submit_and_wait(ops, context, card_fd, &outcome.restore_request_id);
    if (rc != 0) {
        outcome.result = EBC_BARRIER_RESTORE_FAILURE;
        outcome.restore_error = rc;
        if (outcome.error == 0)
            outcome.error = rc;
    } else if (outcome.error != 0) {
        outcome.result = EBC_BARRIER_ACK_FAILURE_RESTORED;
    } else {
        ops->message(context, "exact snapshot restored", outcome.restore_request_id);
        outcome.result = EBC_BARRIER_OK;
    }
out:
    if (armed)
        outcome.result = EBC_BARRIER_INITIAL_FAILURE;
    if (card_fd >= 0 && (rc = ops->close(context, card_fd)) != 0 && outcome.cleanup_error == 0)
        outcome.cleanup_error = rc;
    if (snapshot != NULL)
        ops->free(context, snapshot);
    if (mapping != NULL && (rc = ops->unmap(context, mapping, length)) != 0 && outcome.cleanup_error == 0)
        outcome.cleanup_error = rc;
    if (fb_fd >= 0 && (rc = ops->close(context, fb_fd)) != 0 && outcome.cleanup_error == 0)
        outcome.cleanup_error = rc;
    if (tty_fd >= 0 && (rc = ops->close(context, tty_fd)) != 0 && outcome.cleanup_error == 0)
        outcome.cleanup_error = rc;
    if (outcome.cleanup_error != 0 && outcome.result == EBC_BARRIER_OK) {
        outcome.result = EBC_BARRIER_CLEANUP_FAILURE;
        outcome.error = outcome.cleanup_error;
    }
    return outcome;
}
