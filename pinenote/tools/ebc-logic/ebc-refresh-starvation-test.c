/* ebc-refresh-starvation-test: offline reproducer for the 2026-07-29
 * hardware observation that a REFRESH_BARRIER generation is never
 * credited while the EBC keeps completing frames at panel rate.
 *
 * Hardware symptom (os2, 7.0.11-rt, supervised run of
 * pinenote-ebc-sleep-frame-test --run):
 *   - SUBMIT returned a generation, WAIT(10000 ms) returned -EINPROGRESS
 *     (so barrier_poison == 0 and completed_generation < request_id),
 *   - the "ebc-refresh/fdec0000.ebc" kthread sat in D, never I,
 *   - EBC IRQ 66 climbed at a sustained ~63.4 Hz for minutes,
 *   - dmesg gained neither "Refresh timed out!" (the *global* message,
 *     patch line 3628) nor "Frame %d timed out!" (the *partial* message,
 *     patch line 4290), and no poison line.
 *
 * The claim under test: the refresh thread never reaches its
 * do_one_full_refresh check because it is inside
 * rockchip_ebc_partial_refresh()'s `for (frame = 0;; frame++)` loop,
 * whose ONLY exit is `list_empty(&areas)` (patch ~4241) and which
 * re-splices ctx->queue into `areas` every frame (patch ~4258).  A
 * sustained damage supply therefore starves the barrier indefinitely,
 * with no timeout, because the per-frame wait is EBC_FRAME_TIMEOUT
 * (25 ms, patch line 2981) and every frame completes well inside it.
 *
 * This is a `quirk:` test in the rung-2/7a sense: it pins the driver's
 * actual behavior.  Nothing in rockchip_ebc.c, the forward-port patch,
 * the shim, or any existing test file is modified.
 *
 * 2026-08-24 (issue #22): the SHIPPING driver no longer behaves this way
 * -- it carries the work-item drain gate, and ebc-drain-gate-test pins
 * the guarantee.  This file is unchanged and now compiles against
 * build/nogate, the same extraction with the gate removed
 * (mutate-drain-gate.py, byte-identical to the pre-gate source).  It
 * therefore remains the pinned `quirk:` record of an INHERITED defect --
 * what the m-weigand -> hrdl -> ayakael lineage's published trees still
 * do -- and doubles as the reason to believe the gate is load-bearing.
 * Read every assertion below as "the ungated driver does this".
 *
 * Build (from pinenote/tools/ebc-logic, inside `guix shell gcc-toolchain
 * python`, after `make` has produced build/ and build/fw):
 *   gcc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-maybe-uninitialized \
 *       -g -fsanitize=address -fno-omit-frame-pointer \
 *       -Ishim -Ibuild/include -Ibuild/drivers/gpu/drm \
 *       -Ibuild/drivers/gpu/drm/rockchip \
 *       -o build/ebc-refresh-starvation-test ebc-refresh-starvation-test.c
 * Run:
 *   build/ebc-refresh-starvation-test build/fw
 */

#include "drm_epd_helper.c"	/* verbatim, provides the LUT loader */
#include "rockchip_ebc.c"	/* verbatim driver under test */
#include "fake-ebc.h"		/* the device model behind the regmap */

#include <unistd.h>

/* ---------------------------------------------------------------------- */

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

#define GW 64
#define GH 32

/* How many frames the injector keeps feeding damage.  Far more than any
 * waveform's phase count, and far more than the ~40-frame lifetime of a
 * single area, so "the loop simply has not finished yet" is excluded. */
#define STARVE_FRAMES 300

static void set_px(u8 *buf, u32 pitch, int x, int y, u8 v)
{
	u8 *b = buf + (size_t)y * pitch + x / 2;

	if (x & 1)
		*b = (*b & 0x0f) | (u8)(v << 4);
	else
		*b = (*b & 0xf0) | (v & 0xf);
}

/* ---------------------------------------------------------------------- */
/* harness scaffolding — the same shape ebc-refresh-test.c uses for its
 * WBF-gated real-thread tests (probe, mode set, ctx, worker enable).     */

struct harness {
	struct platform_device pdev;
	struct rockchip_ebc *ebc;
	struct ebc_crtc_state crtc_state;
};

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
	m->flags = DRM_MODE_FLAG_CLKDIV2;

	h->crtc_state.base.crtc = &h->ebc->crtc;
	h->ebc->crtc.state = &h->crtc_state.base;
	rockchip_ebc_crtc_mode_set_nofb(&h->ebc->crtc);
}

static struct rockchip_ebc *wbf_probe(struct harness *h, const char *fwdir)
{
	int ret;

	memset(h, 0, sizeof(*h));
	ebc_shim_reset();
	fake_ebc_install();
	setenv("EBC_SHIM_FW_DIR", fwdir, 1);

	ret = rockchip_ebc_probe(&h->pdev);
	if (ret) {
		printf("FAIL: rockchip_ebc_probe: %d\n", ret);
		failures++;
		return NULL;
	}
	h->ebc = platform_get_drvdata(&h->pdev);
	ebc_shim.rt_resume = rockchip_ebc_runtime_resume;
	ebc_shim.rt_suspend = rockchip_ebc_runtime_suspend;
	ebc_shim.pm_suspended = true;
	return h->ebc;
}

static struct rockchip_ebc_ctx *harness_ctx(struct harness *h, int w, int hgt)
{
	struct rockchip_ebc_ctx *ctx = rockchip_ebc_ctx_alloc(h->ebc, w, hgt);

	h->crtc_state.ctx = ctx;
	memset(ctx->phase[0], 0xff, ctx->phase_size);
	memset(ctx->phase[1], 0xff, ctx->phase_size);
	return ctx;
}

static void harness_enable_worker(struct harness *h)
{
	h->crtc_state.base.mode_changed = true;
	rockchip_ebc_crtc_atomic_enable(&h->ebc->crtc, NULL);
	h->crtc_state.base.mode_changed = false;
}

static void harness_teardown(struct harness *h, struct rockchip_ebc_ctx *ctx)
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
}

/* Replica of rockchip_ebc_plane_atomic_update's commit block (identical
 * to ebc-refresh-test.c's commit_damage; the blit half is rung 2). */
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

/* ---------------------------------------------------------------------- */
/* barrier UAPI helpers (same calls the on-device diagnostic makes)        */

static int barrier_submit(struct rockchip_ebc *ebc, u64 *id)
{
	struct drm_rockchip_ebc_refresh_barrier args = {
		.version = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_VERSION,
		.op = DRM_ROCKCHIP_EBC_REFRESH_BARRIER_SUBMIT,
	};
	int ret = ioctl_refresh_barrier(&ebc->drm, &args, NULL);

	if (ret)
		return ret;
	*id = args.request_id;
	return args.result;
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

/* ---------------------------------------------------------------------- */
/* the reproducer                                                          */

enum starve_shape {
	/* a fresh disjoint rect every frame: the plainest "damage keeps
	 * arriving" supply (KOReader/console scribbling) */
	STARVE_ROTATING,
	/* the same full-screen rect every frame: what fbdev deferred-io
	 * produces for a full-screen mmap write, and what makes
	 * schedule_area chain each new area behind the in-flight one */
	STARVE_FULLSCREEN,
};

static struct rockchip_ebc *starve_ebc;
static struct rockchip_ebc_ctx *starve_ctx;
static enum starve_shape starve_shape;
static int starve_step;		/* schedule_hook step counter */
static unsigned int starve_injected;
static unsigned int starve_submit_frame;
static unsigned long starve_submit_idle_transitions;
static u64 starve_id;
static int starve_submit_result;

/* observations taken at the far end of the starvation window */
static u64 starve_seen_completed;
static u64 starve_seen_active;
static int starve_seen_poison;
static int starve_seen_wait;
static bool starve_seen_flag_pending;
static unsigned long starve_seen_timeouts;
static unsigned long starve_seen_idle_transitions;
static unsigned int starve_seen_dsp_end;
static unsigned int starve_frames_after_submit;
static bool starve_observed;

static void starve_paint(const struct drm_rect *r, u8 v)
{
	int x, y;

	for (y = r->y1; y < r->y2; y++)
		for (x = r->x1; x < r->x2; x++)
			set_px(starve_ctx->final_atomic_update,
			       starve_ctx->gray4_pitch, x, y, v);
}

static void starve_inject_one(unsigned int n)
{
	struct drm_rect r;

	if (starve_shape == STARVE_FULLSCREEN) {
		r.x1 = 0;
		r.y1 = 0;
		r.x2 = GW;
		r.y2 = GH;
	} else {
		/* 8x8 tiles marching across the panel, disjoint per frame */
		unsigned int tiles_x = GW / 8, tiles_y = GH / 8;
		unsigned int t = n % (tiles_x * tiles_y);

		r.x1 = (int)((t % tiles_x) * 8);
		r.y1 = (int)((t / tiles_x) * 8);
		r.x2 = r.x1 + 8;
		r.y2 = r.y1 + 8;
	}
	starve_paint(&r, (u8)(1 + (n % 14)));
	commit_damage(starve_ctx, &r, 1);
}

/* Runs inside the driver's DSP_START register write — i.e. exactly where
 * a concurrent fbdev/atomic damage commit lands on hardware. */
static void starve_frame_hook(u32 hw_frame)
{
	(void)hw_frame;

	if (starve_injected >= STARVE_FRAMES)
		return;

	/* Halfway through the window, do what the on-device diagnostic
	 * did: SUBMIT a barrier generation.  It sets do_one_full_refresh
	 * and wake_up_process()es a thread that is already running. */
	if (starve_injected == STARVE_FRAMES / 2) {
		starve_submit_result = barrier_submit(starve_ebc, &starve_id);
		starve_submit_frame = fake_ebc.dsp_end_irqs;
		starve_submit_idle_transitions = ebc_shim.task_idle_transitions;
	}
	starve_inject_one(starve_injected);
	starve_injected++;

	/* Last injected frame: sample everything the device session
	 * sampled, from inside the still-running partial refresh. */
	if (starve_injected == STARVE_FRAMES && !starve_observed) {
		starve_observed = true;
		mutex_lock(&starve_ebc->barrier_lock);
		starve_seen_completed = starve_ebc->completed_generation;
		starve_seen_active = starve_ebc->active_generation;
		starve_seen_poison = starve_ebc->barrier_poison;
		mutex_unlock(&starve_ebc->barrier_lock);
		spin_lock(&starve_ebc->refresh_once_lock);
		starve_seen_flag_pending = starve_ebc->do_one_full_refresh;
		spin_unlock(&starve_ebc->refresh_once_lock);
		starve_seen_wait = barrier_wait_result(starve_ebc, starve_id, 10000);
		starve_seen_timeouts = ebc_shim.completion_timeouts;
		/* additional TASK_IDLE entries since SUBMIT: the single
		 * priming idle before any damage existed does not count */
		starve_seen_idle_transitions = ebc_shim.task_idle_transitions -
					       starve_submit_idle_transitions;
		starve_seen_dsp_end = fake_ebc.dsp_end_irqs;
		starve_frames_after_submit =
			fake_ebc.dsp_end_irqs - starve_submit_frame;
	}
}

/* First idle: prime the queue so the partial loop has something to chew
 * on.  Second idle: the run is over, let the thread body return. */
static void starve_schedule_hook(void)
{
	if (starve_step == 0)
		starve_inject_one(0);
	else
		ebc_shim.thread_stop = true;
	starve_step++;
}

static unsigned int count_globals(void)
{
	unsigned int i, n = 0;

	for (i = 0; i < fake_ebc.nev; i++)
		n += fake_ebc.ev[i].lut_mode;
	return n;
}

static unsigned int count_partials(void)
{
	unsigned int i, n = 0;

	for (i = 0; i < fake_ebc.nev; i++)
		n += fake_ebc.ev[i].three_win;
	return n;
}

static void test_starvation(const char *fwdir, enum starve_shape shape,
			    const char *label)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct rockchip_ebc_ctx *ctx;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned int partials, globals;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);

	/* Start from the device's steady state: reset already done, no
	 * pending global, and the shipped ebc.scm scheduler budget. */
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	split_area_limit = 0;

	starve_ebc = ebc;
	starve_ctx = ctx;
	starve_shape = shape;
	starve_step = 0;
	starve_injected = 0;
	starve_submit_frame = 0;
	starve_id = 0;
	starve_submit_result = 0;
	starve_observed = false;
	starve_seen_completed = 0;
	starve_seen_active = 0;
	starve_seen_poison = 0;
	starve_seen_wait = 0;
	starve_seen_flag_pending = false;
	starve_seen_timeouts = 0;
	starve_seen_idle_transitions = 0;
	starve_seen_dsp_end = 0;
	starve_frames_after_submit = 0;

	ebc_shim.schedule_hook = starve_schedule_hook;
	fake_ebc.on_frm_start = starve_frame_hook;
	kthread_unpark(ebc->refresh_thread);

	ret = ebc_shim.thread_fn(ebc_shim.thread_data);

	fake_ebc.on_frm_start = NULL;
	partials = count_partials();
	globals = count_globals();

	check(ret == 0 && starve_injected == STARVE_FRAMES && starve_observed,
	      "%s: scripted starvation session ran to completion (%u injected frames)",
	      label, starve_injected);
	check(starve_submit_result == -EINPROGRESS && starve_id == 1,
	      "%s: mid-playback SUBMIT is accepted and returns generation %llu (%d)",
	      label, (unsigned long long)starve_id, starve_submit_result);

	/* --- the reproduction itself --- */
	check(starve_seen_wait == -EINPROGRESS && starve_seen_completed == 0 &&
	      starve_seen_poison == 0,
	      "%s quirk: WAIT still -EINPROGRESS with completed_generation=%llu, poison=%d "
	      "after %u further frames",
	      label, (unsigned long long)starve_seen_completed, starve_seen_poison,
	      starve_frames_after_submit);
	check(starve_seen_flag_pending && starve_seen_active == 0,
	      "%s quirk: do_one_full_refresh is set but unread (active_generation=%llu) — "
	      "the thread never reached the top of the inner loop",
	      label, (unsigned long long)starve_seen_active);
	check(starve_seen_timeouts == 0,
	      "%s quirk: zero completion timeouts across the window — no \"Frame %%d timed out!\", "
	      "no \"Refresh timed out!\", no poison",
	      label);
	check(starve_seen_idle_transitions == 0,
	      "%s quirk: the worker never entered TASK_IDLE after SUBMIT "
	      "(%lu further transitions) — D-state, not I-state",
	      label, starve_seen_idle_transitions);
	/* sampled from inside frame STARVE_FRAMES's DSP_START write, i.e.
	 * before that frame's own DSP_END */
	check(starve_seen_dsp_end >= STARVE_FRAMES - 1,
	      "%s quirk: the EBC kept raising DSP_END throughout (%u interrupts)",
	      label, starve_seen_dsp_end);
	check(starve_frames_after_submit >= STARVE_FRAMES / 2 - 1,
	      "%s quirk: %u frames completed after SUBMIT without crediting the generation",
	      label, starve_frames_after_submit);

	/* --- and the release: starvation, not deadlock --- */
	check(ebc->completed_generation == starve_id && ebc->active_generation == 0 &&
	      barrier_wait_result(ebc, starve_id, 1) == 0,
	      "%s: once the damage supply stops the loop drains and the generation is credited",
	      label);
	check(globals == 1 && partials > STARVE_FRAMES,
	      "%s: exactly one global ran, after %u three-window frames",
	      label, partials);
	check(ebc_shim.completion_timeouts == 0 && ebc_shim.dma_violations == 0 &&
	      fake_ebc.bad_frames == 0 && fake_ebc.frames_unpowered == 0 &&
	      fake_ebc.frm_start_config_dirty == 0 && fake_ebc.event_overflow == 0,
	      "%s: no harness violations (timeouts %lu dma %lu bad %u unpowered %u "
	      "config-dirty %u overflow %u)",
	      label, ebc_shim.completion_timeouts, ebc_shim.dma_violations,
	      fake_ebc.bad_frames, fake_ebc.frames_unpowered,
	      fake_ebc.frm_start_config_dirty, fake_ebc.event_overflow);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	harness_teardown(&h, ctx);
}

/* Control: the identical script with the injector disabled must credit
 * the generation promptly.  Without this, "never credited" could just be
 * a broken harness. */
static unsigned int control_frames_after_submit;

static void control_frame_hook(u32 hw_frame)
{
	(void)hw_frame;
	if (starve_injected == 0) {
		starve_submit_result = barrier_submit(starve_ebc, &starve_id);
		starve_submit_frame = fake_ebc.dsp_end_irqs;
		starve_injected = 1;
	}
}

static void test_control_no_supply(const char *fwdir)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct rockchip_ebc_ctx *ctx;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	split_area_limit = 0;

	starve_ebc = ebc;
	starve_ctx = ctx;
	starve_shape = STARVE_ROTATING;
	starve_step = 0;
	starve_injected = 0;
	starve_id = 0;
	starve_submit_result = 0;
	starve_submit_frame = 0;

	ebc_shim.schedule_hook = starve_schedule_hook;
	fake_ebc.on_frm_start = control_frame_hook;
	kthread_unpark(ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);
	fake_ebc.on_frm_start = NULL;
	control_frames_after_submit = fake_ebc.dsp_end_irqs - starve_submit_frame;

	check(ret == 0 && starve_submit_result == -EINPROGRESS,
	      "control: SUBMIT during a single finite partial refresh");
	check(ebc->completed_generation == starve_id &&
	      barrier_wait_result(ebc, starve_id, 1) == 0 &&
	      control_frames_after_submit < STARVE_FRAMES,
	      "control: with no further damage the generation is credited after %u frames",
	      control_frames_after_submit);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	harness_teardown(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* How sparse may the damage supply be and still starve the barrier?
 * An area lives (num_phases + 2) frames in the partial loop, so a commit
 * arriving at least that often keeps `areas` permanently non-empty.  On
 * the device that is the difference between "a busy reader" and "an idle
 * console with a blinking cursor".                                       */

static unsigned int sweep_period;
static unsigned int sweep_budget;
static unsigned int sweep_frame_ctr;
static unsigned int sweep_drains;		/* loop returned -> TASK_IDLE */
static unsigned int sweep_drains_after_submit;
static bool sweep_submitted;
static u64 sweep_id;

static void sweep_inject(void)
{
	struct drm_rect r = {8, 8, 24, 24};

	starve_paint(&r, (u8)(1 + (sweep_budget % 14)));
	commit_damage(starve_ctx, &r, 1);
	sweep_budget--;
}

static void sweep_frame_hook(u32 hw_frame)
{
	(void)hw_frame;
	sweep_frame_ctr++;
	if (!sweep_submitted && sweep_frame_ctr == 2) {
		sweep_submitted = true;
		barrier_submit(starve_ebc, &sweep_id);
	}
	if (sweep_budget && sweep_frame_ctr % sweep_period == 0)
		sweep_inject();
}

static void sweep_schedule_hook(void)
{
	/* Reaching schedule() means the partial loop returned and the top
	 * of the inner loop (the do_one_full_refresh check) was reached. */
	if (sweep_frame_ctr && sweep_budget) {
		/* only drains *inside* the supply window count; the final
		 * drain once the budget is exhausted is the release path */
		sweep_drains++;
		if (sweep_submitted)
			sweep_drains_after_submit++;
	}
	if (sweep_budget)
		sweep_inject();
	else
		ebc_shim.thread_stop = true;
}

static void test_supply_period_sweep(const char *fwdir)
{
	static const unsigned int periods[] = {1, 8, 16, 32, 38, 39, 40, 41, 48, 64};
	unsigned int i;
	unsigned int largest_starving = 0, smallest_draining = 0;
	unsigned int num_phases = 0;

	for (i = 0; i < ARRAY_SIZE(periods); i++) {
		struct harness h;
		struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
		struct rockchip_ebc_ctx *ctx;
		bool saved_no_off_screen = no_off_screen;
		int saved_split = split_area_limit;

		if (!ebc)
			return;
		harness_mode_set(&h, GW, GH);
		ctx = harness_ctx(&h, GW, GH);
		harness_enable_worker(&h);
		ebc->reset_complete = true;
		ebc->do_one_full_refresh = false;
		no_off_screen = true;
		split_area_limit = 0;

		starve_ebc = ebc;
		starve_ctx = ctx;
		sweep_period = periods[i];
		sweep_budget = 20;
		sweep_frame_ctr = 0;
		sweep_drains = 0;
		sweep_drains_after_submit = 0;
		sweep_submitted = false;
		sweep_id = 0;

		ebc_shim.schedule_hook = sweep_schedule_hook;
		fake_ebc.on_frm_start = sweep_frame_hook;
		kthread_unpark(ebc->refresh_thread);
		ebc_shim.thread_fn(ebc_shim.thread_data);
		fake_ebc.on_frm_start = NULL;

		if (!num_phases)
			num_phases = ebc->lut.num_phases;
		printf("INFO: supply every %2u frames -> %u in-window loop drain(s) after "
		       "SUBMIT, %u frames total -> %s\n",
		       periods[i], sweep_drains_after_submit, sweep_frame_ctr,
		       sweep_drains_after_submit ? "barrier serviced during the supply"
						 : "BARRIER STARVED for the whole supply");
		if (!sweep_drains_after_submit)
			largest_starving = periods[i];
		else if (!smallest_draining)
			smallest_draining = periods[i];

		no_off_screen = saved_no_off_screen;
		split_area_limit = saved_split;
		harness_teardown(&h, ctx);
	}

	/* An area committed on frame f is deleted during frame f+num_phases
	 * (frame_delta > last_phase, patch ~4197), so the list first becomes
	 * empty at the end of that frame: the supply must arrive at least
	 * every num_phases frames.  The sweep must land exactly there. */
	check(largest_starving == num_phases && smallest_draining == num_phases + 1,
	      "sweep: starvation persists up to one commit every %u frames and stops at %u "
	      "— exactly the %u-phase area lifetime of this waveform",
	      largest_starving, smallest_draining, num_phases);
}

int main(int argc, char **argv)
{
	const char *fwdir = argc > 1 ? argv[1] : "";

	if (!fwdir[0]) {
		printf("SKIP: waveform-gated (pass a FWDIR containing rockchip/ebc.wbf)\n");
		printf("RESULT: skipped\n");
		return 0;
	}

	test_control_no_supply(fwdir);
	test_starvation(fwdir, STARVE_ROTATING, "rotating-damage");
	test_starvation(fwdir, STARVE_FULLSCREEN, "fullscreen-damage");
	test_supply_period_sweep(fwdir);

	printf("RESULT: %s\n", failures ? "FAILED" : "ok");
	return failures ? 1 : 0;
}
