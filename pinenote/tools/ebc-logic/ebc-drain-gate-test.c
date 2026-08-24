/* ebc-drain-gate-test: the positive counterpart to
 * ebc-refresh-starvation-test.c.
 *
 * =====================================================================
 * THE CLAIM UNDER TEST (issue #22)
 * =====================================================================
 *
 * While a *work item* is pending -- a queued global refresh (the
 * REFRESH_BARRIER / GLOBAL_REFRESH / resume / auto-refresh wash), or the
 * refresh kthread being parked or stopped -- rockchip_ebc_partial_refresh
 * must STOP folding newly arrived damage into its local `areas` list, so
 * that the list drains within one area lifetime and the refresh thread
 * gets back to the top of its inner loop.
 *
 * Without that gate, rockchip_ebc_partial_refresh's only exit is
 * `list_empty(&areas)` and it re-splices ctx->queue into `areas` every
 * frame, so a damage supply arriving at least once per area lifetime
 * keeps the list permanently non-empty and the queued global never runs.
 * That is the 2026-07-29 hardware failure -- CLAUDE.md's "sustained
 * damage starves the global-refresh path" standing lesson, which the
 * project otherwise handles by PROCEDURE (vt.global_cursor_default=0,
 * unbinding fbcon, requiring EBC-idle before supervised campaigns).
 * ebc-refresh-starvation-test.c pins that defect against the *ungated*
 * driver (build/nogate, produced by mutate-drain-gate.py); this binary
 * pins the guarantee against the shipping one.
 *
 * The two binaries are built from the same extraction and run back to
 * back by run-tests.sh, which additionally requires
 * ebc-drain-gate-test-nogate -- this same source compiled against the
 * ungated driver -- to FAIL.  A liveness test that passes with and
 * without the gate would prove nothing.
 *
 * =====================================================================
 * WHAT A GREEN RUN HERE DOES *NOT* MEAN
 * =====================================================================
 *
 * - Nothing here has run on glass.  The gate changes which frames the
 *   panel is driven with; only a hardware session can say what that
 *   looks like.  The harness validates bookkeeping and ordering.
 * - The device model completes every frame instantly and this is a
 *   single-stack, scripted run: it models ORDERING, never a race (see
 *   ebc-fbdev-order-test.c's header and doc/testing.md).
 * - Waveform-gated, for the same reason the starvation test is: the
 *   drain bound IS the waveform's phase count, so without a real .wbf
 *   there is no number to assert.  It skips cleanly.
 *
 * Build/run: see the Makefile; run-tests.sh drives it.
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

/* The supply window.  Far longer than any waveform's phase count, so
 * "the loop simply has not finished yet" is excluded, and long enough
 * that the whole drain-plus-wash still lands well inside it. */
#define SUPPLY_FRAMES	300
#define SUBMIT_AT	60	/* commits of supply before the work item */
/* Runaway guard: the ungated driver never returns from the partial loop,
 * so every scenario needs a hard stop that does not depend on the fix. */
#define WATCHDOG_FRAMES	3000

static void set_px(u8 *buf, u32 pitch, int x, int y, u8 v)
{
	u8 *b = buf + (size_t)y * pitch + x / 2;

	if (x & 1)
		*b = (*b & 0x0f) | (u8)(v << 4);
	else
		*b = (*b & 0xf0) | (v & 0xf);
}

/* ---------------------------------------------------------------------- */
/* harness scaffolding -- the same shape ebc-refresh-starvation-test.c
 * and ebc-refresh-test.c use for their real-thread tests.               */

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
	ebc_shim.parkme_hook = NULL;
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
/* the damage supply (same two shapes the starvation reproducer uses)      */

enum supply_shape {
	/* a fresh disjoint rect every frame: the plainest "damage keeps
	 * arriving" supply (KOReader/console scribbling, ink strokes) */
	SUPPLY_ROTATING,
	/* the same full-screen rect every frame: what fbdev deferred-io
	 * produces for a full-screen mmap write */
	SUPPLY_FULLSCREEN,
};

static struct rockchip_ebc *g_ebc;
static struct rockchip_ebc_ctx *g_ctx;
static enum supply_shape g_shape;
static unsigned int g_injected;

static void supply_paint(const struct drm_rect *r, u8 v)
{
	int x, y;

	for (y = r->y1; y < r->y2; y++)
		for (x = r->x1; x < r->x2; x++)
			set_px(g_ctx->final_atomic_update,
			       g_ctx->gray4_pitch, x, y, v);
}

static void inject_one(unsigned int n)
{
	struct drm_rect r;

	if (g_shape == SUPPLY_FULLSCREEN) {
		r.x1 = 0;
		r.y1 = 0;
		r.x2 = GW;
		r.y2 = GH;
	} else {
		/* 8x8 tiles marching across the panel, disjoint per commit */
		unsigned int tiles_x = GW / 8;
		unsigned int tiles_y = GH / 8;
		unsigned int t = n % (tiles_x * tiles_y);

		r.x1 = (int)((t % tiles_x) * 8);
		r.y1 = (int)((t / tiles_x) * 8);
		r.x2 = r.x1 + 8;
		r.y2 = r.y1 + 8;
	}
	supply_paint(&r, (u8)(1 + (n % 14)));
	commit_damage(g_ctx, &r, 1);
}

/* The supply must survive the loop actually returning: once the gate
 * works, rockchip_ebc_partial_refresh DOES come back, and if the only
 * injector were the DSP_START hook the run would stall right there. */
static void supply_schedule_hook(void)
{
	if (g_injected < SUPPLY_FRAMES)
		inject_one(g_injected++);
	else
		ebc_shim.thread_stop = true;
}

static void watchdog(void)
{
	if (fake_ebc.dsp_end_irqs > WATCHDOG_FRAMES)
		ebc_shim.thread_stop = true;
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

/* ---------------------------------------------------------------------- */
/* Scenario 1: a queued global overtakes a sustained damage supply.        */

static u64 gate_id;
static int gate_submit_result;
static unsigned int gate_submit_dsp;	/* DSP_END count at SUBMIT */
static unsigned int gate_credit_dsp;	/* DSP_END count when credited */
static unsigned int gate_credit_injected;
static unsigned int gate_globals_at_credit;
static bool gate_credited;

static void gate_frame_hook(u32 hw_frame)
{
	u64 completed;

	(void)hw_frame;
	watchdog();

	if (g_injected < SUPPLY_FRAMES) {
		if (g_injected == SUBMIT_AT) {
			gate_submit_result = barrier_submit(g_ebc, &gate_id);
			gate_submit_dsp = fake_ebc.dsp_end_irqs;
		}
		inject_one(g_injected++);
	}

	if (gate_id && !gate_credited) {
		mutex_lock(&g_ebc->barrier_lock);
		completed = g_ebc->completed_generation;
		mutex_unlock(&g_ebc->barrier_lock);
		if (completed >= gate_id) {
			gate_credited = true;
			gate_credit_dsp = fake_ebc.dsp_end_irqs;
			gate_credit_injected = g_injected;
			gate_globals_at_credit = count_globals();
		}
	}
}

static void test_gate(const char *fwdir, enum supply_shape shape,
		      const char *label)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct rockchip_ebc_ctx *ctx;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned int num_phases, bound, delta = 0;
	unsigned int partials, globals, partials_after_credit;
	int ret;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	harness_enable_worker(&h);

	/* the device's steady state: reset already done, no pending
	 * global, and the shipped ebc.scm scheduler budget */
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	split_area_limit = 0;

	g_ebc = ebc;
	g_ctx = ctx;
	g_shape = shape;
	g_injected = 0;
	gate_id = 0;
	gate_submit_result = 0;
	gate_submit_dsp = 0;
	gate_credit_dsp = 0;
	gate_credit_injected = 0;
	gate_globals_at_credit = 0;
	gate_credited = false;

	ebc_shim.schedule_hook = supply_schedule_hook;
	fake_ebc.on_frm_start = gate_frame_hook;
	kthread_unpark(ebc->refresh_thread);

	ret = ebc_shim.thread_fn(ebc_shim.thread_data);

	fake_ebc.on_frm_start = NULL;
	partials = count_partials();
	globals = count_globals();
	partials_after_credit = gate_credited && partials > gate_credit_dsp ?
				partials - gate_credit_dsp : 0;
	if (gate_credited)
		delta = gate_credit_dsp - gate_submit_dsp;
	/* Read the phase count AFTER the run: rockchip_ebc_refresh selects
	 * and loads the LUT for default_waveform, so lut.num_phases is only
	 * the partial waveform's own phase count once a partial has run. */
	num_phases = ebc->lut.num_phases;
	/* An area committed on frame f is deleted during frame
	 * f + num_phases.  Once folding stops, everything still in the
	 * list is at most one lifetime from the end -- plus whatever
	 * chaining rockchip_ebc_schedule_area already applied to
	 * collisions in flight.  Two lifetimes is a generous ceiling and
	 * still far below the ungated driver's "never". */
	bound = 2 * num_phases;

	check(ret == 0 && g_injected == SUPPLY_FRAMES &&
	      fake_ebc.dsp_end_irqs <= WATCHDOG_FRAMES,
	      "%s: scripted session ran to completion (%u injected commits, %u frames)",
	      label, g_injected, fake_ebc.dsp_end_irqs);
	check(gate_submit_result == -EINPROGRESS && gate_id == 1,
	      "%s: mid-supply SUBMIT is accepted and returns generation %llu (%d)",
	      label, (unsigned long long)gate_id, gate_submit_result);

	/* --- the guarantee --- */
	check(gate_credited,
	      "%s: the queued global LAUNCHED while damage kept arriving",
	      label);
	check(gate_credited && gate_credit_injected < SUPPLY_FRAMES,
	      "%s: it launched with the supply still running (%u of %u commits injected)",
	      label, gate_credit_injected, SUPPLY_FRAMES);
	check(gate_credited && delta <= bound,
	      "%s: credited %u frames after SUBMIT (bound %u = 2 x the %u-phase area lifetime)",
	      label, delta, bound, num_phases);
	check(gate_credited && gate_globals_at_credit == 1,
	      "%s: exactly one global refresh had run at credit time (%u)",
	      label, gate_globals_at_credit);
	check(barrier_wait_result(ebc, gate_id, 1) == 0 &&
	      ebc->completed_generation == gate_id &&
	      ebc->active_generation == 0 && ebc->barrier_poison == 0,
	      "%s: WAIT returns 0, no poison, no generation left active",
	      label);

	/* --- and the damage the gate deferred is not dropped --- */
	check(partials_after_credit > 0,
	      "%s: partial refreshes resume after the wash (%u further frames)",
	      label, partials_after_credit);
	check(list_empty(&ctx->queue),
	      "%s: the damage queue is empty at the end -- nothing deferred was stranded",
	      label);
	check(globals == 1 && partials > SUPPLY_FRAMES / 2,
	      "%s: one global, %u three-window frames",
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

/* ---------------------------------------------------------------------- */
/* Scenario 2: the gate must be IDLE when no work item is pending.
 *
 * A "fix" that simply stopped folding damage mid-refresh would pass
 * scenario 1 and destroy the reason the driver splices at all: a
 * continuous damage supply has to run as ONE partial refresh, not as a
 * separate pass per commit.  This pins that the ungated path is
 * unchanged.                                                            */

static unsigned long idle_transitions_at_first_frame;
static bool idle_baseline_taken;

static void control_frame_hook(u32 hw_frame)
{
	(void)hw_frame;
	watchdog();
	if (!idle_baseline_taken) {
		idle_baseline_taken = true;
		idle_transitions_at_first_frame = ebc_shim.task_idle_transitions;
	}
	if (g_injected < SUPPLY_FRAMES)
		inject_one(g_injected++);
}

static void test_no_work_item_no_gate(const char *fwdir, const char *label)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct rockchip_ebc_ctx *ctx;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned long transitions;
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

	g_ebc = ebc;
	g_ctx = ctx;
	g_shape = SUPPLY_ROTATING;
	g_injected = 0;
	idle_baseline_taken = false;
	idle_transitions_at_first_frame = 0;

	ebc_shim.schedule_hook = supply_schedule_hook;
	fake_ebc.on_frm_start = control_frame_hook;
	kthread_unpark(ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);
	fake_ebc.on_frm_start = NULL;

	/* The final drain (supply exhausted) is the ONE inner-loop return
	 * this scenario may show; it is what lets the run stop. */
	transitions = ebc_shim.task_idle_transitions -
		      idle_transitions_at_first_frame;

	check(ret == 0 && g_injected == SUPPLY_FRAMES,
	      "%s: control session ran to completion (%u injected commits)",
	      label, g_injected);
	check(transitions <= 1,
	      "%s: with no work item pending the partial loop still runs as ONE "
	      "continuous refresh (%lu inner-loop returns)",
	      label, transitions);
	check(count_globals() == 0,
	      "%s: and no global refresh happened (%u)", label, count_globals());
	check(count_partials() >= SUPPLY_FRAMES,
	      "%s: %u three-window frames for %u commits",
	      label, count_partials(), SUPPLY_FRAMES);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	harness_teardown(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* Scenario 3: a park request is a work item too.
 *
 * rockchip_ebc_quiesce_worker() calls kthread_park(), which BLOCKS until
 * the thread parks itself.  The partial loop only ever tested
 * kthread_should_stop(), so under a sustained supply a system suspend
 * would block in kthread_park for as long as the supply lasted.         */

static unsigned int park_request_dsp;
static unsigned int park_reached_dsp;
static unsigned int park_injected_at_park;
static bool park_requested;
static bool park_reached;

static void park_parkme_hook(void)
{
	if (!park_reached) {
		park_reached = true;
		park_reached_dsp = fake_ebc.dsp_end_irqs;
	}
	/* let the scripted run end rather than spin in the outer loop */
	ebc_shim.thread_parked = false;
	ebc_shim.thread_stop = true;
}

static void park_frame_hook(u32 hw_frame)
{
	(void)hw_frame;
	watchdog();
	if (g_injected < SUPPLY_FRAMES) {
		if (g_injected == SUBMIT_AT && !park_requested) {
			park_requested = true;
			park_request_dsp = fake_ebc.dsp_end_irqs;
			park_injected_at_park = g_injected;
			kthread_park(g_ebc->refresh_thread);
		}
		inject_one(g_injected++);
	}
}

static void test_park_drains(const char *fwdir, const char *label)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct rockchip_ebc_ctx *ctx;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned int num_phases, bound, delta = 0;
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

	g_ebc = ebc;
	g_ctx = ctx;
	g_shape = SUPPLY_ROTATING;
	g_injected = 0;
	park_requested = false;
	park_reached = false;
	park_request_dsp = 0;
	park_reached_dsp = 0;
	park_injected_at_park = 0;

	ebc_shim.schedule_hook = supply_schedule_hook;
	ebc_shim.parkme_hook = park_parkme_hook;
	fake_ebc.on_frm_start = park_frame_hook;
	kthread_unpark(ebc->refresh_thread);
	ret = ebc_shim.thread_fn(ebc_shim.thread_data);
	fake_ebc.on_frm_start = NULL;
	ebc_shim.parkme_hook = NULL;
	if (park_reached)
		delta = park_reached_dsp - park_request_dsp;
	num_phases = ebc->lut.num_phases;	/* see test_gate: read it after */
	bound = 2 * num_phases;

	check(ret == 0 && park_requested,
	      "%s: park requested %u commits into a live supply",
	      label, park_injected_at_park);
	check(park_reached,
	      "%s: the thread reached kthread_parkme() with damage still arriving",
	      label);
	check(park_reached && delta <= bound,
	      "%s: parked %u frames after the request (bound %u = 2 x the %u-phase "
	      "area lifetime)", label, delta, bound, num_phases);
	check(park_reached && g_injected < SUPPLY_FRAMES,
	      "%s: and it parked before the supply ran out (%u of %u)",
	      label, g_injected, SUPPLY_FRAMES);
	check(ebc_shim.completion_timeouts == 0 && fake_ebc.bad_frames == 0,
	      "%s: no harness violations (timeouts %lu bad %u)",
	      label, ebc_shim.completion_timeouts, fake_ebc.bad_frames);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	harness_teardown(&h, ctx);
}

/* ---------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	const char *fwdir = argc > 1 ? argv[1] : "";

	if (!fwdir[0]) {
		printf("SKIP: waveform-gated (pass a FWDIR containing rockchip/ebc.wbf)\n");
		printf("RESULT: skipped\n");
		return 0;
	}

	test_gate(fwdir, SUPPLY_ROTATING, "rotating-damage");
	test_gate(fwdir, SUPPLY_FULLSCREEN, "fullscreen-damage");
	test_no_work_item_no_gate(fwdir, "no-work-item");
	test_park_drains(fwdir, "park");

	printf("RESULT: %s\n", failures ? "FAILED" : "ok");
	return failures ? 1 : 0;
}
