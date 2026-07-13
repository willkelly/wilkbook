/* ebc-dump — host-side decoder for EXTRACT_FBS dump containers.
 *
 * Input: a version-1 container written by ebc-dump-grab (device) or by
 * the ebc-refresh-test dbg harness (offline).  Outputs, into OUTDIR:
 *
 *   prev.pgm / next.pgm / final.pgm   P5 8-bit, nibble expansion v*17,
 *                                     low-nibble-first (the driver's Y4
 *                                     convention, pinned by rung 2)
 *   phase0.pgm / phase1.pgm           raw byte planes (0xff = idle)
 *   diff-prev-next.pgm                255 where prev != next: pixels the
 *                                     driver believes are mid-refresh —
 *                                     must be empty in a verified-stable
 *                                     dump (that itself is a check)
 *   diff-next-final.pgm               255 where next != final: damage
 *                                     accepted but not yet driven
 *
 * Mirror handling: when the container's EBC_DUMP_F_REFLECTED flag is
 * set (panel_reflection=1, the shipped config) the planes are stored
 * panel-mirrored; by default the decoder un-mirrors to glass/camera
 * orientation so images join directly against rig frames.  --mirror /
 * --no-mirror force it either way.
 *
 * --json prints a machine summary (geometry, timestamps, flags,
 * per-plane 16-bin histograms, prev!=next and next!=final pixel counts
 * with bounding boxes) for pinenote/tools/optics/analyze.py — the
 * belief half of the camera<->driver-belief join (PLAN task 23).
 *
 * --selftest exercises the nibble/mirror conventions on a synthetic
 * 4x2 plane and exits; no input needed.
 *
 * Usage:
 *   ebc-dump [--json] [--mirror|--no-mirror] CONTAINER OUTDIR
 *   ebc-dump --selftest
 */
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "ebc-dump-format.h"

static uint8_t y4_get(const uint8_t *plane, uint32_t w, uint32_t x, uint32_t y)
{
	uint8_t b = plane[(size_t)y * (w / 2) + x / 2];

	return (x & 1) ? b >> 4 : b & 0xf;
}

/* Expand a Y4 plane to gray8 (v*17), optionally un-mirroring in x. */
static void y4_to_gray8(const uint8_t *plane, uint32_t w, uint32_t h,
			bool unmirror, uint8_t *out)
{
	uint32_t x, y;

	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++) {
			uint32_t sx = unmirror ? w - 1 - x : x;

			out[(size_t)y * w + x] = (uint8_t)(y4_get(plane, w, sx, y) * 17);
		}
}

static void bytes_maybe_mirror(const uint8_t *plane, uint32_t w, uint32_t h,
			       bool unmirror, uint8_t *out)
{
	uint32_t x, y;

	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++) {
			uint32_t sx = unmirror ? w - 1 - x : x;

			out[(size_t)y * w + x] = plane[(size_t)y * w + sx];
		}
}

static int write_pgm(const char *dir, const char *name, const uint8_t *gray,
		     uint32_t w, uint32_t h)
{
	char path[4096];
	FILE *f;

	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "wb");
	if (!f) {
		fprintf(stderr, "ebc-dump: cannot write %s: %s\n", path,
			strerror(errno));
		return -1;
	}
	fprintf(f, "P5\n%u %u\n255\n", w, h);
	fwrite(gray, 1, (size_t)w * h, f);
	fclose(f);
	return 0;
}

struct diff_stats {
	uint64_t count;
	uint32_t x1, y1, x2, y2;	/* bbox, [x1,x2) x [y1,y2); empty if count==0 */
};

/* Diff two gray8 images (already in output orientation). */
static void diff_gray8(const uint8_t *a, const uint8_t *b, uint32_t w,
		       uint32_t h, uint8_t *out, struct diff_stats *st)
{
	uint32_t x, y;

	memset(st, 0, sizeof(*st));
	st->x1 = w;
	st->y1 = h;
	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++) {
			size_t i = (size_t)y * w + x;
			bool d = a[i] != b[i];

			out[i] = d ? 255 : 0;
			if (d) {
				st->count++;
				if (x < st->x1) st->x1 = x;
				if (y < st->y1) st->y1 = y;
				if (x + 1 > st->x2) st->x2 = x + 1;
				if (y + 1 > st->y2) st->y2 = y + 1;
			}
		}
	if (!st->count)
		st->x1 = st->y1 = st->x2 = st->y2 = 0;
}

static void gray8_hist16(const uint8_t *gray, size_t n, uint64_t hist[16])
{
	size_t i;

	memset(hist, 0, 16 * sizeof(hist[0]));
	for (i = 0; i < n; i++)
		hist[gray[i] / 17]++;
}

static void json_hist(FILE *f, const char *name, const uint64_t hist[16])
{
	int i;

	fprintf(f, "    \"%s\": [", name);
	for (i = 0; i < 16; i++)
		fprintf(f, "%s%llu", i ? ", " : "",
			(unsigned long long)hist[i]);
	fprintf(f, "]");
}

static int selftest(void)
{
	/* 4x2 Y4 plane: pixel values row0 = 1,2,3,4; row1 = 5,6,7,8.
	 * Packed low-nibble-first: row0 = 0x21, 0x43; row1 = 0x65, 0x87. */
	static const uint8_t plane[4] = { 0x21, 0x43, 0x65, 0x87 };
	static const uint8_t want_straight[8] = {
		1 * 17, 2 * 17, 3 * 17, 4 * 17,
		5 * 17, 6 * 17, 7 * 17, 8 * 17,
	};
	static const uint8_t want_mirrored[8] = {
		4 * 17, 3 * 17, 2 * 17, 1 * 17,
		8 * 17, 7 * 17, 6 * 17, 5 * 17,
	};
	uint8_t out[8];
	int fail = 0;

	y4_to_gray8(plane, 4, 2, false, out);
	if (memcmp(out, want_straight, 8)) {
		fprintf(stderr, "FAIL: selftest: nibble order (low nibble = even x)\n");
		fail = 1;
	}
	y4_to_gray8(plane, 4, 2, true, out);
	if (memcmp(out, want_mirrored, 8)) {
		fprintf(stderr, "FAIL: selftest: un-mirror\n");
		fail = 1;
	}
	if (!fail)
		printf("PASS: ebc-dump selftest (nibble order + mirror)\n");
	return fail;
}

int main(int argc, char **argv)
{
	const char *container = NULL, *outdir = NULL;
	int mirror_override = -1;	/* -1 auto, 0 off, 1 on */
	bool json = false;
	unsigned char hdrbuf[EBC_DUMP_HEADER_SIZE];
	struct ebc_dump_header h;
	uint8_t *planes[5];
	uint8_t *gray[3], *phases[2], *diffbuf;
	struct diff_stats d_pn, d_nf;
	uint64_t hist[3][16];
	bool unmirror;
	size_t n;
	FILE *f;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--selftest"))
			return selftest();
		else if (!strcmp(argv[i], "--json"))
			json = true;
		else if (!strcmp(argv[i], "--mirror"))
			mirror_override = 1;
		else if (!strcmp(argv[i], "--no-mirror"))
			mirror_override = 0;
		else if (!container)
			container = argv[i];
		else if (!outdir)
			outdir = argv[i];
		else
			goto usage;
	}
	if (!container || !outdir) {
usage:
		fprintf(stderr, "usage: ebc-dump [--json] [--mirror|--no-mirror] CONTAINER OUTDIR\n"
				"       ebc-dump --selftest\n");
		return 2;
	}

	f = fopen(container, "rb");
	if (!f) {
		fprintf(stderr, "ebc-dump: cannot open %s: %s\n", container,
			strerror(errno));
		return 1;
	}
	if (fread(hdrbuf, 1, sizeof(hdrbuf), f) != sizeof(hdrbuf) ||
	    ebc_dump_header_read(hdrbuf, &h) != 0) {
		fprintf(stderr, "ebc-dump: %s: not an EBCDUMP1 container\n",
			container);
		fclose(f);
		return 1;
	}
	for (i = 0; i < 5; i++) {
		size_t sz = i < 3 ? h.gray4_size : h.phase_size;

		planes[i] = malloc(sz);
		if (!planes[i] || fread(planes[i], 1, sz, f) != sz) {
			fprintf(stderr, "ebc-dump: %s: truncated (plane %d)\n",
				container, i);
			fclose(f);
			return 1;
		}
	}
	fclose(f);

	unmirror = mirror_override >= 0 ? mirror_override != 0
					: !!(h.flags & EBC_DUMP_F_REFLECTED);

	if (mkdir(outdir, 0777) != 0 && errno != EEXIST) {
		fprintf(stderr, "ebc-dump: mkdir %s: %s\n", outdir,
			strerror(errno));
		return 1;
	}

	n = (size_t)h.width * h.height;
	for (i = 0; i < 3; i++) {
		gray[i] = malloc(n);
		y4_to_gray8(planes[i], h.width, h.height, unmirror, gray[i]);
		gray8_hist16(gray[i], n, hist[i]);
	}
	for (i = 0; i < 2; i++) {
		phases[i] = malloc(n);
		bytes_maybe_mirror(planes[3 + i], h.width, h.height, unmirror,
				   phases[i]);
	}
	diffbuf = malloc(n);

	if (write_pgm(outdir, "prev.pgm", gray[0], h.width, h.height) ||
	    write_pgm(outdir, "next.pgm", gray[1], h.width, h.height) ||
	    write_pgm(outdir, "final.pgm", gray[2], h.width, h.height) ||
	    write_pgm(outdir, "phase0.pgm", phases[0], h.width, h.height) ||
	    write_pgm(outdir, "phase1.pgm", phases[1], h.width, h.height))
		return 1;

	diff_gray8(gray[0], gray[1], h.width, h.height, diffbuf, &d_pn);
	if (write_pgm(outdir, "diff-prev-next.pgm", diffbuf, h.width, h.height))
		return 1;
	diff_gray8(gray[1], gray[2], h.width, h.height, diffbuf, &d_nf);
	if (write_pgm(outdir, "diff-next-final.pgm", diffbuf, h.width, h.height))
		return 1;

	if (json) {
		printf("{\n");
		printf("  \"width\": %u,\n  \"height\": %u,\n", h.width, h.height);
		printf("  \"gray4_size\": %u,\n  \"phase_size\": %u,\n",
		       h.gray4_size, h.phase_size);
		printf("  \"t_mono_ns\": %llu,\n",
		       (unsigned long long)h.t_mono_ns);
		printf("  \"flags\": %llu,\n", (unsigned long long)h.flags);
		printf("  \"verified_stable\": %s,\n",
		       (h.flags & EBC_DUMP_F_VERIFIED_STABLE) ? "true" : "false");
		printf("  \"reflected\": %s,\n",
		       (h.flags & EBC_DUMP_F_REFLECTED) ? "true" : "false");
		printf("  \"unmirrored\": %s,\n", unmirror ? "true" : "false");
		printf("  \"histograms\": {\n");
		json_hist(stdout, "prev", hist[0]);
		printf(",\n");
		json_hist(stdout, "next", hist[1]);
		printf(",\n");
		json_hist(stdout, "final", hist[2]);
		printf("\n  },\n");
		printf("  \"prev_ne_next\": { \"count\": %llu, \"bbox\": [%u, %u, %u, %u] },\n",
		       (unsigned long long)d_pn.count, d_pn.x1, d_pn.y1,
		       d_pn.x2, d_pn.y2);
		printf("  \"next_ne_final\": { \"count\": %llu, \"bbox\": [%u, %u, %u, %u] }\n",
		       (unsigned long long)d_nf.count, d_nf.x1, d_nf.y1,
		       d_nf.x2, d_nf.y2);
		printf("}\n");
	} else {
		printf("ebc-dump: %ux%u flags=0x%llx%s%s\n", h.width, h.height,
		       (unsigned long long)h.flags,
		       (h.flags & EBC_DUMP_F_VERIFIED_STABLE) ? " verified-stable" : "",
		       unmirror ? " (un-mirrored)" : "");
		printf("  prev!=next:  %llu px, bbox [%u,%u)x[%u,%u)\n",
		       (unsigned long long)d_pn.count, d_pn.x1, d_pn.x2,
		       d_pn.y1, d_pn.y2);
		printf("  next!=final: %llu px, bbox [%u,%u)x[%u,%u)\n",
		       (unsigned long long)d_nf.count, d_nf.x1, d_nf.x2,
		       d_nf.y1, d_nf.y2);
		if ((h.flags & EBC_DUMP_F_VERIFIED_STABLE) && d_pn.count)
			printf("  WARNING: verified-stable dump with prev!=next "
			       "pixels — driver believes a refresh is in flight\n");
	}

	for (i = 0; i < 5; i++)
		free(planes[i]);
	for (i = 0; i < 3; i++)
		free(gray[i]);
	for (i = 0; i < 2; i++)
		free(phases[i]);
	free(diffbuf);
	return 0;
}
