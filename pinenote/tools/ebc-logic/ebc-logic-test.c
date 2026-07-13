/* ebc-logic-test: host-side unit tests for rockchip_ebc's pure logic
 * (offline testing ladder, rung 2).
 *
 * Includes the *verbatim* driver sources from the forward-port patch
 * (extracted at build time) into this translation unit, so the static
 * functions under test are directly callable, and the module-parameter
 * globals (panel_reflection, bw_mode, bw_threshold, fourtone_*,
 * split_area_limit, diff_mode, default_waveform, ...) are directly
 * settable.
 *
 * Under test:
 *   - rockchip_ebc_blit_fb_xrgb8888 / rockchip_ebc_blit_fb_r4
 *     (XRGB8888/R4 -> packed Y4), driven through a replica of
 *     rockchip_ebc_plane_atomic_update's coordinate adjustment, against
 *     an independent per-pixel reference
 *   - try_to_split_area / rockchip_ebc_schedule_area, driven through a
 *     replica of rockchip_ebc_partial_refresh's scheduling loop, with a
 *     coverage-bitmap checker
 *   - convert_final_buf_to_target (A2 dither / DU4 fourtone)
 *   - rockchip_ebc_blit_pixels (Y4 rect copy)
 *   - rockchip_ebc_blit_direct (LUT phase packing), with a synthetic LUT
 *     always and with the device's real .wbf when a path is passed
 *
 * All randomness is a fixed-seed xorshift32: output is deterministic.
 *
 * Where the driver's behavior diverges from the obvious intent, the tests
 * pin the *driver's* behavior (it is hardware-validated) and mark the
 * test name with "quirk:"; see README.md "Findings" for the analysis.
 *
 * Usage: ebc-logic-test [/path/to/ebc.wbf]
 */

#include "drm_epd_helper.c"	/* verbatim, provides the LUT loader */
#include "rockchip_ebc.c"	/* verbatim driver under test */

/* ---------------------------------------------------------------------- */
/* test plumbing                                                          */

static int failures;

#define check(cond, ...) \
	do { \
		if (cond) { \
			printf("PASS: " __VA_ARGS__); \
			printf("\n"); \
		} else { \
			printf("FAIL: " __VA_ARGS__); \
			printf("\n"); \
			failures++; \
		} \
	} while (0)

#define expect(cond, ...) \
	do { \
		if (!(cond)) { \
			printf("FAIL: " __VA_ARGS__); \
			printf("\n"); \
			failures++; \
		} \
	} while (0)

static u32 prng_state;

static void prng_seed(u32 seed)
{
	prng_state = seed ? seed : 1;
}

static u32 prng(void)
{
	u32 x = prng_state;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	prng_state = x;
	return x;
}

static u32 prng_below(u32 n)
{
	return prng() % n;
}

/* Y4 nibble accessors: even x = low nibble, odd x = high nibble (the
 * layout all the driver blitters use). */
static u8 get_px(const u8 *buf, u32 pitch, int x, int y)
{
	u8 b = buf[(size_t)y * pitch + x / 2];

	return (x & 1) ? b >> 4 : b & 0xf;
}

static void set_px(u8 *buf, u32 pitch, int x, int y, u8 v)
{
	u8 *b = buf + (size_t)y * pitch + x / 2;

	if (x & 1)
		*b = (*b & 0x0f) | (u8)(v << 4);
	else
		*b = (*b & 0xf0) | (v & 0xf);
}

/* ---------------------------------------------------------------------- */
/* ctx setup (mirrors rockchip_ebc_crtc_atomic_check -> ctx_alloc)         */

static void test_ctx_alloc(void)
{
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(NULL, 1872, 1404);

	check(ctx != NULL, "ctx_alloc(1872x1404) succeeds");
	if (!ctx)
		return;
	check(ctx->gray4_pitch == 936, "ctx gray4_pitch = width/2 = 936");
	check(ctx->gray4_size == 1314144, "ctx gray4_size = 1314144 (one Y4 screen)");
	check(ctx->phase_pitch == 1872, "ctx phase_pitch = width = 1872");
	check(ctx->phase_size == 2628288, "ctx phase_size = width*height");
	check(ctx->final == ctx->final_buffer[0] && ctx->ebc_buffer_index == 0,
	      "ctx starts on final_buffer[0]");
	check(ctx->first_switch && ctx->switch_required,
	      "ctx starts with first_switch and switch_required set");
	check(list_empty(&ctx->queue), "ctx damage queue starts empty");
	rockchip_ebc_ctx_free(ctx);
}

/* ---------------------------------------------------------------------- */
/* XRGB8888 -> Y4 blitter                                                  */

/* Independent grayscale reference, from the intent of the bit tricks in
 * rockchip_ebc_blit_fb_xrgb8888: truncate each channel to 5 bits, then
 * gray = (2*R5 + 5*G5 + B5 + 7) >> 4 (a rounded 4-bit luma; X ignored). */
static u8 ref_gray(u32 xrgb)
{
	u32 r5 = (xrgb >> 19) & 0x1f;
	u32 g5 = (xrgb >> 11) & 0x1f;
	u32 b5 = (xrgb >> 3) & 0x1f;

	return (u8)((2 * r5 + 5 * g5 + b5 + 7) >> 4);
}

/* The driver's dither matrix, transcribed by hand from the source. */
static const int ref_pattern[4][4] = {
	{ 7,  8,  2, 10},
	{12,  4, 14,  6},
	{ 3, 11,  1,  9},
	{15,  7, 13,  5},
};

/* bw_mode post-processing.  (lx, ly) are the driver's *loop* coordinates:
 * for the dither matrix the driver indexes with the source-clip loop
 * variables, not with the (possibly reflected) destination position. */
static u8 ref_bw_mode(u8 gray, int lx, int ly)
{
	u8 dither_low = bw_dither_invert ? 15 : 0;
	u8 dither_high = bw_dither_invert ? 0 : 15;

	switch (bw_mode) {
	case 1:
		return gray >= ref_pattern[lx & 3][ly & 3] ? dither_high : dither_low;
	case 2:
		return gray >= bw_threshold ? dither_high : dither_low;
	case 3:
		if (gray < fourtone_low_threshold)
			return 0;
		if (gray < fourtone_mid_threshold)
			return 5;
		if (gray < fourtone_hi_threshold)
			return 10;
		return 15;
	default:
		return gray;
	}
}

/* Replica of rockchip_ebc_plane_atomic_update's coordinate handling for a
 * full-screen plane (translate = 0, non-direct mode): 2px alignment, then
 * x-mirror (panel_reflection) or y-flip. */
struct blit_call {
	struct drm_rect dst_clip;
	struct drm_rect src_clip;
	int adjust_x1;
	int adjust_x2;
};

static void caller_transform(const struct drm_rect *damage, int plane_w,
			     int plane_h, struct blit_call *c)
{
	c->dst_clip = *damage;
	c->src_clip = *damage;
	c->adjust_x1 = c->dst_clip.x1 & 1;
	c->adjust_x2 = c->dst_clip.x2 & 1;

	c->dst_clip.x1 -= c->adjust_x1;
	c->src_clip.x1 -= c->adjust_x1;
	c->dst_clip.x2 += c->adjust_x2;
	c->src_clip.x2 += c->adjust_x2;

	if (panel_reflection) {
		int x1 = c->dst_clip.x1, x2 = c->dst_clip.x2;

		c->dst_clip.x1 = plane_w - x2;
		c->dst_clip.x2 = plane_w - x1;
	} else {
		int y1 = c->dst_clip.y1, y2 = c->dst_clip.y2;

		c->dst_clip.y1 = plane_h - y2;
		c->dst_clip.y2 = plane_h - y1;
	}
}

/* Reference model of blit_fb_xrgb8888 + its caller, applied to a shadow
 * copy of the whole Y4 buffer.  Written from the code's specification;
 * the two places where the driver diverges from the obvious intent are
 * implemented as the DRIVER behaves and flagged QUIRK (see README):
 *
 *  QUIRK A (odd-x preservation cross-wired): the blit preserves the old
 *  destination value of exactly one pixel per row: the *first* output
 *  byte's low nibble, and only when (panel_reflection ? adjust_x1 :
 *  adjust_x2) == 1.  Because of the x-mirror (or of nothing, in the
 *  y-flip case), that nibble corresponds to the *other* end of the clip
 *  than the adjust flag it is keyed on, so a genuinely damaged pixel can
 *  be left stale.  The matching preservation for the last output byte is
 *  dead code (the loop condition x < x2 makes x == x2 unreachable).
 *
 *  QUIRK B (y-flip drops a row): with panel_reflection=0 the loop runs
 *  height-1 times starting at source row y2-2, so the last source row is
 *  never read and the last destination row is never written; a 1-row-high
 *  damage clip blits nothing.
 */
static bool ref_blit_xrgb(u8 *buf, u32 dst_pitch, int plane_w, int plane_h,
			  const u32 *fb_px, u32 fb_pitch_px,
			  const struct drm_rect *damage)
{
	int a1 = damage->x1 & 1;
	int a2 = damage->x2 & 1;
	int x1 = damage->x1 - a1;
	int x2 = damage->x2 + a2;
	int y1 = damage->y1;
	int y2 = damage->y2;
	int rows = panel_reflection ? y2 - y1 : y2 - y1 - 1;	/* QUIRK B */
	int preserve_first = panel_reflection ? a1 : a2;	/* QUIRK A */
	bool changed = false;
	int i, j;

	for (j = 0; j < rows; j++) {
		int ly = y1 + j;	/* driver's loop y (dither index) */
		int src_y = panel_reflection ? y1 + j : y2 - 2 - j;
		int dst_y = panel_reflection ? y1 + j : (plane_h - y2) + j;

		for (i = 0; i < (x2 - x1) / 2; i++) {
			int lx = x1 + 2 * i;	/* driver's loop x */
			int sx0 = panel_reflection ? x2 - 1 - 2 * i : lx;
			int sx1 = panel_reflection ? x2 - 2 - 2 * i : lx + 1;
			/* low nibble of output byte i */
			int dx0 = panel_reflection ? (plane_w - x2) + 2 * i : lx;
			u8 raw0, g0, g1;

			if (i == 0 && preserve_first)
				raw0 = get_px(buf, dst_pitch, dx0, dst_y);
			else
				raw0 = ref_gray(fb_px[(size_t)src_y * fb_pitch_px + sx0]);
			/* the preserved value still goes through bw_mode */
			g0 = ref_bw_mode(raw0, lx, ly);
			g1 = ref_bw_mode(ref_gray(fb_px[(size_t)src_y * fb_pitch_px + sx1]),
					 lx + 1, ly);

			if (g0 != get_px(buf, dst_pitch, dx0, dst_y) ||
			    g1 != get_px(buf, dst_pitch, dx0 + 1, dst_y))
				changed = true;
			set_px(buf, dst_pitch, dx0, dst_y, g0);
			set_px(buf, dst_pitch, dx0 + 1, dst_y, g1);
		}
	}
	return changed;
}

#define XRGB_W 32
#define XRGB_H 16

struct xrgb_env {
	struct rockchip_ebc_ctx *ctx;
	struct drm_format_info fmt;
	struct drm_framebuffer fb;
	u32 fb_pitch_px;
	u32 *fb_px;
	u8 *shadow;
};

static void xrgb_env_init(struct xrgb_env *e, u32 fb_extra_px)
{
	memset(e, 0, sizeof(*e));
	e->ctx = rockchip_ebc_ctx_alloc(NULL, XRGB_W, XRGB_H);
	e->fb_pitch_px = XRGB_W + fb_extra_px;
	e->fmt.format = DRM_FORMAT_XRGB8888;
	e->fmt.cpp[0] = 4;
	e->fb.format = &e->fmt;
	e->fb.pitches[0] = e->fb_pitch_px * 4;
	e->fb_px = malloc((size_t)e->fb_pitch_px * XRGB_H * 4);
	e->shadow = malloc(e->ctx->gray4_size);
}

static void xrgb_env_free(struct xrgb_env *e)
{
	free(e->fb_px);
	free(e->shadow);
	rockchip_ebc_ctx_free(e->ctx);
}

static void xrgb_env_randomize(struct xrgb_env *e)
{
	u32 i;

	for (i = 0; i < e->fb_pitch_px * XRGB_H; i++)
		e->fb_px[i] = prng();
	for (i = 0; i < e->ctx->gray4_size; i++)
		e->ctx->final_atomic_update[i] = (u8)prng();
	memcpy(e->shadow, e->ctx->final_atomic_update, e->ctx->gray4_size);
}

/* Run driver and reference on one damage rect; return true if the whole
 * buffer and the changed flag agree. */
static bool xrgb_one(struct xrgb_env *e, const struct drm_rect *damage,
		     const char *what)
{
	struct blit_call c;
	bool drv, ref;

	caller_transform(damage, XRGB_W, XRGB_H, &c);
	drv = rockchip_ebc_blit_fb_xrgb8888(e->ctx, &c.dst_clip, e->fb_px,
					    &e->fb, &c.src_clip,
					    c.adjust_x1, c.adjust_x2);
	ref = ref_blit_xrgb(e->shadow, e->ctx->gray4_pitch, XRGB_W, XRGB_H,
			    e->fb_px, e->fb_pitch_px, damage);
	if (memcmp(e->ctx->final_atomic_update, e->shadow, e->ctx->gray4_size)) {
		printf("FAIL: %s: buffer mismatch (damage %d,%d-%d,%d refl=%d bw=%d)\n",
		       what, damage->x1, damage->y1, damage->x2, damage->y2,
		       panel_reflection, bw_mode);
		failures++;
		return false;
	}
	if (drv != ref) {
		printf("FAIL: %s: changed flag %d != ref %d (damage %d,%d-%d,%d)\n",
		       what, drv, ref, damage->x1, damage->y1, damage->x2,
		       damage->y2);
		failures++;
		return false;
	}
	return true;
}

static void xrgb_random_rect(struct drm_rect *r)
{
	r->x1 = prng_below(XRGB_W);
	r->x2 = r->x1 + 1 + prng_below(XRGB_W - r->x1);
	r->y1 = prng_below(XRGB_H);
	r->y2 = r->y1 + 1 + prng_below(XRGB_H - r->y1);
}

static void test_blit_xrgb8888_randomized(bool reflection, int mode, u32 seed)
{
	static const struct drm_rect corners[] = {
		{0, 0, XRGB_W, XRGB_H},		/* full screen */
		{0, 0, 1, 1},			/* 1x1 at origin */
		{XRGB_W - 1, XRGB_H - 1, XRGB_W, XRGB_H}, /* 1x1 odd corner */
		{1, 0, 3, 2},			/* odd x1, odd x2 */
		{1, 5, 4, 7},			/* odd x1, even x2 */
		{2, 5, 5, 7},			/* even x1, odd x2 */
		{0, 3, XRGB_W, 4},		/* single row */
		{0, 0, XRGB_W, 2},		/* two rows */
		{5, 0, 6, XRGB_H},		/* single odd column */
	};
	struct xrgb_env e;
	unsigned int i;
	bool ok = true;

	panel_reflection = reflection;
	bw_mode = mode;
	prng_seed(seed);
	/* nontrivial fb pitch: 7 extra pixels per line */
	xrgb_env_init(&e, 7);

	for (i = 0; i < ARRAY_SIZE(corners); i++) {
		xrgb_env_randomize(&e);
		if (!xrgb_one(&e, &corners[i], "blit_fb_xrgb8888 corner"))
			ok = false;
	}
	for (i = 0; ok && i < 200; i++) {
		struct drm_rect r;

		xrgb_random_rect(&r);
		xrgb_env_randomize(&e);
		if (!xrgb_one(&e, &r, "blit_fb_xrgb8888 random"))
			ok = false;
	}
	/* incremental damage on one buffer, like successive atomic commits */
	xrgb_env_randomize(&e);
	for (i = 0; ok && i < 100; i++) {
		struct drm_rect r;
		u32 j;

		xrgb_random_rect(&r);
		/* mutate a few fb pixels between commits */
		for (j = 0; j < 16; j++)
			e.fb_px[prng_below(e.fb_pitch_px * XRGB_H)] = prng();
		if (!xrgb_one(&e, &r, "blit_fb_xrgb8888 incremental"))
			ok = false;
	}
	check(ok, "blit_fb_xrgb8888 matches reference (reflection=%d bw_mode=%d, 309 cases)",
	      reflection, mode);
	xrgb_env_free(&e);
	panel_reflection = true;
	bw_mode = 0;
}

static void test_blit_xrgb8888_gray_extraction(void)
{
	/* colors chosen so the 5-bit truncation + weighted sum is easy to
	 * verify by hand: gray = (2*R5 + 5*G5 + B5 + 7) >> 4 */
	static const struct { u32 xrgb; u8 gray; } golden[] = {
		{0x00000000,  0},	/* black */
		{0x00ffffff, 15},	/* white */
		{0xff000000,  0},	/* X byte must be ignored */
		{0x00f80000,  4},	/* pure red:   (2*31+7)>>4 */
		{0x0000f800, 10},	/* pure green: (5*31+7)>>4 */
		{0x000000f8,  2},	/* pure blue:  (31+7)>>4 */
		{0x00808080,  8},	/* mid gray:   (8*16+7)>>4 */
		{0x00181818,  1},	/* dark gray:  (8*3+7)>>4 */
		{0x00070707,  0},	/* truncated to 0 */
	};
	struct xrgb_env e;
	struct drm_rect all = {0, 0, XRGB_W, XRGB_H};
	unsigned int i;
	bool ok = true;

	panel_reflection = true;
	bw_mode = 0;
	xrgb_env_init(&e, 0);

	for (i = 0; i < ARRAY_SIZE(golden); i++) {
		struct blit_call c;
		int x, y;

		for (y = 0; y < XRGB_H; y++)
			for (x = 0; x < XRGB_W; x++)
				e.fb_px[y * e.fb_pitch_px + x] = golden[i].xrgb;
		memset(e.ctx->final_atomic_update, 0xAA, e.ctx->gray4_size);
		caller_transform(&all, XRGB_W, XRGB_H, &c);
		rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px,
					      &e.fb, &c.src_clip,
					      c.adjust_x1, c.adjust_x2);
		for (y = 0; ok && y < XRGB_H; y++)
			for (x = 0; ok && x < XRGB_W; x++)
				if (get_px(e.ctx->final_atomic_update,
					   e.ctx->gray4_pitch, x, y) != golden[i].gray) {
					printf("FAIL: gray extraction: color 0x%08x -> %u, want %u\n",
					       golden[i].xrgb,
					       get_px(e.ctx->final_atomic_update,
						      e.ctx->gray4_pitch, x, y),
					       golden[i].gray);
					failures++;
					ok = false;
				}
	}
	check(ok, "gray extraction: gray = (2*R5 + 5*G5 + B5 + 7) >> 4, X ignored");
	xrgb_env_free(&e);
}

static void test_blit_xrgb8888_reflection_mapping(void)
{
	/* pixel-unique image: verify dst pixel x on row y equals
	 * gray(src pixel W-1-x, y) when reflected */
	struct xrgb_env e;
	struct drm_rect all = {0, 0, XRGB_W, XRGB_H};
	struct blit_call c;
	int x, y;
	bool ok = true;

	panel_reflection = true;
	bw_mode = 0;
	xrgb_env_init(&e, 3);
	for (y = 0; y < XRGB_H; y++)
		for (x = 0; x < XRGB_W; x++) {
			/* per-pixel gray level (x+y)&0xf: channel k=2v
			 * gives gray (8*2v+7)>>4 = v */
			u32 v = ((u32)(x + y) & 0xf) << 1;	/* 5-bit */
			u32 c8 = v << 3;			/* 8-bit */

			e.fb_px[y * e.fb_pitch_px + x] = c8 << 16 | c8 << 8 | c8;
		}
	memset(e.ctx->final_atomic_update, 0, e.ctx->gray4_size);
	caller_transform(&all, XRGB_W, XRGB_H, &c);
	rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px, &e.fb,
				      &c.src_clip, c.adjust_x1, c.adjust_x2);
	for (y = 0; ok && y < XRGB_H; y++)
		for (x = 0; ok && x < XRGB_W; x++) {
			u8 want = (u8)((XRGB_W - 1 - x + y) & 0xf);

			if (get_px(e.ctx->final_atomic_update,
				   e.ctx->gray4_pitch, x, y) != want) {
				printf("FAIL: reflection: dst(%d,%d)=%u want %u\n",
				       x, y,
				       get_px(e.ctx->final_atomic_update,
					      e.ctx->gray4_pitch, x, y), want);
				failures++;
				ok = false;
			}
		}
	check(ok, "panel_reflection=1 mirrors: dst pixel x = gray(src pixel W-1-x)");
	xrgb_env_free(&e);
}

static void test_blit_xrgb8888_threshold_boundaries(void)
{
	/* channel value k (5-bit, applied to r=g=b) yields gray (8k+7)>>4;
	 * walk all 32 values through the shipped thresholds.
	 * pinenote/services/ebc.scm does not override these, so the driver
	 * defaults ship: bw_threshold=7, fourtone 4/7/12, bw_dither_invert=0. */
	struct xrgb_env e;
	struct drm_rect all = {0, 0, XRGB_W, XRGB_H};
	int k, x;
	bool ok_bw = true, ok_bw_inv = true, ok_four = true;
	struct blit_call c;

	panel_reflection = true;
	expect(bw_threshold == 7 && fourtone_low_threshold == 4 &&
	       fourtone_mid_threshold == 7 && fourtone_hi_threshold == 12 &&
	       bw_dither_invert == 0 && bw_mode == 0,
	       "module-param defaults match the shipped ebc.scm configuration");

	xrgb_env_init(&e, 0);
	for (x = 0; x < XRGB_W; x++) {
		u32 c8 = (u32)(x & 0x1f) << 3;
		int y;

		for (y = 0; y < XRGB_H; y++)
			e.fb_px[y * e.fb_pitch_px + x] = c8 << 16 | c8 << 8 | c8;
	}

	caller_transform(&all, XRGB_W, XRGB_H, &c);

	bw_mode = 2;
	memset(e.ctx->final_atomic_update, 0xAA, e.ctx->gray4_size);
	rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px, &e.fb,
				      &c.src_clip, c.adjust_x1, c.adjust_x2);
	for (k = 0; k < XRGB_W; k++) {
		u8 gray = (u8)((8 * k + 7) >> 4);
		u8 want = gray >= 7 ? 15 : 0;	/* bw_threshold=7 */
		u8 got = get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch,
				XRGB_W - 1 - k, 0);	/* reflected */

		if (got != want) {
			printf("FAIL: bw_mode=2: channel %d (gray %u) -> %u want %u\n",
			       k, gray, got, want);
			failures++;
			ok_bw = false;
		}
	}
	check(ok_bw, "bw_mode=2 boundary: gray>=bw_threshold(7) is white, below is black");

	bw_dither_invert = 1;
	memset(e.ctx->final_atomic_update, 0xAA, e.ctx->gray4_size);
	rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px, &e.fb,
				      &c.src_clip, c.adjust_x1, c.adjust_x2);
	for (k = 0; k < XRGB_W; k++) {
		u8 gray = (u8)((8 * k + 7) >> 4);
		u8 want = gray >= 7 ? 0 : 15;
		u8 got = get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch,
				XRGB_W - 1 - k, 0);

		if (got != want) {
			ok_bw_inv = false;
			failures++;
			printf("FAIL: bw_dither_invert=1: channel %d -> %u want %u\n",
			       k, got, want);
		}
	}
	check(ok_bw_inv, "bw_dither_invert=1 swaps black and white in bw_mode=2");
	bw_dither_invert = 0;

	bw_mode = 3;
	memset(e.ctx->final_atomic_update, 0xAA, e.ctx->gray4_size);
	rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px, &e.fb,
				      &c.src_clip, c.adjust_x1, c.adjust_x2);
	for (k = 0; k < XRGB_W; k++) {
		u8 gray = (u8)((8 * k + 7) >> 4);
		u8 want = gray < 4 ? 0 : gray < 7 ? 5 : gray < 12 ? 10 : 15;
		u8 got = get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch,
				XRGB_W - 1 - k, 0);

		if (got != want) {
			printf("FAIL: bw_mode=3: channel %d (gray %u) -> %u want %u\n",
			       k, gray, got, want);
			failures++;
			ok_four = false;
		}
	}
	check(ok_four, "bw_mode=3 fourtone boundaries 4/7/12 map to 0/5/10/15");
	bw_mode = 0;
	xrgb_env_free(&e);
}

static void test_blit_xrgb8888_changed_flag(void)
{
	struct xrgb_env e;
	struct drm_rect r = {2, 2, 20, 10};
	struct blit_call c;
	bool first, second;

	panel_reflection = true;
	bw_mode = 0;
	prng_seed(0x11);
	xrgb_env_init(&e, 0);
	xrgb_env_randomize(&e);
	caller_transform(&r, XRGB_W, XRGB_H, &c);
	first = rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px,
					      &e.fb, &c.src_clip,
					      c.adjust_x1, c.adjust_x2);
	second = rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px,
					       &e.fb, &c.src_clip,
					       c.adjust_x1, c.adjust_x2);
	check(first && !second,
	      "changed flag: first blit reports change, identical re-blit does not");
	xrgb_env_free(&e);
}

static void test_blit_xrgb8888_quirk_stale_pixel(void)
{
	/* QUIRK A pinned: reflection on, damage [1,4)x[0,1) (adjust_x1=1,
	 * adjust_x2=0).  Damaged pixel x=3 maps to dst pixel W-4 = the low
	 * nibble of the first output byte, which the driver *preserves*
	 * instead of updating; the padding pixel x=0 (outside the damage)
	 * is overwritten with fb content instead of being preserved. */
	struct xrgb_env e;
	struct drm_rect damage = {1, 0, 4, 1};
	struct blit_call c;
	int x;
	u8 px_w4, px_w1;

	panel_reflection = true;
	bw_mode = 0;
	xrgb_env_init(&e, 0);
	for (x = 0; x < XRGB_W; x++)
		e.fb_px[x] = 0x00ffffff;	/* white row */
	memset(e.ctx->final_atomic_update, 0x55, e.ctx->gray4_size); /* gray 5 */
	caller_transform(&damage, XRGB_W, XRGB_H, &c);
	rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px, &e.fb,
				      &c.src_clip, c.adjust_x1, c.adjust_x2);
	px_w4 = get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch, XRGB_W - 4, 0);
	px_w1 = get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch, XRGB_W - 1, 0);
	check(px_w4 == 5,
	      "quirk: odd-x1 damage leaves its highest-x pixel stale (dst keeps 5, not white)");
	check(px_w1 == 15,
	      "quirk: the padding pixel below x1 is overwritten with fb content instead");
	xrgb_env_free(&e);
}

static void test_blit_xrgb8888_quirk_yflip_rows(void)
{
	/* QUIRK B pinned: reflection off, 3-row damage writes only 2 rows,
	 * sourced from rows y2-2 and y2-3; the last source row is unread
	 * and the last dst row keeps its old content.  A 1-row clip blits
	 * nothing and reports no change. */
	struct xrgb_env e;
	struct drm_rect damage = {0, 0, XRGB_W, 3};
	struct drm_rect one_row = {0, 5, XRGB_W, 6};
	struct blit_call c;
	int x, y;
	bool rows_ok = true, changed;

	panel_reflection = false;
	bw_mode = 0;
	xrgb_env_init(&e, 0);
	for (y = 0; y < XRGB_H; y++)
		for (x = 0; x < XRGB_W; x++) {
			u32 c8 = (u32)((y * 2) & 0x1f) << 3;	/* gray = y */

			e.fb_px[y * e.fb_pitch_px + x] = c8 << 16 | c8 << 8 | c8;
		}
	memset(e.ctx->final_atomic_update, 0xCC, e.ctx->gray4_size); /* gray 12 */
	caller_transform(&damage, XRGB_W, XRGB_H, &c);
	rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px, &e.fb,
				      &c.src_clip, c.adjust_x1, c.adjust_x2);
	/* dst rows H-3, H-2 get src rows 1, 0; dst row H-1 stays 12 */
	for (x = 0; x < XRGB_W; x++) {
		rows_ok &= get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch,
				  x, XRGB_H - 3) == 1;
		rows_ok &= get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch,
				  x, XRGB_H - 2) == 0;
		rows_ok &= get_px(e.ctx->final_atomic_update, e.ctx->gray4_pitch,
				  x, XRGB_H - 1) == 12;
	}
	check(rows_ok,
	      "quirk: panel_reflection=0 blits height-1 rows and never reads the last source row");

	caller_transform(&one_row, XRGB_W, XRGB_H, &c);
	changed = rockchip_ebc_blit_fb_xrgb8888(e.ctx, &c.dst_clip, e.fb_px,
						&e.fb, &c.src_clip,
						c.adjust_x1, c.adjust_x2);
	check(!changed,
	      "quirk: panel_reflection=0 single-row damage blits nothing (area dropped)");
	panel_reflection = true;
	xrgb_env_free(&e);
}

/* ---------------------------------------------------------------------- */
/* R4 -> Y4 blitter                                                        */

static void test_blit_r4(void)
{
	/* rockchip_ebc_blit_fb_r4 is a plain byte-rect copy: it ignores
	 * panel_reflection (only the caller's dst_clip mirroring moves the
	 * rect) and the adjust arguments, and it always reports change. */
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(NULL, XRGB_W, XRGB_H);
	struct drm_format_info fmt = { .format = DRM_FORMAT_R4, .cpp = {0} };
	struct drm_framebuffer fb = { .format = &fmt, .pitches = {XRGB_W / 2 + 5} };
	u32 src_pitch = fb.pitches[0];
	u8 *src = malloc((size_t)src_pitch * XRGB_H);
	u8 *shadow = malloc(ctx->gray4_size);
	bool ok = true, ret = true;
	int iter;

	panel_reflection = true;
	prng_seed(0x2222);
	for (iter = 0; iter < 200 && ok; iter++) {
		struct drm_rect damage;
		struct blit_call c;
		unsigned int i, x1b, x2b;
		int y;

		xrgb_random_rect(&damage);
		for (i = 0; i < src_pitch * XRGB_H; i++)
			src[i] = (u8)prng();
		for (i = 0; i < ctx->gray4_size; i++)
			ctx->final_atomic_update[i] = (u8)prng();
		memcpy(shadow, ctx->final_atomic_update, ctx->gray4_size);

		caller_transform(&damage, XRGB_W, XRGB_H, &c);
		ret &= rockchip_ebc_blit_fb_r4(ctx, &c.dst_clip, src, &fb,
					       &c.src_clip, c.adjust_x1,
					       c.adjust_x2);

		/* reference: row-wise byte copy of the (2px-aligned) clip */
		x1b = c.src_clip.x1 / 2;
		x2b = c.src_clip.x2 / 2;
		for (y = c.src_clip.y1; y < c.src_clip.y2; y++)
			memcpy(shadow + (size_t)y * ctx->gray4_pitch + c.dst_clip.x1 / 2,
			       src + (size_t)y * src_pitch + x1b, x2b - x1b);

		if (memcmp(ctx->final_atomic_update, shadow, ctx->gray4_size)) {
			printf("FAIL: blit_fb_r4: mismatch (damage %d,%d-%d,%d)\n",
			       damage.x1, damage.y1, damage.x2, damage.y2);
			failures++;
			ok = false;
		}
	}
	check(ok, "blit_fb_r4 matches byte-copy reference (200 random clips, odd pitch)");
	check(ret, "blit_fb_r4 always reports change (never drops its area)");
	free(src);
	free(shadow);
	rockchip_ebc_ctx_free(ctx);
}

/* ---------------------------------------------------------------------- */
/* Y4 rect copy helper (prev/next/final shuffling in the refresh thread)   */

static void test_blit_pixels(void)
{
	/* Reference written from the code's spec: copy the byte range
	 * covering [x1,x2) per row, preserving the out-of-clip nibbles at
	 * both odd edges (same semantics as rastersim's rs_y4_blit).
	 *
	 * History: this soak used to *emulate* QUIRK C (odd-x1 "preserve"
	 * re-read the source nibble — a no-op that leaked the out-of-clip
	 * column) and QUIRK D (odd-x2 preserve targeted byte pitch-1
	 * instead of width-1 — wrong byte for partial-width clips, and a
	 * 1-byte heap overrun on last-row clips with x1 >= 2, which the
	 * randomized clips had to avoid).  Both were fixed 2026-07-12 via
	 * hrdl v6.19_ebc_custom 11c358d1ca7a applied verbatim (findings
	 * 1/7 in doc/driver-findings-report.md); the reference now checks
	 * true both-edge preservation and the formerly-forbidden
	 * odd-x2/last-row/x1>=2 corner is exercised on purpose as the
	 * overrun regression gate. */
	static const struct drm_rect corners[] = {
		{0, 0, XRGB_W, XRGB_H},
		{1, 0, 3, 2},		/* odd x1, odd x2 */
		{1, 5, 4, 7},		/* odd x1, even x2 */
		{2, 5, 5, 7},		/* even x1, odd x2 */
		{3, 3, 4, 4},		/* 1x1, odd x1 */
		{0, 15, 32, 16},	/* last row */
		{0, 0, XRGB_W - 1, 2},	/* full-width odd x2 */
		{2, 0, 5, 1},		/* partial-width odd x2 */
		{2, 15, 5, 16},		/* odd x2 + last row + x1>=2: the
					 * ex-QUIRK-D out-of-bounds corner */
	};
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(NULL, XRGB_W, XRGB_H);
	u8 *shadow = malloc(ctx->gray4_size);
	u8 *src = malloc(ctx->gray4_size);
	bool ok = true;
	unsigned int iter;

	prng_seed(0x3333);
	for (iter = 0; iter < 200 + ARRAY_SIZE(corners) && ok; iter++) {
		struct drm_rect r;
		unsigned int i, x1b, x2b;
		int y;

		if (iter < ARRAY_SIZE(corners))
			r = corners[iter];
		else
			xrgb_random_rect(&r);
		for (i = 0; i < ctx->gray4_size; i++) {
			src[i] = (u8)prng();
			ctx->next[i] = (u8)prng();
		}
		memcpy(shadow, ctx->next, ctx->gray4_size);

		rockchip_ebc_blit_pixels(ctx, ctx->next, src, &r);

		x1b = r.x1 / 2;
		x2b = r.x2 / 2 + ((r.x2 & 1) ? 1 : 0);
		for (y = r.y1; y < r.y2; y++) {
			u8 *drow = shadow + (size_t)y * ctx->gray4_pitch;
			const u8 *srow = src + (size_t)y * ctx->gray4_pitch;
			u8 saved_low = (u8)(drow[x1b] & 0x0f);
			u8 saved_high = (u8)(drow[x2b - 1] & 0xf0);

			memcpy(drow + x1b, srow + x1b, x2b - x1b);
			/* true both-edge preservation (fixed behavior) */
			if (r.x1 & 1)
				drow[x1b] = (drow[x1b] & 0xf0) | saved_low;
			if (r.x2 & 1)
				drow[x2b - 1] =
					(drow[x2b - 1] & 0x0f) | saved_high;
		}
		if (memcmp(ctx->next, shadow, ctx->gray4_size)) {
			printf("FAIL: blit_pixels mismatch (clip %d,%d-%d,%d)\n",
			       r.x1, r.y1, r.x2, r.y2);
			failures++;
			ok = false;
		}
	}
	check(ok, "blit_pixels matches reference (209 cases incl. odd-x bounds + ex-OOB corner)");

	/* Regression guard for ex-QUIRK C (was: odd-x1 "preserve" re-read
	 * the src nibble, so pixel x1-1 leaked src content; the pin
	 * asserted px(0,0)==0xE).  Fixed 2026-07-12 via hrdl 11c358d1ca7a:
	 * the out-of-clip even pixel is now truly preserved. */
	memset(ctx->next, 0x11, ctx->gray4_size);
	memset(src, 0xEE, ctx->gray4_size);
	{
		struct drm_rect r = {1, 0, 2, 1};

		rockchip_ebc_blit_pixels(ctx, ctx->next, src, &r);
	}
	check(get_px(ctx->next, ctx->gray4_pitch, 0, 0) == 0x1 &&
	      get_px(ctx->next, ctx->gray4_pitch, 1, 0) == 0xE &&
	      get_px(ctx->next, ctx->gray4_pitch, 2, 0) == 0x1,
	      "fix: blit_pixels odd-x1 preserves the out-of-clip even pixel (was QUIRK C; hrdl 11c358d1ca7a)");

	/* Regression guard for ex-QUIRK D (was: odd-x2 preserve targeted
	 * byte pitch-1 instead of width-1, so partial-width clips copied
	 * the out-of-clip pixel x2 — the pin asserted px(3,0)==0xE — and
	 * only full-width clips hit the intended byte).  Fixed 2026-07-12
	 * via hrdl 11c358d1ca7a: preservation lands on the clip edge for
	 * every width. */
	memset(ctx->next, 0x11, ctx->gray4_size);
	memset(src, 0xEE, ctx->gray4_size);
	{
		struct drm_rect r = {0, 0, 3, 1};	/* partial width */

		rockchip_ebc_blit_pixels(ctx, ctx->next, src, &r);
	}
	check(get_px(ctx->next, ctx->gray4_pitch, 3, 0) == 0x1,
	      "fix: blit_pixels partial-width odd-x2 preserves the out-of-clip pixel x2 (was QUIRK D; hrdl 11c358d1ca7a)");
	memset(ctx->next, 0x11, ctx->gray4_size);
	{
		struct drm_rect r = {0, 0, XRGB_W - 1, 1};	/* full width */

		rockchip_ebc_blit_pixels(ctx, ctx->next, src, &r);
	}
	check(get_px(ctx->next, ctx->gray4_pitch, XRGB_W - 1, 0) == 0x1,
	      "fix: blit_pixels full-width odd-x2 still preserves pixel x2 (green before and after 11c358d1ca7a)");
	free(shadow);
	free(src);
	rockchip_ebc_ctx_free(ctx);
}

/* ---------------------------------------------------------------------- */
/* convert_final_buf_to_target (full-screen, hardcoded 1872x1404)          */

#define SCREEN_G4 1314144u

static void test_convert_final_buf(void)
{
	u8 *buf = malloc(SCREEN_G4);
	u8 *tmp = malloc(SCREEN_G4);
	u8 *orig = malloc(SCREEN_G4);
	int saved_waveform = default_waveform;
	u32 i;
	bool ok;

	prng_seed(0x4444);
	for (i = 0; i < SCREEN_G4; i++)
		orig[i] = (u8)prng();

	/* GC16 (shipped default_waveform) is a no-op */
	memcpy(buf, orig, SCREEN_G4);
	default_waveform = DRM_EPD_WF_GC16;
	convert_final_buf_to_target(buf, tmp, SCREEN_G4);
	check(!memcmp(buf, orig, SCREEN_G4),
	      "convert_final_buf: no-op for default_waveform=GC16 (shipped default)");

	/* A2: ordered dither against the 4x4 matrix, indexed by pixel pos */
	default_waveform = DRM_EPD_WF_A2;
	bw_dither_invert = 0;
	memcpy(buf, orig, SCREEN_G4);
	convert_final_buf_to_target(buf, tmp, SCREEN_G4);
	ok = true;
	for (i = 0; i < SCREEN_G4 && ok; i++) {
		int x = (int)(i % 936) * 2;
		int y = (int)(i / 936);
		u8 p1 = orig[i] & 0xf, p2 = orig[i] >> 4;
		u8 w1 = p1 >= ref_pattern[x & 3][y & 3] ? 15 : 0;
		u8 w2 = p2 >= ref_pattern[(x + 1) & 3][y & 3] ? 15 : 0;

		if (buf[i] != (u8)(w1 | w2 << 4)) {
			printf("FAIL: convert A2 dither: byte %u: %02x want %02x\n",
			       i, buf[i], w1 | w2 << 4);
			failures++;
			ok = false;
		}
	}
	check(ok, "convert_final_buf A2 matches ordered-dither reference (full screen)");

	/* A2 with bw_dither_invert */
	bw_dither_invert = 1;
	memcpy(buf, orig, SCREEN_G4);
	convert_final_buf_to_target(buf, tmp, SCREEN_G4);
	ok = true;
	for (i = 0; i < SCREEN_G4 && ok; i++) {
		int x = (int)(i % 936) * 2;
		int y = (int)(i / 936);
		u8 p1 = orig[i] & 0xf, p2 = orig[i] >> 4;
		u8 w1 = p1 >= ref_pattern[x & 3][y & 3] ? 0 : 15;
		u8 w2 = p2 >= ref_pattern[(x + 1) & 3][y & 3] ? 0 : 15;

		if (buf[i] != (u8)(w1 | w2 << 4)) {
			failures++;
			ok = false;
			printf("FAIL: convert A2 invert: byte %u: %02x want %02x\n",
			       i, buf[i], w1 | w2 << 4);
		}
	}
	check(ok, "convert_final_buf A2 honors bw_dither_invert");
	bw_dither_invert = 0;

	/* extremes: 0 stays low (matrix min is 1), 15 goes high (max 15) */
	memset(buf, 0x00, SCREEN_G4);
	convert_final_buf_to_target(buf, tmp, SCREEN_G4);
	ok = buf[0] == 0x00 && buf[SCREEN_G4 - 1] == 0x00;
	memset(buf, 0xff, SCREEN_G4);
	convert_final_buf_to_target(buf, tmp, SCREEN_G4);
	ok = ok && buf[0] == 0xff && buf[SCREEN_G4 - 1] == 0xff;
	check(ok, "convert_final_buf A2: all-black stays black, all-white stays white");

	/* DU4: fourtone thresholds (shipped defaults 4/7/12 -> 0/5/10/15) */
	default_waveform = DRM_EPD_WF_DU4;
	for (i = 0; i < SCREEN_G4; i++)
		orig[i] = (u8)((i & 0xf) | ((15 - (i & 0xf)) << 4));
	memcpy(buf, orig, SCREEN_G4);
	convert_final_buf_to_target(buf, tmp, SCREEN_G4);
	ok = true;
	for (i = 0; i < SCREEN_G4 && ok; i++) {
		u8 p1 = orig[i] & 0xf, p2 = orig[i] >> 4;
		u8 w1 = p1 < 4 ? 0 : p1 < 7 ? 5 : p1 < 12 ? 10 : 15;
		u8 w2 = p2 < 4 ? 0 : p2 < 7 ? 5 : p2 < 12 ? 10 : 15;

		if (buf[i] != (u8)(w1 | w2 << 4)) {
			printf("FAIL: convert DU4: byte %u: in %02x out %02x want %02x\n",
			       i, orig[i], buf[i], w1 | w2 << 4);
			failures++;
			ok = false;
		}
	}
	check(ok, "convert_final_buf DU4 fourtone boundaries 4/7/12 map to 0/5/10/15");

	default_waveform = saved_waveform;
	free(buf);
	free(tmp);
	free(orig);
}

/* ---------------------------------------------------------------------- */
/* damage-area scheduling                                                  */

#define COV_W 64
#define COV_H 64
#define NUM_PHASES 38u	/* GC16 at 25 C on the PineNote's waveform */

static struct rockchip_ebc_area *area_new(int x1, int y1, int x2, int y2,
					  u32 frame_begin)
{
	struct rockchip_ebc_area *a = kmalloc(sizeof(*a), GFP_KERNEL);

	a->clip.x1 = x1;
	a->clip.y1 = y1;
	a->clip.x2 = x2;
	a->clip.y2 = y2;
	a->frame_begin = frame_begin;
	return a;
}

/* Replica of the scheduling block in rockchip_ebc_partial_refresh. */
static void schedule_all(struct list_head *areas, u32 current_frame,
			 u32 num_phases)
{
	struct rockchip_ebc_area *area, *next_area;
	int split_counter = 0;

	list_for_each_entry_safe(area, next_area, areas, list) {
		if (area->frame_begin == EBC_FRAME_PENDING &&
		    !rockchip_ebc_schedule_area(areas, area, NULL,
						current_frame, num_phases,
						&next_area, &split_counter)) {
			list_del(&area->list);
			kfree(area);
			continue;
		}
	}
}

static void cov_mark(u8 *cov, const struct drm_rect *r)
{
	int x, y;

	for (y = r->y1; y < r->y2; y++)
		for (x = r->x1; x < r->x2; x++)
			cov[y * COV_W + x] = 1;
}

static void cov_list(u8 *cov, const struct list_head *areas)
{
	struct rockchip_ebc_area *a;

	memset(cov, 0, COV_W * COV_H);
	list_for_each_entry(a, areas, list)
		cov_mark(cov, &a->clip);
}

/* forward+backward traversal must agree (validates prev/next pointers) */
static int list_len_checked(const struct list_head *head)
{
	const struct list_head *p;
	int fwd = 0, bwd = 0;

	for (p = head->next; p != head; p = p->next) {
		if (p->next->prev != p || p->prev->next != p)
			return -1;
		fwd++;
	}
	for (p = head->prev; p != head; p = p->prev)
		bwd++;
	return fwd == bwd ? fwd : -1;
}

static void free_areas(struct list_head *areas)
{
	struct rockchip_ebc_area *a, *n;

	list_for_each_entry_safe(a, n, areas, list) {
		list_del(&a->list);
		kfree(a);
	}
}

static struct rockchip_ebc_area *area_at(struct list_head *areas, int idx)
{
	struct rockchip_ebc_area *a;
	int i = 0;

	list_for_each_entry(a, areas, list)
		if (i++ == idx)
			return a;
	return NULL;
}

static void test_schedule_disjoint(void)
{
	LIST_HEAD(areas);
	struct rockchip_ebc_area *a;
	bool ok = true;
	int n = 0;

	split_area_limit = 12;
	list_add_tail(&area_new(0, 0, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(16, 0, 24, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(0, 16, 8, 24, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 7, NUM_PHASES);
	list_for_each_entry(a, &areas, list) {
		n++;
		ok &= a->frame_begin == 7;
	}
	check(ok && n == 3,
	      "schedule: disjoint areas pass through and start on the current frame");
	free_areas(&areas);
}

static void test_schedule_contained_pending(void)
{
	LIST_HEAD(areas);

	split_area_limit = 12;
	list_add_tail(&area_new(0, 0, 16, 16, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(4, 4, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(0, 0, 16, 16, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 0, NUM_PHASES);
	check(list_len_checked(&areas) == 1 &&
	      area_at(&areas, 0)->frame_begin == 0,
	      "schedule: contained and duplicate pending areas are dropped as redundant");
	free_areas(&areas);
}

static void test_schedule_partial_overlap_split(void)
{
	LIST_HEAD(areas);
	struct rockchip_ebc_area *a;
	static const struct drm_rect want[] = {
		{0, 0, 8, 8},	/* A */
		{4, 8, 8, 12},	/* B bottom-left piece */
		{8, 4, 12, 8},	/* B top-right piece */
		{8, 8, 12, 12},	/* B bottom-right piece */
	};
	u8 cov_in[COV_W * COV_H], cov_out[COV_W * COV_H];
	bool ok;
	int i = 0;

	split_area_limit = 12;
	list_add_tail(&area_new(0, 0, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(4, 4, 12, 12, EBC_FRAME_PENDING)->list, &areas);
	memset(cov_in, 0, sizeof(cov_in));
	cov_mark(cov_in, &(struct drm_rect){0, 0, 8, 8});
	cov_mark(cov_in, &(struct drm_rect){4, 4, 12, 12});

	schedule_all(&areas, 0, NUM_PHASES);

	ok = list_len_checked(&areas) == 4;
	list_for_each_entry(a, &areas, list) {
		if (i < 4)
			ok &= drm_rect_equals(&a->clip, &want[i]);
		ok &= a->frame_begin == 0;
		i++;
	}
	cov_list(cov_out, &areas);
	ok &= !memcmp(cov_in, cov_out, sizeof(cov_in));
	check(ok, "schedule: pending partial overlap splits into quadrants, all begin together, coverage preserved");
	free_areas(&areas);
}

static void test_schedule_axis_splits(void)
{
	/* overlap flush with one axis: only the other axis is split */
	LIST_HEAD(areas);
	struct rockchip_ebc_area *a;
	u8 cov_in[COV_W * COV_H], cov_out[COV_W * COV_H];
	bool ok;
	int n;

	split_area_limit = 12;
	/* B shares A's full y-range: x-only split (no_ysplit) */
	list_add_tail(&area_new(0, 0, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(4, 0, 12, 8, EBC_FRAME_PENDING)->list, &areas);
	memset(cov_in, 0, sizeof(cov_in));
	cov_mark(cov_in, &(struct drm_rect){0, 0, 8, 8});
	cov_mark(cov_in, &(struct drm_rect){4, 0, 12, 8});
	schedule_all(&areas, 0, NUM_PHASES);
	n = list_len_checked(&areas);
	cov_list(cov_out, &areas);
	ok = n == 2 && !memcmp(cov_in, cov_out, sizeof(cov_in));
	list_for_each_entry(a, &areas, list)
		ok &= a->frame_begin == 0;
	check(ok, "schedule: y-aligned overlap splits on x only (2 areas, coverage preserved)");
	free_areas(&areas);

	/* B shares A's full x-range: y-only split (no_xsplit) */
	list_add_tail(&area_new(0, 0, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(0, 4, 8, 12, EBC_FRAME_PENDING)->list, &areas);
	memset(cov_in, 0, sizeof(cov_in));
	cov_mark(cov_in, &(struct drm_rect){0, 0, 8, 8});
	cov_mark(cov_in, &(struct drm_rect){0, 4, 8, 12});
	schedule_all(&areas, 0, NUM_PHASES);
	n = list_len_checked(&areas);
	cov_list(cov_out, &areas);
	ok = n == 2 && !memcmp(cov_in, cov_out, sizeof(cov_in));
	list_for_each_entry(a, &areas, list)
		ok &= a->frame_begin == 0;
	check(ok, "schedule: x-aligned overlap splits on y only (2 areas, coverage preserved)");
	free_areas(&areas);
}

static void test_schedule_inflight_contained(void)
{
	LIST_HEAD(areas);
	struct rockchip_ebc_area *b;

	split_area_limit = 12;
	/* A started at frame 0 and is still refreshing at current frame 5 */
	list_add_tail(&area_new(0, 0, 16, 16, 0)->list, &areas);
	list_add_tail(&area_new(4, 4, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 5, NUM_PHASES);
	b = area_at(&areas, 1);
	/* end-exclusive since 59b2113e8b9c (2026-07-12): the deferred area
	 * starts on the first frame after the in-flight window [0, NPH),
	 * i.e. NUM_PHASES, not NUM_PHASES+1 */
	check(list_len_checked(&areas) == 2 && b &&
	      b->frame_begin == NUM_PHASES,
	      "schedule: area inside an in-flight area defers to the window end (frame %u)",
	      NUM_PHASES);
	free_areas(&areas);
}

static void test_schedule_inflight_split(void)
{
	LIST_HEAD(areas);
	struct rockchip_ebc_area *a;
	u8 cov_in[COV_W * COV_H], cov_out[COV_W * COV_H];
	bool ok = true;
	int with_wait = 0, immediate = 0;

	split_area_limit = 12;
	/* in-flight A; new B partially overlaps it */
	list_add_tail(&area_new(0, 0, 8, 8, 0)->list, &areas);
	list_add_tail(&area_new(4, 4, 12, 12, EBC_FRAME_PENDING)->list, &areas);
	memset(cov_in, 0, sizeof(cov_in));
	cov_mark(cov_in, &(struct drm_rect){0, 0, 8, 8});
	cov_mark(cov_in, &(struct drm_rect){4, 4, 12, 12});

	schedule_all(&areas, 5, NUM_PHASES);

	cov_list(cov_out, &areas);
	ok &= !memcmp(cov_in, cov_out, sizeof(cov_in));
	list_for_each_entry(a, &areas, list) {
		struct drm_rect inter = a->clip;

		if (a->frame_begin == 0)
			continue;	/* the in-flight seed */
		if (drm_rect_intersect(&inter, &(struct drm_rect){0, 0, 8, 8})) {
			/* still collides with A: must wait for it
			 * (end-exclusive since 59b2113e8b9c) */
			ok &= a->frame_begin == NUM_PHASES;
			with_wait++;
		} else {
			ok &= a->frame_begin == 5;
			immediate++;
		}
	}
	check(ok && with_wait == 1 && immediate == 3,
	      "schedule: collision with in-flight area splits; 3 disjoint pieces start now, overlap waits");
	free_areas(&areas);
}

static void test_schedule_split_area_limit_zero(void)
{
	/* split_area_limit=0 is what pinenote/services/ebc.scm ships: no
	 * splitting at all; whole areas defer or piggyback instead. */
	LIST_HEAD(areas);
	struct rockchip_ebc_area *b;

	split_area_limit = 0;

	/* in-flight collision: whole area waits (end-exclusive since
	 * 59b2113e8b9c) */
	list_add_tail(&area_new(0, 0, 8, 8, 0)->list, &areas);
	list_add_tail(&area_new(4, 4, 12, 12, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 5, NUM_PHASES);
	b = area_at(&areas, 1);
	check(list_len_checked(&areas) == 2 && b &&
	      drm_rect_equals(&b->clip, &(struct drm_rect){4, 4, 12, 12}) &&
	      b->frame_begin == NUM_PHASES,
	      "schedule: split_area_limit=0 (shipped): in-flight collision defers whole area");
	free_areas(&areas);

	/* pending collision: whole area begins together with the other */
	list_add_tail(&area_new(0, 0, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(4, 4, 12, 12, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 3, NUM_PHASES);
	b = area_at(&areas, 1);
	check(list_len_checked(&areas) == 2 && b &&
	      drm_rect_equals(&b->clip, &(struct drm_rect){4, 4, 12, 12}) &&
	      b->frame_begin == 3 && area_at(&areas, 0)->frame_begin == 3,
	      "schedule: split_area_limit=0 (shipped): pending overlap begins together, unsplit");
	free_areas(&areas);
	split_area_limit = 12;
}

static void test_schedule_split_limit_counts(void)
{
	/* split_area_limit=1: the first collision in a scheduling call may
	 * split; the second may not and begins together instead */
	LIST_HEAD(areas);
	struct rockchip_ebc_area *c;
	u8 cov_in[COV_W * COV_H], cov_out[COV_W * COV_H];
	int n;
	bool ok;

	split_area_limit = 1;
	list_add_tail(&area_new(0, 0, 8, 8, EBC_FRAME_PENDING)->list, &areas);
	/* B overlaps A on the x axis: splits (uses up the budget) */
	list_add_tail(&area_new(4, 0, 12, 8, EBC_FRAME_PENDING)->list, &areas);
	/* C overlaps A on the y axis: budget exhausted, no split */
	list_add_tail(&area_new(0, 4, 8, 12, EBC_FRAME_PENDING)->list, &areas);
	memset(cov_in, 0, sizeof(cov_in));
	cov_mark(cov_in, &(struct drm_rect){0, 0, 8, 8});
	cov_mark(cov_in, &(struct drm_rect){4, 0, 12, 8});
	cov_mark(cov_in, &(struct drm_rect){0, 4, 8, 12});
	schedule_all(&areas, 0, NUM_PHASES);
	n = list_len_checked(&areas);
	cov_list(cov_out, &areas);
	/* A + B's non-overlapping piece + C kept whole */
	c = area_at(&areas, 2);
	ok = n == 3 && !memcmp(cov_in, cov_out, sizeof(cov_in)) && c &&
	     drm_rect_equals(&c->clip, &(struct drm_rect){0, 4, 8, 12}) &&
	     c->frame_begin == 0;
	check(ok, "schedule: split_area_limit=1 allows one split per call; later overlap stays whole");
	free_areas(&areas);
	split_area_limit = 12;
}

static void test_schedule_min_size_no_split(void)
{
	/* areas thinner than 2px can never split */
	LIST_HEAD(areas);
	struct rockchip_ebc_area *b;

	split_area_limit = 12;
	list_add_tail(&area_new(0, 0, 8, 1, 0)->list, &areas);	/* in-flight, 1px tall */
	list_add_tail(&area_new(4, 0, 12, 1, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 5, NUM_PHASES);
	b = area_at(&areas, 1);
	/* end-exclusive since 59b2113e8b9c */
	check(list_len_checked(&areas) == 2 && b &&
	      drm_rect_equals(&b->clip, &(struct drm_rect){4, 0, 12, 1}) &&
	      b->frame_begin == NUM_PHASES,
	      "schedule: sub-2px areas never split; whole area defers");
	free_areas(&areas);
}

static void test_schedule_quirk_begin_together_conflict(void)
{
	/* Regression guard for ex-QUIRK E (finding 2).  Was pinned buggy:
	 * the pending-vs-pending "begin together" path ignored
	 * do_not_start_before_frame, so with splitting unavailable
	 * (split_area_limit=0 is what ebc.scm ships) an area that chained
	 * begin-togethers with two staggered pending areas was scheduled
	 * *inside* the first one's refresh window (b=39, c=41, a=41 —
	 * mid-window of b [39,77); conflicting phase data on hardware).
	 *
	 * Fixed 2026-07-12 via the minimal translation of hrdl
	 * v6.19_ebc_custom 59b2113e8b9c: begin-together is only allowed
	 * when the other area starts outside the dead zone; otherwise the
	 * area defers past *both* windows.  With end-exclusive window
	 * arithmetic the same scenario now schedules:
	 *
	 *   in-flight s1@0, s2@2 (disjoint); pending b waits for s1
	 *   (fb=38), pending c waits for s2 (fb=40); pending a overlaps
	 *   b and c only -> must clear b's window [38,76) AND c's window
	 *   [40,78): fb=78, outside both. */
	LIST_HEAD(areas);
	struct rockchip_ebc_area *b, *c, *a;

	split_area_limit = 0;
	list_add_tail(&area_new(0, 0, 4, 4, 0)->list, &areas);	/* s1 */
	list_add_tail(&area_new(20, 0, 24, 4, 2)->list, &areas); /* s2 */
	list_add_tail(&area_new(0, 2, 4, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(20, 2, 24, 8, EBC_FRAME_PENDING)->list, &areas);
	list_add_tail(&area_new(0, 6, 24, 8, EBC_FRAME_PENDING)->list, &areas);
	schedule_all(&areas, 5, NUM_PHASES);
	b = area_at(&areas, 2);
	c = area_at(&areas, 3);
	a = area_at(&areas, 4);
	check(list_len_checked(&areas) == 5 && b && c && a &&
	      b->frame_begin == NUM_PHASES &&
	      c->frame_begin == 2 + NUM_PHASES &&
	      a->frame_begin == 2 + 2 * NUM_PHASES &&
	      a->frame_begin >= b->frame_begin + NUM_PHASES &&
	      a->frame_begin >= c->frame_begin + NUM_PHASES,
	      "fix: chained begin-together defers past every overlapping window (was QUIRK E; hrdl 59b2113e8b9c)");
	free_areas(&areas);
	split_area_limit = 12;
}

static void test_schedule_soak_persistent(void)
{
	/* multi-round randomized soak with a persistent queue: coverage-
	 * bitmap equality, list integrity, everything scheduled, and —
	 * since the 59b2113e8b9c translation landed (2026-07-12) —
	 * pairwise no-conflict: two spatially overlapping areas either
	 * begin together (identical windows) or occupy disjoint refresh
	 * windows.  (Historically this last property was deliberately NOT
	 * asserted: QUIRK E showed the pre-fix scheduler did not provide
	 * it.) */
	LIST_HEAD(areas);
	u8 cov_in[COV_W * COV_H], cov_out[COV_W * COV_H];
	bool cov_ok = true, int_ok = true, sched_ok = true, pair_ok = true;
	u32 frame = 0;
	int round;

	split_area_limit = 12;
	prng_seed(0x5eed);
	for (round = 0; round < 50; round++) {
		struct rockchip_ebc_area *a, *n;
		int i;

		/* retire areas whose refresh windows completed */
		list_for_each_entry_safe(a, n, &areas, list) {
			if (a->frame_begin + NUM_PHASES < frame) {
				list_del(&a->list);
				kfree(a);
			}
		}
		/* inject new damage */
		for (i = 0; i < 5; i++) {
			int x1 = prng_below(COV_W - 1);
			int y1 = prng_below(COV_H - 1);
			int x2 = x1 + 1 + prng_below(COV_W - x1 - 1);
			int y2 = y1 + 1 + prng_below(COV_H - y1 - 1);

			list_add_tail(&area_new(x1, y1, x2, y2,
						EBC_FRAME_PENDING)->list,
				      &areas);
		}
		cov_list(cov_in, &areas);

		schedule_all(&areas, frame, NUM_PHASES);

		int_ok &= list_len_checked(&areas) >= 0;
		cov_list(cov_out, &areas);
		cov_ok &= !memcmp(cov_in, cov_out, sizeof(cov_in));
		list_for_each_entry(a, &areas, list) {
			struct rockchip_ebc_area *e;

			sched_ok &= a->frame_begin != EBC_FRAME_PENDING;
			/* pairwise no-conflict (holds since 59b2113e8b9c) */
			list_for_each_entry(e, &areas, list) {
				struct drm_rect inter = a->clip;

				if (e == a)
					break;
				if (!drm_rect_intersect(&inter, &e->clip))
					continue;
				if (a->frame_begin != e->frame_begin &&
				    a->frame_begin < e->frame_begin + NUM_PHASES &&
				    e->frame_begin < a->frame_begin + NUM_PHASES) {
					printf("FAIL: window conflict: areas @%u and @%u overlap\n",
					       a->frame_begin, e->frame_begin);
					pair_ok = false;
				}
			}
		}
		frame += 1 + prng_below(2 * NUM_PHASES);
	}
	check(int_ok, "schedule soak: list stays a valid doubly-linked list (50 rounds)");
	check(cov_ok, "schedule soak: union of scheduled rects == union of requested rects");
	check(sched_ok, "schedule soak: every surviving area gets a frame_begin");
	check(pair_ok, "schedule soak: overlapping areas begin together or in disjoint windows (fix 59b2113e8b9c)");
	free_areas(&areas);
}

static void test_schedule_soak_inflight_guarantee(void)
{
	/* single-round randomized soak against in-flight areas: what the
	 * scheduler DOES guarantee is that a newly scheduled area never
	 * begins inside the refresh window of an area that had already
	 * started (frame_begin < current frame) when it was scheduled. */
	bool ok = true;
	int round;

	split_area_limit = 12;
	prng_seed(0xf00d);
	for (round = 0; round < 100 && ok; round++) {
		LIST_HEAD(areas);
		struct drm_rect seeds[3];
		u32 seed_begin[3];
		struct rockchip_ebc_area *a;
		u32 frame = NUM_PHASES;	/* seeds started in the past */
		int i;

		for (i = 0; i < 3; i++) {
			int x1 = prng_below(COV_W - 1);
			int y1 = prng_below(COV_H - 1);

			seeds[i].x1 = x1;
			seeds[i].y1 = y1;
			seeds[i].x2 = x1 + 1 + prng_below(COV_W - x1 - 1);
			seeds[i].y2 = y1 + 1 + prng_below(COV_H - y1 - 1);
			/* started, still active: begin in [1, frame-1] */
			seed_begin[i] = 1 + prng_below(frame - 1);
			list_add_tail(&area_new(seeds[i].x1, seeds[i].y1,
						seeds[i].x2, seeds[i].y2,
						seed_begin[i])->list, &areas);
		}
		for (i = 0; i < 5; i++) {
			int x1 = prng_below(COV_W - 1);
			int y1 = prng_below(COV_H - 1);
			int x2 = x1 + 1 + prng_below(COV_W - x1 - 1);
			int y2 = y1 + 1 + prng_below(COV_H - y1 - 1);

			list_add_tail(&area_new(x1, y1, x2, y2,
						EBC_FRAME_PENDING)->list,
				      &areas);
		}

		schedule_all(&areas, frame, NUM_PHASES);

		ok &= list_len_checked(&areas) >= 0;
		i = 0;
		list_for_each_entry(a, &areas, list) {
			if (i++ < 3)
				continue;	/* the seeds themselves */
			for (int s = 0; s < 3; s++) {
				struct drm_rect inter = a->clip;

				if (!drm_rect_intersect(&inter, &seeds[s]))
					continue;
				if (a->frame_begin < seed_begin[s] + NUM_PHASES) {
					printf("FAIL: inflight guarantee: area @%u vs seed @%u\n",
					       a->frame_begin, seed_begin[s]);
					ok = false;
				}
			}
		}
		free_areas(&areas);
	}
	check(ok, "schedule soak: new areas never begin inside an in-flight area's window (100 rounds)");
}

/* ---------------------------------------------------------------------- */
/* direct-mode LUT blit (rockchip_ebc_blit_direct)                         */

#define LUT_BYTES 16384u	/* 256 phases * 16 next * 16 prev * 2 bits */

static void ref_blit_direct(const struct rockchip_ebc_ctx *ctx, u8 *dst,
			    u8 phase, const u8 *lut_buf, bool diff,
			    const struct drm_rect *clip)
{
	const u32 *words = (const u32 *)(const void *)lut_buf + 16 * phase;
	u32 dst_pitch = ctx->phase_pitch / 4;
	int x, y, i;

	for (y = clip->y1; y < clip->y2; y++)
		for (x = clip->x1; x < clip->x2; x += 4) {
			u8 out = 0;

			for (i = 0; i < 4; i++) {
				int px = x + i;
				u8 bp = ctx->prev[(size_t)y * ctx->gray4_pitch + px / 2];
				u8 bn = ctx->next[(size_t)y * ctx->gray4_pitch + px / 2];
				u8 pn = (px & 1) ? bp >> 4 : bp & 0xf;
				u8 nn = (px & 1) ? bn >> 4 : bn & 0xf;
				u8 code = (words[nn] >> (pn * 2)) & 0x3;

				if (diff && pn == nn)
					code = 0;
				out |= (u8)(code << (2 * i));
			}
			dst[(size_t)y * dst_pitch + x / 4] = out;
		}
}

static void test_blit_direct_synthetic(void)
{
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(NULL, 64, 16);
	struct drm_epd_lut lut = { 0 };
	u8 *shadow = malloc(ctx->phase_size);
	bool saved_diff = diff_mode;
	bool ok = true;
	int iter;

	lut.buf = malloc(LUT_BYTES);
	lut.num_phases = 256;
	prng_seed(0x6666);
	for (iter = 0; iter < (int)LUT_BYTES; iter++)
		lut.buf[iter] = (u8)prng();

	for (iter = 0; iter < 100 && ok; iter++) {
		/* direct mode uses 4px-aligned clips (the caller aligns) */
		struct drm_rect clip;
		u8 phase = (u8)prng();
		u32 i;

		clip.x1 = 4 * prng_below(16);
		clip.x2 = clip.x1 + 4 * (1 + prng_below(16 - clip.x1 / 4));
		clip.y1 = prng_below(16);
		clip.y2 = clip.y1 + 1 + prng_below(16 - clip.y1);
		diff_mode = prng() & 1;

		for (i = 0; i < ctx->gray4_size; i++) {
			ctx->prev[i] = (u8)prng();
			/* make some pixels equal so diff_mode has effect */
			ctx->next[i] = (prng() & 1) ? ctx->prev[i] : (u8)prng();
		}
		for (i = 0; i < ctx->phase_size; i++)
			ctx->phase[0][i] = (u8)prng();
		memcpy(shadow, ctx->phase[0], ctx->phase_size);

		rockchip_ebc_blit_direct(ctx, ctx->phase[0], phase, &lut, &clip);
		ref_blit_direct(ctx, shadow, phase, lut.buf, diff_mode, &clip);

		if (memcmp(ctx->phase[0], shadow, ctx->phase_size)) {
			printf("FAIL: blit_direct mismatch (clip %d,%d-%d,%d phase %u diff %d)\n",
			       clip.x1, clip.y1, clip.x2, clip.y2, phase,
			       diff_mode);
			failures++;
			ok = false;
		}
	}
	check(ok, "blit_direct matches LUT-lookup reference (100 random cases, synthetic LUT)");

	diff_mode = saved_diff;
	free(lut.buf);
	free(shadow);
	rockchip_ebc_ctx_free(ctx);
}

/* ---------------------------------------------------------------------- */
/* waveform-dependent tests (need the per-device .wbf)                     */

static void test_with_waveform(const char *wbf_path)
{
	static const char *const names[DRM_EPD_WF_MAX] = {
		"RESET", "A2", "DU", "DU4", "GC16", "GCC16", "GL16",
		"GLR16", "GLD16",
	};
	struct drm_epd_lut_file file = { 0 };
	struct drm_epd_lut lut = { 0 };
	struct drm_device dev = { 0 };
	struct rockchip_ebc_ctx *ctx;
	bool saved_diff = diff_mode;
	int ret, wf;
	bool neutral_ok = true, phases_ok = true;

	/* Load exactly like rockchip_ebc_drm_init does. */
	ret = drmm_epd_lut_file_init(&dev, &file, wbf_path);
	check(ret == 0, "wbf: lut file loads (%s)", wbf_path);
	if (ret)
		return;
	ret = drmm_epd_lut_init(&file, &lut, DRM_EPD_LUT_4BIT_PACKED,
				EBC_MAX_PHASES);
	check(ret == 0, "wbf: lut init (DRM_EPD_LUT_4BIT_PACKED, 256 phases)");
	if (ret)
		return;
	ret = drm_epd_lut_set_temperature(&lut, 25);
	check(ret >= 0, "wbf: set_temperature(25)");

	ctx = rockchip_ebc_ctx_alloc(NULL, 64, 16);
	diff_mode = false;
	prng_seed(0x7777);

	for (wf = 0; wf < DRM_EPD_WF_MAX; wf++) {
		struct drm_rect clip = {0, 0, 64, 16};
		u32 i;
		size_t j;
		u8 last_real;

		ret = drm_epd_lut_set_waveform(&lut, wf);
		if (ret < 0) {
			printf("FAIL: wbf: set_waveform(%s): %d\n", names[wf], ret);
			failures++;
			continue;
		}
		phases_ok &= lut.num_phases > 0 &&
			     lut.num_phases <= EBC_MAX_PHASES;

		for (i = 0; i < ctx->gray4_size; i++) {
			ctx->prev[i] = (u8)prng();
			ctx->next[i] = (u8)prng();
		}

		/* The partial-refresh path writes phase number 0xff for
		 * finished areas and relies on it being neutral (all-zero
		 * LUT data) for *every* waveform; the last real phase must
		 * be neutral too (the driver blits prev<-next concurrently
		 * with it).  Verify against the device's own waveform. */
		memset(ctx->phase[0], 0xAA, ctx->phase_size);
		rockchip_ebc_blit_direct(ctx, ctx->phase[0], 0xff, &lut, &clip);
		for (j = 0; j < (size_t)16 * 16; j++)
			neutral_ok &= ctx->phase[0][j] == 0;

		last_real = (u8)(lut.num_phases - 1);
		memset(ctx->phase[0], 0xAA, ctx->phase_size);
		rockchip_ebc_blit_direct(ctx, ctx->phase[0], last_real, &lut,
					 &clip);
		for (j = 0; j < (size_t)16 * 16; j++)
			neutral_ok &= ctx->phase[0][j] == 0;
	}
	check(phases_ok, "wbf: every waveform decodes with 0 < phases <= 256");
	check(neutral_ok,
	      "wbf: phase 0xff and the last real phase are neutral for all 9 waveforms");

	diff_mode = saved_diff;
	rockchip_ebc_ctx_free(ctx);
}

/* ---------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	test_ctx_alloc();

	test_blit_xrgb8888_gray_extraction();
	test_blit_xrgb8888_reflection_mapping();
	test_blit_xrgb8888_threshold_boundaries();
	test_blit_xrgb8888_changed_flag();
	test_blit_xrgb8888_quirk_stale_pixel();
	test_blit_xrgb8888_quirk_yflip_rows();
	test_blit_xrgb8888_randomized(true, 0, 0xA0);
	test_blit_xrgb8888_randomized(true, 1, 0xA1);
	test_blit_xrgb8888_randomized(true, 2, 0xA2);
	test_blit_xrgb8888_randomized(true, 3, 0xA3);
	test_blit_xrgb8888_randomized(false, 0, 0xB0);
	test_blit_xrgb8888_randomized(false, 1, 0xB1);

	test_blit_r4();
	test_blit_pixels();
	test_convert_final_buf();

	test_schedule_disjoint();
	test_schedule_contained_pending();
	test_schedule_partial_overlap_split();
	test_schedule_axis_splits();
	test_schedule_inflight_contained();
	test_schedule_inflight_split();
	test_schedule_split_area_limit_zero();
	test_schedule_split_limit_counts();
	test_schedule_min_size_no_split();
	test_schedule_quirk_begin_together_conflict();
	test_schedule_soak_persistent();
	test_schedule_soak_inflight_guarantee();

	test_blit_direct_synthetic();

	if (argc > 1 && argv[1][0] != '\0')
		test_with_waveform(argv[1]);
	else
		printf("SKIP: waveform-dependent tests (run with WBF=/path/to/ebc.wbf)\n");

	if (failures) {
		printf("RESULT: %d failures\n", failures);
		return 1;
	}
	printf("RESULT: ok\n");
	return 0;
}
