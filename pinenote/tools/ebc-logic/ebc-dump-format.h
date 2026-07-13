/* ebc-dump-format.h — the EXTRACT_FBS dump container, version 1.
 *
 * One header shared by the device-side grabber (ebc-dump-grab.c, runs
 * on the PineNote against the debug kernel's EXTRACT_FBS ioctl) and the
 * host-side decoder (ebc-dump.c) plus the offline harness tests
 * (ebc-refresh-test.c dbg variant), so the two sides can never drift.
 *
 * Layout (little-endian, packed by explicit field order — every field
 * is naturally aligned, no compiler padding):
 *
 *   offset  size  field
 *   0       8     magic "EBCDUMP1"
 *   8       4     u32 width          (PineNote: 1872)
 *   12      4     u32 height         (PineNote: 1404)
 *   16      4     u32 gray4_size     (width*height/2; PN: 1,314,144)
 *   20      4     u32 phase_size     (width*height;   PN: 2,628,288)
 *   24      8     u64 t_mono_ns      (CLOCK_MONOTONIC at the ioctl —
 *                                     joinable against dmesg timestamps)
 *   32      8     u64 flags          (EBC_DUMP_F_*)
 *   40      —     planes, raw, in this order:
 *                 prev, next, final          (gray4_size bytes each)
 *                 phase0, phase1             (phase_size bytes each)
 *
 * Y4 conventions (the driver's, pinned by the ebc-logic suites): two
 * pixels per byte, LOW nibble = even x, high nibble = odd x, 0 = black
 * … 15 = white.  Phase planes are one byte per pixel; 0xff = idle /
 * neutral (the invariant rung 2 pins).  When EBC_DUMP_F_REFLECTED is
 * set the planes are stored panel-mirrored (panel_reflection=1, the
 * shipped configuration) and the decoder un-mirrors by default so
 * images are directly comparable to camera frames.
 */
#ifndef EBC_DUMP_FORMAT_H
#define EBC_DUMP_FORMAT_H

#include <stdint.h>
#include <string.h>

#define EBC_DUMP_MAGIC "EBCDUMP1"
#define EBC_DUMP_MAGIC_LEN 8
#define EBC_DUMP_HEADER_SIZE 40

/* Double-dump verified stable: two back-to-back ioctls were
 * byte-identical, so the panel was quiescent and the (deliberately
 * lock-free) copies are coherent. */
#define EBC_DUMP_F_VERIFIED_STABLE (1ull << 0)
/* panel_reflection was 1: planes are stored panel-mirrored. */
#define EBC_DUMP_F_REFLECTED       (1ull << 1)

/* PineNote panel geometry (the only real hardware target). */
#define EBC_DUMP_PN_WIDTH  1872u
#define EBC_DUMP_PN_HEIGHT 1404u

struct ebc_dump_header {
	uint32_t width;
	uint32_t height;
	uint32_t gray4_size;
	uint32_t phase_size;
	uint64_t t_mono_ns;
	uint64_t flags;
};

/* Serialize/deserialize explicitly (field by field, little-endian) so
 * the on-disk layout never depends on struct packing. */

static inline void ebc_dump_put_u32(unsigned char *p, uint32_t v)
{
	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
	p[2] = (v >> 16) & 0xff;
	p[3] = (v >> 24) & 0xff;
}

static inline void ebc_dump_put_u64(unsigned char *p, uint64_t v)
{
	ebc_dump_put_u32(p, (uint32_t)v);
	ebc_dump_put_u32(p + 4, (uint32_t)(v >> 32));
}

static inline uint32_t ebc_dump_get_u32(const unsigned char *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline uint64_t ebc_dump_get_u64(const unsigned char *p)
{
	return (uint64_t)ebc_dump_get_u32(p) |
	       ((uint64_t)ebc_dump_get_u32(p + 4) << 32);
}

static inline void ebc_dump_header_write(unsigned char buf[EBC_DUMP_HEADER_SIZE],
					 const struct ebc_dump_header *h)
{
	memcpy(buf, EBC_DUMP_MAGIC, EBC_DUMP_MAGIC_LEN);
	ebc_dump_put_u32(buf + 8, h->width);
	ebc_dump_put_u32(buf + 12, h->height);
	ebc_dump_put_u32(buf + 16, h->gray4_size);
	ebc_dump_put_u32(buf + 20, h->phase_size);
	ebc_dump_put_u64(buf + 24, h->t_mono_ns);
	ebc_dump_put_u64(buf + 32, h->flags);
}

/* Returns 0 on success, -1 on bad magic or inconsistent geometry. */
static inline int ebc_dump_header_read(const unsigned char buf[EBC_DUMP_HEADER_SIZE],
				       struct ebc_dump_header *h)
{
	if (memcmp(buf, EBC_DUMP_MAGIC, EBC_DUMP_MAGIC_LEN) != 0)
		return -1;
	h->width = ebc_dump_get_u32(buf + 8);
	h->height = ebc_dump_get_u32(buf + 12);
	h->gray4_size = ebc_dump_get_u32(buf + 16);
	h->phase_size = ebc_dump_get_u32(buf + 20);
	h->t_mono_ns = ebc_dump_get_u64(buf + 24);
	h->flags = ebc_dump_get_u64(buf + 32);
	if (h->width == 0 || h->height == 0 || (h->width & 1))
		return -1;
	if (h->gray4_size != h->width * h->height / 2)
		return -1;
	if (h->phase_size != h->width * h->height)
		return -1;
	return 0;
}

#endif /* EBC_DUMP_FORMAT_H */
