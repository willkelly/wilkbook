/* ebc-card-reference: emit the exact bytes pinenote-ebc-sleep-frame-test
 * paints into /dev/fb0, so the on-device check is a hash comparison instead
 * of a judgement call about a photograph.
 *
 * Why this exists.  The 2026-07-29 campaign left the panel washed white with
 * none of the card's black features visible (doc/status.md).  The offline
 * probe says the driver renders those features from ctx->final onward, which
 * points upstream -- at the mmap/fsync -> deferred-io -> damage path, which
 * is DRM/fbdev core and is NOT compiled into the ebc-logic harness.  So the
 * question "did the card reach the framebuffer at all?" cannot be settled
 * offline; it has to be read off the device.  This tool makes reading it off
 * the device unambiguous.
 *
 * It calls the SAME ebc_barrier_paint_card() the device runs, over the same
 * geometry, so a byte-for-byte match proves the paint landed in fb memory and
 * isolates any fault to damage propagation rather than to the diagnostic.
 *
 * Usage:
 *   ebc-card-reference > card.raw                 # PineNote defaults
 *   ebc-card-reference LINE_LENGTH XRES YRES XRES_VIRT YRES_VIRT XOFF YOFF
 *
 * On device, while the diagnostic is blocked at its "press Enter" prompt
 * (a second session; the campaign run is NOT consumed):
 *   dd if=/dev/fb0 bs=7488 count=1404 iflag=fullblock status=none | sha256sum
 * and compare against the hash of this tool's output.  Note fbcon must be
 * unbound first or its cursor mutates fb0 under the comparison -- which the
 * corrected procedure in doc/hardware-deploy.md already requires.
 */

#include "ebc-barrier.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The deployed PineNote reader's fb0: 1872x1404 XRGB8888, stride 7488, no
 * stride padding (1872 * 4 == 7488) and no off-screen rows, so the whole
 * 10,513,152-byte buffer is the card.  Confirmed live on 2026-07-29 from
 * /sys/class/graphics/fb0/{virtual_size,stride,bits_per_pixel}. */
#define DEF_LINE_LENGTH 7488u
#define DEF_XRES        1872u
#define DEF_YRES        1404u

static unsigned long parse(const char *s, const char *what)
{
	char *end;
	unsigned long v;

	errno = 0;
	v = strtoul(s, &end, 10);
	if (errno != 0 || *end != '\0') {
		fprintf(stderr, "ebc-card-reference: bad %s: %s\n", what, s);
		exit(2);
	}
	return v;
}

int main(int argc, char **argv)
{
	struct ebc_barrier_fb_info info;
	size_t length = 0;
	uint8_t *pixels;
	int rc;

	memset(&info, 0, sizeof(info));
	info.line_length = DEF_LINE_LENGTH;
	info.xres = DEF_XRES;
	info.yres = DEF_YRES;
	info.xres_virtual = DEF_XRES;
	info.yres_virtual = DEF_YRES;
	info.xoffset = 0;
	info.yoffset = 0;

	if (argc != 1 && argc != 8) {
		fprintf(stderr,
			"usage: ebc-card-reference [LINE_LENGTH XRES YRES "
			"XRES_VIRT YRES_VIRT XOFF YOFF] > card.raw\n");
		return 2;
	}
	if (argc == 8) {
		info.line_length  = (uint32_t)parse(argv[1], "line_length");
		info.xres         = (uint32_t)parse(argv[2], "xres");
		info.yres         = (uint32_t)parse(argv[3], "yres");
		info.xres_virtual = (uint32_t)parse(argv[4], "xres_virtual");
		info.yres_virtual = (uint32_t)parse(argv[5], "yres_virtual");
		info.xoffset      = (uint32_t)parse(argv[6], "xoffset");
		info.yoffset      = (uint32_t)parse(argv[7], "yoffset");
	}

	/* Fixed by the format the diagnostic requires; validate_geometry
	 * rejects anything else, so the reference can never be generated for
	 * a configuration the device would have refused. */
	info.bits_per_pixel = 32;
	info.visual = 2;	/* FB_VISUAL_TRUECOLOR */
	info.type = 0;		/* FB_TYPE_PACKED_PIXELS */
	info.smem_len = info.line_length * info.yres_virtual;

	rc = ebc_barrier_validate_geometry(&info, &length);
	if (rc != 0) {
		fprintf(stderr,
			"ebc-card-reference: geometry rejected (%d) — the "
			"device would have refused this too\n", rc);
		return 1;
	}

	pixels = malloc(length);
	if (pixels == NULL) {
		fprintf(stderr, "ebc-card-reference: out of memory\n");
		return 1;
	}

	/* the verbatim painter the device runs */
	ebc_barrier_paint_card(pixels, &info, length);

	if (fwrite(pixels, 1, length, stdout) != length) {
		fprintf(stderr, "ebc-card-reference: short write\n");
		free(pixels);
		return 1;
	}
	free(pixels);
	return 0;
}
