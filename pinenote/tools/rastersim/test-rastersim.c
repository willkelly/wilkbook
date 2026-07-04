/* Waveform-independent tests for librastersim.
 *
 * Usage:
 *   test-rastersim                        run all unit tests
 *   test-rastersim dump-quant PGM OUTDIR  write quant-<mode>.y4 files
 *                                         (golden inputs, see run-tests.sh)
 *
 * Prints PASS/FAIL lines; exits nonzero on any failure.
 */
#include "rastersim.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(int cond, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	printf(cond ? "PASS: " : "FAIL: ");
	vprintf(fmt, ap);
	printf("\n");
	va_end(ap);
	if (!cond)
		failures++;
}

/* Deterministic xorshift64* PRNG; no libc rand(). */
static uint64_t rng_state;

static uint64_t rng(void)
{
	uint64_t x = rng_state;

	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	rng_state = x;
	return x * 0x2545F4914F6CDD1DULL;
}

static unsigned rng_range(unsigned n)
{
	return (unsigned)(rng() % n);
}

/* ---------------- pack/unpack roundtrip ---------------- */

static void test_pack_roundtrip(void)
{
	unsigned w, h = 3, x, y;
	int ok;

	/* unpack(pack(nib)) == nib for random nibbles, odd + even widths */
	rng_state = 0x1234567897531ULL;
	for (w = 1; w <= 9; w++) {
		uint8_t nib[9 * 3], out[9 * 3], y4[5 * 3];
		size_t pitch = rs_y4_pitch(w);

		for (y = 0; y < h; y++)
			for (x = 0; x < w; x++)
				nib[y * w + x] = (uint8_t)rng_range(16);
		memset(y4, 0xaa, sizeof(y4));
		rs_y4_pack(y4, pitch, nib, w, w, h);
		rs_y4_unpack(out, w, y4, pitch, w, h);
		ok = memcmp(nib, out, (size_t)w * h) == 0;
		check(ok, "pack/unpack roundtrip w=%u", w);

		/* get/set agree with unpack */
		ok = 1;
		for (y = 0; y < h; y++)
			for (x = 0; x < w; x++)
				if (rs_y4_get(y4, pitch, (int)x, (int)y) !=
				    nib[y * w + x])
					ok = 0;
		check(ok, "y4_get matches unpack w=%u", w);
	}

	/* pack(unpack(y4)) == y4 for every byte value (even width) */
	{
		uint8_t y4[256], nib[512], back[256];

		for (x = 0; x < 256; x++)
			y4[x] = (uint8_t)x;
		rs_y4_unpack(nib, 512, y4, 256, 512, 1);
		rs_y4_pack(back, 256, nib, 512, 512, 1);
		check(memcmp(y4, back, 256) == 0,
		      "unpack/pack identity over all byte values");
	}

	/* nibble order: low nibble = even x (driver layout) */
	{
		uint8_t y4[1] = { 0 };

		rs_y4_set(y4, 1, 0, 0, 0x3);
		rs_y4_set(y4, 1, 1, 0, 0xc);
		check(y4[0] == 0xc3, "low nibble is even x (got 0x%02x)",
		      y4[0]);
	}

	/* y4_to_gray8 expansion v*17 */
	{
		uint8_t y4[8], g8[16];

		for (x = 0; x < 8; x++)
			y4[x] = (uint8_t)((2 * x + 1) << 4 | 2 * x);
		rs_y4_to_gray8(g8, 16, y4, 8, 16, 1);
		ok = 1;
		for (x = 0; x < 16; x++)
			if (g8[x] != x * 17)
				ok = 0;
		check(ok, "y4_to_gray8 expands v*17");
	}
}

/* ---------------- blit edge cases ---------------- */

static void test_blit_edges(void)
{
	enum { W = 8, H = 5 };
	size_t pitch = rs_y4_pitch(W);
	uint8_t src[4 * H], dst[4 * H];
	int x1, y1, x2, y2, x, y;
	unsigned bad = 0, cases = 0;

	rng_state = 0xfeedbeefULL;
	for (x = 0; x < (int)(pitch * H); x++)
		src[x] = (uint8_t)rng();

	for (x1 = 0; x1 < W; x1++)
	for (x2 = x1 + 1; x2 <= W; x2++)
	for (y1 = 0; y1 < H; y1++)
	for (y2 = y1 + 1; y2 <= H; y2++) {
		rs_rect clip = { x1, y1, x2, y2 };

		memset(dst, 0x55, sizeof(dst));
		rs_y4_blit(dst, pitch, src, pitch, &clip);
		cases++;
		for (y = 0; y < H; y++)
			for (x = 0; x < W; x++) {
				int inside = x >= x1 && x < x2 &&
					     y >= y1 && y < y2;
				uint8_t want = inside ?
					rs_y4_get(src, pitch, x, y) : 0x5;

				if (rs_y4_get(dst, pitch, x, y) != want)
					bad++;
			}
	}
	check(bad == 0, "blit preserves out-of-clip nibbles "
	      "(%u rects, %u bad pixels)", cases, bad);
}

/* ---------------- quantization thresholds ---------------- */

static uint8_t quant1(uint8_t g, rs_quant_mode mode,
		      const rs_quant_params *p, unsigned x, unsigned y)
{
	/* Quantize a single pixel placed at (x, y) of a small buffer so
	 * position-dependent modes see the right coordinates. */
	uint8_t g8[8 * 8] = { 0 }, y4[4 * 8] = { 0 };

	g8[y * 8 + x] = g;
	rs_gray8_to_y4(y4, 4, g8, 8, 8, 8, mode, p);
	return rs_y4_get(y4, 4, (int)x, (int)y);
}

static void test_thresholds(void)
{
	rs_quant_params p;

	rs_quant_params_init(&p);
	check(p.bw_threshold == 7 && p.fourtone_low == 4 &&
	      p.fourtone_mid == 7 && p.fourtone_hi == 12 &&
	      p.dither_invert == 0, "default params match driver defaults");

	/* bw_mode=2: (g>>4) >= 7 -> white */
	check(quant1(0x70, RS_QUANT_BW, &p, 0, 0) == 15,
	      "bw: 0x70 (v4=7) >= 7 -> 15");
	check(quant1(0x7f, RS_QUANT_BW, &p, 0, 0) == 15,
	      "bw: 0x7f (v4=7) -> 15");
	check(quant1(0x6f, RS_QUANT_BW, &p, 0, 0) == 0,
	      "bw: 0x6f (v4=6) -> 0");
	check(quant1(0x00, RS_QUANT_BW, &p, 0, 0) == 0, "bw: 0 -> 0");
	check(quant1(0xff, RS_QUANT_BW, &p, 0, 0) == 15, "bw: 255 -> 15");
	p.dither_invert = 1;
	check(quant1(0x70, RS_QUANT_BW, &p, 0, 0) == 0 &&
	      quant1(0x6f, RS_QUANT_BW, &p, 0, 0) == 15,
	      "bw: dither_invert swaps outputs");
	p.dither_invert = 0;

	/* fourtone (driver bw_mode=3 / DU4 prep): strict < thresholds */
	check(quant1(0x3f, RS_QUANT_FOURTONE, &p, 0, 0) == 0,
	      "fourtone: v4=3 < low(4) -> 0");
	check(quant1(0x40, RS_QUANT_FOURTONE, &p, 0, 0) == 5,
	      "fourtone: v4=4 == low -> 5");
	check(quant1(0x6f, RS_QUANT_FOURTONE, &p, 0, 0) == 5,
	      "fourtone: v4=6 < mid(7) -> 5");
	check(quant1(0x70, RS_QUANT_FOURTONE, &p, 0, 0) == 10,
	      "fourtone: v4=7 == mid -> 10");
	check(quant1(0xbf, RS_QUANT_FOURTONE, &p, 0, 0) == 10,
	      "fourtone: v4=11 < hi(12) -> 10");
	check(quant1(0xc0, RS_QUANT_FOURTONE, &p, 0, 0) == 15,
	      "fourtone: v4=12 == hi -> 15");
	check(quant1(0xff, RS_QUANT_FOURTONE, &p, 0, 0) == 15,
	      "fourtone: v4=15 -> 15");

	/* ordered dither: pattern[x&3][y&3], >= semantics; pins the
	 * pattern's axis orientation (pattern[0][0]=7, pattern[0][1]=8,
	 * pattern[1][0]=12). */
	check(quant1(0x70, RS_QUANT_ORDERED_BW, &p, 0, 0) == 15,
	      "ordered: v4=7 at (0,0) [cell 7] -> 15");
	check(quant1(0x70, RS_QUANT_ORDERED_BW, &p, 0, 1) == 0,
	      "ordered: v4=7 at (0,1) [cell 8] -> 0");
	check(quant1(0x70, RS_QUANT_ORDERED_BW, &p, 1, 0) == 0,
	      "ordered: v4=7 at (1,0) [cell 12] -> 0");
	check(quant1(0xc0, RS_QUANT_ORDERED_BW, &p, 1, 0) == 15,
	      "ordered: v4=12 at (1,0) [cell 12] -> 15");
	check(quant1(0xe0, RS_QUANT_ORDERED_BW, &p, 3, 0) == 0,
	      "ordered: v4=14 at (3,0) [cell 15] -> 0");

	/* shift */
	check(quant1(0xef, RS_QUANT_SHIFT, &p, 0, 0) == 14,
	      "shift: 0xef -> 14");
}

static void test_fs_dither(void)
{
	enum { W = 64, H = 64 };
	static uint8_t g8[W * H], y4a[W / 2 * H], y4b[W / 2 * H];
	unsigned x, y;
	int ok;

	/* Exact multiples of 17 quantize losslessly (zero error). */
	ok = 1;
	for (y = 0; y < 16; y++) {
		memset(g8, (int)(y * 17), W * H);
		rs_gray8_to_y4(y4a, W / 2, g8, W, W, H, RS_QUANT_FS, NULL);
		for (x = 0; x < W / 2 * H; x++)
			if (y4a[x] != (y | y << 4))
				ok = 0;
	}
	check(ok, "fs: multiples of 17 are exact");

	/* Deterministic: two runs identical. */
	rng_state = 0xd17e5ULL;
	for (x = 0; x < W * H; x++)
		g8[x] = (uint8_t)rng();
	rs_gray8_to_y4(y4a, W / 2, g8, W, W, H, RS_QUANT_FS, NULL);
	rs_gray8_to_y4(y4b, W / 2, g8, W, W, H, RS_QUANT_FS, NULL);
	check(memcmp(y4a, y4b, sizeof(y4a)) == 0, "fs: deterministic");

	/* Mean preservation on flat mid-gray: average of q*17 within 1
	 * gray level of the input. */
	{
		long sum = 0;

		memset(g8, 100, W * H);
		rs_gray8_to_y4(y4a, W / 2, g8, W, W, H, RS_QUANT_FS, NULL);
		for (y = 0; y < H; y++)
			for (x = 0; x < W; x++)
				sum += 17 * rs_y4_get(y4a, W / 2, (int)x,
						      (int)y);
		sum /= W * H;
		check(sum >= 99 && sum <= 101,
		      "fs: mean preserved on flat 100 (got %ld)", sum);
	}
}

/* ---------------- damage composition ---------------- */

static void test_damage_composition(void)
{
	static const struct { unsigned w, h; } sizes[] = {
		{ 64, 64 }, { 61, 47 }, { 33, 9 },
	};
	unsigned si, iter, r, x, y;
	unsigned bad = 0, total = 0;

	rng_state = 0xdefacedbadfacadeULL;
	for (si = 0; si < 3; si++) {
		unsigned w = sizes[si].w, h = sizes[si].h;
		size_t pitch = rs_y4_pitch(w);
		uint8_t *ref = malloc(pitch * h);     /* packed reference */
		uint8_t *final = malloc(pitch * h);   /* full-frame source */
		rs_screen s;

		if (rs_screen_init(&s, w, h, 15) || !ref || !final) {
			check(0, "alloc %ux%u", w, h);
			free(ref);
			free(final);
			return;
		}
		memset(ref, 0xff, pitch * h);

		for (iter = 0; iter < 100; iter++) {
			/* A batch of overlapping partial updates: all
			 * submitted before any completes (the driver
			 * keeps areas in flight concurrently), then
			 * completed in a shuffled order. */
			rs_rect clips[8];
			unsigned order[8];
			unsigned nrects = 1 + rng_range(8);

			for (r = 0; r < nrects; r++) {
				rs_rect c;

				c.x1 = (int)rng_range(w);
				c.x2 = c.x1 + 1 + (int)rng_range(w - c.x1);
				c.y1 = (int)rng_range(h);
				c.y2 = c.y1 + 1 + (int)rng_range(h - c.y1);
				clips[r] = c;

				for (x = 0; x < pitch * h; x++)
					final[x] = (uint8_t)rng();
				rs_screen_submit(&s, &c, final, pitch);

				/* Reference: per-pixel composition. */
				for (y = (unsigned)c.y1; y < (unsigned)c.y2;
				     y++)
					for (x = (unsigned)c.x1;
					     x < (unsigned)c.x2; x++)
						rs_y4_set(ref, pitch, (int)x,
							  (int)y,
							  rs_y4_get(final,
								    pitch,
								    (int)x,
								    (int)y));
				order[r] = r;
			}
			for (r = nrects; r > 1; r--) {
				unsigned j = rng_range(r), t = order[r - 1];

				order[r - 1] = order[j];
				order[j] = t;
			}
			for (r = 0; r < nrects; r++)
				rs_screen_complete(&s, &clips[order[r]]);

			for (y = 0; y < h; y++)
				for (x = 0; x < w; x++) {
					total++;
					if (rs_y4_get(s.prev, s.pitch,
						      (int)x, (int)y) !=
					    rs_y4_get(ref, pitch, (int)x,
						      (int)y))
						bad++;
				}
		}
		rs_screen_free(&s);
		free(ref);
		free(final);
	}
	check(bad == 0, "damage composition == full redraw "
	      "(%u pixels compared, %u bad)", total, bad);
}

static void test_screen_semantics(void)
{
	rs_screen s;
	uint8_t final[2 * 4];
	rs_rect c = { 1, 1, 3, 3 };
	int ok;

	if (rs_screen_init(&s, 4, 4, 15)) {
		check(0, "screen init");
		return;
	}
	memset(final, 0x00, sizeof(final));
	rs_screen_submit(&s, &c, final, 2);

	/* submit touches next only, and only inside the clip */
	ok = rs_y4_get(s.next, s.pitch, 1, 1) == 0 &&
	     rs_y4_get(s.next, s.pitch, 2, 2) == 0 &&
	     rs_y4_get(s.next, s.pitch, 0, 0) == 15 &&
	     rs_y4_get(s.next, s.pitch, 3, 1) == 15 &&
	     rs_y4_get(s.next, s.pitch, 1, 3) == 15;
	check(ok, "submit writes next inside clip only");
	ok = 1;
	for (int y = 0; y < 4; y++)
		for (int x = 0; x < 4; x++)
			if (rs_y4_get(s.prev, s.pitch, x, y) != 15)
				ok = 0;
	check(ok, "submit leaves prev untouched");

	rs_screen_complete(&s, &c);
	ok = rs_y4_get(s.prev, s.pitch, 1, 1) == 0 &&
	     rs_y4_get(s.prev, s.pitch, 0, 0) == 15;
	check(ok, "complete copies next to prev inside clip only");
	rs_screen_free(&s);
}

/* ---------------- quant golden dump mode ---------------- */

static uint8_t *load_pgm(const char *path, unsigned *w, unsigned *h)
{
	unsigned maxval;
	uint8_t *data;
	FILE *f = fopen(path, "rb");

	if (!f)
		return NULL;
	if (fscanf(f, "P5 %u %u %u", w, h, &maxval) != 3 || maxval != 255 ||
	    fgetc(f) != '\n') {
		fclose(f);
		return NULL;
	}
	data = malloc((size_t)*w * *h);
	if (!data || fread(data, 1, (size_t)*w * *h, f) != (size_t)*w * *h) {
		free(data);
		fclose(f);
		return NULL;
	}
	fclose(f);
	return data;
}

static int dump_quant(const char *pgm, const char *outdir)
{
	static const struct { rs_quant_mode mode; const char *name; } modes[] = {
		{ RS_QUANT_SHIFT, "shift" },
		{ RS_QUANT_BW, "bw" },
		{ RS_QUANT_ORDERED_BW, "ordered" },
		{ RS_QUANT_FOURTONE, "fourtone" },
		{ RS_QUANT_FS, "fs" },
	};
	unsigned w, h, i;
	uint8_t *g8 = load_pgm(pgm, &w, &h);
	uint8_t *y4;
	size_t pitch;

	if (!g8) {
		fprintf(stderr, "FAIL: cannot load %s\n", pgm);
		return 1;
	}
	pitch = rs_y4_pitch(w);
	y4 = malloc(pitch * h);
	if (!y4) {
		fprintf(stderr, "FAIL: alloc\n");
		return 1;
	}
	for (i = 0; i < 5; i++) {
		char path[512];
		FILE *f;

		if (rs_gray8_to_y4(y4, pitch, g8, w, w, h, modes[i].mode,
				   NULL)) {
			fprintf(stderr, "FAIL: quantize %s\n",
				modes[i].name);
			return 1;
		}
		snprintf(path, sizeof(path), "%s/quant-%s.y4", outdir,
			 modes[i].name);
		f = fopen(path, "wb");
		if (!f || fwrite(y4, 1, pitch * h, f) != pitch * h) {
			fprintf(stderr, "FAIL: write %s\n", path);
			return 1;
		}
		fclose(f);
	}
	free(y4);
	free(g8);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "dump-quant"))
		return dump_quant(argv[2], argv[3]);
	if (argc != 1) {
		fprintf(stderr,
			"usage: %s [dump-quant IMAGE.pgm OUTDIR]\n",
			argv[0]);
		return 2;
	}

	test_pack_roundtrip();
	test_blit_edges();
	test_thresholds();
	test_fs_dither();
	test_damage_composition();
	test_screen_semantics();

	if (failures) {
		printf("RESULT: %d failures\n", failures);
		return 1;
	}
	printf("RESULT: ok\n");
	return 0;
}
