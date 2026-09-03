/* ebc-replay: replay KOReader [pn-refresh] intent traces through the
 * verbatim rockchip_ebc refresh machine (offline testing ladder, the
 * rung-7a phase-B workbench — see doc/refresh-policy.md).
 *
 * The reader-session log records every refresh *intent* KOReader emits
 * (one line per post-merge UIManager refresh op).  This tool re-decides
 * each intent under a candidate policy (the KOReader-side layer our
 * pinenote device target implements: area-thresholded flashes, waveform
 * choices, driver params), feeds the resulting damage and global-refresh
 * requests into the real driver code driven by the rung-7a fake device,
 * and reports what the panel would have been asked to do: washes by
 * cause, the black-flash census (believed-white pixels driven dark),
 * pixel-phases of drive, settle latency per event, and end-of-trace
 * scrub staleness.  Time is modeled as a 63.744 Hz frame clock (the
 * driver's own dclk-derived rate -- NOT the .wbf header's 85 Hz, which
 * the driver never reads); wall-clock
 * gaps in the trace become idle frames that pass without device work.
 *
 * Replicas of device-side callers, deliberately minimal and documented
 * (same policy as ebc-refresh-test.c):
 *   - commit_damage()      the plane_atomic_update commit block;
 *   - request_global()     the GLOBAL_REFRESH ioctl body (flag + wake);
 *   - the deferred-io model maps traced rects to page-granular
 *     full-width row bands, which is how fbdev damage actually reaches
 *     the driver on the device (one traced rect -> one band clip).
 *
 * Honesty limits: this measures what the driver *drives*, not what the
 * panel *shows* — optics stay hardware-only.  Content is synthetic
 * (deterministic pseudo-text), so pixel counts compare policies against
 * each other, not against the user's actual book.  Traced rects are in
 * KOReader's logical coordinates; replay assumes the native portrait
 * orientation.  "partial" trace lines are annotations of deferred-io
 * damage, replayed here at trace-line time (the real flush timer adds a
 * small delay).  Residue physics (what GL16 leaves behind optically)
 * cannot arise in this model; the honest proxy reported is how long
 * pixels go without an active drive.
 *
 * Usage:
 *   ebc-replay selftest [FWDIR]
 *       run the self-tests; FWDIR is a directory containing
 *       rockchip/ebc.wbf (enables the replay tests; without it they
 *       SKIP)
 *   ebc-replay synth OUT [pages=N] [period=SEC] [menus=N]
 *       [full-every=N] [seed=N]
 *       write a deterministic synthetic reading-session trace
 *   ebc-replay replay FWDIR TRACE [key=val ...]
 *       replay TRACE and print the metrics report.  Keys:
 *         scale=N               1 = full 1872x1404 (slow); 8 = fast
 *         flash-frac=F          flashui/flashpartial wash threshold (0.60)
 *         default-waveform=W    partial waveform (GC16)
 *         refresh-waveform=W    global waveform (GL16; W in RESET A2 DU
 *                               DU4 GC16 GCC16 GL16 GLR16 GLD16)
 *         auto-refresh=0|1      driver auto wash (1)
 *         refresh-threshold=N   driver accumulator threshold (60),
 *                               auto-compensated for scale
 *         split-area-limit=N    driver scheduler splits per call (0)
 *         defio=bands|rect      damage granularity model (bands)
 *         defio-delay-ms=N      deferred-io flush delay; the device is
 *                               250 ms (0 = flush at trace time).  This
 *                               banner used to say ~50 ms and argue a
 *                               consequence from it -- that a wash
 *                               usually starts on stale content and a
 *                               follow-up partial drives the new page.
 *                               ea580b8 pinned 250 ms on 2026-07-31 and
 *                               nobody re-derived that consequence, so
 *                               it is WITHDRAWN.  The number is stated
 *                               here because `make settings-check' pins
 *                               it against ebc.scm; the consequence is
 *                               not, because nobody has measured it.
 *         temp-c=N              panel temperature in C (25)
 *         verify-decisions=1    compare policy against recorded decisions
 *         pgm-dir=DIR           per-frame PGMs (needs scale small enough
 *                               for seq recording, w*h <= 65536)
 */

#include "drm_epd_helper.c"	/* verbatim, provides the LUT loader */
#include "rockchip_ebc.c"	/* verbatim driver under replay */
#include "fake-ebc.h"		/* the device model behind the regmap */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---------------------------------------------------------------------- */
/* plumbing (same conventions as ebc-refresh-test.c)                       */

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

/* deterministic xorshift64 — replay must never consult wall clock */
static u64 xr_next(u64 *s)
{
	u64 x = *s ? *s : 0x9e3779b97f4a7c15ull;

	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	*s = x;
	return x;
}

/* ---------------------------------------------------------------------- */
/* the device and trace-space constants                                    */

#define PANEL_W		1872
#define PANEL_H		1404
/* The panel frame clock is set by the DRIVER, not by the waveform.  The
 * .wbf header carries a frame_rate field (85 on this device) but the
 * driver never reads it -- it exists only as an unused struct member
 * (patch:1933-1934).  Do NOT take the frame rate from a .wbf again.
 *
 * Shipped config is dclk_select=0 (pinenote/services/ebc.scm:18, and the
 * compiled-in default at patch:3143), so:
 *   dclk            = 200 MHz                       (patch:4806-4807)
 *   pixels_per_sdck = 8, from DRM_MODE_FLAG_CLKDIV2 (patch:4773-4774),
 *                     programmed as SDCLK_DIV(7)    (patch:4838)
 *   sdck.htotal     = mode.htotal / 8 = 2208/8 = 276 (patch:2591, :4778)
 *   vtotal          = 1421, used raw                (patch:2596, :4849-4850)
 * => 276 * 1421 / 25 MHz = 15.68784 ms = 63.7436 Hz.
 * Mode-independent: all 8 modes share htotal/vtotal/CLKDIV2 and differ
 * only in .clock, which dclk_select=0 discards and overwrites
 * (patch:2774, :4918).  Cross-checked on hardware 2026-07-29: the EBC
 * interrupt ran at 63.4 Hz during a stuck partial refresh (0.5 % low --
 * a software-paced lower bound; doc/status.md).
 *
 * Do NOT derive this from replay_mode_set(): that mode is synthetic and
 * arbitrary at every scale except 1.
 */
#define PANEL_DCLK_HZ		200000000.0
#define PANEL_PX_PER_SDCK	8
#define PANEL_HTOTAL_SDCK	276
#define PANEL_VTOTAL		1421
#define PANEL_FPS		(PANEL_DCLK_HZ / PANEL_PX_PER_SDCK / \
				 ((double)PANEL_HTOTAL_SDCK * PANEL_VTOTAL))
#define FB_STRIDE	(PANEL_W * 4)	/* XR24, the deferred-io space */
#define PAGE_SIZE_FB	4096
/* the driver's hardcoded auto-refresh unit (gray4_size of the panel) */
#define ONE_SCREEN_AREA	1314144.0

enum replay_intent {
	IN_PARTIAL, IN_UI, IN_FAST, IN_A2, IN_FLASHUI, IN_FLASHPARTIAL,
	IN_FULL, IN_UNKNOWN
};

static const char *const intent_names[] = {
	"partial", "ui", "fast", "a2", "flashui", "flashpartial", "full",
	"unknown"
};

static enum replay_intent intent_parse(const char *s, size_t len)
{
	unsigned int i;

	for (i = 0; i < IN_UNKNOWN; i++)
		if (strlen(intent_names[i]) == len &&
		    !memcmp(intent_names[i], s, len))
			return (enum replay_intent)i;
	return IN_UNKNOWN;
}

static const struct { const char *name; int wf; } wf_names[] = {
	{ "RESET", DRM_EPD_WF_RESET }, { "A2", DRM_EPD_WF_A2 },
	{ "DU", DRM_EPD_WF_DU }, { "DU4", DRM_EPD_WF_DU4 },
	{ "GC16", DRM_EPD_WF_GC16 }, { "GCC16", DRM_EPD_WF_GCC16 },
	{ "GL16", DRM_EPD_WF_GL16 }, { "GLR16", DRM_EPD_WF_GLR16 },
	{ "GLD16", DRM_EPD_WF_GLD16 },
};

static int wf_parse(const char *s)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(wf_names); i++)
		if (!strcmp(wf_names[i].name, s))
			return wf_names[i].wf;
	return -1;
}

static const char *wf_name(int wf)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(wf_names); i++)
		if (wf_names[i].wf == wf)
			return wf_names[i].name;
	return "?";
}

/* ---------------------------------------------------------------------- */
/* trace parsing                                                           */

struct trace_event {
	double t;			/* trace wall clock, seconds */
	enum replay_intent intent;
	int recorded_global;		/* decision field: 1 global, 0
					 * partial, -1 unknown */
	double x, y, w, h;		/* raw, unclamped, nil -> 0 */
};

struct trace {
	struct trace_event *ev;
	unsigned int n, cap;
};

/* one numeric field of rect=..., where the device can emit "nil" or a
 * non-integer (tostring of a Lua number) — parse defensively */
static const char *trace_num(const char *p, double *out)
{
	char *end;

	if (!strncmp(p, "nil", 3)) {
		*out = 0;
		return p + 3;
	}
	*out = strtod(p, &end);
	if (end == p)
		return NULL;
	return end;
}

/* Parse one log line.  Lines carry a shepherd timestamp prefix and a
 * KOReader logger prefix before the payload; key strictly on the
 * "[pn-refresh] " token.  Returns 1 and fills *ev on success. */
static int trace_parse_line(const char *line, struct trace_event *ev)
{
	static const char token[] = "[pn-refresh] ";
	const char *p = strstr(line, token);
	const char *q;
	size_t len;
	double sec;
	unsigned int i;
	double *dims[4];

	if (!p)
		return 0;
	p += sizeof(token) - 1;

	memset(ev, 0, sizeof(*ev));
	ev->recorded_global = -1;

	q = strchr(p, ' ');
	if (!q)
		return 0;
	ev->intent = intent_parse(p, (size_t)(q - p));
	p = q + 1;

	q = strchr(p, ' ');
	if (!q)
		return 0;
	len = (size_t)(q - p);
	if (len == 6 && !memcmp(p, "global", 6))
		ev->recorded_global = 1;
	else if (len == 7 && !memcmp(p, "partial", 7))
		ev->recorded_global = 0;
	p = q + 1;

	if (strncmp(p, "rect=", 5))
		return 0;
	p += 5;
	dims[0] = &ev->x;
	dims[1] = &ev->y;
	dims[2] = &ev->w;
	dims[3] = &ev->h;
	for (i = 0; i < 4; i++) {
		p = trace_num(p, dims[i]);
		if (!p)
			return 0;
		if (!isfinite(*dims[i]))	/* "nan"/"inf" parse as such */
			*dims[i] = 0;
		if (i < 3) {
			if (*p != ',')
				return 0;
			p++;
		}
	}

	p = strstr(p, "t=");
	if (!p)
		return 0;
	p += 2;
	p = trace_num(p, &sec);	/* strtod consumes ".<usec>" as a fraction */
	if (!p || !isfinite(sec))
		return 0;
	ev->t = sec;
	return 1;
}

static void trace_push(struct trace *tr, const struct trace_event *ev)
{
	if (tr->n == tr->cap) {
		tr->cap = tr->cap ? tr->cap * 2 : 256;
		tr->ev = realloc(tr->ev, tr->cap * sizeof(*tr->ev));
		if (!tr->ev) {
			fprintf(stderr, "ebc-replay: out of memory\n");
			exit(1);
		}
	}
	tr->ev[tr->n++] = *ev;
}

static int trace_load(struct trace *tr, const char *path)
{
	FILE *f = fopen(path, "r");
	char line[1024];
	struct trace_event ev;

	memset(tr, 0, sizeof(*tr));
	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (trace_parse_line(line, &ev))
			trace_push(tr, &ev);
	fclose(f);
	return 0;
}

/* ---------------------------------------------------------------------- */
/* synthetic traces (deterministic reading sessions)                       */

struct synth_params {
	unsigned int pages;
	double period;
	unsigned int menus;
	unsigned int full_every;	/* UIManager promotion, 0 = never */
	u64 seed;
	double flash_frac;		/* only for the recorded decision */
};

static void synth_default(struct synth_params *sp)
{
	memset(sp, 0, sizeof(*sp));
	sp->pages = 24;
	sp->period = 1.5;
	sp->menus = 2;
	sp->full_every = 6;
	sp->seed = 42;
	sp->flash_frac = 0.98;	/* device.lua flash_area_fraction (S2, 2026-09-03) */
}

static void synth_line(FILE *f, double t, enum replay_intent in,
		       int x, int y, int w, int h, double flash_frac)
{
	const char *decision = "partial";

	if (in == IN_FULL ||
	    ((in == IN_FLASHUI || in == IN_FLASHPARTIAL) &&
	     (double)w * h >= flash_frac * PANEL_W * PANEL_H))
		decision = "global";
	fprintf(f, "[pn-refresh] %s %s rect=%d,%d,%d,%d dither=nil t=%.6f \n",
		intent_names[in], decision, x, y, w, h, t);
}

static int synth_write(const char *path, const struct synth_params *sp)
{
	FILE *f = fopen(path, "w");
	u64 rng = sp->seed;
	double t = 1000.0;	/* arbitrary epoch; only deltas matter */
	unsigned int page, counted = 0;
	unsigned int menu_gap = sp->menus ? sp->pages / (sp->menus + 1) : 0;
	unsigned int menu_no = 0;

	if (!f)
		return -1;
	for (page = 1; page <= sp->pages; page++) {
		enum replay_intent in = IN_PARTIAL;

		t += sp->period + (double)(xr_next(&rng) % 400) / 1000.0;
		counted++;
		if (sp->full_every && counted >= sp->full_every) {
			in = IN_FULL;	/* the UIManager promotion */
			counted = 0;
		}
		synth_line(f, t, in, 0, 0, PANEL_W, PANEL_H, sp->flash_frac);

		if (menu_gap && page % menu_gap == 0 && menu_no < sp->menus) {
			/* menu open + a highlight move + close; alternate a
			 * small menu (stays partial under the 0.60 policy)
			 * with a large one (washes) */
			int big = menu_no & 1;
			int mw = big ? 1728 : 1123;	/* 83% / 45% of area */
			int mh = big ? 1264 : 1052;
			int mx = (PANEL_W - mw) / 2;
			int my = (PANEL_H - mh) / 2;

			menu_no++;
			t += 0.7;
			synth_line(f, t, IN_FLASHUI, mx, my, mw, mh,
				   sp->flash_frac);
			t += 0.4;
			synth_line(f, t, IN_UI, mx + 24, my + 24, mw / 3, 64,
				   sp->flash_frac);
			t += 0.6;
			synth_line(f, t, IN_FLASHUI, mx, my, mw, mh,
				   sp->flash_frac);
		}
	}
	fclose(f);
	return 0;
}

/* ---------------------------------------------------------------------- */
/* policy (the KOReader-side layer, mirroring device.lua)                  */

struct policy {
	double flash_frac;	/* device.lua flash_area_fraction */
	int default_wf;		/* driver param: partial waveform */
	int refresh_wf;		/* driver param: global waveform */
	bool auto_refresh;
	int refresh_threshold;	/* raw, in ONE_SCREEN_AREA units */
	int split_area_limit;
	bool defio_bands;	/* model deferred-io page granularity */
	int defio_delay_ms;	/* deferred-io flush delay; shipped is 250 ms
				 * (ea580b8), 0 = flush modeled at trace
				 * time */
	int temp_c;
};

static void policy_ship(struct policy *p)
{
	/* The DEPLOYED stack: pinenote/services/ebc.scm params + the
	 * rockchip_ebc.refresh_waveform=6 cmdline + device.lua 0.60.
	 *
	 * This drifted for seven weeks and nobody noticed, because nothing
	 * connected it to ebc.scm.  Written 2026-07-05 when it was correct;
	 * b9bbc0e shipped auto_refresh=0 on 2026-07-11 (threshold-path
	 * globals corrupt panel state) and ea580b8 pinned defio_delay_ms=250
	 * on 2026-07-31, and this function was never touched.  The 2026-07-30
	 * recalibration therefore RE-MEASURED refresh-policy.md's tables
	 * against a baseline already 19 days stale.  `make settings-check'
	 * now pins these three values against ebc.scm, so the next drift is
	 * a build failure rather than a silent reprice. */
	memset(p, 0, sizeof(*p));
	p->flash_frac = 0.98;
	p->default_wf = DRM_EPD_WF_GC16;
	p->refresh_wf = DRM_EPD_WF_GL16;
	p->auto_refresh = false;	/* shipped since 2026-07-11 (b9bbc0e) */
	p->refresh_threshold = 60;
	p->split_area_limit = 0;
	p->defio_bands = true;
	p->defio_delay_ms = 250;	/* shipped since 2026-07-31 (ea580b8) */
	p->temp_c = 25;
}

/* 1 = global wash, 0 = partial.  Mirrors device.lua: full always washes;
 * flashui/flashpartial wash by raw area against the native screen area;
 * everything else annotates deferred-io.  Raw (unclamped, nil->0)
 * dimensions on purpose — the device computes the same way. */
static int policy_global(const struct policy *p, const struct trace_event *ev)
{
	double rect_area;

	switch (ev->intent) {
	case IN_FULL:
		return 1;
	case IN_FLASHUI:
	case IN_FLASHPARTIAL:
		rect_area = ev->w * ev->h;
		return rect_area >= p->flash_frac * PANEL_W * PANEL_H;
	default:
		return 0;
	}
}

/* ---------------------------------------------------------------------- */
/* deferred-io damage model                                                */

/* Map a traced rect (native fb coordinates) to the page-granular
 * full-width row band that fbdev deferred-io actually hands the driver:
 * the rect's rows span bytes [y1*stride, y2*stride) of the fb, damage is
 * tracked in whole 4096-byte pages, and each touched page maps back to
 * the rows it covers. */
static struct drm_rect defio_band(int y1, int y2)
{
	long page_lo = (long)y1 * FB_STRIDE / PAGE_SIZE_FB;
	long page_hi = ((long)y2 * FB_STRIDE + PAGE_SIZE_FB - 1) / PAGE_SIZE_FB;
	struct drm_rect band;

	band.x1 = 0;
	band.x2 = PANEL_W;
	band.y1 = (int)(page_lo * PAGE_SIZE_FB / FB_STRIDE);
	band.y2 = (int)((page_hi * PAGE_SIZE_FB + FB_STRIDE - 1) / FB_STRIDE);
	if (band.y1 < 0)
		band.y1 = 0;
	if (band.y2 > PANEL_H)
		band.y2 = PANEL_H;
	return band;
}

/* Clamp a raw traced rect into native space, then optionally widen it to
 * the deferred-io band, then scale into replay geometry (x even-aligned
 * for the packed-Y4 buffers).  Returns 0 if nothing remains. */
static int damage_rect(const struct policy *p, const struct trace_event *ev,
		       int scale, int rw, int rh, struct drm_rect *out)
{
	double x1 = ev->x, y1 = ev->y;
	double x2 = ev->x + ev->w, y2 = ev->y + ev->h;
	struct drm_rect r;

	if (x1 < 0)
		x1 = 0;
	if (y1 < 0)
		y1 = 0;
	if (x2 > PANEL_W)
		x2 = PANEL_W;
	if (y2 > PANEL_H)
		y2 = PANEL_H;
	if (x2 <= x1 || y2 <= y1)
		return 0;

	r.x1 = (int)floor(x1);
	r.y1 = (int)floor(y1);
	r.x2 = (int)ceil(x2);
	r.y2 = (int)ceil(y2);
	if (p->defio_bands) {
		struct drm_rect band = defio_band(r.y1, r.y2);

		r.x1 = band.x1;
		r.x2 = band.x2;
		r.y1 = band.y1;
		r.y2 = band.y2;
	}

	out->x1 = (r.x1 / scale) & ~1;
	out->y1 = r.y1 / scale;
	out->x2 = ((r.x2 + scale - 1) / scale + 1) & ~1;
	out->y2 = (r.y2 + scale - 1) / scale;
	if (out->x2 > rw)
		out->x2 = rw;
	if (out->y2 > rh)
		out->y2 = rh;
	if (out->x1 >= out->x2 || out->y1 >= out->y2)
		return 0;
	return 1;
}

/* ---------------------------------------------------------------------- */
/* content model (deterministic pseudo-text)                               */

/* Fill the rect with text-like content that differs per event: white
 * background, ink lines with run-length alternation.  Policies are
 * compared on identical content streams; absolute pixel counts depend on
 * this model, relative ones are the point. */
static void content_paint(u8 *y4, u32 pitch, const struct drm_rect *r,
			  int rh_total, u64 seed)
{
	int line_h = rh_total / 40;
	int x, y;

	if (line_h < 6)
		line_h = 6;
	for (y = r->y1; y < r->y2; y++) {
		int band = y % line_h;
		int ink_row = band >= line_h / 4 && band < (3 * line_h) / 4;
		u64 rng = seed ^ (u64)(y / line_h) * 0x2545f4914f6cdd1dull;
		int run = 0, ink = 0;
		u8 gray = 0;

		for (x = r->x1; x < r->x2; x++) {
			if (!ink_row) {
				set_px(y4, pitch, x, y, 0xf);
				continue;
			}
			if (run == 0) {
				u64 v = xr_next(&rng);

				ink = !ink;
				run = ink ? 3 + (int)(v % 10)
					  : 2 + (int)((v >> 8) % 7);
				gray = (u8)((v >> 16) % 4);
			}
			set_px(y4, pitch, x, y, ink ? gray : 0xf);
			run--;
		}
	}
}

/* ---------------------------------------------------------------------- */
/* replica: the commit block of rockchip_ebc_plane_atomic_update           */

static void commit_damage(struct rockchip_ebc_ctx *ctx,
			  const struct drm_rect *rects, int n)
{
	int i;

	spin_lock(&ctx->queue_lock);
	memcpy(ctx->final_buffer[!ctx->ebc_buffer_index],
	       ctx->final_atomic_update, ctx->gray4_size);
	if (ctx->first_switch) {
		memcpy(ctx->final_buffer[ctx->ebc_buffer_index],
		       ctx->final_atomic_update, ctx->gray4_size);
		ctx->first_switch = false;
	}
	for (i = 0; i < n; i++) {
		struct rockchip_ebc_area *a = kmalloc(sizeof(*a), GFP_KERNEL);

		a->clip = rects[i];
		a->frame_begin = EBC_FRAME_PENDING;
		list_add_tail(&a->list, &ctx->queue);
	}
	ctx->switch_required = true;
	spin_unlock(&ctx->queue_lock);
}

/* replica: ioctl_trigger_global_refresh's body (flag + wake) */
static void request_global(struct rockchip_ebc *ebc)
{
	spin_lock(&ebc->refresh_once_lock);
	ebc->do_one_full_refresh = true;
	spin_unlock(&ebc->refresh_once_lock);
	wake_up_process(ebc->refresh_thread);
}

/* ---------------------------------------------------------------------- */
/* harness setup (probe replica, as in ebc-refresh-test.c)                 */

struct harness {
	struct platform_device pdev;
	struct rockchip_ebc *ebc;
	struct ebc_crtc_state crtc_state;
};

static struct rockchip_ebc *replay_probe(struct harness *h)
{
	int ret;

	memset(h, 0, sizeof(*h));
	ebc_shim_reset();
	fake_ebc_install();

	ret = rockchip_ebc_probe(&h->pdev);
	if (ret) {
		fprintf(stderr, "ebc-replay: rockchip_ebc_probe: %d\n", ret);
		return NULL;
	}
	h->ebc = platform_get_drvdata(&h->pdev);

	ebc_shim.rt_resume = rockchip_ebc_runtime_resume;
	ebc_shim.rt_suspend = rockchip_ebc_runtime_suspend;
	ebc_shim.pm_suspended = true;
	return h->ebc;
}

static void replay_teardown(struct harness *h, struct rockchip_ebc_ctx *ctx)
{
	struct rockchip_ebc *ebc = h->ebc;

	if (ctx)
		rockchip_ebc_ctx_free(ctx);
	drm_epd_lut_free(&ebc->drm, &ebc->lut);
	drm_epd_lut_file_free(&ebc->drm, &ebc->lut_file);
	free(ebc);
	ebc_shim.regmap_hook = NULL;
	ebc_shim.schedule_hook = NULL;
	fake_ebc.on_frm_start = NULL;
	fake_ebc.on_event = NULL;
}

/* The real ED103TC2 mode at scale 1 (the timing set pinned by
 * ebc-refresh-test's mode_set golden); consistent-but-arbitrary timings
 * at other scales — only the geometry registers feed the device model. */
static void replay_mode_set(struct harness *h, int w, int hgt)
{
	struct drm_display_mode *m = &h->crtc_state.base.adjusted_mode;

	memset(m, 0, sizeof(*m));
	if (w == PANEL_W && hgt == PANEL_H) {
		m->clock = 3137;
		m->hsync_start = w + 56;
		m->hsync_end = w + 56 + 144;
		m->htotal = w + 56 + 144 + 136;
		m->hskew = 64;
		m->vsync_start = hgt + 12;
		m->vsync_end = hgt + 12 + 1;
		m->vtotal = hgt + 12 + 1 + 4;
	} else {
		m->clock = 1000;
		m->hsync_start = w + 8;
		m->hsync_end = w + 16;
		m->htotal = w + 24;
		m->hskew = 8;
		m->vsync_start = hgt + 1;
		m->vsync_end = hgt + 2;
		m->vtotal = hgt + 4;
	}
	m->hdisplay = w;
	m->vdisplay = hgt;
	m->flags = DRM_MODE_FLAG_CLKDIV2;

	h->crtc_state.base.crtc = &h->ebc->crtc;
	h->ebc->crtc.state = &h->crtc_state.base;
	rockchip_ebc_crtc_mode_set_nofb(&h->ebc->crtc);
}

/* ---------------------------------------------------------------------- */
/* the replay engine                                                       */

enum wash_class { WASH_RESET, WASH_BOOT, WASH_IOCTL, WASH_AUTO, WASH_MAX };

static const char *const wash_names[] = { "reset", "boot", "ioctl", "auto" };

struct wash_stats {
	u64 count;
	u64 planes;
	u64 white_white_px;	/* believed (prev,next) == (15,15) */
	u64 white_dark_px;	/* of those, driven dark by the LUT */
	u64 driven_px;
	u64 px_phases;
};

struct replay {
	/* configuration */
	const struct policy *pol;
	int scale, rw, rh;
	u64 content_seed;
	int verify_decisions;

	/* the machine under replay */
	struct rockchip_ebc *ebc;
	struct rockchip_ebc_ctx *ctx;

	/* trace cursor */
	const struct trace *tr;
	double t0;

	/* the 63.744 Hz timeline: effective frame = hw frame + idle offset */
	u64 idle_offset;
	struct { u64 hw; u64 off; } *off_hist;
	unsigned int off_hist_n;

	/* Trace epoch: on the device the session's first trace line lands
	 * long after the driver's RESET + boot wash; anchor frame 0 of the
	 * trace at the machine's first idle instead of at probe. */
	int epoch_set;
	u64 epoch_eff;

	/* Two injection phases per event, like the device: the ioctl (if
	 * the policy washes) fires at trace time; the painted damage
	 * arrives via the deferred-io flush timer defio_delay frames
	 * later (0 = flush modeled at trace time). */
	unsigned int next_req, next_commit;
	u64 defio_delay;
	int at_wash_start;	/* injecting from a wash's own frm_start */

	/* per-event accounting */
	struct ev_acct {
		int decided_global;
		int requested, committed;
		u64 rel;		/* due frame, relative to the epoch */
		u64 inject_eff;		/* frame the request phase ran */
		u64 settle_eff;		/* next machine idle after it */
		int settled;
	} *acct;

	/* wash accounting */
	struct wash_stats wash[WASH_MAX];
	u64 ioctl_requests;
	u64 lut_events;
	int pending_ioctl;
	u64 decision_mismatch;

	/* runaway guard */
	u64 max_hw_frames;
	int aborted;
};

static struct replay rp;

/* the request phase's due frame (absolute effective frame) */
static u64 due_req(unsigned int i)
{
	return rp.epoch_eff + rp.acct[i].rel;
}

/* the damage-commit phase's due frame (deferred-io flush) */
static u64 due_commit(unsigned int i)
{
	return rp.epoch_eff + rp.acct[i].rel + rp.defio_delay;
}

/* Phase 1 of an event: the KOReader-side decision and (for globals) the
 * ioctl, at trace time. */
static void replay_request(unsigned int i)
{
	const struct trace_event *ev = &rp.tr->ev[i];
	struct ev_acct *a = &rp.acct[i];

	a->requested = 1;
	a->inject_eff = fake_ebc.hw_frames + rp.idle_offset;
	a->decided_global = policy_global(rp.pol, ev);
	if (rp.verify_decisions && ev->recorded_global >= 0 &&
	    ev->recorded_global != a->decided_global)
		rp.decision_mismatch++;
	if (a->decided_global) {
		rp.ioctl_requests++;
		rp.pending_ioctl = 1;
		/* If this injection runs from the first frame of a wash the
		 * thread has already committed to, the device-side ioctl
		 * would have landed while do_one_full_refresh was still set
		 * (during the previous wash) and been absorbed by the
		 * boolean flag — setting it here, *after* the thread's
		 * clear, would mint a wash the device never runs. */
		if (!rp.at_wash_start)
			request_global(rp.ebc);
	}
}

/* Phase 2 of an event: the painted pixels reach the driver.  KOReader
 * painted only the traced rect; deferred-io widens the *clip* to page
 * bands whose out-of-rect rows are byte-identical and therefore
 * diff-masked — so paint the rect, commit the band. */
static void replay_commit(unsigned int i)
{
	const struct trace_event *ev = &rp.tr->ev[i];
	struct drm_rect paint, clip;
	struct policy nopol;

	rp.acct[i].committed = 1;
	nopol = *rp.pol;
	nopol.defio_bands = false;
	if (damage_rect(&nopol, ev, rp.scale, rp.rw, rp.rh, &paint))
		content_paint(rp.ctx->final_atomic_update,
			      rp.ctx->gray4_pitch, &paint, rp.rh,
			      rp.content_seed ^
			      (u64)(i + 1) * 0x9e3779b97f4a7c15ull);
	if (damage_rect(rp.pol, ev, rp.scale, rp.rw, rp.rh, &clip))
		commit_damage(rp.ctx, &clip, 1);
}

static void replay_inject_due(void)
{
	u64 eff = fake_ebc.hw_frames + rp.idle_offset;

	if (!rp.epoch_set)
		return;
	while (rp.next_req < rp.tr->n && due_req(rp.next_req) <= eff)
		replay_request(rp.next_req++);
	while (rp.next_commit < rp.tr->n && due_commit(rp.next_commit) <= eff)
		replay_commit(rp.next_commit++);
}

/* fake-device hook: fires at the start of every honored DSP_FRM_START —
 * the point where a concurrent atomic update could land on hardware */
static void replay_frm_start(u32 hw_frame)
{
	(void)hw_frame;
	if (rp.max_hw_frames && fake_ebc.hw_frames > rp.max_hw_frames) {
		rp.aborted = 1;
		ebc_shim.thread_stop = true;
		return;
	}
	rp.at_wash_start = !!(fake_ebc.latched[EBC_DSP_CTRL / 4] &
			      EBC_DSP_CTRL_DSP_LUT_MODE);
	replay_inject_due();
	rp.at_wash_start = 0;
}

/* thread hook: the machine is idle (queue drained, no wash pending) */
static void replay_schedule(void)
{
	u64 eff = fake_ebc.hw_frames + rp.idle_offset;
	u64 next_due;
	unsigned int i;

	/* the boot sequence (RESET + probe wash) has drained: this first
	 * idle is the session start the trace's t0 corresponds to */
	if (!rp.epoch_set) {
		rp.epoch_set = 1;
		rp.epoch_eff = eff;
	}

	/* every event fully delivered so far has settled at this frame */
	for (i = 0; i < rp.next_req; i++)
		if (rp.acct[i].requested && rp.acct[i].committed &&
		    !rp.acct[i].settled) {
			rp.acct[i].settle_eff = eff;
			rp.acct[i].settled = 1;
		}

	if (rp.next_req >= rp.tr->n && rp.next_commit >= rp.tr->n) {
		ebc_shim.thread_stop = true;
		return;
	}

	/* idle until the earliest pending action */
	next_due = (u64)-1;
	if (rp.next_req < rp.tr->n && due_req(rp.next_req) < next_due)
		next_due = due_req(rp.next_req);
	if (rp.next_commit < rp.tr->n && due_commit(rp.next_commit) < next_due)
		next_due = due_commit(rp.next_commit);
	if (next_due > eff) {
		rp.idle_offset = next_due - fake_ebc.hw_frames;
		rp.off_hist[rp.off_hist_n].hw = fake_ebc.hw_frames;
		rp.off_hist[rp.off_hist_n].off = rp.idle_offset;
		rp.off_hist_n++;
	}
	replay_inject_due();
}

/* fake-device hook: census point, once per honored refresh */
static void replay_on_event(const struct fake_ebc_event *ev, const u8 *prev,
			    const u8 *next, const u8 *phase_buf)
{
	enum wash_class cls;
	struct wash_stats *ws;
	u64 hist[16][16];
	u8 dark_any[16][16], any[16][16], count[16][16];
	unsigned int w = ev->win_act & 0xffff, h = ev->win_act >> 16;
	size_t pitch = w / 2;
	unsigned int x, y, p, n, ph;

	(void)phase_buf;
	if (!ev->lut_mode)
		return;

	/* The thread always plays RESET first, then the probe-set
	 * do_one_full_refresh boot wash; a policy request landing before
	 * or during those coalesces into them (the flag is a boolean on
	 * the device too). */
	rp.lut_events++;
	if (rp.lut_events == 1) {
		cls = WASH_RESET;
	} else if (rp.lut_events == 2) {
		cls = WASH_BOOT;
		rp.pending_ioctl = 0;
	} else if (rp.pending_ioctl) {
		rp.pending_ioctl = 0;
		cls = WASH_IOCTL;
	} else {
		cls = WASH_AUTO;
	}
	ws = &rp.wash[cls];
	ws->count++;
	ws->planes += ev->planes;

	/* decode the uploaded LUT once per (from,to) pair */
	for (p = 0; p < 16; p++)
		for (n = 0; n < 16; n++) {
			u8 d = 0, a = 0, c = 0;

			for (ph = 0; ph < ev->planes; ph++) {
				u8 code = fake_ebc_lut_code(ph, n, p);

				if (code) {
					a = 1;
					c++;
					if (code == 1)
						d = 1;
				}
			}
			dark_any[p][n] = d;
			any[p][n] = a;
			count[p][n] = c;
		}

	memset(hist, 0, sizeof(hist));
	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
			hist[fake_ebc_y4(prev, pitch, x, y)]
			    [fake_ebc_y4(next, pitch, x, y)]++;

	ws->white_white_px += hist[15][15];
	if (dark_any[15][15])
		ws->white_dark_px += hist[15][15];
	for (p = 0; p < 16; p++)
		for (n = 0; n < 16; n++) {
			if (any[p][n])
				ws->driven_px += hist[p][n];
			ws->px_phases += hist[p][n] * count[p][n];
		}
}

/* effective frame of a raw hw frame index, via the idle-offset history
 * (history is ordered by hw frame; binary-search the last entry <= hw) */
static u64 eff_of_hw(u64 hw)
{
	u64 off = 0;
	unsigned int lo = 0, hi = rp.off_hist_n;

	while (lo < hi) {
		unsigned int mid = lo + (hi - lo) / 2;

		if (rp.off_hist[mid].hw <= hw) {
			off = rp.off_hist[mid].off;
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	return hw + off;
}

static int cmp_u64(const void *a, const void *b)
{
	u64 x = *(const u64 *)a, y = *(const u64 *)b;

	return x < y ? -1 : x > y;
}

struct replay_result {
	u64 events, decided_global, decided_partial;
	u64 ioctl_requests, decision_mismatch;
	struct wash_stats wash[WASH_MAX];
	u64 partial_frames, partial_px_phases, total_px_phases;
	u64 active_frames, end_eff;
	u64 settle_min, settle_med, settle_max, settled_n;
	u64 stale_p50, stale_p90, stale_max, never_driven;
	u64 conflicts, event_overflow;
	int clean, aborted;
	int eff_threshold;
	unsigned int lut_phases;
};

/* Run one trace under one policy.  Returns 0 on setup failure. */
static int replay_run(const char *fwdir, const struct trace *tr,
		      const struct policy *pol, int scale, int verify,
		      const char *pgm_dir, struct replay_result *res)
{
	struct harness h;
	struct rockchip_ebc_ctx *ctx;
	int rw = ((PANEL_W / scale) + 1) & ~1;
	int rh = PANEL_H / scale;
	int eff_threshold;
	unsigned int i;
	u64 *stale;
	size_t npix;
	int ret;

	memset(res, 0, sizeof(*res));
	memset(&rp, 0, sizeof(rp));
	if (!tr->n) {
		fprintf(stderr, "ebc-replay: trace has no [pn-refresh] events\n");
		return 0;
	}

	setenv("EBC_SHIM_FW_DIR", fwdir, 1);

	/* driver params for this run (plain globals in this TU) */
	default_waveform = pol->default_wf;
	refresh_waveform = pol->refresh_wf;
	auto_refresh = pol->auto_refresh;
	split_area_limit = pol->split_area_limit;
	no_off_screen = true;	/* session metrics, not shutdown */
	direct_mode = false;
	diff_mode = true;
	/* the driver hardcodes the panel's screen area as its accumulator
	 * unit; compensate for scaled geometry so auto washes fire after
	 * the same number of (scaled) screenfuls */
	eff_threshold = (int)llround((double)pol->refresh_threshold *
				     ((double)rw * rh) /
				     (2.0 * ONE_SCREEN_AREA));
	if (pol->auto_refresh && eff_threshold < 1)
		eff_threshold = 1;
	refresh_threshold = eff_threshold;
	res->eff_threshold = eff_threshold;
	ebc_shim.iio_temp_override = true;
	ebc_shim.iio_temp_mC = pol->temp_c * 1000;

	if (!replay_probe(&h))
		return 0;
	fake_ebc.record_seq = pgm_dir && (size_t)rw * rh <= 65536;
	replay_mode_set(&h, rw, rh);
	ctx = rockchip_ebc_ctx_alloc(h.ebc, rw, rh);
	h.crtc_state.ctx = ctx;
	memset(ctx->phase[0], 0xff, ctx->phase_size);
	memset(ctx->phase[1], 0xff, ctx->phase_size);

	rp.pol = pol;
	rp.scale = scale;
	rp.rw = rw;
	rp.rh = rh;
	rp.verify_decisions = verify;
	rp.content_seed = 0x77696c6b626f6f6bull;	/* "wilkbook" */
	rp.ebc = h.ebc;
	rp.ctx = ctx;
	rp.tr = tr;
	rp.t0 = tr->ev[0].t;
	rp.acct = calloc(tr->n, sizeof(*rp.acct));
	rp.off_hist = calloc(2 * (size_t)tr->n + 4, sizeof(*rp.off_hist));
	if (!rp.acct || !rp.off_hist) {
		fprintf(stderr, "ebc-replay: out of memory\n");
		exit(1);
	}
	rp.max_hw_frames = 10u * 1000 * 1000;
	/* Replay legitimately runs far past the shim's liveness cap: a long
	 * trace is many thousands of real refreshes, and rp.max_hw_frames
	 * above is already this tool's own bound.  Opt out explicitly rather
	 * than raising the shared default, which exists to catch a
	 * non-terminating refresh loop in the rung-7a tests. */
	fake_ebc.hw_frame_cap = 0xffffffffu;
	rp.defio_delay = (u64)llround((double)pol->defio_delay_ms *
				      PANEL_FPS / 1000.0);
	{
		u64 prev_rel = 0;

		for (i = 0; i < tr->n; i++) {
			double dt = tr->ev[i].t - rp.t0;
			u64 rel;

			/* clock steps and hostile values: keep the timeline
			 * finite and monotonic (order in the log is real
			 * even when the wall clock jumps) */
			if (!isfinite(dt) || dt < 0)
				dt = 0;
			if (dt > 1e7)
				dt = 1e7;
			rel = (u64)llround(dt * PANEL_FPS);
			if (rel < prev_rel)
				rel = prev_rel;
			rp.acct[i].rel = rel;
			prev_rel = rel;
		}
	}

	ebc_shim.schedule_hook = replay_schedule;
	fake_ebc.on_frm_start = replay_frm_start;
	fake_ebc.on_event = replay_on_event;

	kthread_unpark(h.ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);
	(void)ret;

	/* -------- collect -------- */
	res->events = tr->n;
	res->lut_phases = h.ebc->lut.num_phases;
	for (i = 0; i < tr->n; i++) {
		if (!rp.acct[i].requested)
			continue;
		if (rp.acct[i].decided_global)
			res->decided_global++;
		else
			res->decided_partial++;
	}
	res->ioctl_requests = rp.ioctl_requests;
	res->decision_mismatch = rp.decision_mismatch;
	memcpy(res->wash, rp.wash, sizeof(res->wash));

	npix = (size_t)rw * rh;
	res->active_frames = fake_ebc.hw_frames;
	res->end_eff = fake_ebc.hw_frames + rp.idle_offset;
	res->conflicts = fake_ebc.conflicts;
	res->aborted = rp.aborted;
	res->clean = ebc_shim.completion_timeouts == 0 &&
		     ebc_shim.regmap_oob == 0 &&
		     ebc_shim.dma_violations == 0 &&
		     fake_ebc.frm_start_config_dirty == 0 &&
		     fake_ebc.frames_unpowered == 0 &&
		     fake_ebc.bad_frames == 0;

	for (i = 0; i < WASH_MAX; i++)
		res->total_px_phases += res->wash[i].px_phases;
	{
		u64 total_drive = 0;
		size_t j;

		for (j = 0; j < npix; j++)
			total_drive += fake_ebc.drive_count[j];
		res->partial_px_phases = total_drive - res->total_px_phases;
		res->total_px_phases = total_drive;
	}
	/* one hw frame per three-window DSP_START; derive from the plane
	 * counter rather than the event log, whose 4096-entry capacity a
	 * long session exceeds */
	{
		u64 wash_planes = 0;

		for (i = 0; i < WASH_MAX; i++)
			wash_planes += res->wash[i].planes;
		res->partial_frames = fake_ebc.hw_frames - wash_planes;
	}
	res->event_overflow = fake_ebc.event_overflow;

	/* settle latency over injected events (frames from injection to
	 * the machine's next idle) */
	{
		u64 *lat = calloc(tr->n, sizeof(*lat));
		unsigned int n = 0;

		if (!lat) {
			fprintf(stderr, "ebc-replay: out of memory\n");
			exit(1);
		}

		for (i = 0; i < tr->n; i++)
			if (rp.acct[i].requested && rp.acct[i].settled)
				lat[n++] = rp.acct[i].settle_eff -
					   rp.acct[i].inject_eff;
		if (n) {
			qsort(lat, n, sizeof(*lat), cmp_u64);
			res->settle_min = lat[0];
			res->settle_med = lat[n / 2];
			res->settle_max = lat[n - 1];
			res->settled_n = n;
		}
		free(lat);
	}

	/* scrub staleness: effective frames since each pixel's last active
	 * drive at end of trace (the honest GL16-residue-risk proxy) */
	stale = malloc(npix * sizeof(*stale));
	if (!stale) {
		fprintf(stderr, "ebc-replay: out of memory\n");
		exit(1);
	}
	{
		size_t j;

		for (j = 0; j < npix; j++) {
			if (fake_ebc.drive_count[j] == 0) {
				res->never_driven++;
				stale[j] = res->end_eff;
			} else {
				stale[j] = res->end_eff -
					eff_of_hw(fake_ebc.last_drive_frame[j]);
			}
		}
		qsort(stale, npix, sizeof(*stale), cmp_u64);
		res->stale_p50 = stale[npix / 2];
		res->stale_p90 = stale[(size_t)(npix * 0.9)];
		res->stale_max = stale[npix - 1];
	}
	free(stale);

	/* optional per-frame PGMs from the recorded drive codes: a crude
	 * optical integrator (two gray steps per driven phase) — for
	 * eyeballing flash patterns, explicitly qualitative */
	if (pgm_dir && fake_ebc.record_seq && fake_ebc.seq) {
		u8 *optical = malloc(npix);
		u8 *gray = malloc(npix);
		u32 f, frames = fake_ebc.hw_frames;
		size_t j;

		if (!optical || !gray) {
			fprintf(stderr, "ebc-replay: out of memory\n");
			exit(1);
		}
		if (frames > fake_ebc.seq_frames)
			frames = fake_ebc.seq_frames;
		mkdir(pgm_dir, 0777);
		memset(optical, 0xff, npix);
		for (f = 0; f < frames; f++) {
			char path[512];
			FILE *pf;

			for (j = 0; j < npix; j++) {
				u8 code = fake_ebc.seq[(size_t)f * npix + j];

				if (code == 1)
					optical[j] = optical[j] > 34 ?
						     optical[j] - 34 : 0;
				else if (code == 2)
					optical[j] = optical[j] < 221 ?
						     optical[j] + 34 : 255;
			}
			snprintf(path, sizeof(path), "%s/frame-%05u.pgm",
				 pgm_dir, f);
			pf = fopen(path, "wb");
			if (pf) {
				fprintf(pf, "P5\n%d %d\n255\n", rw, rh);
				fwrite(optical, 1, npix, pf);
				fclose(pf);
			}
		}
		/* the believed end state, for comparison */
		for (j = 0; j < npix; j++) {
			unsigned int x2 = (unsigned int)(j % rw);
			unsigned int y2 = (unsigned int)(j / rw);

			gray[j] = (u8)(get_px(ctx->next, ctx->gray4_pitch,
					      (int)x2, (int)y2) * 17);
		}
		{
			char path[512];
			FILE *pf;

			snprintf(path, sizeof(path), "%s/believed-final.pgm",
				 pgm_dir);
			pf = fopen(path, "wb");
			if (pf) {
				fprintf(pf, "P5\n%d %d\n255\n", rw, rh);
				fwrite(gray, 1, npix, pf);
				fclose(pf);
			}
		}
		free(optical);
		free(gray);
	}

	free(rp.acct);
	free(rp.off_hist);
	replay_teardown(&h, ctx);
	return 1;
}

static void replay_report(const struct trace *tr, const struct policy *pol,
			  int scale, const struct replay_result *r)
{
	u64 washes = 0;
	unsigned int i;

	for (i = 0; i < WASH_MAX; i++)
		washes += r->wash[i].count;

	printf("ebc-replay: events=%llu span=%.1fs geometry=%dx%d scale=%d "
	       "temp=%dC lut-phases=%u\n",
	       (unsigned long long)r->events,
	       tr->n ? tr->ev[tr->n - 1].t - tr->ev[0].t : 0.0,
	       ((PANEL_W / scale) + 1) & ~1, PANEL_H / scale, scale,
	       pol->temp_c, r->lut_phases);
	printf("policy: flash-frac=%.2f default-waveform=%s "
	       "refresh-waveform=%s auto-refresh=%d refresh-threshold=%d"
	       "(eff=%d) split-area-limit=%d defio=%s defio-delay-ms=%d\n",
	       pol->flash_frac, wf_name(pol->default_wf),
	       wf_name(pol->refresh_wf), pol->auto_refresh,
	       pol->refresh_threshold, r->eff_threshold,
	       pol->split_area_limit, pol->defio_bands ? "bands" : "rect",
	       pol->defio_delay_ms);
	printf("decisions: partial=%llu global=%llu ioctl-requests=%llu",
	       (unsigned long long)r->decided_partial,
	       (unsigned long long)r->decided_global,
	       (unsigned long long)r->ioctl_requests);
	if (r->decision_mismatch)
		printf(" DECISION-MISMATCH=%llu",
		       (unsigned long long)r->decision_mismatch);
	printf("\n");
	printf("washes: total=%llu", (unsigned long long)washes);
	for (i = 0; i < WASH_MAX; i++)
		printf(" %s=%llu", wash_names[i],
		       (unsigned long long)r->wash[i].count);
	printf("\n");
	for (i = 0; i < WASH_MAX; i++) {
		const struct wash_stats *w = &r->wash[i];

		if (!w->count)
			continue;
		printf("  wash[%s]: planes=%llu white-white-px=%llu "
		       "dark-driven-white-px=%llu driven-px=%llu "
		       "px-phases=%llu\n", wash_names[i],
		       (unsigned long long)w->planes,
		       (unsigned long long)w->white_white_px,
		       (unsigned long long)w->white_dark_px,
		       (unsigned long long)w->driven_px,
		       (unsigned long long)w->px_phases);
	}
	printf("partial: hw-frames=%llu px-phases=%llu\n",
	       (unsigned long long)r->partial_frames,
	       (unsigned long long)r->partial_px_phases);
	printf("frames: active=%llu idle=%llu est-wall=%.1fs\n",
	       (unsigned long long)r->active_frames,
	       (unsigned long long)(r->end_eff - r->active_frames),
	       (double)r->end_eff / PANEL_FPS);
	printf("settle: n=%llu min=%llu med=%llu max=%llu frames "
	       "(med %.0f ms)\n",
	       (unsigned long long)r->settled_n,
	       (unsigned long long)r->settle_min,
	       (unsigned long long)r->settle_med,
	       (unsigned long long)r->settle_max,
	       (double)r->settle_med * 1000.0 / PANEL_FPS);
	printf("scrub-staleness: p50=%llu p90=%llu max=%llu eff-frames "
	       "(p90 %.1fs) never-driven=%llu px\n",
	       (unsigned long long)r->stale_p50,
	       (unsigned long long)r->stale_p90,
	       (unsigned long long)r->stale_max,
	       (double)r->stale_p90 / PANEL_FPS,
	       (unsigned long long)r->never_driven);
	printf("health: clean=%d conflicts=%llu event-log-overflow=%llu "
	       "aborted=%d\n",
	       r->clean, (unsigned long long)r->conflicts,
	       (unsigned long long)r->event_overflow, r->aborted);
}

/* ---------------------------------------------------------------------- */
/* self-tests                                                              */

static void test_parse(void)
{
	struct trace_event ev;
	int ok;

	ok = trace_parse_line(
		"2026-07-05 14:23:01 07/05/26-14:23:01 INFO  [pn-refresh] "
		"flashui partial rect=341,520,722,832 dither=nil "
		"t=1751725381.482913 \n", &ev);
	check(ok && ev.intent == IN_FLASHUI && ev.recorded_global == 0 &&
	      ev.x == 341 && ev.y == 520 && ev.w == 722 && ev.h == 832 &&
	      fabs(ev.t - 1751725381.482913) < 1e-5,
	      "parse: doubly-prefixed on-disk line");

	ok = trace_parse_line(
		"[pn-refresh] full global rect=0,0,1872,1404 dither=nil "
		"t=100.000000\n", &ev);
	check(ok && ev.intent == IN_FULL && ev.recorded_global == 1 &&
	      ev.w == 1872, "parse: bare full-screen line");

	ok = trace_parse_line(
		"[pn-refresh] ui partial rect=nil,nil,2.5,-4 dither=true "
		"t=5.000001\n", &ev);
	check(ok && ev.intent == IN_UI && ev.x == 0 && ev.y == 0 &&
	      ev.w == 2.5 && ev.h == -4,
	      "parse: nil, fractional and negative dimensions");

	ok = trace_parse_line("random log noise without the token\n", &ev);
	check(!ok, "parse: non-trace lines are ignored");

	ok = trace_parse_line("[pn-refresh] partial partial rect=1,2,3 "
			      "dither=nil t=1.0\n", &ev);
	check(!ok, "parse: truncated rect is rejected");
}

static void test_policy(void)
{
	struct policy p;
	struct trace_event ev;

	policy_ship(&p);
	memset(&ev, 0, sizeof(ev));

	ev.intent = IN_FULL;
	check(policy_global(&p, &ev) == 1, "policy: full always washes");

	/* The promotion boundary is the policy's own flash_frac (device.lua's
	 * flash_area_fraction; 0.60 on the old driver, 0.98 since the embrace
	 * sweep's S2), so the test follows the model rather than a literal. */
	ev.intent = IN_FLASHUI;
	ev.w = PANEL_W;
	ev.h = ceil(p.flash_frac * PANEL_H);
	check(policy_global(&p, &ev) == 1,
	      "policy: flashui at the promotion boundary washes");
	ev.h = floor(p.flash_frac * PANEL_H) - 1;
	check(policy_global(&p, &ev) == 0,
	      "policy: flashui just under the boundary stays partial");

	ev.intent = IN_UI;
	ev.h = PANEL_H;
	check(policy_global(&p, &ev) == 0,
	      "policy: full-screen ui never washes");
}

static void test_defio(void)
{
	struct drm_rect b;

	/* row 0 spans fb bytes 0..7487 = pages 0 and 1; page 1 bleeds into
	 * row 1, so the page-granular clip covers rows 0..1 (y2 = 2) */
	b = defio_band(0, 1);
	check(b.x1 == 0 && b.x2 == PANEL_W && b.y1 == 0 && b.y2 == 2,
	      "defio: row 0 touches two pages -> rows 0..%d", b.y2 - 1);
	b = defio_band(700, 702);
	check(b.y1 <= 700 && b.y2 >= 702 && b.x1 == 0 && b.x2 == PANEL_W,
	      "defio: interior band covers its rows (got %d..%d)",
	      b.y1, b.y2);
	/* pages are smaller than a row (4096 < 7488 bytes), so the band
	 * widens by at most one row on each side */
	check(b.y1 >= 699 && b.y2 <= 703,
	      "defio: page granularity adds at most one row per side");
	b = defio_band(PANEL_H - 1, PANEL_H);
	check(b.y2 == PANEL_H, "defio: last row band clamps to the panel");
}

static void test_content(void)
{
	u8 buf1[64 * 32], buf2[64 * 32];
	struct drm_rect r = { 0, 0, 128, 32 };
	unsigned int ink = 0, x, y;

	memset(buf1, 0, sizeof(buf1));
	memset(buf2, 0, sizeof(buf2));
	content_paint(buf1, 64, &r, 320, 7);
	content_paint(buf2, 64, &r, 320, 7);
	check(!memcmp(buf1, buf2, sizeof(buf1)),
	      "content: identical seeds paint identical pixels");
	content_paint(buf2, 64, &r, 320, 8);
	check(memcmp(buf1, buf2, sizeof(buf1)) != 0,
	      "content: different seeds paint different pixels");
	for (y = 0; y < 32; y++)
		for (x = 0; x < 128; x++)
			ink += get_px(buf1, 64, (int)x, (int)y) != 0xf;
	check(ink > 128 * 32 / 20 && ink < 128 * 32 * 6 / 10,
	      "content: ink coverage is text-like (%u/%u px)", ink, 128 * 32);
}

static void test_synth_roundtrip(void)
{
	struct synth_params sp;
	struct trace tr;
	unsigned int i, fulls = 0, mismatch = 0;
	struct policy pol;
	char path[] = "/tmp/ebc-replay-synth-XXXXXX";
	int fd = mkstemp(path);

	if (fd < 0) {
		check(0, "synth: mkstemp");
		return;
	}
	close(fd);
	synth_default(&sp);
	sp.pages = 12;
	sp.full_every = 4;
	check(synth_write(path, &sp) == 0, "synth: trace written");
	check(trace_load(&tr, path) == 0 && tr.n > 12,
	      "synth: parses back (%u events)", tr.n);
	policy_ship(&pol);
	for (i = 0; i < tr.n; i++) {
		if (tr.ev[i].intent == IN_FULL)
			fulls++;
		if (tr.ev[i].recorded_global >= 0 &&
		    tr.ev[i].recorded_global !=
		    policy_global(&pol, &tr.ev[i]))
			mismatch++;
		if (i && tr.ev[i].t < tr.ev[i - 1].t)
			mismatch += 1000;	/* time must be monotonic */
	}
	check(fulls == 12 / 4, "synth: every-4th page promoted to full (%u)",
	      fulls);
	check(mismatch == 0,
	      "synth: recorded decisions match the ship policy (verify mode)");
	free(tr.ev);
	unlink(path);
}

/* WBF-gated: replay a short synthetic session at scale 8 and pin the
 * structural expectations; then the headline differential — the same
 * trace under GC16 vs GL16 globals. */
static void test_replay_washes(const char *fwdir)
{
	struct synth_params sp;
	struct trace tr;
	struct policy pol;
	struct replay_result r_gl16, r_gc16;
	char path[] = "/tmp/ebc-replay-trace-XXXXXX";
	int fd = mkstemp(path);
	u64 expect_washes;

	if (fd < 0) {
		check(0, "replay: mkstemp");
		return;
	}
	close(fd);
	synth_default(&sp);
	sp.pages = 10;
	sp.full_every = 5;
	sp.menus = 2;
	synth_write(path, &sp);
	trace_load(&tr, path);

	policy_ship(&pol);
	pol.auto_refresh = false;	/* isolate the KOReader-layer washes */

	check(replay_run(fwdir, &tr, &pol, 8, 1, NULL, &r_gl16),
	      "replay: GL16 run completes");
	check(r_gl16.decision_mismatch == 0,
	      "replay: policy reproduces the recorded decisions");
	check(r_gl16.clean && !r_gl16.aborted,
	      "replay: no harness violations (GL16 run)");
	check(r_gl16.wash[WASH_RESET].count == 1 &&
	      r_gl16.wash[WASH_BOOT].count == 1,
	      "replay: session starts with RESET + boot wash");
	/* 2 promoted fulls + 1 large menu open + 1 large menu close */
	expect_washes = r_gl16.ioctl_requests;
	check(expect_washes == 4 &&
	      r_gl16.wash[WASH_IOCTL].count == expect_washes,
	      "replay: 4 policy washes requested, none coalesced "
	      "(req=%llu washed=%llu)",
	      (unsigned long long)r_gl16.ioctl_requests,
	      (unsigned long long)r_gl16.wash[WASH_IOCTL].count);
	check(r_gl16.wash[WASH_AUTO].count == 0,
	      "replay: auto washes off when auto_refresh=0");
	check(r_gl16.partial_frames > 0 && r_gl16.settled_n == tr.n,
	      "replay: partials ran and every event settled");
	check(r_gl16.wash[WASH_IOCTL].white_dark_px == 0,
	      "replay: GL16 washes never drive believed-white pixels dark");

	pol.refresh_wf = DRM_EPD_WF_GC16;
	check(replay_run(fwdir, &tr, &pol, 8, 0, NULL, &r_gc16),
	      "replay: GC16 run completes");
	check(r_gc16.wash[WASH_IOCTL].white_dark_px > 0 &&
	      r_gc16.wash[WASH_IOCTL].white_white_px ==
	      r_gc16.wash[WASH_IOCTL].white_dark_px,
	      "replay: GC16 washes drive every believed-white pixel dark "
	      "(the black flash, quantified: %llu px)",
	      (unsigned long long)r_gc16.wash[WASH_IOCTL].white_dark_px);
	check(r_gc16.wash[WASH_IOCTL].px_phases >
	      r_gl16.wash[WASH_IOCTL].px_phases,
	      "replay: GC16 washes drive more pixel-phases than GL16");
	/* anchor the staleness metric, not just its ordering: the last
	 * event is a promoted full, so GC16 scrubbed everything within a
	 * couple hundred frames of the end, while under GL16 the white
	 * background has not been driven since the boot wash — its
	 * staleness must span most of the session */
	check(r_gc16.stale_p90 <= 200,
	      "replay: GC16 staleness p90 anchors at the final wash "
	      "(%llu frames)", (unsigned long long)r_gc16.stale_p90);
	check(r_gl16.stale_p90 * 4 >= r_gl16.end_eff * 3,
	      "replay: GL16 staleness p90 spans the session "
	      "(%llu of %llu frames)",
	      (unsigned long long)r_gl16.stale_p90,
	      (unsigned long long)r_gl16.end_eff);

	free(tr.ev);
	unlink(path);
}

/* WBF-gated: the driver's own auto-refresh accumulator fires untraced
 * washes, and — the quirk — manual washes do not reset it.  The trace is
 * hand-built so the two hypotheses predict DIFFERENT auto counts:
 * 12 full-screen page turns (1 scaled screenful of banded damage each)
 * with one manual full between pages 4 and 5, threshold = 6 screenfuls
 * (raw 12 -> eff 3 at scale 2; eff * 1314144 = 6 * 936*702).
 *   no-reset (actual driver): crossings at pages 6 and 12 -> 2 autos
 *   reset-on-manual-wash:     4 counted, reset, crossing at 10 -> 1 auto
 * (The manual wash's own band is spliced into the global and freed
 * without being counted — only the partial path accumulates.) */
static void test_replay_auto(const char *fwdir)
{
	struct trace tr;
	struct trace_event ev;
	struct policy pol;
	struct replay_result r;
	unsigned int page;

	memset(&tr, 0, sizeof(tr));
	memset(&ev, 0, sizeof(ev));
	ev.w = PANEL_W;
	ev.h = PANEL_H;
	for (page = 1; page <= 12; page++) {
		ev.intent = IN_PARTIAL;
		ev.t = 10.0 + 2.0 * page;
		trace_push(&tr, &ev);
		if (page == 4) {
			ev.intent = IN_FULL;
			ev.t = 10.0 + 2.0 * page + 1.0;
			trace_push(&tr, &ev);
		}
	}

	policy_ship(&pol);
	pol.auto_refresh = true;	/* THIS suite is the auto-accumulator test:
				 * it must ask for auto-refresh explicitly now that
				 * the shipped baseline has it off. */
	pol.refresh_threshold = 12;

	check(replay_run(fwdir, &tr, &pol, 2, 0, NULL, &r),
	      "replay-auto: run completes");
	check(r.eff_threshold == 3,
	      "replay-auto: threshold compensates exactly at scale 2 "
	      "(got %d)", r.eff_threshold);
	check(r.wash[WASH_IOCTL].count == 1,
	      "replay-auto: the one manual wash ran");
	/* quirk (executed): 2 autos means the accumulator survived the
	 * interleaved manual wash; 1 would mean the wash reset it. */
	check(r.wash[WASH_AUTO].count == 2,
	      "quirk: manual washes do not reset the auto-refresh "
	      "accumulator (auto=%llu, reset hypothesis predicts 1)",
	      (unsigned long long)r.wash[WASH_AUTO].count);
	check(r.clean && !r.aborted, "replay-auto: no harness violations");

	free(tr.ev);
}

/* WBF-gated: globals coalesce exactly like the device's boolean ioctl
 * flag — two requests in the same repaint burst produce one wash, and
 * no wash is ever minted out of thin air (auto stays 0 with the
 * accumulator off).  Also the verify-decisions negative case: a trace
 * whose recorded decision contradicts the policy must be flagged. */
static void test_replay_coalesce(const char *fwdir)
{
	struct trace tr;
	struct trace_event ev;
	struct policy pol;
	struct replay_result r;

	memset(&tr, 0, sizeof(tr));
	memset(&ev, 0, sizeof(ev));
	ev.intent = IN_FULL;
	ev.w = PANEL_W;
	ev.h = PANEL_H;
	ev.t = 50.0;
	ev.recorded_global = 0;	/* deliberately wrong: full washes */
	trace_push(&tr, &ev);
	ev.t = 53.0;		/* a same-instant pair */
	ev.recorded_global = 1;
	trace_push(&tr, &ev);
	trace_push(&tr, &ev);

	policy_ship(&pol);
	pol.auto_refresh = false;

	check(replay_run(fwdir, &tr, &pol, 8, 1, NULL, &r),
	      "replay-coalesce: run completes");
	check(r.ioctl_requests == 3 && r.wash[WASH_IOCTL].count == 2 &&
	      r.wash[WASH_BOOT].count == 1 && r.wash[WASH_AUTO].count == 0,
	      "replay-coalesce: 3 requests -> 2 washes (same-frame pair "
	      "coalesced, none minted: ioctl=%llu auto=%llu)",
	      (unsigned long long)r.wash[WASH_IOCTL].count,
	      (unsigned long long)r.wash[WASH_AUTO].count);
	check(r.decision_mismatch == 1,
	      "replay-coalesce: verify-decisions flags the mislabeled event");
	free(tr.ev);
}

/* ---------------------------------------------------------------------- */
/* CLI                                                                     */

static int kv_match(const char *arg, const char *key, const char **val)
{
	size_t n = strlen(key);

	if (!strncmp(arg, key, n) && arg[n] == '=') {
		*val = arg + n + 1;
		return 1;
	}
	return 0;
}

static int cmd_selftest(const char *fwdir)
{
	test_parse();
	test_policy();
	test_defio();
	test_content();
	test_synth_roundtrip();

	if (fwdir && fwdir[0]) {
		test_replay_washes(fwdir);
		test_replay_auto(fwdir);
		test_replay_coalesce(fwdir);
	} else {
		printf("SKIP: waveform replay tests need a WBF "
		       "(pass FWDIR with rockchip/ebc.wbf)\n");
	}

	if (failures) {
		printf("RESULT: %d failures\n", failures);
		return 1;
	}
	printf("RESULT: ok\n");
	return 0;
}

static int cmd_synth(int argc, char **argv)
{
	struct synth_params sp;
	const char *out, *val;
	int i;

	if (argc < 1) {
		fprintf(stderr, "usage: ebc-replay synth OUT [pages=N] "
			"[period=SEC] [menus=N] [full-every=N] [seed=N]\n");
		return 2;
	}
	out = argv[0];
	synth_default(&sp);
	for (i = 1; i < argc; i++) {
		if (kv_match(argv[i], "pages", &val))
			sp.pages = (unsigned int)atoi(val);
		else if (kv_match(argv[i], "period", &val))
			sp.period = atof(val);
		else if (kv_match(argv[i], "menus", &val))
			sp.menus = (unsigned int)atoi(val);
		else if (kv_match(argv[i], "full-every", &val))
			sp.full_every = (unsigned int)atoi(val);
		else if (kv_match(argv[i], "seed", &val))
			sp.seed = (u64)strtoull(val, NULL, 0);
		else {
			fprintf(stderr, "ebc-replay: unknown synth arg %s\n",
				argv[i]);
			return 2;
		}
	}
	if (synth_write(out, &sp)) {
		fprintf(stderr, "ebc-replay: cannot write %s\n", out);
		return 1;
	}
	printf("synth: %u pages, %u menus, full-every=%u -> %s\n",
	       sp.pages, sp.menus, sp.full_every, out);
	return 0;
}

static int cmd_replay(int argc, char **argv)
{
	struct trace tr;
	struct policy pol;
	struct replay_result res;
	const char *fwdir, *trace_path, *val, *pgm_dir = NULL;
	int scale = 4;
	int verify = 0;
	int i, wf;

	if (argc < 2) {
		fprintf(stderr, "usage: ebc-replay replay FWDIR TRACE "
			"[key=val ...]\n");
		return 2;
	}
	fwdir = argv[0];
	trace_path = argv[1];
	policy_ship(&pol);

	for (i = 2; i < argc; i++) {
		if (kv_match(argv[i], "scale", &val))
			scale = atoi(val);
		else if (kv_match(argv[i], "flash-frac", &val))
			pol.flash_frac = atof(val);
		else if (kv_match(argv[i], "default-waveform", &val)) {
			wf = wf_parse(val);
			if (wf < 0)
				goto badwf;
			pol.default_wf = wf;
		} else if (kv_match(argv[i], "refresh-waveform", &val)) {
			wf = wf_parse(val);
			if (wf < 0)
				goto badwf;
			pol.refresh_wf = wf;
		} else if (kv_match(argv[i], "auto-refresh", &val))
			pol.auto_refresh = atoi(val) != 0;
		else if (kv_match(argv[i], "refresh-threshold", &val))
			pol.refresh_threshold = atoi(val);
		else if (kv_match(argv[i], "split-area-limit", &val))
			pol.split_area_limit = atoi(val);
		else if (kv_match(argv[i], "defio", &val))
			pol.defio_bands = !strcmp(val, "bands");
		else if (kv_match(argv[i], "defio-delay-ms", &val))
			pol.defio_delay_ms = atoi(val);
		else if (kv_match(argv[i], "temp-c", &val))
			pol.temp_c = atoi(val);
		else if (kv_match(argv[i], "verify-decisions", &val))
			verify = atoi(val);
		else if (kv_match(argv[i], "pgm-dir", &val))
			pgm_dir = val;
		else {
			fprintf(stderr, "ebc-replay: unknown replay arg %s\n",
				argv[i]);
			return 2;
		}
	}
	if (scale < 1 || scale > 16) {
		fprintf(stderr, "ebc-replay: scale must be 1..16\n");
		return 2;
	}

	if (trace_load(&tr, trace_path)) {
		fprintf(stderr, "ebc-replay: cannot read %s\n", trace_path);
		return 1;
	}
	if (!replay_run(fwdir, &tr, &pol, scale, verify, pgm_dir, &res))
		return 1;
	replay_report(&tr, &pol, scale, &res);
	free(tr.ev);
	return res.clean && !res.aborted ? 0 : 1;

badwf:
	fprintf(stderr, "ebc-replay: unknown waveform (use RESET A2 DU DU4 "
		"GC16 GCC16 GL16 GLR16 GLD16)\n");
	return 2;
}

int main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "selftest"))
		return cmd_selftest(argc >= 3 ? argv[2] : "");
	if (argc >= 2 && !strcmp(argv[1], "synth"))
		return cmd_synth(argc - 2, argv + 2);
	if (argc >= 2 && !strcmp(argv[1], "replay"))
		return cmd_replay(argc - 2, argv + 2);
	fprintf(stderr,
		"usage: ebc-replay selftest [FWDIR]\n"
		"       ebc-replay synth OUT [key=val ...]\n"
		"       ebc-replay replay FWDIR TRACE [key=val ...]\n");
	return 2;
}
