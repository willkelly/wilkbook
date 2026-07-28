#include "ebc-barrier.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

struct fake {
    struct ebc_barrier_fb_info info;
    uint8_t framebuffer[256], original[256];
    int reader, reader_second, cancelled, cancel_after_snapshot, tty, fb, info_rc, map_fail, alloc_fail, paint_rc, fsync_at, card, barrier_fail_at;
    int result_at, result_value;
    int ack_rc, malformed_at, malformed_field, unmap_rc, close_rc[13];
    int reader_calls, cancelled_calls, tty_calls, fb_calls, map_calls, unmap_calls, alloc_calls, free_calls;
    int snapshot_copies, restore_copies, fsync_calls, card_calls, barrier_calls, ack_calls, message_calls, close_calls;
    int closes[3]; size_t mapped_length, unmapped_length; uint64_t ids[2];
};

static int reader(void *p) { struct fake *f = p; f->reader_calls++; return f->reader_calls > 1 && f->reader_second ? f->reader_second : f->reader; }
static int cancelled(void *p) { struct fake *f = p; f->cancelled_calls++; return f->cancelled; }
static int tty(void *p) { struct fake *f = p; f->tty_calls++; return f->tty ? f->tty : 10; }
static int fb(void *p) { struct fake *f = p; f->fb_calls++; return f->fb ? f->fb : 11; }
static int info(void *p, int fd, struct ebc_barrier_fb_info *out) { struct fake *f = p; (void)fd; *out = f->info; return f->info_rc; }
static void *map(void *p, int fd, size_t length) { struct fake *f = p; (void)fd; f->map_calls++; f->mapped_length = length; return f->map_fail ? NULL : f->framebuffer; }
static int unmap(void *p, void *address, size_t length) { struct fake *f = p; CHECK(address == f->framebuffer); f->unmap_calls++; f->unmapped_length = length; return f->unmap_rc; }
static void *allocate(void *p, size_t length) { struct fake *f = p; f->alloc_calls++; return f->alloc_fail ? NULL : malloc(length); }
static void deallocate(void *p, void *address) { struct fake *f = p; f->free_calls++; free(address); }
static void copy(void *p, void *dst, const void *src, size_t length, int restore)
{ struct fake *f = p; if (restore) f->restore_copies++; else { f->snapshot_copies++; if (f->cancel_after_snapshot) f->cancelled = 1; } memcpy(dst, src, length); }
static int paint(void *p, uint8_t *pixels, const struct ebc_barrier_fb_info *i, size_t length)
{ struct fake *f = p; if (f->paint_rc) return f->paint_rc; ebc_barrier_paint_card(pixels, i, length); return 0; }
static int sync(void *p, int fd) { struct fake *f = p; (void)fd; f->fsync_calls++; return f->fsync_at == f->fsync_calls ? -EIO : 0; }
static int card(void *p) { struct fake *f = p; f->card_calls++; return f->card ? f->card : 12; }

static void corrupt(struct ebc_barrier_request *r, int field)
{
    switch (field) {
    case 0: r->version++; break; case 1: r->op++; break; case 2: r->request_id ^= 1; break;
    case 3: r->timeout_ms++; break; case 4: r->result = 7; break; case 5: r->reserved[0] = 1; break;
    case 6: r->reserved[1] = 1; break; case 7: r->reserved[2] = 1; break;
    case 8: r->reserved[3] = 1; break; case 9: r->request_id = 0; break;
    default: r->result = -EINPROGRESS; break;
    }
}
static int barrier(void *p, int fd, struct ebc_barrier_request *r)
{
    struct fake *f = p; int index;
    (void)fd; f->barrier_calls++;
    CHECK(r->version == 1 && (r->op == 1 || r->op == 2));
    CHECK(r->reserved[0] == 0 && r->reserved[1] == 0 && r->reserved[2] == 0 && r->reserved[3] == 0);
    if (f->barrier_fail_at == f->barrier_calls) return -EIO;
    if (f->result_at == f->barrier_calls) {
        r->result = f->result_value;
        return 0;
    }
    index = (f->barrier_calls - 1) / 2;
    if (r->op == 1) {
        CHECK(r->request_id == 0 && r->timeout_ms == 0 && r->result == 0);
        r->request_id = UINT64_C(9007199254740999) + (uint64_t)f->barrier_calls;
        r->result = -EINPROGRESS;
    } else {
        CHECK(r->timeout_ms == 10000 && r->result == 0);
        f->ids[index] = r->request_id; r->result = 0;
    }
    if (f->malformed_at == f->barrier_calls) corrupt(r, f->malformed_field);
    return 0;
}
static int acknowledge(void *p, int fd) { struct fake *f = p; (void)fd; f->ack_calls++; return f->ack_rc; }
static void message(void *p, const char *text, uint64_t id) { struct fake *f = p; (void)text; f->message_calls++; CHECK(id > UINT64_C(9007199254740992)); }
static int close_fake(void *p, int fd) { struct fake *f = p; f->closes[f->close_calls++] = fd; return f->close_rc[fd]; }
static const struct ebc_barrier_ops ops = { reader, cancelled, tty, fb, info, map, unmap, allocate, deallocate, copy, paint, sync, card, barrier, acknowledge, message, close_fake };

static struct fake fresh(void)
{
    struct fake f; memset(&f, 0, sizeof(f));
    f.info = (struct ebc_barrier_fb_info){ .line_length = 24, .smem_len = 256, .xres = 3, .yres = 2, .xres_virtual = 5, .yres_virtual = 8, .bits_per_pixel = 32, .visual = 2, .type = 0 };
    memset(f.framebuffer, 0xa5, sizeof(f.framebuffer)); memcpy(f.original, f.framebuffer, sizeof(f.framebuffer)); return f;
}
static void cleanup(const struct fake *f, int mapped, int allocated)
{
    CHECK(f->unmap_calls == mapped && f->free_calls == allocated);
    CHECK(f->close_calls == (f->tty_calls && f->tty >= 0 ? 1 : 0) + (f->fb_calls && f->fb >= 0 ? 1 : 0) + (f->card_calls && f->card >= 0 ? 1 : 0));
    if (f->card_calls && f->card >= 0) CHECK(f->closes[0] == 12);
    if (f->fb_calls && f->fb >= 0) CHECK(f->closes[f->close_calls - 2 + !(f->tty_calls && f->tty >= 0)] == 11);
    if (f->tty_calls && f->tty >= 0) CHECK(f->closes[f->close_calls - 1] == 10);
}

static void happy_and_offsets(void)
{
    struct fake f = fresh(); struct ebc_barrier_outcome o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_OK && o.error == 0 && o.cleanup_error == 0);
    CHECK(o.initial_request_id > UINT64_C(9007199254740992) && o.restore_request_id > UINT64_C(9007199254740992));
    CHECK(o.initial_request_id != o.restore_request_id && f.ids[0] == o.initial_request_id && f.ids[1] == o.restore_request_id);
    CHECK(f.mapped_length == 192 && f.snapshot_copies == 1 && f.restore_copies == 1 && f.fsync_calls == 2 && f.barrier_calls == 4 && f.message_calls == 2);
    CHECK(memcmp(f.framebuffer, f.original, sizeof(f.framebuffer)) == 0); cleanup(&f, 1, 1);
    f = fresh(); f.info.xoffset = 1; f.info.yoffset = 2; ebc_barrier_paint_card(f.framebuffer, &f.info, 192);
    CHECK(*(uint32_t *)(f.framebuffer + 2 * 24 + 4) == 0xff000000U);
    CHECK(*(uint32_t *)(f.framebuffer + 0) == 0 && f.framebuffer[23] == 0 && f.framebuffer[191] == 0);
}

static void geometry(void)
{
    struct ebc_barrier_fb_info i = fresh().info; size_t length;
    CHECK(ebc_barrier_validate_geometry(&i, &length) == 0 && length == 192);
    i.xoffset = 3; CHECK(ebc_barrier_validate_geometry(&i, &length) == -EINVAL);
    i = fresh().info; i.yoffset = 7; CHECK(ebc_barrier_validate_geometry(&i, &length) == -EINVAL);
    i = fresh().info; i.line_length = 22; CHECK(ebc_barrier_validate_geometry(&i, &length) == -EINVAL);
    i = fresh().info; i.xres_virtual = UINT32_MAX; i.line_length = UINT32_MAX; CHECK(ebc_barrier_validate_geometry(&i, &length) != 0);
    i = fresh().info; i.smem_len = 191; CHECK(ebc_barrier_validate_geometry(&i, &length) != 0);
}

static void initial_failures(void)
{
    int which; for (which = 0; which < 9; which++) {
        struct fake f = fresh(); struct ebc_barrier_outcome o;
        if (which == 0) f.fb = -ENOENT;
        if (which == 1) f.info_rc = -EIO;
        if (which == 2) f.map_fail = 1;
        if (which == 3) f.alloc_fail = 1;
        if (which == 4) f.paint_rc = -EIO;
        if (which == 5) f.fsync_at = 1;
        if (which == 6) f.card = -ENOENT;
        if (which == 7) f.barrier_fail_at = 1;
        if (which == 8) f.barrier_fail_at = 2;
        o = ebc_barrier_run(&ops, &f); CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE);
        CHECK(f.restore_copies == 0 && f.fsync_calls <= 1 && f.barrier_calls <= 2); cleanup(&f, which >= 3, which >= 4);
    }
}

static void refusals(void)
{
    struct fake f = fresh(); struct ebc_barrier_outcome o;
    f.reader = 1; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_REFUSED_READER && o.error == -EBUSY);
    CHECK(f.reader_calls == 1 && f.tty_calls == 0 && f.fb_calls == 0);

    f = fresh(); f.reader = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -EIO);
    CHECK(f.reader_calls == 1 && f.tty_calls == 0 && f.fb_calls == 0);

    f = fresh(); f.tty = -ENOTTY; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_REFUSED_TTY && o.error == -ENOTTY);
    CHECK(f.reader_calls == 1 && f.tty_calls == 1 && f.fb_calls == 0);

    f = fresh(); f.reader_second = 1; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_REFUSED_READER && o.error == -EBUSY);
    CHECK(f.reader_calls == 2 && f.snapshot_copies == 0 && f.restore_copies == 0);
    CHECK(f.fsync_calls == 0 && f.barrier_calls == 0); cleanup(&f, 1, 1);

    f = fresh(); f.reader_second = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -EIO);
    CHECK(f.reader_calls == 2 && f.snapshot_copies == 0 && f.barrier_calls == 0);
    cleanup(&f, 1, 1);

    f = fresh(); f.cancelled = 1; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -EINTR);
    CHECK(f.cancelled_calls == 1 && f.snapshot_copies == 0 && f.restore_copies == 0);
    CHECK(f.fsync_calls == 0 && f.barrier_calls == 0); cleanup(&f, 1, 1);

    f = fresh(); f.cancelled = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -EIO);
    CHECK(f.cancelled_calls == 1 && f.snapshot_copies == 0 && f.barrier_calls == 0);
    cleanup(&f, 1, 1);

    f = fresh(); f.cancel_after_snapshot = 1; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -EINTR);
    CHECK(f.cancelled_calls == 2 && f.snapshot_copies == 1 && f.restore_copies == 0);
    CHECK(f.fsync_calls == 0 && f.barrier_calls == 0);
    CHECK(memcmp(f.framebuffer, f.original, sizeof(f.framebuffer)) == 0);
    cleanup(&f, 1, 1);
}

static void kernel_results(void)
{
    struct fake f = fresh(); struct ebc_barrier_outcome o;
    f.result_at = 1; f.result_value = -ENODEV; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -ENODEV);
    CHECK(o.initial_request_id == 0 && f.barrier_calls == 1 && f.restore_copies == 0);

    f = fresh(); f.result_at = 2; f.result_value = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && o.error == -EIO);
    CHECK(o.initial_request_id != 0 && f.barrier_calls == 2 && f.restore_copies == 0);

    f = fresh(); f.result_at = 3; f.result_value = -EOVERFLOW; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_RESTORE_FAILURE && o.restore_error == -EOVERFLOW);
    CHECK(o.restore_request_id == 0 && f.barrier_calls == 3 && f.restore_copies == 1);

    f = fresh(); f.result_at = 4; f.result_value = -EUCLEAN; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_RESTORE_FAILURE && o.restore_error == -EUCLEAN);
    CHECK(o.restore_request_id != 0 && f.barrier_calls == 4 && f.restore_copies == 1);
}

static void malformed_matrix(void)
{
    int call, field;
    for (call = 1; call <= 4; call++) for (field = 0; field <= 10; field++) {
        struct fake f = fresh(); struct ebc_barrier_outcome o;
        if ((call == 1 || call == 3) && (field == 2 || field == 10)) continue;
        f.malformed_at = call; f.malformed_field = field; o = ebc_barrier_run(&ops, &f);
        if (call <= 2) { CHECK(o.result == EBC_BARRIER_INITIAL_FAILURE && f.restore_copies == 0); }
        else { CHECK(o.result == EBC_BARRIER_RESTORE_FAILURE && f.restore_copies == 1); }
        CHECK(f.barrier_calls == call); /* strict failure: no retry */
    }
    { struct fake f = fresh(); struct ebc_barrier_outcome o; f.malformed_at = 2; f.malformed_field = 10; o = ebc_barrier_run(&ops, &f); CHECK(o.error == -ETIMEDOUT && f.restore_copies == 0); }
    { struct fake f = fresh(); struct ebc_barrier_outcome o; f.malformed_at = 4; f.malformed_field = 10; o = ebc_barrier_run(&ops, &f); CHECK(o.result == EBC_BARRIER_RESTORE_FAILURE && o.restore_error == -ETIMEDOUT && f.barrier_calls == 4); }
}

static void arm_and_cleanup(void)
{
    struct fake f = fresh(); struct ebc_barrier_outcome o;
    f.ack_rc = -EINTR; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_ACK_FAILURE_RESTORED && o.error == -EINTR && f.restore_copies == 1 && f.barrier_calls == 4);
    f = fresh(); f.unmap_rc = -EUCLEAN; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_CLEANUP_FAILURE && o.error == -EUCLEAN && o.cleanup_error == -EUCLEAN);
    f = fresh(); f.close_rc[10] = -EBADF; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_CLEANUP_FAILURE && o.cleanup_error == -EBADF && f.close_calls == 3);
    f = fresh(); f.close_rc[11] = -ENOSPC; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_CLEANUP_FAILURE && o.cleanup_error == -ENOSPC && f.close_calls == 3);
    f = fresh(); f.close_rc[12] = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_CLEANUP_FAILURE && o.cleanup_error == -EIO && f.close_calls == 3);
    f = fresh(); f.close_rc[12] = -EIO; f.close_rc[11] = -ENOSPC; f.close_rc[10] = -EBADF; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_CLEANUP_FAILURE && o.cleanup_error == -EIO && f.close_calls == 3);
    f = fresh(); f.ack_rc = -EINTR; f.close_rc[12] = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_ACK_FAILURE_RESTORED && o.error == -EINTR && o.cleanup_error == -EIO);
    f = fresh(); f.fsync_at = 2; f.close_rc[12] = -EIO; o = ebc_barrier_run(&ops, &f);
    CHECK(o.result == EBC_BARRIER_RESTORE_FAILURE && o.error == -EIO && o.restore_error == -EIO && o.cleanup_error == -EIO && f.restore_copies == 1 && f.barrier_calls == 2);
}

int main(void)
{
    happy_and_offsets(); geometry(); initial_failures(); refusals(); kernel_results(); malformed_matrix(); arm_and_cleanup();
    puts("ebc-barrier: all tests passed"); return 0;
}
