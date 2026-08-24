/* ebc-refresh-test: execute the verbatim rockchip_ebc refresh machine
 * against a behavioral device model (offline testing ladder, rung 7a —
 * see doc/ebc-harness-spike.md §3).
 *
 * Where rung 2 (ebc-logic-test) unit-tests the driver's pure functions,
 * this harness *runs* the hardware-facing half: the global/partial
 * refresh orchestration, per-frame register discipline (CONFIG_DONE →
 * DSP_START), LUT upload, WIN_MST0/1/2 DMA windowing, the IRQ/completion
 * contract, buffer switching and mid-refresh queue splicing — with the
 * fake EBC in shim/fake-ebc.h behind the regmap and the driver's own
 * rockchip_ebc_irq() completing its waits.  Built with ASan, so lifetime
 * bugs in these paths crash the test instead of a kernel.
 *
 * Two replicas of driver-side callers exist here, both documented and
 * deliberately minimal (the same policy as rung 2's caller transforms):
 *   - commit_damage() mirrors rockchip_ebc_plane_atomic_update's commit
 *     block (the blit half is rung 2 territory);
 *   - run_refresh_synth() mirrors rockchip_ebc_refresh minus the
 *     pm/temperature/waveform-selection preamble, for tests that use a
 *     synthetic LUT (drm_epd_lut_set_* need a parsed .wbf file).  The
 *     WBF-gated tests run the real rockchip_ebc_probe() and
 *     rockchip_ebc_refresh()/refresh-thread body instead.
 *
 * Usage:
 *   ebc-refresh-test [FWDIR [GC16_RSL]]     run the suite; FWDIR is a
 *       directory containing rockchip/ebc.wbf (enables the WBF-gated
 *       tests), GC16_RSL a `wbf-info --dump-lut GC16 25` export
 *       (enables the rastersim drive-sequence differential)
 */

#include "drm_epd_helper.c"	/* verbatim, provides the LUT loader */
#include "rockchip_ebc.c"	/* verbatim driver under test */
#include "fake-ebc.h"		/* the device model behind the regmap */

#include "../rastersim/rastersim.h"

#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

/* ---------------------------------------------------------------------- */
/* test plumbing (same conventions as ebc-logic-test.c)                    */

static int failures;

static_assert(sizeof(struct drm_rockchip_ebc_refresh_barrier) == 40);

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

/* All shim/device counters that must be zero after a healthy scenario. */
static bool harness_clean(const char *what)
{
	bool ok = ebc_shim.completion_timeouts == 0 &&
		  ebc_shim.regmap_oob == 0 &&
		  ebc_shim.regmap_volatile_cache_only_writes == 0 &&
		  ebc_shim.dma_violations == 0 &&
		  fake_ebc.frm_start_config_dirty == 0 &&
		  fake_ebc.frames_unpowered == 0 &&
		  fake_ebc.bad_frames == 0 &&
		  fake_ebc.event_overflow == 0;

	if (!ok)
		printf("FAIL: %s: harness violations (timeouts %lu oob %lu "
		       "volatile-cache %lu dma %lu config-dirty %u unpowered %u "
		       "bad %u overflow %u)\n", what,
		       ebc_shim.completion_timeouts, ebc_shim.regmap_oob,
		       ebc_shim.regmap_volatile_cache_only_writes,
		       ebc_shim.dma_violations, fake_ebc.frm_start_config_dirty,
		       fake_ebc.frames_unpowered, fake_ebc.bad_frames,
		       fake_ebc.event_overflow);
	return ok;
}

/* ---------------------------------------------------------------------- */
/* synthetic LUT (independent formula, not derived from driver code)       */

/* Drive code for the transition (phase, from, to): diagonal transitions
 * get a sparse darken pulse (so diff-mode masking is observable),
 * off-diagonal ones alternate darken/lighten.  The last real phase and
 * everything beyond (incl. 0xff) is neutral, mirroring the real-waveform
 * invariant the driver relies on (pinned by rung 2's wbf tests). */
static u8 synth_code(unsigned int phase, unsigned int from, unsigned int to)
{
	if (from == to)
		return (phase + to) % 3 == 1 ? 1 : 0;
	return 1 + ((phase + to + 2 * from) % 2);
}

/* 4BIT_PACKED per the pinned axis convention: word[phase*16 + from],
 * bit pair 2*to (see fake_ebc_lut_code and the rung 1/3 crosscheck). */
static void synth_lut(u8 *buf, unsigned int num_phases)
{
	u32 *words = (u32 *)(void *)buf;
	unsigned int p, fr, to;

	memset(buf, 0, EBC_NUM_LUT_REGS * 4);
	for (p = 0; p + 1 < num_phases; p++)
		for (fr = 0; fr < 16; fr++) {
			u32 w = 0;

			for (to = 0; to < 16; to++)
				w |= (u32)synth_code(p, fr, to) << (to * 2);
			words[p * 16 + fr] = w;
		}
}

static unsigned int synth_expected_drives(unsigned int num_phases, u8 from, u8 to)
{
	unsigned int c = 0, p;

	for (p = 0; p + 1 < num_phases; p++)
		if (synth_code(p, from, to))
			c++;
	return c;
}

/* ---------------------------------------------------------------------- */
/* harness setup                                                           */

struct harness {
	struct platform_device pdev;
	struct rockchip_ebc *ebc;
	struct ebc_crtc_state crtc_state;
	bool synth;
};

/* Set the CRTC mode and run the driver's real mode_set (the config
 * register writes).  Timings are arbitrary-but-consistent for the small
 * test screens; only the geometry registers feed the device model. */
static void harness_mode_set(struct harness *h, int w, int hgt)
{
	struct drm_display_mode *m = &h->crtc_state.base.adjusted_mode;

	memset(m, 0, sizeof(*m));
	m->clock = 1000;
	m->hdisplay = w;
	m->hsync_start = w + 8;
	m->hsync_end = w + 16;
	m->htotal = w + 24;
	m->hskew = 8;
	m->vdisplay = hgt;
	m->vsync_start = hgt + 1;
	m->vsync_end = hgt + 2;
	m->vtotal = hgt + 4;
	m->flags = DRM_MODE_FLAG_CLKDIV2;	/* 16-bit bus, like the panel */

	h->crtc_state.base.crtc = &h->ebc->crtc;
	h->ebc->crtc.state = &h->crtc_state.base;
	rockchip_ebc_crtc_mode_set_nofb(&h->ebc->crtc);
}

static void harness_enable_worker(struct harness *h)
{
	h->crtc_state.base.mode_changed = true;
	rockchip_ebc_crtc_atomic_enable(&h->ebc->crtc, NULL);
	h->crtc_state.base.mode_changed = false;
}

/* Probe-lite: the same acquisitions rockchip_ebc_probe makes, minus
 * rockchip_ebc_drm_init (which needs a parsed .wbf).  num_phases > 0
 * installs a synthetic LUT.  The device starts runtime-suspended with
 * the real runtime-PM callbacks wired into the shim, exactly like a
 * freshly probed device. */
static struct rockchip_ebc *harness_ebc(struct harness *h, int w, int hgt,
					unsigned int num_phases)
{
	struct rockchip_ebc *ebc;
	int i;

	memset(h, 0, sizeof(*h));
	ebc_shim_reset();
	fake_ebc_install();
	fake_ebc.record_seq = (size_t)w * hgt <= 65536;

	ebc = devm_drm_dev_alloc(&h->pdev.dev, &rockchip_ebc_drm_driver,
				 struct rockchip_ebc, drm);
	h->ebc = ebc;
	h->synth = num_phases > 0;

	ebc->do_one_full_refresh = true;
	spin_lock_init(&ebc->refresh_once_lock);
	mutex_init(&ebc->barrier_lock);
	init_waitqueue_head(&ebc->barrier_wait);
	platform_set_drvdata(&h->pdev, ebc);
	init_completion(&ebc->display_end);
	ebc->reset_complete = skip_reset;
	ebc->regmap = devm_regmap_init_mmio(&h->pdev.dev,
					    devm_platform_ioremap_resource(&h->pdev, 0),
					    &rockchip_ebc_regmap_config);
	regcache_cache_only(ebc->regmap, true);
	ebc->dclk = devm_clk_get(&h->pdev.dev, "dclk");
	ebc->hclk = devm_clk_get(&h->pdev.dev, "hclk");
	ebc->temperature_channel = devm_iio_channel_get(&h->pdev.dev, NULL);
	for (i = 0; i < EBC_NUM_SUPPLIES; i++)
		ebc->supplies[i].supply = rockchip_ebc_supplies[i];
	devm_regulator_bulk_get(&h->pdev.dev, EBC_NUM_SUPPLIES, ebc->supplies);
	devm_request_irq(&h->pdev.dev, 1, rockchip_ebc_irq, 0, "ebc-shim", ebc);

	ebc_shim.rt_resume = rockchip_ebc_runtime_resume;
	ebc_shim.rt_suspend = rockchip_ebc_runtime_suspend;
	ebc_shim.pm_suspended = true;

	if (num_phases) {
		ebc->lut.buf = malloc(EBC_NUM_LUT_REGS * 4);
		synth_lut(ebc->lut.buf, num_phases);
		ebc->lut.num_phases = num_phases;
	}

	harness_mode_set(h, w, hgt);
	return ebc;
}

static struct rockchip_ebc_ctx *harness_ctx(struct harness *h, int w, int hgt)
{
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(h->ebc, w, hgt);

	h->crtc_state.ctx = ctx;
	/* the refresh-thread invariants the direct-call tests rely on */
	memset(ctx->phase[0], 0xff, ctx->phase_size);
	memset(ctx->phase[1], 0xff, ctx->phase_size);
	return ctx;
}

static void harness_free(struct harness *h, struct rockchip_ebc_ctx *ctx)
{
	if (ctx)
		rockchip_ebc_ctx_free(ctx);
	if (h->synth)
		free(h->ebc->lut.buf);
	free(h->ebc);
	ebc_shim.regmap_hook = NULL;
	ebc_shim.schedule_hook = NULL;
	fake_ebc.on_frm_start = NULL;
}

/* Replica of rockchip_ebc_plane_atomic_update's commit block: the test
 * writes the new frame into ctx->final_atomic_update first (bypassing
 * the blitters, which rung 2 covers), then this queues the damage. */
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

/* Replica of rockchip_ebc_refresh minus its pm/temperature/LUT-selection
 * preamble (drm_epd_lut_set_* need a parsed .wbf; the WBF-gated tests
 * exercise the real function).  Register order matches the driver:
 * resume, LUT upload, DSP_START base, mode bits, window addresses,
 * dispatch, unmap, OUT_LOW. */
static int run_refresh_synth(struct rockchip_ebc *ebc,
			     struct rockchip_ebc_ctx *ctx, bool global)
{
	struct device *dev = ebc->drm.dev;
	u32 dsp_ctrl = 0, epd_ctrl = 0;
	dma_addr_t next_handle, prev_handle;
	int ret;

	/* The refresh thread reads and CLEARS do_one_full_refresh before it
	 * picks global vs partial, so no dispatch ever runs with the flag
	 * still latched.  These direct calls bypass the thread, and since
	 * issue #22 the partial loop's work-item drain gate reads that flag
	 * -- so model the thread's read-and-clear here, or a direct call
	 * would run from a state the real driver never reaches.  (The
	 * auto-refresh epilogue below may set it again, as the driver does.) */
	spin_lock(&ebc->refresh_once_lock);
	ebc->do_one_full_refresh = false;
	spin_unlock(&ebc->refresh_once_lock);

	pm_runtime_get(dev);
	pm_runtime_resume(dev);

	if (ebc->lut_changed) {
		ebc->lut_changed = false;
		regmap_bulk_write(ebc->regmap, EBC_LUT_DATA,
				  ebc->lut.buf, EBC_NUM_LUT_REGS);
	}

	regmap_write(ebc->regmap, EBC_DSP_START, ebc->dsp_start);

	if (global) {
		dsp_ctrl |= EBC_DSP_CTRL_DSP_LUT_MODE;
	} else if (!direct_mode) {
		epd_ctrl |= EBC_EPD_CTRL_DSP_THREE_WIN_MODE;
		if (diff_mode)
			dsp_ctrl |= EBC_DSP_CTRL_DSP_DIFF_MODE;
	}
	regmap_update_bits(ebc->regmap, EBC_EPD_CTRL,
			   EBC_EPD_CTRL_DSP_THREE_WIN_MODE, epd_ctrl);
	regmap_update_bits(ebc->regmap, EBC_DSP_CTRL,
			   EBC_DSP_CTRL_DSP_DIFF_MODE |
			   EBC_DSP_CTRL_DSP_LUT_MODE, dsp_ctrl);

	next_handle = dma_map_single(dev, ctx->next, ctx->gray4_size, DMA_TO_DEVICE);
	prev_handle = dma_map_single(dev, ctx->prev, ctx->gray4_size, DMA_TO_DEVICE);
	regmap_write(ebc->regmap, EBC_WIN_MST1, next_handle);
	regmap_write(ebc->regmap, EBC_WIN_MST0, prev_handle);

	if (global)
		ret = rockchip_ebc_global_refresh(ebc, ctx, next_handle, prev_handle);
	else
		ret = rockchip_ebc_partial_refresh(ebc, ctx, next_handle, prev_handle);
	if (ret)
		return ret; /* hardware may still own every active DMA mapping */

	dma_unmap_single(dev, next_handle, ctx->gray4_size, DMA_TO_DEVICE);
	dma_unmap_single(dev, prev_handle, ctx->gray4_size, DMA_TO_DEVICE);

	regmap_write(ebc->regmap, EBC_DSP_START,
		     ebc->dsp_start | EBC_DSP_START_DSP_OUT_LOW);

	/* the auto-refresh threshold epilogue, verbatim from
	 * rockchip_ebc_refresh (including its local one_screen_area
	 * constant).  auto_refresh defaults to false, so tests that do
	 * not opt in are unaffected. */
	{
		int one_screen_area = 1314144;

		if (auto_refresh) {
			if (ctx->area_count >= refresh_threshold * one_screen_area) {
				spin_lock(&ebc->refresh_once_lock);
				ebc->do_one_full_refresh = true;
				spin_unlock(&ebc->refresh_once_lock);
				ctx->area_count = 0;
			}
		} else {
			ctx->area_count = 0;
		}
	}

	pm_runtime_mark_last_busy(dev);
	pm_runtime_put_autosuspend(dev);
	return 0;
}

/* ---------------------------------------------------------------------- */
/* PGM output (goldens; hashed by run-tests.sh)                            */

static void write_pgm(const char *path, const u8 *gray, unsigned int w,
		      unsigned int hgt)
{
	FILE *f = fopen(path, "wb");

	if (!f) {
		printf("FAIL: cannot write %s\n", path);
		failures++;
		return;
	}
	fprintf(f, "P5\n%u %u\n255\n", w, hgt);
	fwrite(gray, 1, (size_t)w * hgt, f);
	fclose(f);
}

/* ---------------------------------------------------------------------- */
/* the shim's non-coherent DMA model itself                                */

/* Every device-side read in the harness goes through a mapping's shadow,
 * which only dma_map_single (whole buffer) and dma_sync_single_for_device
 * (the synced range) update.  This self-test pins that contract — it is
 * what makes an under-synced driver change a test failure instead of a
 * silent pass, and it must hold before any shrunken-sync cherry-pick can
 * be trusted. */
static void test_dma_shadow_model(void)
{
	u8 buf[256];
	dma_addr_t handle;
	const u8 *dev_view;
	unsigned long violations;

	ebc_shim_reset();
	memset(buf, 0xAA, sizeof(buf));
	handle = dma_map_single(NULL, buf, sizeof(buf), DMA_TO_DEVICE);
	dev_view = ebc_shim_dma_resolve((u32)handle, sizeof(buf));

	check(dev_view && !memcmp(dev_view, buf, sizeof(buf)),
	      "dma shadow: mapping publishes the buffer (map-time cache clean)");

	memset(buf, 0x55, sizeof(buf));
	check(dev_view[0] == 0xAA && dev_view[255] == 0xAA,
	      "dma shadow: unsynced CPU writes stay invisible to the device");

	dma_sync_single_for_device(NULL, handle + 64, 32, DMA_TO_DEVICE);
	check(dev_view[63] == 0xAA && dev_view[64] == 0x55 &&
	      dev_view[95] == 0x55 && dev_view[96] == 0xAA,
	      "dma shadow: for_device publishes exactly the synced range");

	dma_sync_single_for_cpu(NULL, handle + 64, 32, DMA_TO_DEVICE);
	check(ebc_shim.dma_violations == 0,
	      "dma shadow: in-range offset syncs are not violations");

	violations = ebc_shim.dma_violations;
	dma_sync_single_for_device(NULL, handle + 240, 32, DMA_TO_DEVICE);
	check(ebc_shim.dma_violations == violations + 1,
	      "dma shadow: a sync crossing the mapping end is a violation");

	dma_unmap_single(NULL, handle, sizeof(buf), DMA_TO_DEVICE);
	ebc_shim_reset();	/* clear the deliberate violation */
}

/* ---------------------------------------------------------------------- */
/* mode_set: config-register golden for the real panel mode                */

static void test_mode_set_golden(void)
{
	/* The ED103TC2 1 Hz mode as carried in the forward-port patch's
	 * panel-simple entry.  Expected register values are hand-derived
	 * from the driver's documented timing translation (SDCK = pixel
	 * clock / 8 on the 16-bit bus; hardware order sync/bp/act/fp),
	 * not copied from the code. */
	struct harness h;
	struct drm_display_mode *m;
	static const struct { unsigned int reg; u32 want; const char *name; } golden[] = {
		{ EBC_EPD_CTRL,     (268u << 16) | (26u << 8) | BIT(6), "EPD_CTRL" },
		{ EBC_DSP_CTRL,     (2u << 30) | (7u << 16),		"DSP_CTRL" },
		{ EBC_DSP_HTIMING0, (276u << 16) | 18u,			"DSP_HTIMING0" },
		{ EBC_DSP_HTIMING1, (269u << 16) | 34u,			"DSP_HTIMING1" },
		{ EBC_DSP_VTIMING0, (1421u << 16) | 1u,			"DSP_VTIMING0" },
		{ EBC_DSP_VTIMING1, (1409u << 16) | 5u,			"DSP_VTIMING1" },
		{ EBC_DSP_ACT_INFO, (1404u << 16) | 1872u,		"DSP_ACT_INFO" },
		{ EBC_WIN_CTRL,     (496u << 19) | BIT(18) | (7u << 10) |
				    (240u << 2),			"WIN_CTRL" },
		{ EBC_WIN_VIR,      (1404u << 16) | 1872u,		"WIN_VIR" },
		{ EBC_WIN_ACT,      (1404u << 16) | 1872u,		"WIN_ACT" },
		{ EBC_WIN_DSP,      (1404u << 16) | 1872u,		"WIN_DSP" },
		{ EBC_WIN_DSP_ST,   (5u << 16) | 35u,			"WIN_DSP_ST" },
	};
	unsigned int i;
	bool ok = true;

	harness_ebc(&h, 64, 32, 4);
	/* replace the small default mode with the real panel mode */
	m = &h.crtc_state.base.adjusted_mode;
	memset(m, 0, sizeof(*m));
	m->clock = 3137;
	m->hdisplay = 1872;
	m->hsync_start = 1872 + 56;
	m->hsync_end = 1872 + 56 + 144;
	m->htotal = 1872 + 56 + 144 + 136;
	m->hskew = 64;
	m->vdisplay = 1404;
	m->vsync_start = 1404 + 12;
	m->vsync_end = 1404 + 12 + 1;
	m->vtotal = 1404 + 12 + 1 + 4;
	m->flags = DRM_MODE_FLAG_CLKDIV2;
	rockchip_ebc_crtc_mode_set_nofb(&h.ebc->crtc);

	for (i = 0; i < ARRAY_SIZE(golden); i++) {
		u32 got = ebc_shim.regs[golden[i].reg / 4];

		if (got != golden[i].want) {
			printf("FAIL: mode_set %s = 0x%08x, want 0x%08x\n",
			       golden[i].name, got, golden[i].want);
			failures++;
			ok = false;
		}
	}
	check(ok, "mode_set writes the hand-derived ED103TC2 timing registers (12 regs)");
	check(h.ebc->dsp_start == ((234u << 16) | BIT(12)),
	      "mode_set computes dsp_start = SDCE_WIDTH(234) | SW_BURST_CTRL");
	check(ebc_shim.regmap_volatile_cache_only_writes == 0,
	      "mode_set touches no volatile register while runtime-suspended");
	check(fake_ebc.config_dirty,
	      "mode_set leaves config pending until the refresh's CONFIG_DONE");
	harness_free(&h, NULL);
}

/* ---------------------------------------------------------------------- */
/* global refresh                                                          */

#define GW 64
#define GH 32
#define NPH 6u

static void test_global_refresh(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rect rects[2] = { {2, 2, 20, 12}, {30, 8, 60, 30} };
	const struct fake_ebc_event *ev = &fake_ebc.ev[0];
	bool ok;
	int x, y;

	memset(ctx->prev, 0x33, ctx->gray4_size);
	memset(ctx->next, 0x33, ctx->gray4_size);
	memset(ctx->final_atomic_update, 0xC5, ctx->gray4_size);
	commit_damage(ctx, rects, 2);

	run_refresh_synth(ebc, ctx, true);

	check(fake_ebc.nev == 1 && ev->lut_mode && !ev->three_win,
	      "global refresh: one DSP_FRM_START in LUT mode");
	check(fake_ebc.nev == 1 && ev->planes == NPH &&
	      ((ev->dsp_start >> 2) & 0x3ff) == NPH - 1,
	      "global refresh: DSP_FRM_TOTAL = num_phases-1 (%u frames)", NPH);
	check(fake_ebc.nev == 1 && ev->prev_cpu == ctx->prev && ev->next_cpu == ctx->next,
	      "global refresh: WIN_MST0/1 resolve to ctx->prev/ctx->next through the DMA registry");
	check(fake_ebc.dsp_end_irqs == 1 && ebc->display_end.done == 0,
	      "global refresh: one DSP_END irq, completion consumed by the wait");
	check(fake_ebc.lut_uploads == 1,
	      "global refresh: LUT uploaded once (lut_changed set by runtime resume)");
	check(!memcmp(ctx->next, ctx->final, ctx->gray4_size) &&
	      !memcmp(ctx->prev, ctx->next, ctx->gray4_size),
	      "global refresh: next <- final before the frame, prev <- next after");
	check(list_empty(&ctx->queue), "global refresh: queued damage drained and freed");
	check(fake_ebc.out_low_writes == 1,
	      "refresh epilogue drives the output pins low (DSP_OUT_LOW)");
	check((ebc_shim.regs[EBC_INT_STATUS / 4] & 0xf) == 0,
	      "irq handler leaves all INT_STATUS status bits cleared");
	check(!ebc_shim.pm_suspended && ebc_shim.pm_refcount == 0,
	      "pm: device resumed for the refresh, refcount balanced after");

	/* every pixel's drive count matches the independent LUT formula */
	ok = true;
	for (y = 0; y < GH && ok; y++)
		for (x = 0; x < GW && ok; x++) {
			u8 to = get_px(ctx->next, ctx->gray4_pitch, x, y);
			unsigned int want = synth_expected_drives(NPH, 3, to);
			u32 got = fake_ebc.drive_count[(size_t)y * GW + x];

			if (got != want) {
				printf("FAIL: global drive count (%d,%d): %u want %u\n",
				       x, y, got, want);
				failures++;
				ok = false;
			}
		}
	check(ok, "global refresh: per-pixel drive counts match the synthetic LUT (%ux%u)",
	      GW, GH);
	check(harness_clean("global"), "global refresh: no harness violations");
	harness_free(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* partial refresh                                                         */

static void test_partial_refresh_single_area(const char *outdir)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rect rect = {8, 4, 24, 12};
	bool saved_diff = diff_mode;
	bool ok;
	unsigned int f;
	int x, y;

	diff_mode = false;
	memset(ctx->prev, 0x55, ctx->gray4_size);
	memset(ctx->next, 0x55, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, ctx->prev, ctx->gray4_size);
	for (y = rect.y1; y < rect.y2; y++)
		for (x = rect.x1; x < rect.x2; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y,
			       (u8)((x + y) & 0xf));
	commit_damage(ctx, &rect, 1);

	run_refresh_synth(ebc, ctx, false);

	check(fake_ebc.hw_frames == NPH && fake_ebc.nev == NPH,
	      "partial refresh: one area runs num_phases (%u) three-window frames", NPH);
	ok = true;
	for (f = 0; f < fake_ebc.nev; f++) {
		const struct fake_ebc_event *ev = &fake_ebc.ev[f];

		ok &= ev->three_win && !ev->lut_mode && !ev->diff;
		ok &= ev->phase_cpu == ctx->phase[0];
		ok &= ev->prev_cpu == ctx->prev && ev->next_cpu == ctx->next;
	}
	check(ok, "partial refresh: every frame in three-window mode, windows resolve to ctx buffers");
	check(fake_ebc.config_done_writes == NPH,
	      "partial refresh: CONFIG_DONE written before every frame start");

	/* full per-pixel drive sequence vs the independent formula:
	 * frames 0..n-2 play the real phases, frame n-1 substitutes the
	 * neutral 0xff (the driver's last-phase trick) */
	ok = true;
	for (y = 0; y < GH && ok; y++)
		for (x = 0; x < GW && ok; x++) {
			size_t idx = (size_t)y * GW + x;
			bool inside = x >= rect.x1 && x < rect.x2 &&
				      y >= rect.y1 && y < rect.y2;
			u8 to = get_px(ctx->next, ctx->gray4_pitch, x, y);

			for (f = 0; f < NPH && ok; f++) {
				u8 want = 0;
				u8 got = fake_ebc.seq[(size_t)f * GW * GH + idx];

				if (inside && f + 1 < NPH)
					want = synth_code(f, 5, to);
				if (got != want) {
					printf("FAIL: partial seq (%d,%d) frame %u: %u want %u\n",
					       x, y, f, got, want);
					failures++;
					ok = false;
				}
			}
		}
	check(ok, "partial refresh: per-pixel drive sequences match (inside real phases + neutral tail, outside silent)");

	check(!memcmp(ctx->prev, ctx->next, ctx->gray4_size),
	      "partial refresh: prev caught up with next after the last phase");
	check(fake_ebc.conflicts == 0 && list_empty(&ctx->queue),
	      "partial refresh: no phase conflicts, queue drained");
	check(harness_clean("partial"), "partial refresh: no harness violations");

	/* golden images: drive-count map + final screen */
	if (outdir) {
		char path[512];
		u8 *img = malloc((size_t)GW * GH);
		size_t i;

		for (i = 0; i < (size_t)GW * GH; i++) {
			u32 c = fake_ebc.drive_count[i] * 40;

			img[i] = c > 255 ? 255 : (u8)c;
		}
		snprintf(path, sizeof(path), "%s/refresh-drive-count.pgm", outdir);
		write_pgm(path, img, GW, GH);
		rs_y4_to_gray8(img, GW, ctx->next, ctx->gray4_pitch, GW, GH);
		snprintf(path, sizeof(path), "%s/refresh-final.pgm", outdir);
		write_pgm(path, img, GW, GH);
		free(img);
	}

	diff_mode = saved_diff;
	harness_free(&h, ctx);
}

static void test_partial_diff_mode(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rect rect = {0, 0, 32, 16};
	bool saved_diff = diff_mode;
	bool ok_same = true, ok_changed = true;
	int x, y;

	diff_mode = true;
	memset(ctx->prev, 0x55, ctx->gray4_size);
	memset(ctx->next, 0x55, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, ctx->prev, ctx->gray4_size);
	/* left half of the rect stays 5 (unchanged), right half becomes 9 */
	for (y = rect.y1; y < rect.y2; y++)
		for (x = 16; x < rect.x2; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y, 9);
	commit_damage(ctx, &rect, 1);

	run_refresh_synth(ebc, ctx, false);

	check(fake_ebc.nev == NPH && fake_ebc.ev[0].diff,
	      "diff_mode=1: the driver sets DSP_DIFF_MODE for the partial refresh");
	/* the synthetic LUT drives 5->5 on some phases; diff must mask it */
	check(synth_expected_drives(NPH, 5, 5) > 0,
	      "diff_mode: synthetic LUT drives the 5->5 diagonal (mask has something to do)");
	for (y = rect.y1; y < rect.y2; y++)
		for (x = rect.x1; x < rect.x2; x++) {
			u32 c = fake_ebc.drive_count[(size_t)y * GW + x];

			if (x < 16)
				ok_same &= c == 0;
			else
				ok_changed &= c == synth_expected_drives(NPH, 5, 9);
		}
	check(ok_same, "diff_mode: unchanged pixels inside the damage get zero drives");
	check(ok_changed, "diff_mode: changed pixels drive their full sequence");
	check(harness_clean("diff"), "diff_mode: no harness violations");

	diff_mode = saved_diff;
	harness_free(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* mid-refresh commit: queue splice + final-buffer switch                  */

static struct rockchip_ebc_ctx *inject_ctx;
static int inject_done;

static void inject_second_commit(u32 hw_frame)
{
	struct drm_rect rect = {8, 8, 32, 24};
	int x, y;

	if (inject_done || hw_frame != 2)
		return;
	inject_done = 1;
	for (y = rect.y1; y < rect.y2; y++)
		for (x = rect.x1; x < rect.x2; x++)
			set_px(inject_ctx->final_atomic_update,
			       inject_ctx->gray4_pitch, x, y, 0x2);
	commit_damage(inject_ctx, &rect, 1);
}

static void test_midrefresh_commit(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rect rect_a = {0, 0, 16, 16};
	bool saved_diff = diff_mode;
	int saved_split = split_area_limit;
	bool ok;
	int x, y;

	diff_mode = false;
	split_area_limit = 12;
	memset(ctx->prev, 0x55, ctx->gray4_size);
	memset(ctx->next, 0x55, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, ctx->prev, ctx->gray4_size);
	for (y = rect_a.y1; y < rect_a.y2; y++)
		for (x = rect_a.x1; x < rect_a.x2; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y, 0xC);
	commit_damage(ctx, &rect_a, 1);

	inject_ctx = ctx;
	inject_done = 0;
	fake_ebc.on_frm_start = inject_second_commit;

	run_refresh_synth(ebc, ctx, false);
	fake_ebc.on_frm_start = NULL;

	/* B committed during frame 2 splices after that frame's start and
	 * schedules on frame 3; its piece overlapping in-flight A defers
	 * to A's window end.  End-exclusive since the 59b2113e8b9c
	 * translation (2026-07-12): the deferred piece starts on frame
	 * num_phases (was num_phases+1), so the whole run is
	 * num_phases + num_phases frames.  The conflicts==0 check below
	 * staying green is the empirical proof that the one-frame-earlier
	 * handoff is phase-clean. */
	check(fake_ebc.hw_frames == 2 * NPH,
	      "mid-refresh commit: overlap defers to the in-flight window end (%u frames total)",
	      2 * NPH);
	check(fake_ebc.conflicts == 0,
	      "mid-refresh commit: no per-pixel phase conflicts");

	/* the injected commit's content reached the refresh via the
	 * final-buffer switch: B pixels ended at gray 2, A-only pixels
	 * at gray 0xC */
	ok = true;
	for (y = 0; y < GH; y++)
		for (x = 0; x < GW; x++) {
			bool in_a = x < 16 && y < 16;
			bool in_b = x >= 8 && x < 32 && y >= 8 && y < 24;
			u8 want = in_b ? 2 : in_a ? 0xC : 5;

			ok &= get_px(ctx->next, ctx->gray4_pitch, x, y) == want;
		}
	check(ok, "mid-refresh commit: buffer switch delivered the new frame to the later area");
	check(!memcmp(ctx->prev, ctx->next, ctx->gray4_size) && list_empty(&ctx->queue),
	      "mid-refresh commit: both areas completed, queue empty");

	/* first drive of the B-only region must be at frame >= 3 (the
	 * splice happened during frame 2), of the B/A overlap at the
	 * deferred window (frame num_phases) */
	ok = true;
	for (y = 8; y < 24 && ok; y++)
		for (x = 8; x < 32 && ok; x++) {
			size_t idx = (size_t)y * GW + x;
			bool in_a = x < 16 && y < 16;
			u32 first = 0;
			unsigned int f;

			for (f = 0; f < fake_ebc.hw_frames; f++)
				if (fake_ebc.seq[(size_t)f * GW * GH + idx]) {
					first = f;
					break;
				}
			if (in_a)
				continue; /* first drive belongs to A */
			if (first < 3) {
				printf("FAIL: B pixel (%d,%d) first drive at frame %u\n",
				       x, y, first);
				failures++;
				ok = false;
			}
		}
	check(ok, "mid-refresh commit: injected area only starts after its splice frame");
	check(harness_clean("mid-refresh"), "mid-refresh commit: no harness violations");

	diff_mode = saved_diff;
	split_area_limit = saved_split;
	harness_free(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* ex-QUIRK E at the device: chained begin-together (fixed 59b2113e8b9c)   */

static int quirk_step;

static void quirk_inject(u32 hw_frame)
{
	struct drm_rect s2 = {20, 0, 24, 4};
	struct drm_rect bca[3] = {
		{0, 2, 4, 8},	/* b: overlaps in-flight s1 */
		{20, 2, 24, 8},	/* c: overlaps in-flight s2 */
		{0, 6, 24, 8},	/* a: overlaps b and c only */
	};
	int x, y;

	if (hw_frame == 1 && quirk_step == 0) {
		quirk_step = 1;
		for (y = s2.y1; y < s2.y2; y++)
			for (x = s2.x1; x < s2.x2; x++)
				set_px(inject_ctx->final_atomic_update,
				       inject_ctx->gray4_pitch, x, y, 0x8);
		commit_damage(inject_ctx, &s2, 1);
	} else if (hw_frame == 4 && quirk_step == 1) {
		quirk_step = 2;
		for (y = 0; y < 8; y++)
			for (x = 0; x < 24; x++)
				set_px(inject_ctx->final_atomic_update,
				       inject_ctx->gray4_pitch, x, y, 0x1);
		commit_damage(inject_ctx, bca, 3);
	}
}

static void test_quirk_begin_together_conflict(void)
{
	/* Regression guard for ex-QUIRK E (finding 2), device-visible
	 * form.  Rung 2 used to pin the scheduler bug (an area chained
	 * through two begin-togethers landed inside an overlapping area's
	 * refresh window), and this test used to assert its consequence
	 * at the panel: fake_ebc.conflicts > 0 (overlap pixels' phase
	 * indices regressing mid-sequence — conflicting waveform data on
	 * hardware).  Fixed 2026-07-12 via the 59b2113e8b9c translation:
	 * with the shipped split_area_limit=0 the same staggered-commit
	 * scenario must now produce ZERO per-pixel phase conflicts. */
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rect s1 = {0, 0, 4, 4};
	bool saved_diff = diff_mode;
	int saved_split = split_area_limit;
	int x, y;

	diff_mode = false;
	split_area_limit = 0;	/* what pinenote/services/ebc.scm ships */
	memset(ctx->prev, 0x55, ctx->gray4_size);
	memset(ctx->next, 0x55, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, ctx->prev, ctx->gray4_size);
	for (y = s1.y1; y < s1.y2; y++)
		for (x = s1.x1; x < s1.x2; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y, 0xF);
	commit_damage(ctx, &s1, 1);

	inject_ctx = ctx;
	quirk_step = 0;
	fake_ebc.on_frm_start = quirk_inject;

	run_refresh_synth(ebc, ctx, false);
	fake_ebc.on_frm_start = NULL;

	check(quirk_step == 2, "quirk scenario: both staggered commits injected");
	check(fake_ebc.conflicts == 0,
	      "fix: chained begin-together no longer feeds the panel conflicting phase data (%u conflicts; was QUIRK E, hrdl 59b2113e8b9c)",
	      fake_ebc.conflicts);
	check(ebc_shim.completion_timeouts == 0 && list_empty(&ctx->queue),
	      "quirk scenario: the refresh still completes and drains");

	diff_mode = saved_diff;
	split_area_limit = saved_split;
	harness_free(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* QUIRK F: the threshold-fired auto-global launches zero-gap and lets a  */
/* straggling DSP_END satisfy its wait (doc/driver-findings-report.md,    */
/* 2026-07-12 finding: threshold-path globals corrupt, ioctl-path globals */
/* are clean)                                                             */

/* Mirrors the thread loop's flag consumption (rockchip_ebc_refresh_thread,
 * the read/clear under refresh_once_lock). */
/* Historical QUIRK F explanation is retained below in its fix guard and docs. */
static void discard_test_queue(struct rockchip_ebc_ctx *ctx);

/* The old reproducer's decisive perturbation is retained as a fix guard:
 * delay the final partial END.  The former code continued through the
 * threshold epilogue and could launch a global into that late END. */
static void arm_quirk_f_timeout(u32 hw_frame)
{
	if (hw_frame == NPH - 1)
		fake_ebc.defer_dsp_end = 1;
}

static void test_quirk_threshold_zero_gap_global(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rect rect = {8, 8, 24, 16};
	struct drm_rockchip_ebc_trigger_global_refresh legacy = {
		.trigger_global_refresh = true,
	};
	bool saved_auto = auto_refresh;
	int saved_threshold = refresh_threshold;
	bool saved_diff = diff_mode;
	u32 starts;
	int x, y, ret;

	diff_mode = false;
	auto_refresh = true;
	refresh_threshold = 1;
	ebc->do_one_full_refresh = false;
	memset(ctx->prev, 0x55, ctx->gray4_size);
	memset(ctx->next, 0x55, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, ctx->prev, ctx->gray4_size);
	for (y = rect.y1; y < rect.y2; y++)
		for (x = rect.x1; x < rect.x2; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y, 0x0);
	commit_damage(ctx, &rect, 1);
	fake_ebc.on_frm_start = arm_quirk_f_timeout;
	run_refresh_synth(ebc, ctx, false);
	fake_ebc.on_frm_start = NULL;

	check(ebc->barrier_poison == -ETIMEDOUT &&
	      ebc_shim.completion_timeouts == 1 && fake_ebc.pending_dsp_end == 1,
	      "fix QUIRK F: deferred final partial END immediately creates terminal poison");
	check(!ebc->do_one_full_refresh,
	      "fix QUIRK F: a failed partial cannot arm the threshold follow-up");
	starts = fake_ebc.nev;
	ret = ioctl_trigger_global_refresh(&ebc->drm, &legacy, NULL);
	check(ret == -ETIMEDOUT && !ebc->do_one_full_refresh,
	      "fix QUIRK F: an explicit post-poison global request is rejected before queueing");
	ret = rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	check(ret == -ETIMEDOUT && fake_ebc.nev == starts,
	      "fix QUIRK F: threshold/global follow-up cannot start after timeout");
	fake_ebc_deliver_dsp_end();
	ret = rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	check(ret == -ETIMEDOUT && fake_ebc.nev == starts &&
	      ebc->barrier_poison == -ETIMEDOUT &&
	      memcmp(ctx->prev, ctx->next, ctx->gray4_size),
	      "fix QUIRK F: late END cannot heal poison or claim clean recovery");

	discard_test_queue(ctx);
	auto_refresh = saved_auto;
	refresh_threshold = saved_threshold;
	diff_mode = saved_diff;
	harness_free(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* queued-area teardown regression                                           */

static void test_ctx_free_queued_area(void)
{
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(NULL, 64, 16);
	struct rockchip_ebc_area *a = kmalloc(sizeof(*a), GFP_KERNEL);

	a->clip = (struct drm_rect){0, 0, 8, 8};
	a->frame_begin = EBC_FRAME_PENDING;
	list_add_tail(&a->list, &ctx->queue);

	rockchip_ebc_ctx_free(ctx);
	check(true, "ctx_free: queued areas are unlinked before free (ASan regression)");
}

/* ---------------------------------------------------------------------- */
/* WBF-gated: real probe, real refresh, thread body, LUT differential      */

static void wbf_teardown(struct harness *h, struct rockchip_ebc_ctx *ctx)
{
	struct rockchip_ebc *ebc = h->ebc;

	if (ctx)
		rockchip_ebc_ctx_free(ctx);
	/* run the drmm-managed frees by hand (the shim's drmm is inert) */
	drm_epd_lut_free(&ebc->drm, &ebc->lut);
	drm_epd_lut_file_free(&ebc->drm, &ebc->lut_file);
	free(ebc);
	ebc_shim.regmap_hook = NULL;
	ebc_shim.schedule_hook = NULL;
	fake_ebc.on_frm_start = NULL;
}

static struct rockchip_ebc *wbf_probe(struct harness *h)
{
	int ret;

	memset(h, 0, sizeof(*h));
	ebc_shim_reset();
	fake_ebc_install();

	ret = rockchip_ebc_probe(&h->pdev);
	if (ret) {
		printf("FAIL: rockchip_ebc_probe: %d\n", ret);
		failures++;
		return NULL;
	}
	h->ebc = platform_get_drvdata(&h->pdev);

	/* what the PM core does on the real device: callbacks installed,
	 * device initially runtime-suspended */
	ebc_shim.rt_resume = rockchip_ebc_runtime_resume;
	ebc_shim.rt_suspend = rockchip_ebc_runtime_suspend;
	ebc_shim.pm_suspended = true;
	return h->ebc;
}

static void test_wbf_probe(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);

	if (!ebc)
		return;
	check(ebc_shim.thread_fn == rockchip_ebc_refresh_thread &&
	      ebc_shim.thread_data == ebc,
	      "wbf probe: refresh thread created with the ebc as its argument");
	check(ebc_shim.thread_parked, "wbf probe: refresh thread starts parked");
	check(ebc_shim.irq_handler == rockchip_ebc_irq && ebc_shim.irq_dev_id == ebc,
	      "wbf probe: rockchip_ebc_irq registered with the ebc cookie");
	check(ebc_shim.volatile_reg == rockchip_ebc_volatile_reg,
	      "wbf probe: regmap wired with the driver's volatile set");
	check(ebc->lut.buf != NULL && ebc->lut.num_phases > 0,
	      "wbf probe: LUT file parsed, initial RESET waveform decoded (%u phases)",
	      ebc->lut.num_phases);
	check((u8)ebc->off_screen[0] == 0xff,
	      "wbf probe: no default off-screen firmware -> all-white off screen");
	check(ebc_shim.cache_only, "wbf probe: regmap left cache-only (device suspended)");
	wbf_teardown(&h, NULL);
}

static void test_wbf_real_refresh(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	struct drm_rect rect = {0, 0, GW, GH};
	u32 n, uploads_after_first;
	int x, y;

	if (!ebc)
		return;
	fake_ebc.record_seq = true;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);

	memset(ctx->prev, 0xff, ctx->gray4_size);
	memset(ctx->next, 0xff, ctx->gray4_size);
	memset(ctx->final_atomic_update, 0xff, ctx->gray4_size);
	for (y = 4; y < 28; y++)
		for (x = 8; x < 56; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y,
			       (u8)(x & 0xf));
	commit_damage(ctx, &rect, 1);

	rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	n = ebc->lut.num_phases;

	check(n > 0 && n <= EBC_MAX_PHASES,
	      "wbf refresh: GC16@25C selected from the device waveform (%u phases)", n);
	check(fake_ebc.lut_uploads == 1,
	      "wbf refresh: LUT uploaded on the first refresh (lut_changed path)");
	check(fake_ebc.nev == 1 && fake_ebc.ev[0].lut_mode &&
	      fake_ebc.ev[0].planes == n,
	      "wbf refresh: global refresh plays exactly num_phases hardware frames");
	check(!memcmp(ctx->prev, ctx->next, ctx->gray4_size),
	      "wbf refresh: prev == next after the global refresh");
	uploads_after_first = fake_ebc.lut_uploads;

	/* same waveform + same temperature -> no re-upload */
	commit_damage(ctx, &rect, 1);
	rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	check(fake_ebc.lut_uploads == uploads_after_first,
	      "wbf refresh: unchanged waveform/temperature skips the LUT upload");
	check(!ebc_shim.pm_suspended && ebc_shim.pm_refcount == 0,
	      "wbf refresh: runtime resume ran, refcounts balanced");
	check(harness_clean("wbf-refresh"), "wbf refresh: no harness violations");
	wbf_teardown(&h, ctx);
}

/* Cold-panel LUT selection and orchestration.  hrdl's v6.19 tree clamps
 * the temperature to >= 19 C (5d6e5b43360, "emergency fix") because
 * *their* early-cancellation feature breaks on long DU sequences; our
 * m-weigand-lineage copy has no early cancellation, so we deliberately do
 * NOT carry the clamp — the waveform's cold bins are per-device
 * calibration and dropping them costs image quality.  This test backs
 * that decision: the coldest bin must select and orchestrate cleanly.
 * (Optics stay hardware-only, as ever.) */
static void test_wbf_cold_temperature(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	struct drm_rect rect = {0, 0, GW, GH};
	u32 n;

	if (!ebc)
		return;
	ebc_shim.iio_temp_override = true;
	ebc_shim.iio_temp_mC = 0;	/* 0 C */
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);

	memset(ctx->prev, 0xff, ctx->gray4_size);
	memset(ctx->next, 0xff, ctx->gray4_size);
	memset(ctx->final_atomic_update, 0x00, ctx->gray4_size);
	commit_damage(ctx, &rect, 1);

	rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	n = ebc->lut.num_phases;

	/* this device's waveform: GC16 is 131 phases in the 0 C bin
	 * (vs 38 at 25 C) — the doc/status.md rung-1 numbers */
	check(n == 131, "wbf cold: GC16@0C selects the 131-phase cold bin (got %u)", n);
	check(fake_ebc.nev == 1 && fake_ebc.ev[0].lut_mode &&
	      fake_ebc.ev[0].planes == n,
	      "wbf cold: global refresh plays all %u cold-bin frames", n);
	check(fake_ebc.dsp_end_irqs == 1 && ebc_shim.completion_timeouts == 0,
	      "wbf cold: hardware wait completed");
	check(harness_clean("wbf-cold"), "wbf cold: no harness violations");
	wbf_teardown(&h, ctx);
}

/* thread-body scripting */
static struct rockchip_ebc_ctx *thread_ctx;
static int thread_step;
static u8 *thread_caller_snapshot;

/* Make the shutdown snapshots distinguishable at the byte and nibble level:
 * a plain 0xff off-screen buffer would not catch an accidental source swap. */
static void fill_y4_pattern(u8 *buf, u32 pitch, int w, int h, unsigned int salt)
{
	int x, y;

	memset(buf, 0, (size_t)pitch * h);
	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
			set_px(buf, pitch, x, y, (u8)((3 * x + 5 * y + salt) & 0xf));
}

static void prepare_thread_caller(struct rockchip_ebc_ctx *ctx, u8 *caller)
{
	struct drm_rect rect = {8, 8, 24, 24};
	int x, y;

	fill_y4_pattern(caller, ctx->gray4_pitch, GW, GH, 1);
	/* The scheduled partial's pixels are part of the caller image too, so
	 * the expected suspend_next snapshot includes both caller paths. */
	for (y = rect.y1; y < rect.y2; y++)
		for (x = rect.x1; x < rect.x2; x++)
			set_px(caller, ctx->gray4_pitch, x, y, 0x3);
	memcpy(ctx->prev, caller, ctx->gray4_size);
	memcpy(ctx->next, caller, ctx->gray4_size);
	memcpy(ctx->final, caller, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, caller, ctx->gray4_size);
}

static unsigned int thread_global_events(void)
{
	unsigned int i, globals = 0;

	for (i = 0; i < fake_ebc.nev; i++)
		globals += fake_ebc.ev[i].lut_mode;
	return globals;
}

static void check_thread_completion_accounting(const char *what,
					       unsigned int globals,
					       unsigned int stale_cleared)
{
	check(ebc_shim.completion_timeouts == 0 &&
	      ebc_shim.completion_waits == ebc_shim.completion_successful_waits &&
	      ebc_shim.completion_calls == ebc_shim.completion_successful_waits + stale_cleared &&
	      ebc_shim.completion_reinits == ebc_shim.completion_waits,
	      "%s: completion accounting (%lu complete, %lu starts/reinits, %lu/%lu waits, %u stale cleared)",
	      what, ebc_shim.completion_calls, ebc_shim.completion_reinits,
	      ebc_shim.completion_successful_waits, ebc_shim.completion_waits,
	      stale_cleared);
}

static void thread_script(void)
{
	if (thread_step == 0) {
		struct drm_rect rect = {8, 8, 24, 24};
		int x, y;

		for (y = rect.y1; y < rect.y2; y++)
			for (x = rect.x1; x < rect.x2; x++)
				set_px(thread_ctx->final_atomic_update,
				       thread_ctx->gray4_pitch, x, y, 0x3);
		commit_damage(thread_ctx, &rect, 1);
	} else {
		if (thread_caller_snapshot)
			memcpy(thread_caller_snapshot, thread_ctx->prev,
			       thread_ctx->gray4_size);
		ebc_shim.thread_stop = true;
	}
	thread_step++;
}

static void test_wbf_thread_body(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	u8 *caller, *off_screen;
	unsigned int i, n_global = 0, n_partial = 0;
	bool order_ok = true;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	caller = malloc(ctx->gray4_size);
	off_screen = malloc(ctx->gray4_size);
	prepare_thread_caller(ctx, caller);
	fill_y4_pattern(off_screen, ctx->gray4_pitch, GW, GH, 9);
	memcpy(ebc->off_screen, off_screen, ctx->gray4_size);

	thread_ctx = ctx;
	thread_step = 0;
	thread_caller_snapshot = caller;
	ebc_shim.schedule_hook = thread_script;
	kthread_unpark(ebc->refresh_thread);	/* what atomic_enable does */

	ret = ebc_shim.thread_fn(ebc_shim.thread_data);

	check(ret == 0 && thread_step == 2,
	      "wbf thread: body runs the scripted session and returns 0");
	/* expected shape: RESET global, full-refresh global (probe sets
	 * do_one_full_refresh), the scripted damage as a partial run,
	 * then the off-screen global on exit */
	for (i = 0; i < fake_ebc.nev; i++) {
		if (fake_ebc.ev[i].lut_mode)
			n_global++;
		else if (fake_ebc.ev[i].three_win)
			n_partial++;
	}
	order_ok = fake_ebc.nev >= 4 &&
		   fake_ebc.ev[0].lut_mode && fake_ebc.ev[1].lut_mode &&
		   fake_ebc.ev[fake_ebc.nev - 1].lut_mode;
	for (i = 2; i < fake_ebc.nev - 1; i++)
		order_ok &= fake_ebc.ev[i].three_win;
	check(n_global == 3 && n_partial > 0 && order_ok,
	      "wbf thread: RESET global, full-refresh global, %u partial frames, off-screen global",
	      n_partial);
	check(ebc_shim.completion_timeouts == 0,
	      "wbf thread: every hardware wait completed");
	check(!memcmp(ebc->suspend_next, caller, ctx->gray4_size),
	      "wbf thread: default disable saves the caller image in suspend_next");
	check(!memcmp(ebc->suspend_prev, off_screen, ctx->gray4_size) &&
	      !memcmp(ctx->prev, off_screen, ctx->gray4_size) &&
	      !memcmp(ctx->next, off_screen, ctx->gray4_size) &&
	      !memcmp(ctx->final, off_screen, ctx->gray4_size),
	      "wbf thread: default disable saves off_screen in suspend_prev and ctx buffers");
	check_thread_completion_accounting("wbf thread", n_global, 0);
	check(harness_clean("wbf-thread"), "wbf thread: no harness violations");
	free(caller);
	free(off_screen);
	thread_caller_snapshot = NULL;
	wbf_teardown(&h, ctx);
}

static void test_wbf_thread_no_off_screen(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	u8 *caller, *off_screen;
	bool saved_no_off_screen = no_off_screen;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	caller = malloc(ctx->gray4_size);
	off_screen = malloc(ctx->gray4_size);
	prepare_thread_caller(ctx, caller);
	fill_y4_pattern(off_screen, ctx->gray4_pitch, GW, GH, 9);
	memcpy(ebc->off_screen, off_screen, ctx->gray4_size);

	no_off_screen = true;
	thread_ctx = ctx;
	thread_step = 0;
	thread_caller_snapshot = caller;
	ebc_shim.schedule_hook = thread_script;
	kthread_unpark(ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);

	check(ret == 0 && thread_global_events() == 2,
	      "wbf thread: no_off_screen retains the caller and submits no off-screen global");
	check(!memcmp(ebc->suspend_next, caller, ctx->gray4_size) &&
	      !memcmp(ebc->suspend_prev, caller, ctx->gray4_size) &&
	      !memcmp(ctx->prev, caller, ctx->gray4_size) &&
	      !memcmp(ctx->next, caller, ctx->gray4_size) &&
	      !memcmp(ctx->final, caller, ctx->gray4_size),
	      "wbf thread: no_off_screen preserves caller in both suspend snapshots and ctx buffers");
	check_thread_completion_accounting("wbf thread no_off_screen",
					 thread_global_events(), 0);
	check(harness_clean("wbf-thread-no-off-screen"),
	      "wbf thread: no_off_screen has no harness violations");

	no_off_screen = saved_no_off_screen;
	free(caller);
	free(off_screen);
	thread_caller_snapshot = NULL;
	wbf_teardown(&h, ctx);
}

static void test_wbf_thread_stale_completion_credit(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	u8 *caller;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	caller = malloc(ctx->gray4_size);
	prepare_thread_caller(ctx, caller);
	complete(&ebc->display_end);
	check(ebc->display_end.done == 1,
	      "wbf thread: stale pre-credit is present before the first global reinit");

	thread_ctx = ctx;
	thread_step = 0;
	thread_caller_snapshot = caller;
	ebc_shim.schedule_hook = thread_script;
	kthread_unpark(ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);

	check(ret == 0 && ebc->display_end.done == 0,
	      "wbf thread: first global reinit clears stale pre-credit before waiting");
	check_thread_completion_accounting("wbf thread stale credit",
					 thread_global_events(), 1);
	check(harness_clean("wbf-thread-stale-credit"),
	      "wbf thread: stale-credit session is otherwise clean");

	free(caller);
	thread_caller_snapshot = NULL;
	wbf_teardown(&h, ctx);
}

/* Historical WBF deferred-END reproducer is covered by the synthetic QUIRK F guard and fail-closed worker timeout tests. */

static void test_wbf_lut_differential(const char *rsl_path)
{
	/* The strongest closed loop: the device model decodes the LUT
	 * that the driver uploaded into the LUT registers; rastersim's
	 * rs_wf_* decodes the same waveform via wbf-info --dump-lut (an
	 * independent re-derivation of the format).  Every 4-bit
	 * transition (from,to) is placed on a 16x16 screen and the full
	 * observed drive sequence must match. */
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	struct drm_rect rect = {0, 0, 16, 16};
	bool saved_diff = diff_mode;
	rs_wf_lut lut;
	u32 n;
	unsigned int f;
	int x, y;
	bool ok;

	if (!ebc)
		return;
	if (rs_wf_load(&lut, rsl_path)) {
		printf("FAIL: rs_wf_load(%s)\n", rsl_path);
		failures++;
		wbf_teardown(&h, NULL);
		return;
	}

	diff_mode = false;
	fake_ebc.record_seq = true;
	harness_mode_set(&h, 16, 16);
	ctx = harness_ctx(&h, 16, 16);

	for (y = 0; y < 16; y++)
		for (x = 0; x < 16; x++) {
			set_px(ctx->prev, ctx->gray4_pitch, x, y, (u8)y);
			set_px(ctx->next, ctx->gray4_pitch, x, y, (u8)y);
			set_px(ctx->final_atomic_update, ctx->gray4_pitch, x, y, (u8)x);
		}
	commit_damage(ctx, &rect, 1);

	rockchip_ebc_refresh(ebc, ctx, false, DRM_EPD_WF_GC16);
	n = ebc->lut.num_phases;

	check(n == lut.num_phases,
	      "wbf differential: driver and wbf-info agree on GC16@25C phase count (%u)", n);
	check(fake_ebc.hw_frames == n,
	      "wbf differential: partial refresh played %u frames", n);
	ok = true;
	for (y = 0; y < 16 && ok; y++)
		for (x = 0; x < 16 && ok; x++)
			for (f = 0; f < n && ok; f++) {
				u8 got = fake_ebc.seq[(size_t)f * 16 * 16 + y * 16 + x];
				/* frame n-1 substitutes 0xff; the last real
				 * phase is neutral (rung 1/2 invariant), so
				 * the rastersim code still applies */
				u8 want = rs_wf_code_y4(&lut, f, y, x);

				if (f + 1 == n)
					want = 0;
				if (got != want) {
					printf("FAIL: differential (%d->%d) phase %u: drive %u, rastersim %u\n",
					       y, x, f, got, want);
					failures++;
					ok = false;
				}
			}
	check(ok, "wbf differential: all 256 (from,to) drive sequences match rastersim's independent decode");
	check(harness_clean("wbf-differential"), "wbf differential: no harness violations");

	diff_mode = saved_diff;
	rs_wf_free(&lut);
	wbf_teardown(&h, ctx);
}

/* ---------------------------------------------------------------------- */

/* ---------------------------------------------------------------------- */
/* EXTRACT_FBS: the belief-dump ioctl                                      */
/*                                                                          */
/* The dbg build (make check's dbg half: the extracted driver with the      */
/* linux-pinenote-debug-*.patch stack applied, -DEBC_HARNESS_DBG) executes  */
/* the real implementation from the extract-fbs debug patch and pins the    */
/* four corrected reference defects (doc/driver-findings-report.md,         */
/* EXTRACT_FBS reference-defects note).  The normal build pins the primary  */
/* kernel's -EOPNOTSUPP stub, which is itself ABI: userspace probes it to   */
/* detect a debug kernel.                                                   */

#ifdef EBC_HARNESS_DBG

#include "ebc-dump-format.h"

static struct rockchip_ebc_ctx *extract_lifetime_ctx;
static unsigned int extract_lifetime_hook_refcount;
static int extract_lifetime_hook_calls;

/* Simulates a concurrent atomic commit: the CRTC state that owns ctx is
 * destroyed during the FIRST plane copy, dropping what would be the last
 * reference if the ioctl had not taken its own kref (the hrdl-reference
 * UAF, defect 2).  Without the ioctl's pin, the remaining plane copies
 * read freed memory and ASan aborts the suite. */
static void extract_lifetime_hook(void)
{
	if (extract_lifetime_hook_calls++ == 0) {
		extract_lifetime_hook_refcount =
			(unsigned int)extract_lifetime_ctx->kref.refcount;
		kref_put(&extract_lifetime_ctx->kref,
			 rockchip_ebc_ctx_release);
	}
}

static void test_extract_fbs(const char *outdir)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx;
	struct drm_rockchip_ebc_extract_fbs args;
	struct drm_rect rect = {8, 4, 40, 20};
	struct drm_crtc_state *saved_state;
	bool saved_diff = diff_mode;
	u8 *bp, *bn, *bf, *ph0, *ph1;	/* exact-size dump buffers */
	u8 *lp, *ln, *lf, *lph0, *lph1;	/* second set for the lifetime run */
	u32 g4, psz;	/* cached: ctx is gone after the lifetime dump */
	bool ok;
	size_t i;
	int x, y, ret;

	/* extract:pre-modeset — no ctx exists yet (harness_ctx not
	 * called): must be -ENODEV, not a NULL dereference (defect 3;
	 * the hrdl-verbatim body would oops here) */
	memset(&args, 0, sizeof(args));
	ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);
	check(ret == -ENODEV,
	      "extract: pre-modeset dump returns -ENODEV (no NULL deref)");
	saved_state = ebc->crtc.state;
	ebc->crtc.state = NULL;
	ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);
	ebc->crtc.state = saved_state;
	check(ret == -ENODEV, "extract: NULL crtc state returns -ENODEV");

	/* run a real partial refresh to completion on the fake device so
	 * prev/next/final hold known content and phase[0] is back to
	 * neutral */
	ctx = harness_ctx(&h, GW, GH);
	g4 = ctx->gray4_size;
	psz = ctx->phase_size;
	diff_mode = false;
	memset(ctx->prev, 0x55, ctx->gray4_size);
	memset(ctx->next, 0x55, ctx->gray4_size);
	memcpy(ctx->final_atomic_update, ctx->prev, ctx->gray4_size);
	for (y = rect.y1; y < rect.y2; y++)
		for (x = rect.x1; x < rect.x2; x++)
			set_px(ctx->final_atomic_update, ctx->gray4_pitch,
			       x, y, (u8)((x + y) & 0xf));
	commit_damage(ctx, &rect, 1);
	run_refresh_synth(ebc, ctx, false);

	/* extract:roundtrip + extract:sizes — full five-plane dump into
	 * EXACT-size sentinel-filled buffers.  Sizes must come from ctx
	 * (defect 1: the reference hard-codes 1313144, 1,000 bytes short
	 * per gray4 plane): a short copy leaves sentinel tail bytes that
	 * fail the memcmp below; an over-copy trips ASan on the
	 * exact-size allocations. */
	bp = malloc(ctx->gray4_size);
	bn = malloc(ctx->gray4_size);
	bf = malloc(ctx->gray4_size);
	ph0 = malloc(ctx->phase_size);
	ph1 = malloc(ctx->phase_size);
	memset(bp, 0xA5, ctx->gray4_size);
	memset(bn, 0xA5, ctx->gray4_size);
	memset(bf, 0xA5, ctx->gray4_size);
	memset(ph0, 0xA5, ctx->phase_size);
	memset(ph1, 0xA5, ctx->phase_size);
	args.ptr_prev = (char *)bp;
	args.ptr_next = (char *)bn;
	args.ptr_final = (char *)bf;
	args.ptr_phase1 = (char *)ph0;
	args.ptr_phase2 = (char *)ph1;
	ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);
	check(ret == 0, "extract: five-plane dump returns 0");
	check(!memcmp(bp, ctx->prev, ctx->gray4_size) &&
	      !memcmp(bn, ctx->next, ctx->gray4_size) &&
	      !memcmp(bf, ctx->final, ctx->gray4_size),
	      "extract: prev/next/final roundtrip byte-exact at ctx sizes (no 1313144-typo class)");
	check(!memcmp(bp, bn, ctx->gray4_size),
	      "extract: dumped prev == next after a completed refresh (the in-dump quiescence invariant)");
	ok = true;
	for (i = 0; i < ctx->phase_size; i++)
		ok &= ph0[i] == 0xff && ph1[i] == 0xff;
	check(ok, "extract: both phase planes dumped, all neutral post-refresh (0xff)");
	check(ctx->kref.refcount == 1,
	      "extract: ctx kref returns to baseline (get/put balanced)");

	/* decoder-differential artifacts: the container (written through
	 * ebc-dump-format.h, exactly like the device grabber) plus the
	 * harness's own rs_y4_to_gray8 rendering of final.  The dbg test
	 * runner decodes the container with the ebc-dump tool and
	 * byte-compares its final.pgm against this rendering — tying the
	 * decoder's nibble conventions to the pinned driver conventions. */
	if (outdir) {
		unsigned char hdrbuf[EBC_DUMP_HEADER_SIZE];
		struct ebc_dump_header dh;
		char path[512];
		FILE *f2;
		u8 *img = malloc((size_t)GW * GH);

		dh.width = GW;
		dh.height = GH;
		dh.gray4_size = ctx->gray4_size;
		dh.phase_size = ctx->phase_size;
		dh.t_mono_ns = 0;
		/* buffers were written directly (no xrgb blit), so the
		 * content is not panel-mirrored: flags bit1 stays 0 and
		 * the decoder must not un-mirror */
		dh.flags = EBC_DUMP_F_VERIFIED_STABLE;
		snprintf(path, sizeof(path), "%s/extract-dump.bin", outdir);
		f2 = fopen(path, "wb");
		if (f2) {
			ebc_dump_header_write(hdrbuf, &dh);
			fwrite(hdrbuf, 1, sizeof(hdrbuf), f2);
			fwrite(bp, 1, ctx->gray4_size, f2);
			fwrite(bn, 1, ctx->gray4_size, f2);
			fwrite(bf, 1, ctx->gray4_size, f2);
			fwrite(ph0, 1, ctx->phase_size, f2);
			fwrite(ph1, 1, ctx->phase_size, f2);
			fclose(f2);
		}
		rs_y4_to_gray8(img, GW, bf, ctx->gray4_pitch, GW, GH);
		snprintf(path, sizeof(path),
			 "%s/extract-final-expected.pgm", outdir);
		write_pgm(path, img, GW, GH);
		free(img);
		check(f2 != NULL,
		      "extract: dump container + expected rendering written for the decoder differential");
	}

	/* extract:null-planes — unrequested planes are skipped, the
	 * requested ones still land */
	memset(bp, 0xA5, ctx->gray4_size);
	memset(bn, 0xA5, ctx->gray4_size);
	memset(&args, 0, sizeof(args));
	args.ptr_prev = (char *)bp;
	args.ptr_next = (char *)bn;
	ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);
	check(ret == 0 &&
	      !memcmp(bp, ctx->prev, ctx->gray4_size) &&
	      !memcmp(bn, ctx->next, ctx->gray4_size),
	      "extract: NULL planes are skipped; requested planes still land");

	/* extract:efault — fault injection: exactly -EFAULT, never a
	 * positive uncopied-byte count (defect 4) */
	ebc_shim.uaccess_fail_next = 1;
	args.ptr_prev = (char *)bp;
	args.ptr_next = (char *)bn;
	args.ptr_final = (char *)bf;
	args.ptr_phase1 = (char *)ph0;
	args.ptr_phase2 = (char *)ph1;
	ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);
	check(ret == -EFAULT && ebc_shim.uaccess_fail_next == 0,
	      "extract: uaccess fault yields exactly -EFAULT, never a positive byte count");
	check(ctx->kref.refcount == 1,
	      "extract: kref balanced on the -EFAULT path too");

	/* extract:lifetime — the owning CRTC state dies mid-copy; the
	 * ioctl's own kref must keep ctx alive until its final put.
	 * MUST run last: the ioctl's kref_put releases ctx here. */
	lp = malloc(g4);
	ln = malloc(g4);
	lf = malloc(g4);
	lph0 = malloc(psz);
	lph1 = malloc(psz);
	memset(lp, 0xA5, g4);
	memset(ln, 0xA5, g4);
	memset(lf, 0xA5, g4);
	memset(lph0, 0xA5, psz);
	memset(lph1, 0xA5, psz);
	args.ptr_prev = (char *)lp;
	args.ptr_next = (char *)ln;
	args.ptr_final = (char *)lf;
	args.ptr_phase1 = (char *)lph0;
	args.ptr_phase2 = (char *)lph1;
	extract_lifetime_ctx = ctx;
	extract_lifetime_hook_calls = 0;
	extract_lifetime_hook_refcount = 0;
	ebc_shim.uaccess_hook = extract_lifetime_hook;
	ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);
	ebc_shim.uaccess_hook = NULL;
	check(ret == 0,
	      "extract: dump succeeds while the owning CRTC state dies mid-copy");
	check(extract_lifetime_hook_refcount == 2,
	      "extract: the ioctl holds its own ctx reference during the copy (refcount 2 at the mid-copy state destruction)");
	check(!memcmp(lp, bp, g4) &&
	      !memcmp(ln, bn, g4) &&
	      !memcmp(lf, bf, g4),
	      "extract: all planes copied intact from the kref-pinned ctx (ASan guards the UAF regression)");
	check(harness_clean("extract"), "extract: no harness violations");

	/* ctx was released by the ioctl's final kref_put */
	h.crtc_state.ctx = NULL;
	free(bp); free(bn); free(bf); free(ph0); free(ph1);
	free(lp); free(ln); free(lf); free(lph0); free(lph1);
	diff_mode = saved_diff;
	harness_free(&h, NULL);
}

#else /* !EBC_HARNESS_DBG */

static void test_extract_fbs_stub(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct rockchip_ebc_ctx *ctx = harness_ctx(&h, GW, GH);
	struct drm_rockchip_ebc_extract_fbs args = { 0 };
	int ret = ioctl_extract_fbs(&ebc->drm, &args, NULL);

	check(ret == -EOPNOTSUPP,
	      "extract: primary kernel keeps the -EOPNOTSUPP stub (userspace probes it to detect the debug kernel)");
	harness_free(&h, ctx);
}

#endif /* EBC_HARNESS_DBG */

enum barrier_worker_case {
	BARRIER_BATCH,
	BARRIER_DURING_PLAYBACK,
	BARRIER_LEGACY_BEFORE,
	BARRIER_LEGACY_DURING,
};

static struct rockchip_ebc *barrier_worker_ebc;
static enum barrier_worker_case barrier_worker_case;
static unsigned int barrier_worker_globals;
static unsigned int barrier_worker_globals_before_stop;
static bool barrier_worker_injected;
static u64 barrier_worker_first_active;
static u64 barrier_worker_first_completed;
static int barrier_worker_prepublication_wait;
static bool barrier_presleep_submit_injected;
static int barrier_presleep_submit_result;
static u64 barrier_presleep_submit_id;

static int barrier_submit(struct rockchip_ebc *ebc, u64 *id)
{
	struct drm_rockchip_ebc_refresh_barrier args = {
		.version = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION,
		.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_SUBMIT,
	};
	int ret = ioctl_refresh_barrier(&ebc->drm, &args, NULL);

	if (!ret)
		*id = args.request_id;
	return ret ? ret : args.result;
}

static int barrier_wait_result(struct rockchip_ebc *ebc, u64 id, u32 timeout_ms)
{
	struct drm_rockchip_ebc_refresh_barrier args = {
		.version = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION,
		.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_WAIT,
		.request_id = id,
		.timeout_ms = timeout_ms,
	};
	int ret = ioctl_refresh_barrier(&ebc->drm, &args, NULL);

	return ret ? ret : args.result;
}

static void barrier_submit_at_idle(unsigned int state)
{
	if (state != TASK_IDLE || barrier_presleep_submit_injected)
		return;
	barrier_presleep_submit_injected = true;
	barrier_presleep_submit_result =
		barrier_submit(barrier_worker_ebc, &barrier_presleep_submit_id);
}

static void barrier_worker_event(const struct fake_ebc_event *ev,
			 const u8 *prev, const u8 *next, const u8 *phase_buf)
{
	struct drm_rockchip_ebc_trigger_global_refresh legacy = {
		.trigger_global_refresh = true,
	};
	u64 ignored;

	(void)prev;
	(void)next;
	(void)phase_buf;
	if (!ev->lut_mode)
		return;
	barrier_worker_globals++;
	if (barrier_worker_globals != 1)
		return;
	barrier_worker_first_active = barrier_worker_ebc->active_generation;
	barrier_worker_first_completed = barrier_worker_ebc->completed_generation;
	if (barrier_worker_case == BARRIER_DURING_PLAYBACK) {
		barrier_worker_injected = barrier_submit(barrier_worker_ebc, &ignored) ==
			-EINPROGRESS;
		barrier_worker_prepublication_wait =
			barrier_wait_result(barrier_worker_ebc, 1, 1);
	} else if (barrier_worker_case == BARRIER_LEGACY_DURING) {
		ioctl_trigger_global_refresh(&barrier_worker_ebc->drm, &legacy, NULL);
		ioctl_trigger_global_refresh(&barrier_worker_ebc->drm, &legacy, NULL);
		barrier_worker_injected = barrier_worker_ebc->legacy_pending;
	}
}

static void barrier_worker_stop(void)
{
	barrier_worker_globals_before_stop = barrier_worker_globals;
	ebc_shim.thread_stop = true;
}

static void teardown_stop_runs_active_worker(void)
{
	/* kthread_stop waits for a refresh that was already accepted before
	 * teardown. The worker's timeout path schedules once, where this hook
	 * marks it stopped exactly as the real stop wakeup would. */
	ebc_shim.kthread_stop_hook = NULL;
	ebc_shim.schedule_hook = barrier_worker_stop;
	ebc_shim.thread_fn(ebc_shim.thread_data);
}

static void suspend_helper_runs_active_worker(void)
{
	ebc_shim.drm_suspend_hook = NULL;
	ebc_shim.schedule_hook = barrier_worker_stop;
	ebc_shim.thread_fn(ebc_shim.thread_data);
}

static unsigned int forbidden_drm_resume_calls;

static void forbidden_drm_resume(void)
{
	forbidden_drm_resume_calls++;
}

static int barrier_fail_resume(struct device *dev)
{
	(void)dev;
	return -EIO;
}

static unsigned int active_dma_mappings(void)
{
	unsigned int i, active = 0;

	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++)
		active += ebc_shim.dma[i].active;
	return active;
}

/* The production timeout path deliberately retains queued damage until
 * reboot. This is harness teardown only: avoid the historical
 * ctx_free UAF reproducer after this test has asserted that retention. */
static void discard_test_queue(struct rockchip_ebc_ctx *ctx)
{
	struct rockchip_ebc_area *area, *next;

	list_for_each_entry_safe(area, next, &ctx->queue, list) {
		list_del(&area->list);
		kfree(area);
	}
}

/* Test-only reboot boundary. Production retains uncertain ownership until a
 * real reboot; this releases it only after the assertions so ASan can check
 * the rest of this process. `state_ref` is the CRTC state's ctx reference. */
static void test_reboot_cleanup(struct rockchip_ebc *ebc,
				struct rockchip_ebc_ctx *ctx, bool state_ref)
{
	ebc->uncertain_ctx = NULL;
	kref_put(&ctx->kref, rockchip_ebc_ctx_release);
	if (state_ref)
		kref_put(&ctx->kref, rockchip_ebc_ctx_release);
	module_put(THIS_MODULE);
	ebc_shim_reset();
}

static void assert_uncertain_resumes_are_inert(struct harness *h,
					       const char *kind)
{
	unsigned long pm_force_resume = ebc_shim.pm_force_resume_calls;
	unsigned long drm_resume = ebc_shim.drm_resume_calls;
	unsigned long cache_only = ebc_shim.regcache_cache_only_calls;
	unsigned long mark_dirty = ebc_shim.regcache_mark_dirty_calls;
	unsigned long sync = ebc_shim.regcache_sync_calls;
	unsigned long regmap_writes = ebc_shim.regmap_write_calls;
	unsigned long clk_enable = ebc_shim.clk_prepare_enable_calls;
	unsigned long clk_disable = ebc_shim.clk_disable_unprepare_calls;
	unsigned long regulator_enable = ebc_shim.regulator_bulk_enable_calls;
	unsigned long regulator_disable = ebc_shim.regulator_bulk_disable_calls;
	unsigned long worker_unpark = ebc_shim.kthread_unpark_calls;
	int clks_on = ebc_shim.clks_on;
	int regulators_on = ebc_shim.regulators_on;
	int system_ret = rockchip_ebc_resume(&h->pdev.dev);
	int runtime_ret = rockchip_ebc_runtime_resume(&h->pdev.dev);

	check(system_ret == -EBUSY && runtime_ret == -EBUSY &&
	      ebc_shim.pm_force_resume_calls == pm_force_resume &&
	      ebc_shim.drm_resume_calls == drm_resume &&
	      ebc_shim.regcache_cache_only_calls == cache_only &&
	      ebc_shim.regcache_mark_dirty_calls == mark_dirty &&
	      ebc_shim.regcache_sync_calls == sync &&
	      ebc_shim.regmap_write_calls == regmap_writes &&
	      ebc_shim.clk_prepare_enable_calls == clk_enable &&
	      ebc_shim.clk_disable_unprepare_calls == clk_disable &&
	      ebc_shim.regulator_bulk_enable_calls == regulator_enable &&
	      ebc_shim.regulator_bulk_disable_calls == regulator_disable &&
	      ebc_shim.kthread_unpark_calls == worker_unpark &&
	      ebc_shim.clks_on == clks_on && ebc_shim.regulators_on == regulators_on,
	      "resume containment: %s uncertainty performs no PM, DRM, power, regcache, MMIO or worker action",
	      kind);
}

static void uncertain_remove_child(bool timeout_during_remove)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	u64 id;

	if (!ebc)
		_exit(2);
	harness_mode_set(&h, GW, GH);
	(void)harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	fake_ebc.defer_dsp_end = 1;
	if (barrier_submit(ebc, &id) != -EINPROGRESS)
		_exit(3);
	if (timeout_during_remove) {
		ebc_shim.kthread_stop_hook = teardown_stop_runs_active_worker;
	} else {
		ebc_shim.schedule_hook = barrier_worker_stop;
		kthread_unpark(ebc->refresh_thread);
		ebc_shim.thread_fn(ebc_shim.thread_data);
		if (!ebc->hardware_uncertain)
			_exit(4);
	}
	rockchip_ebc_remove(&h.pdev);
	_exit(0);
}

static void test_wbf_uncertain_remove_panics(void)
{
	unsigned int i;

	for (i = 0; i < 2; i++) {
		pid_t pid = fork();
		int status;

		if (pid == 0)
			uncertain_remove_child(i != 0);
		if (pid < 0 || waitpid(pid, &status, 0) != pid) {
			check(false, "uncertain remove death test: fork/waitpid succeeds");
			continue;
		}
		check(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT,
		      "uncertain remove death test: %s uncertainty emits panic and aborts before devres",
		      i ? "stop-time timeout" : "already-established");
	}
}

static void test_wbf_normal_remove(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);

	if (!ebc)
		return;
	rockchip_ebc_remove(&h.pdev);
	check(ebc_shim.kthread_stop_calls == 1 && ebc_shim.drm_unregister_calls == 1 &&
	      ebc_shim.drm_shutdown_calls == 1 && ebc_shim.pm_disable_calls == 1,
	      "normal remove: teardown remains available without uncertain DMA ownership");
	wbf_teardown(&h, NULL);
}

static void test_barrier_uapi_and_lifecycle(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = harness_ebc(&h, GW, GH, NPH);
	struct drm_rockchip_ebc_refresh_barrier args = {
		.version = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION,
		.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_SUBMIT,
	};
	u64 id;
	int ret;

	check(sizeof(args) == 40, "barrier UAPI: explicit 40-byte layout");
	ret = ioctl_refresh_barrier(&ebc->drm, &args, NULL);
	check(ret == 0 && args.result == -ENODEV && !args.request_id,
	      "barrier lifecycle: SUBMIT fails closed before CRTC/worker enable");
	harness_enable_worker(&h);
	ebc->refresh_thread = &ebc_shim_task;
	h.crtc_state.base.mode_changed = true;
	rockchip_ebc_crtc_atomic_disable(&ebc->crtc, NULL);
	check(!ebc->worker_available && !ebc->barrier_poison,
	      "barrier lifecycle: idle disable does not permanently poison a later enable");
	rockchip_ebc_crtc_atomic_enable(&ebc->crtc, NULL);
	check(ebc->worker_available,
	      "barrier lifecycle: worker is available after an idle disable/enable cycle");
	memset(&args, 0, sizeof(args));
	args.version = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION;
	args.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_SUBMIT;
	ret = ioctl_refresh_barrier(&ebc->drm, &args, NULL);
	id = args.request_id;
	check(ret == 0 && args.result == -EINPROGRESS && id == 1,
	      "barrier lifecycle: enabled worker accepts a generation");

	args.version++;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == -EINVAL,
	      "barrier UAPI: malformed version is rejected");
	args.version--;
	args.op = 99;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == -EINVAL,
	      "barrier UAPI: malformed operation is rejected");
	args.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_WAIT;
	args.request_id = id + 1;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == -EINVAL,
	      "barrier UAPI: future generation is rejected");
	args.request_id = id;
	args.reserved[3] = 1;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == -EINVAL,
	      "barrier UAPI: every reserved word is validated");
	args.reserved[3] = 0;
	args.result = 1;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == -EINVAL,
	      "barrier UAPI: nonzero result input is rejected");
	args.result = 0;
	ebc_shim.wait_killable_result = -ERESTARTSYS;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == -ERESTARTSYS &&
	      args.result == 0,
	      "barrier UAPI: signal interruption is the ioctl error, not payload");
	ebc_shim.wait_killable_result = 0;
	h.crtc_state.base.mode_changed = true;
	rockchip_ebc_crtc_atomic_disable(&ebc->crtc, NULL);
	h.crtc_state.base.mode_changed = false;
	check(!ebc->worker_available && ebc->barrier_poison == -ENODEV &&
	      barrier_wait_result(ebc, id, 1) == -ENODEV,
	      "barrier lifecycle: disable poisons and wakes a pending generation before parking");
	ebc->requested_generation = U64_MAX;
	memset(&args, 0, sizeof(args));
	args.version = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION;
	args.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_SUBMIT;
	check(ioctl_refresh_barrier(&ebc->drm, &args, NULL) == 0 &&
	      args.result == -EOVERFLOW,
	      "barrier UAPI: generation overflow is reported without wraparound");
	harness_free(&h, NULL);
}

static void test_wbf_refresh_setup_failures(void)
{
	static const unsigned int map_stages[] = { 1, 2, 3 };
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(map_stages); i++) {
		struct harness h;
		struct rockchip_ebc *ebc = wbf_probe(&h);
		struct rockchip_ebc_ctx *ctx;
		unsigned long unmaps;

		if (!ebc)
			return;
		harness_mode_set(&h, GW, GH);
		ctx = harness_ctx(&h, GW, GH);
		ebc_shim.dma_fail_map_call = ebc_shim.dma_maps + map_stages[i];
		unmaps = ebc_shim.dma_unmaps;
		check(rockchip_ebc_refresh(ebc, ctx, map_stages[i] != 3,
					DRM_EPD_WF_GC16) == -EIO && !fake_ebc.nev &&
		      !active_dma_mappings() && ebc_shim.dma_unmaps == unmaps +
		      (map_stages[i] - 1) && !ebc_shim.module_pins &&
		      ebc_shim.module_gets == ebc_shim.module_puts,
		      "refresh setup: DMA map failure stage %u returns before MMIO start and unwinds owned maps",
		      map_stages[i]);
		wbf_teardown(&h, ctx);
	}

	{
		struct harness h;
		struct rockchip_ebc *ebc = wbf_probe(&h);
		struct rockchip_ebc_ctx *ctx;

		if (!ebc)
			return;
		harness_mode_set(&h, GW, GH);
		ctx = harness_ctx(&h, GW, GH);
		ebc_shim.iio_temp_override = true;
		ebc_shim.iio_temp_mC = -100000;
		check(rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16) == -ENOENT &&
		      !fake_ebc.nev, "refresh setup: LUT temperature failure prevents start");
		ebc_shim.iio_temp_override = false;
		check(rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_MAX) == -ENOENT &&
		      !fake_ebc.nev, "refresh setup: LUT waveform failure prevents start");
		ebc_shim.module_get_fail = true;
		check(rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16) == -ENODEV &&
		      !fake_ebc.nev && !ebc_shim.module_pins,
		      "refresh setup: failed module pin prevents physical start");
		ebc_shim.module_get_fail = false;
		ebc_shim.pm_get_error = -EIO;
		check(rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16) == -EIO &&
		      !ebc_shim.pm_refcount && !ebc_shim.module_pins,
		      "refresh setup: failed pm_runtime_get balances usage and owners");
		wbf_teardown(&h, ctx);
	}
}

static void test_wbf_barrier_worker(void)
{
	static const enum barrier_worker_case cases[] = {
		BARRIER_BATCH, BARRIER_DURING_PLAYBACK,
		BARRIER_LEGACY_BEFORE, BARRIER_LEGACY_DURING,
	};
	unsigned int n;

	for (n = 0; n < ARRAY_SIZE(cases); n++) {
		struct harness h;
		struct rockchip_ebc *ebc = wbf_probe(&h);
		struct rockchip_ebc_ctx *ctx;
		u64 id1 = 0, id2 = 0;
		struct drm_rockchip_ebc_trigger_global_refresh legacy = {
			.trigger_global_refresh = true,
		};
		int ret;

		if (!ebc)
			return;
		harness_mode_set(&h, GW, GH);
		ctx = harness_ctx(&h, GW, GH);
		harness_enable_worker(&h);
		ebc->reset_complete = true;
		ebc->do_one_full_refresh = false;
		no_off_screen = true;
		barrier_worker_ebc = ebc;
		barrier_worker_case = cases[n];
		barrier_worker_globals = 0;
		barrier_worker_globals_before_stop = 0;
		barrier_worker_injected = false;
		barrier_worker_first_active = 0;
		barrier_worker_first_completed = 0;
		barrier_worker_prepublication_wait = 0;
		if (cases[n] == BARRIER_LEGACY_BEFORE) {
			ret = ioctl_trigger_global_refresh(&ebc->drm, &legacy, NULL);
			check(ret == 0 && ebc->legacy_pending,
			      "barrier worker: legacy request is pending before the worker snapshot");
		} else {
			check(barrier_submit(ebc, &id1) == -EINPROGRESS,
			      "barrier worker: SUBMIT reports -EINPROGRESS before worker publication");
			if (cases[n] == BARRIER_BATCH)
				check(barrier_submit(ebc, &id2) == -EINPROGRESS,
				      "barrier worker: second pre-snapshot SUBMIT also reports -EINPROGRESS");
		}
		ebc_shim.schedule_hook = barrier_worker_stop;
		fake_ebc.on_event = barrier_worker_event;
		kthread_unpark(ebc->refresh_thread);
		ret = ebc_shim.thread_fn(ebc_shim.thread_data);
		fake_ebc.on_event = NULL;
		no_off_screen = false;

		check(ret == 0, "barrier worker: scripted refresh thread returns cleanly");
		if (cases[n] == BARRIER_BATCH) {
			check(barrier_worker_globals_before_stop == 1 &&
			      barrier_worker_first_active == 2 && barrier_worker_first_completed == 0 &&
			      ebc->completed_generation == 2 && ebc->active_generation == 0,
			      "barrier worker: two pre-snapshot submits use one global and publish only after return");
			check(barrier_wait_result(ebc, id1, 1) == 0 &&
			      barrier_wait_result(ebc, id2, 1) == 0,
			      "barrier worker: both batched WAITs succeed after worker publication");
		} else if (cases[n] == BARRIER_DURING_PLAYBACK) {
			check(barrier_worker_globals_before_stop == 2 && barrier_worker_injected &&
			      barrier_worker_first_active == 1 && barrier_worker_first_completed == 0 &&
			      barrier_worker_prepublication_wait == -EINPROGRESS &&
			      ebc->completed_generation == 2,
			      "barrier worker: playback SUBMIT requires a second global and cannot publish early");
			check(barrier_wait_result(ebc, id1, 1) == 0 &&
			      barrier_wait_result(ebc, 2, 1) == 0,
			      "barrier worker: both playback-separated generations complete in order");
		} else if (cases[n] == BARRIER_LEGACY_BEFORE) {
			check(barrier_worker_globals_before_stop == 1 && !ebc->legacy_pending &&
			      ebc->requested_generation == 0 && ebc->completed_generation == 0,
			      "barrier worker: pre-snapshot legacy request coalesces without a generation");
		} else {
			check(barrier_worker_globals_before_stop == 2 && barrier_worker_injected &&
			      !ebc->legacy_pending && ebc->requested_generation == 1 &&
			      ebc->completed_generation == 1 && ebc->active_generation == 0,
			      "barrier worker: playback legacy requests coalesce into the next global only");
		}
		wbf_teardown(&h, ctx);
	}
}

static void test_wbf_barrier_presleep_submit(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	barrier_worker_ebc = ebc;
	barrier_presleep_submit_injected = false;
	barrier_presleep_submit_result = 0;
	barrier_presleep_submit_id = 0;
	ebc_shim.task_state_hook = barrier_submit_at_idle;
	ebc_shim.schedule_hook = barrier_worker_stop;
	kthread_unpark(ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);
	ebc_shim.task_state_hook = NULL;

	check(ret == 0 && barrier_presleep_submit_injected &&
	      barrier_presleep_submit_result == -EINPROGRESS &&
	      barrier_presleep_submit_id == 1 && ebc_shim.wake_up_process_calls == 1,
	      "barrier presleep: TASK_IDLE-window SUBMIT is accepted and wakes the worker");
	check(ebc_shim.schedule_calls == 1 && fake_ebc.nev == 1 &&
	      ebc->completed_generation == barrier_presleep_submit_id &&
	      !ebc->active_generation &&
	      barrier_wait_result(ebc, barrier_presleep_submit_id, 1) == 0,
	      "barrier presleep: injected generation runs and publishes before the only idle schedule");
	no_off_screen = false;
	wbf_teardown(&h, ctx);
}

static void test_wbf_barrier_failures(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	u64 id;
	int (*saved_resume)(struct device *dev);
	u32 starts;
	struct drm_rect rect = {0, 0, 8, 8};

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	saved_resume = ebc_shim.rt_resume;
	ebc_shim.rt_resume = barrier_fail_resume;
	check(barrier_submit(ebc, &id) == -EINPROGRESS,
	      "barrier failure: setup-failure request is accepted then owned by the worker");
	ebc_shim.schedule_hook = barrier_worker_stop;
	kthread_unpark(ebc->refresh_thread);
	ebc_shim.thread_fn(ebc_shim.thread_data);
	check(ebc->barrier_poison == -EIO && barrier_wait_result(ebc, id, 1) == -EIO &&
	      fake_ebc.nev == 0,
	      "barrier failure: pre-start PM error poisons and wakes without an indefinite WAIT");
	ebc_shim.rt_resume = saved_resume;
	wbf_teardown(&h, ctx);

	ebc = wbf_probe(&h);
	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	fake_ebc.defer_dsp_end = 1;
	check(barrier_submit(ebc, &id) == -EINPROGRESS,
	      "barrier failure: global-timeout request enters the real worker");
	ebc_shim.schedule_hook = barrier_worker_stop;
	kthread_unpark(ebc->refresh_thread);
	ebc_shim.thread_fn(ebc_shim.thread_data);
	starts = fake_ebc.nev;
	check(ebc->barrier_poison == -ETIMEDOUT && active_dma_mappings() >= 2 &&
	      barrier_wait_result(ebc, id, 1) == -ETIMEDOUT,
	      "barrier failure: global timeout retains active DMA mappings and wakes waiters");
	{
		struct ebc_crtc_state *old = kzalloc(sizeof(*old), GFP_KERNEL);

		old->base.crtc = &ebc->crtc;
		old->base.mode_changed = true;
		old->ctx = ctx; /* transfer the state-owned reference */
		h.crtc_state.ctx = NULL;
		ebc->crtc.state = &old->base;
		check(ctx->kref.refcount == 2 && ebc->uncertain_ctx == ctx,
		      "timeout retention: active ctx has state and uncertain ownership");
		rockchip_ebc_crtc_atomic_disable(&ebc->crtc, NULL);
		rockchip_ebc_crtc_destroy_state(&ebc->crtc, &old->base);
		ebc->crtc.state = NULL;
		rockchip_ebc_crtc_reset(&ebc->crtc);
		check(ctx->kref.refcount == 1 && ebc->uncertain_ctx == ctx &&
		      active_dma_mappings() >= 2 && ebc_shim.module_pins == 1 &&
		      ebc->crtc.state && !to_ebc_crtc_state(ebc->crtc.state)->ctx,
		      "timeout retention: disable plus CRTC destruction/replacement cannot free mapped ctx");
	}
	{
		unsigned int maps = active_dma_mappings();
		unsigned long unmaps = ebc_shim.dma_unmaps;
		u32 teardown_starts = fake_ebc.nev;

		rockchip_ebc_shutdown(&h.pdev);
		check(active_dma_mappings() == maps && ebc_shim.dma_unmaps == unmaps &&
		      fake_ebc.nev == teardown_starts && ebc_shim.clks_on == 2 &&
		      ebc_shim.regulators_on == EBC_NUM_SUPPLIES && ebc_shim.module_pins == 1 &&
		      ebc_shim.kthread_stop_calls == 1,
		      "timeout shutdown: worker stops while retaining DMA, context power and prohibiting starts");
	}
	assert_uncertain_resumes_are_inert(&h, "global");
	fake_ebc_deliver_dsp_end();
	rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	check(fake_ebc.nev == starts,
	      "barrier failure: late global END cannot heal poison or start hardware");
	rockchip_ebc_crtc_destroy_state(&ebc->crtc, ebc->crtc.state);
	ebc->crtc.state = NULL;
	test_reboot_cleanup(ebc, ctx, false);
	no_off_screen = false;
	wbf_teardown(&h, NULL); /* timeout intentionally retains ctx until reboot */

	ebc = wbf_probe(&h);
	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	commit_damage(ctx, &rect, 1);
	fake_ebc.defer_dsp_end = 1;
	ebc_shim.schedule_hook = barrier_worker_stop;
	kthread_unpark(ebc->refresh_thread);
	ebc_shim.thread_fn(ebc_shim.thread_data);
	starts = fake_ebc.nev;
	check(ebc->barrier_poison == -ETIMEDOUT && ebc->uncertain_ctx == ctx &&
	      ctx->kref.refcount == 2 && active_dma_mappings() >= 3 &&
	      ebc_shim.module_pins == 1 && ebc_shim.clks_on == 2 &&
	      ebc_shim.regulators_on == EBC_NUM_SUPPLIES && !list_empty(&ctx->queue) &&
	      ebc_shim.schedule_calls == 1,
	      "barrier failure: partial timeout retains exact ctx, module, DMA and power until reboot");
	assert_uncertain_resumes_are_inert(&h, "partial");
	fake_ebc_deliver_dsp_end();
	rockchip_ebc_refresh(ebc, ctx, false, DRM_EPD_WF_GC16);
	check(fake_ebc.nev == starts,
	      "barrier failure: late partial END cannot heal poison or start hardware");
	no_off_screen = false;
	h.crtc_state.ctx = NULL;
	test_reboot_cleanup(ebc, ctx, true);
	wbf_teardown(&h, NULL);
}

static void test_wbf_teardown_timeout_race(void)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h);
	struct rockchip_ebc_ctx *ctx;
	u64 id;
	u32 starts;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	fake_ebc.defer_dsp_end = 1;
	check(barrier_submit(ebc, &id) == -EINPROGRESS,
	      "teardown race: worker owns a global before shutdown");
	ebc_shim.kthread_stop_hook = teardown_stop_runs_active_worker;
	rockchip_ebc_shutdown(&h.pdev);
	starts = fake_ebc.nev;
	check(ebc->hardware_uncertain && ebc->uncertain_ctx == ctx &&
	      ctx->kref.refcount == 2 && ebc_shim.kthread_stop_calls == 1 &&
	      active_dma_mappings() >= 2 && ebc_shim.module_pins == 1 &&
	      ebc_shim.pm_refcount == 1 && ebc_shim.clks_on == 2 &&
	      ebc_shim.regulators_on == EBC_NUM_SUPPLIES &&
	      !ebc_shim.drm_unregister_calls && !ebc_shim.drm_shutdown_calls &&
	      !ebc_shim.pm_disable_calls,
	      "teardown race: shutdown rechecks timeout after stop and retains every owner");
	fake_ebc_deliver_dsp_end();
	rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
	check(fake_ebc.nev == starts,
	      "teardown race: late END cannot restart EBC after stop-time timeout");
	h.crtc_state.ctx = NULL;
	test_reboot_cleanup(ebc, ctx, true);
	no_off_screen = false;
	wbf_teardown(&h, NULL);
}

static void test_wbf_suspend_uncertain(void)
{
	unsigned int i;

	for (i = 0; i < 3; i++) {
		struct harness h;
		struct rockchip_ebc *ebc = wbf_probe(&h);
		struct rockchip_ebc_ctx *ctx;
		u64 id;
		u32 starts;
		int ret;

		if (!ebc)
			return;
		harness_mode_set(&h, GW, GH);
		ctx = harness_ctx(&h, GW, GH);
		harness_enable_worker(&h);
		ebc->reset_complete = true;
		ebc->do_one_full_refresh = false;
		no_off_screen = true;
		fake_ebc.defer_dsp_end = 1;
		check(barrier_submit(ebc, &id) == -EINPROGRESS,
		      "suspend containment: worker owns a global");
		if (i < 2) {
			ebc_shim.schedule_hook = barrier_worker_stop;
			kthread_unpark(ebc->refresh_thread);
			ebc_shim.thread_fn(ebc_shim.thread_data);
		} else {
			ebc_shim.drm_suspend_hook = suspend_helper_runs_active_worker;
			forbidden_drm_resume_calls = 0;
			ebc_shim.drm_resume_hook = forbidden_drm_resume;
		}
		if (i == 0)
			ret = rockchip_ebc_runtime_suspend(&h.pdev.dev);
		else
			ret = rockchip_ebc_suspend(&h.pdev.dev);
		starts = fake_ebc.nev;
		check(ret == -EBUSY && ebc->hardware_uncertain &&
		      ebc->uncertain_ctx == ctx && ctx->kref.refcount == 2 &&
		      active_dma_mappings() >= 2 && ebc_shim.module_pins == 1 &&
		      ebc_shim.pm_refcount == 1 && ebc_shim.clks_on == 2 &&
		      ebc_shim.regulators_on == EBC_NUM_SUPPLIES &&
		      !ebc_shim.pm_force_suspend_calls,
		      "suspend containment: %s retains exact uncertain ownership and power",
		      i == 0 ? "runtime suspend" :
		      i == 1 ? "already-uncertain system suspend" : "DRM-suspend timeout");
		if (i == 1)
			check(!ebc_shim.drm_suspend_calls,
			      "suspend containment: already-uncertain system suspend skips DRM helper");
		if (i == 2)
			check(ebc_shim.drm_suspend_calls == 1 && !ebc_shim.drm_resume_calls &&
			      !forbidden_drm_resume_calls,
			      "suspend containment: timeout in DRM helper remains terminally suspended until reboot");
		fake_ebc_deliver_dsp_end();
		rockchip_ebc_refresh(ebc, ctx, true, DRM_EPD_WF_GC16);
		check(fake_ebc.nev == starts,
		      "suspend containment: late END cannot restart uncertain EBC");
		h.crtc_state.ctx = NULL;
		test_reboot_cleanup(ebc, ctx, true);
		no_off_screen = false;
		wbf_teardown(&h, NULL);
	}
}

int main(int argc, char **argv)
{
	const char *fwdir = argc > 1 && argv[1][0] ? argv[1] : NULL;
	const char *rsl = argc > 2 && argv[2][0] ? argv[2] : NULL;
	const char *outdir = argc > 3 && argv[3][0] ? argv[3] : NULL;

	test_dma_shadow_model();
	test_ctx_free_queued_area();
	test_barrier_uapi_and_lifecycle();
	test_mode_set_golden();
	test_global_refresh();
	test_partial_refresh_single_area(outdir);
	test_partial_diff_mode();
	test_midrefresh_commit();
	test_quirk_begin_together_conflict();
	test_quirk_threshold_zero_gap_global();
#ifdef EBC_HARNESS_DBG
	test_extract_fbs(outdir);
#else
	test_extract_fbs_stub();
#endif

	if (fwdir) {
		setenv("EBC_SHIM_FW_DIR", fwdir, 1);
		test_wbf_probe();
		test_wbf_real_refresh();
		test_wbf_cold_temperature();
		test_wbf_thread_body();
		test_wbf_thread_no_off_screen();
		test_wbf_thread_stale_completion_credit();
		test_wbf_refresh_setup_failures();
		test_wbf_barrier_worker();
		test_wbf_barrier_presleep_submit();
		test_wbf_barrier_failures();
		test_wbf_normal_remove();
		test_wbf_uncertain_remove_panics();
		test_wbf_teardown_timeout_race();
		test_wbf_suspend_uncertain();
		/* The former deferred-END reproducer is now the primary fixed-width
		 * barrier guard above: a timeout poisons rather than permitting the
		 * shutdown global to consume a stale completion. */
		if (rsl)
			test_wbf_lut_differential(rsl);
		else
			printf("SKIP: rastersim LUT differential (no RSL dump given)\n");
	} else {
		printf("SKIP: waveform-dependent refresh tests (run with WBF=/path/to/ebc.wbf)\n");
	}

	fake_ebc_free();
	if (failures) {
		printf("RESULT: %d failures\n", failures);
		return 1;
	}
	printf("RESULT: ok\n");
	return 0;
}
