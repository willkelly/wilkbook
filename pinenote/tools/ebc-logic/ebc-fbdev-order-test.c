/* ebc-fbdev-order-test: the ONE ebc-logic binary that compiles
 * rockchip_ebc.c's CONFIG_DRM_FBDEV_EMULATION code.
 *
 * =====================================================================
 * WHY THIS FILE EXISTS
 * =====================================================================
 *
 * The host harness compiles the driver under its own config.  Everything
 * behind an #ifdef the shim does not define compiles as the #else stub,
 * so a fully green ebc-logic-check proved *nothing* about the four
 * CONFIG_DRM_FBDEV_EMULATION blocks -- 118 lines carrying defio_delay_ms,
 * the fbdev_probe wrapper, the publish-on-call deferred-io drain, the
 * fbdev resume barrier, and remove()'s teardown of the helper static.
 * That gap bit twice, and both times the only available gate was a
 * hand-written *textual* validator over the patch
 * (pinenote/scripts/preflight/validate-ebc-fbdev-resume-hunk.sh,
 * validate-ebc-global-arm-order-hunk.sh).  Those pin source text, not
 * behaviour, and they drift as the patch is rebased.
 *
 * This binary defines CONFIG_DRM_FBDEV_EMULATION before including the
 * verbatim driver, so those blocks are compiled and executed.
 *
 * =====================================================================
 * WHAT A GREEN RUN HERE DOES *NOT* MEAN  (read before trusting it)
 * =====================================================================
 *
 * The shim workqueue is SYNCHRONOUS: schedule_work() only marks an item
 * pending and flush_work() runs it inline, in the caller's context.  The
 * two-task scheduler below is a strict baton handoff: exactly one of
 * "userspace" and "the refresh thread" runs at a time, and control moves
 * only at wake_up_process() and schedule().
 *
 * That models ORDERING -- which side of the flush a store lands on, and
 * what the refresh thread sees the instant it is woken.  It does NOT
 * model a RACE.  The real system runs a SCHED_FIFO refresh kthread
 * against a SCHED_OTHER kworker on a PREEMPT_RT kernel; the interleavings
 * this harness cannot generate (preemption anywhere but at a wake, two
 * runnable tasks, torn stores, the kworker landing between the flush and
 * the thread's snapshot of ctx->final) are exactly the class the
 * 2026-08-01 publish-on-call work is about.  Nobody may read a green run
 * here as race-freedom.  Race questions about this path remain hardware
 * or code-reading questions.
 *
 * The rest of the standing harness caveats apply unchanged: no
 * electrophoretic optics, and the device model finishes "instantly"
 * (shim/fake-ebc.h).
 *
 * =====================================================================
 * THE CLAIM UNDER TEST (2026-08-04, commit 8665ed8)
 * =====================================================================
 *
 * With pending fbdev damage, ONE GLOBAL_REFRESH ioctl must produce
 * exactly ONE global refresh and ZERO partial refreshes.
 *
 * ioctl_trigger_global_refresh() drains deferred-io.  That drain ends in
 * the damage worker's atomic commit, which splices the damage into
 * ctx->queue and then calls wake_up_process() on the refresh thread.  If
 * do_one_full_refresh is not already set at that instant, the thread
 * wakes, sees no pending full refresh, and runs a complete PARTIAL pass
 * over that damage before the wash: the user sees the page render, then
 * flash, then render again for one refresh request.  Measured on glass
 * 2026-08-04 as 38 partial frames + 1 global IRQ per intent.
 *
 * Units (doc/testing.md): a global refresh costs 1 IRQ whatever its phase
 * count; a partial costs 1 IRQ per frame.  Never compare the two.
 *
 * This test is negative-tested: build/ebc-fbdev-order-test-prefix is the
 * same source compiled against the pre-fix ordering (mutate-prefix-order.py
 * moves the arm back after the drain, which is exactly what 8665ed8
 * changed) and run-tests.sh requires that binary to FAIL.  A test that
 * passes on both orderings would be worthless.
 *
 * Build/run: see the Makefile; run-tests.sh drives it.
 */

#define CONFIG_DRM_FBDEV_EMULATION 1

#include "drm_epd_helper.c"	/* verbatim, provides the LUT loader */
#include "rockchip_ebc.c"	/* verbatim driver under test */
#include "fake-ebc.h"		/* the device model behind the regmap */

#include <pthread.h>
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

/* ---------------------------------------------------------------------- */
/* Two-task cooperative scheduler.
 *
 * One baton, two pthreads, a condvar.  Whoever does not hold the baton is
 * blocked, so shim state needs no further locking and every run is
 * deterministic.  Control moves at exactly two points, which are the two
 * the kernel uses:
 *
 *   wake_up_process()  -> the refresh thread is SCHED_FIFO, so it runs
 *                         immediately and its waker does not proceed
 *                         until the thread blocks again;
 *   schedule()         -> the refresh thread blocks; the baton goes back.
 *
 * See the ORDERING-NOT-RACE caveat at the top of this file.
 */

#define TASK_USER   0
#define TASK_WORKER 1

static pthread_mutex_t sch_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sch_cv = PTHREAD_COND_INITIALIZER;
static int sch_running = TASK_USER;
static pthread_t worker_tid;
static bool worker_started;
static bool worker_done;
static int worker_ret;

static int self_task(void)
{
	if (worker_started && pthread_equal(pthread_self(), worker_tid))
		return TASK_WORKER;
	return TASK_USER;
}

/* Hand the baton to `target` and block until it comes back to us. */
static void sch_switch_to(int target)
{
	int me = self_task();

	pthread_mutex_lock(&sch_lock);
	sch_running = target;
	pthread_cond_broadcast(&sch_cv);
	while (sch_running != me)
		pthread_cond_wait(&sch_cv, &sch_lock);
	pthread_mutex_unlock(&sch_lock);
}

static void *worker_main(void *arg)
{
	(void)arg;

	pthread_mutex_lock(&sch_lock);
	while (sch_running != TASK_WORKER)
		pthread_cond_wait(&sch_cv, &sch_lock);
	pthread_mutex_unlock(&sch_lock);

	/* the verbatim rockchip_ebc_refresh_thread() body */
	worker_ret = ebc_shim.thread_fn(ebc_shim.thread_data);

	pthread_mutex_lock(&sch_lock);
	worker_done = true;
	sch_running = TASK_USER;
	pthread_cond_broadcast(&sch_cv);
	pthread_mutex_unlock(&sch_lock);
	return NULL;
}

/* the driver's refresh thread called schedule(): it is going to sleep */
static void sch_worker_blocked(void)
{
	sch_switch_to(TASK_USER);
}

/* ---------------------------------------------------------------------- */
/* Observations taken at every wake_up_process().                          */

#define MAX_WAKES 32

struct wake_obs {
	bool flag;		/* do_one_full_refresh at the wake */
	bool queue_nonempty;	/* damage published and not yet consumed */
};

static struct wake_obs wakes[MAX_WAKES];
static unsigned int nwakes;

static struct rockchip_ebc *order_ebc;
static struct rockchip_ebc_ctx *order_ctx;

static void order_wake_hook(void)
{
	if (self_task() == TASK_WORKER)
		return;		/* the worker waking itself is a no-op */
	if (!worker_started || worker_done)
		return;

	if (nwakes < MAX_WAKES && order_ebc && order_ctx) {
		spin_lock(&order_ebc->refresh_once_lock);
		wakes[nwakes].flag = order_ebc->do_one_full_refresh;
		spin_unlock(&order_ebc->refresh_once_lock);
		spin_lock(&order_ctx->queue_lock);
		wakes[nwakes].queue_nonempty = !list_empty(&order_ctx->queue);
		spin_unlock(&order_ctx->queue_lock);
		nwakes++;
	}

	/* SCHED_FIFO: it runs now, and we wait for it. */
	sch_switch_to(TASK_WORKER);
}

/* ---------------------------------------------------------------------- */
/* harness scaffolding (the shape ebc-refresh-starvation-test.c uses)      */

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
	memset(&ebc_shim_fb_info, 0, sizeof(ebc_shim_fb_info));
	rockchip_ebc_defio_helper = NULL;
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
	ebc_shim.wake_up_hook = NULL;
	fake_ebc.on_frm_start = NULL;
	order_ebc = NULL;
	order_ctx = NULL;
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
/* The fbdev client: a real drm_fb_helper driven through the driver's own
 * fbdev_probe wrapper, with the damage chain wired the way the fb core
 * wires it (see shim/kernel-shim.h "fbdev emulation").                    */

static struct drm_fb_helper helper;
static struct ebc_plane_state fb_plane_state;
static struct drm_format_info fb_format = { .format = DRM_FORMAT_XRGB8888,
					    .cpp = { 4, 0, 0, 0 } };
static struct drm_framebuffer fb_object;
static u32 *fb_pixels;

/* damage accumulated by "userspace writes" and not yet committed */
#define MAX_DAMAGE 8
static struct drm_rect damage[MAX_DAMAGE];
static unsigned int ndamage;

static unsigned long resume_worker_runs;

/* stands in for drm_fb_helper_resume_worker() */
static void fake_resume_worker(struct work_struct *work)
{
	struct drm_fb_helper *h = container_of(work, struct drm_fb_helper,
					       resume_work);

	resume_worker_runs++;
	h->suspended = false;
	if (h->info)
		h->info->state = FBINFO_STATE_RUNNING;
}

/*
 * What drm_fb_helper_fb_dirty()'s atomic commit does on this driver: hand
 * the accumulated damage clips to the plane and run the driver's REAL
 * atomic update, which blits the fb, drops clips whose pixels did not
 * change, splices the rest into ctx->queue and wakes the refresh thread.
 * The wake at the end of rockchip_ebc_plane_atomic_update() is the wake
 * this whole test is about.
 */
static void fbdev_fb_dirty(struct drm_fb_helper *h)
{
	unsigned int i;

	(void)h;
	for (i = 0; i < ndamage; i++) {
		struct rockchip_ebc_area *a = kmalloc(sizeof(*a), GFP_KERNEL);

		a->clip = damage[i];
		a->frame_begin = EBC_FRAME_PENDING;
		list_add_tail(&a->list, &fb_plane_state.areas);
	}
	ndamage = 0;
	rockchip_ebc_plane_atomic_update(&order_ebc->plane, NULL);
}

static void fbdev_client_attach(struct rockchip_ebc *ebc)
{
	struct drm_fb_helper_surface_size sizes = {
		.surface_width = GW,
		.surface_height = GH,
		.surface_bpp = 32,
		.surface_depth = 24,
		.fb_width = GW,
		.fb_height = GH,
	};
	int ret;

	memset(&helper, 0, sizeof(helper));
	helper.dev = &ebc->drm;
	/* Through the driver's .fbdev_probe slot, not the symbol: that
	 * assignment is itself one of the four guarded blocks, and this is
	 * the call DRM makes from drm_client_setup(). */
	ret = rockchip_ebc_drm_driver.fbdev_probe(&helper, &sizes);
	if (ret) {
		printf("FAIL: rockchip_ebc_fbdev_probe: %d\n", ret);
		failures++;
		return;
	}
	INIT_WORK(&helper.resume_work, fake_resume_worker);
	helper.fb_dirty = fbdev_fb_dirty;

	memset(&fb_plane_state, 0, sizeof(fb_plane_state));
	INIT_LIST_HEAD(&fb_plane_state.areas);
	fb_object.format = &fb_format;
	fb_object.pitches[0] = GW * 4;
	fb_plane_state.base.base.crtc = &ebc->crtc;
	fb_plane_state.base.base.fb = &fb_object;
	fb_plane_state.base.base.src.x1 = 0;
	fb_plane_state.base.base.src.y1 = 0;
	fb_plane_state.base.base.src.x2 = GW << 16;
	fb_plane_state.base.base.src.y2 = GH << 16;
	fb_plane_state.base.base.dst.x1 = 0;
	fb_plane_state.base.base.dst.y1 = 0;
	fb_plane_state.base.base.dst.x2 = GW;
	fb_plane_state.base.base.dst.y2 = GH;
	fb_plane_state.base.data[0].vaddr = fb_pixels;
	ebc->plane.state = &fb_plane_state.base.base;
	ebc->plane.dev = &ebc->drm;
	ndamage = 0;
}

/* "userspace paints a rect into the fbdev mmap and faults the pages" */
static void fbdev_write(const struct drm_rect *r, u32 argb)
{
	int x, y;

	for (y = r->y1; y < r->y2; y++)
		for (x = r->x1; x < r->x2; x++)
			fb_pixels[(size_t)y * GW + x] = argb;
	if (ndamage < MAX_DAMAGE)
		damage[ndamage++] = *r;
	ebc_shim_fbdev_mkwrite(&helper);
}

static int global_refresh_ioctl(struct rockchip_ebc *ebc)
{
	struct drm_rockchip_ebc_trigger_global_refresh args = {
		.trigger_global_refresh = true,
	};

	return ioctl_trigger_global_refresh(&ebc->drm, &args, NULL);
}

/* ---------------------------------------------------------------------- */
/* Block 1a: defio_delay_ms.  No device needed.                            */

static void test_defio_delay_param(void)
{
	struct drm_fb_helper_surface_size sizes = { .surface_width = GW,
						    .surface_height = GH };
	struct drm_fb_helper h1, h2;
	struct kernel_param kp = { .arg = &defio_delay_ms };
	int saved = defio_delay_ms;
	unsigned long live;
	char buf[64];
	int ret;

	ebc_shim_reset();
	memset(&ebc_shim_fb_info, 0, sizeof(ebc_shim_fb_info));
	memset(&h1, 0, sizeof(h1));
	memset(&h2, 0, sizeof(h2));
	rockchip_ebc_defio_helper = NULL;
	defio_delay_ms = 50;

	check(rockchip_ebc_drm_driver.fbdev_probe == rockchip_ebc_fbdev_probe,
	      "the drm_driver publishes the driver's fbdev_probe wrapper to DRM");

	ret = rockchip_ebc_drm_driver.fbdev_probe(&h1, &sizes);
	check(ret == 0 && h1.info != NULL && rockchip_ebc_defio_helper == &h1,
	      "fbdev_probe wraps the vanilla probe and registers the live helper (ret %d)",
	      ret);
	check(h1.fbdefio.delay == msecs_to_jiffies(50),
	      "the default of 50 leaves the flush period bit-identical to vanilla HZ/20 (%lu)",
	      h1.fbdefio.delay);

	/* a sysfs write, exactly as param_attr_store() performs it */
	live = h1.fbdefio.delay;
	ret = defio_delay_ms_ops.set("250\n", &kp);
	check(ret == 0 && defio_delay_ms == 250 &&
	      h1.fbdefio.delay == msecs_to_jiffies(250) &&
	      h1.fbdefio.delay != live,
	      "the setter retargets the LIVE helper (%lu -> %lu jiffies)",
	      live, h1.fbdefio.delay);

	ret = defio_delay_ms_ops.get(buf, &kp);
	check(ret > 0 && atoi(buf) == 250, "param_get_int reads back 250 (%s)",
	      ret > 0 ? buf : "<err>");

	/* range and parse rejection must not disturb the live helper */
	live = h1.fbdefio.delay;
	check(defio_delay_ms_ops.set("0", &kp) == -EINVAL &&
	      defio_delay_ms_ops.set("-1", &kp) == -EINVAL &&
	      defio_delay_ms_ops.set("10001", &kp) == -EINVAL &&
	      defio_delay_ms_ops.set("nonsense", &kp) == -EINVAL &&
	      defio_delay_ms == 250 && h1.fbdefio.delay == live,
	      "out-of-range and unparseable writes are rejected and change nothing");
	check(defio_delay_ms_ops.set("1", &kp) == 0 && defio_delay_ms == 1 &&
	      defio_delay_ms_ops.set("10000", &kp) == 0 && defio_delay_ms == 10000,
	      "the accepted range is exactly [1, 10000] ms");

	/* a later fbdev probe picks up the current value, and takes over */
	defio_delay_ms_ops.set("250", &kp);
	ret = rockchip_ebc_drm_driver.fbdev_probe(&h2, &sizes);
	check(ret == 0 && h2.fbdefio.delay == msecs_to_jiffies(250) &&
	      rockchip_ebc_defio_helper == &h2,
	      "a probe after the write inherits the parameter (%lu jiffies)",
	      h2.fbdefio.delay);

	/* the vanilla probe failing must not register a helper */
	rockchip_ebc_defio_helper = NULL;
	ebc_shim.fbdev_probe_error = -ENOMEM;
	ret = rockchip_ebc_drm_driver.fbdev_probe(&h1, &sizes);
	check(ret == -ENOMEM && rockchip_ebc_defio_helper == NULL,
	      "a failed vanilla probe leaves no live helper (%d)", ret);
	ebc_shim.fbdev_probe_error = 0;

	defio_delay_ms = saved;
	rockchip_ebc_defio_helper = NULL;
	ebc_shim.fb_helper = NULL;
}

/* ---------------------------------------------------------------------- */
/* Block 1b: the fbdev resume barrier.                                     */

static void test_fbdev_resume_barrier(const char *fwdir)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct rockchip_ebc_ctx *ctx;
	unsigned long dropped_before, dirty_before;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	ctx = harness_ctx(&h, GW, GH);
	order_ebc = ebc;
	order_ctx = ctx;
	fbdev_client_attach(ebc);
	resume_worker_runs = 0;

	/* suspend the client the way drm_mode_config_helper_suspend does */
	drm_client_dev_suspend(&ebc->drm, false);
	check(helper.info->state == FBINFO_STATE_SUSPENDED,
	      "fbdev client suspend puts info->state at FBINFO_STATE_SUSPENDED");

	/*
	 * The defect: console_trylock() fails, so the un-suspend is punted
	 * to helper->resume_work and nothing in the resume path waits for
	 * it.  Damage submitted in that window is dropped in silence.
	 */
	ebc_shim.fb_defer_resume = 1;
	drm_client_dev_resume(&ebc->drm, false);
	check(helper.info->state == FBINFO_STATE_SUSPENDED &&
	      resume_worker_runs == 0,
	      "a deferred un-suspend leaves info->state SUSPENDED with the worker unrun");

	dropped_before = ebc_shim.fb_damage_dropped;
	dirty_before = ebc_shim.fb_dirty_calls;
	schedule_work(&helper.damage_work);
	flush_work(&helper.damage_work);
	check(ebc_shim.fb_damage_dropped == dropped_before + 1 &&
	      ebc_shim.fb_dirty_calls == dirty_before,
	      "and damage submitted in that window is dropped before fb_dirty, silently");

	/* the driver's barrier: the same helper, called a second time */
	rockchip_ebc_fbdev_finish_resume();
	check(resume_worker_runs == 1 &&
	      helper.info->state == FBINFO_STATE_RUNNING,
	      "rockchip_ebc_fbdev_finish_resume() completes the deferred un-suspend");

	dropped_before = ebc_shim.fb_damage_dropped;
	dirty_before = ebc_shim.fb_dirty_calls;
	ndamage = 0;
	schedule_work(&helper.damage_work);
	flush_work(&helper.damage_work);
	check(ebc_shim.fb_damage_dropped == dropped_before &&
	      ebc_shim.fb_dirty_calls == dirty_before + 1,
	      "after the barrier damage reaches drm_fb_helper_fb_dirty() again");

	/* it must also be free when the first call already took the lock */
	ebc_shim.fb_defer_resume = 0;
	drm_client_dev_suspend(&ebc->drm, false);
	drm_client_dev_resume(&ebc->drm, false);
	resume_worker_runs = 0;
	rockchip_ebc_fbdev_finish_resume();
	check(helper.info->state == FBINFO_STATE_RUNNING &&
	      resume_worker_runs == 0,
	      "with no deferral the second call costs nothing and changes nothing");

	rockchip_ebc_defio_helper = NULL;
	harness_teardown(&h, ctx);
}

/* ---------------------------------------------------------------------- */
/* Block 4: remove() clears the static under the param lock.               */

static void test_remove_clears_helper(const char *fwdir)
{
	struct harness h;
	struct rockchip_ebc *ebc = wbf_probe(&h, fwdir);
	struct kernel_param kp = { .arg = &defio_delay_ms };
	int saved = defio_delay_ms;
	unsigned long live;

	if (!ebc)
		return;
	harness_mode_set(&h, GW, GH);
	order_ebc = ebc;
	fbdev_client_attach(ebc);
	check(rockchip_ebc_defio_helper == &helper,
	      "remove: a live fbdev helper is registered before teardown");

	rockchip_ebc_remove(&h.pdev);
	check(rockchip_ebc_defio_helper == NULL,
	      "remove() clears the helper static before the fbdev client is freed");
	check(ebc_shim.param_lock_calls == 1 && ebc_shim.param_unlock_calls == 1 &&
	      !ebc_shim.param_locked,
	      "and it does so under kernel_param_lock/unlock (%lu/%lu)",
	      ebc_shim.param_lock_calls, ebc_shim.param_unlock_calls);

	/* the point of the block: a later sysfs write must not chase the
	 * dangling helper.  (Under ASan a stale pointer here would be a
	 * use-after-free the moment the helper's storage went away.) */
	live = helper.fbdefio.delay;
	check(defio_delay_ms_ops.set("77", &kp) == 0 && defio_delay_ms == 77 &&
	      helper.fbdefio.delay == live,
	      "a param write after remove() updates the value and touches no helper");

	defio_delay_ms = saved;
	drm_epd_lut_free(&ebc->drm, &ebc->lut);
	drm_epd_lut_file_free(&ebc->drm, &ebc->lut_file);
	free(ebc);
	order_ebc = NULL;
}

/* ---------------------------------------------------------------------- */
/* Block 2 (and block 3): publish-on-call ordering.                        */

struct order_result {
	unsigned int globals;
	unsigned int partials;
	unsigned int irqs;
	unsigned int wake_with_stale_damage;	/* wake, damage queued, no wash armed */
	bool painted;				/* the panel shows the new page */
	int ioctl_ret;
};

/*
 * Bring a device up with a live fbdev client and the refresh thread
 * running on the second task, parked at its first schedule().
 */
static bool order_setup(struct harness *h, struct rockchip_ebc_ctx **ctxp,
			const char *fwdir)
{
	struct rockchip_ebc *ebc = wbf_probe(h, fwdir);
	struct rockchip_ebc_ctx *ctx;

	if (!ebc)
		return false;
	harness_mode_set(h, GW, GH);
	ctx = harness_ctx(h, GW, GH);
	harness_enable_worker(h);

	/* the device's steady state: reset done, no pending wash, the
	 * shipped ebc.scm scheduler budget */
	ebc->reset_complete = true;
	ebc->do_one_full_refresh = false;
	no_off_screen = true;
	split_area_limit = 0;

	order_ebc = ebc;
	order_ctx = ctx;
	*ctxp = ctx;

	fbdev_client_attach(ebc);

	nwakes = 0;
	worker_started = false;
	worker_done = false;
	worker_ret = -1;
	sch_running = TASK_USER;

	ebc_shim.schedule_hook = sch_worker_blocked;
	ebc_shim.wake_up_hook = order_wake_hook;
	kthread_unpark(ebc->refresh_thread);

	if (pthread_create(&worker_tid, NULL, worker_main, NULL)) {
		printf("FAIL: pthread_create\n");
		failures++;
		return false;
	}
	worker_started = true;
	/* let it run its startup and settle at its first schedule() */
	sch_switch_to(TASK_WORKER);
	return true;
}

static void order_teardown(struct harness *h, struct rockchip_ebc_ctx *ctx)
{
	ebc_shim.thread_stop = true;
	if (worker_started && !worker_done)
		sch_switch_to(TASK_WORKER);
	if (worker_started)
		pthread_join(worker_tid, NULL);
	worker_started = false;
	rockchip_ebc_defio_helper = NULL;
	harness_teardown(h, ctx);
}

static unsigned int count_stale_wakes(void)
{
	unsigned int i, n = 0;

	for (i = 0; i < nwakes; i++)
		if (wakes[i].queue_nonempty && !wakes[i].flag)
			n++;
	return n;
}

static bool panel_shows_new_page(struct rockchip_ebc_ctx *ctx)
{
	u32 i;
	bool nonblank = false;

	for (i = 0; i < ctx->gray4_size; i++)
		if (ctx->final_atomic_update[i]) {
			nonblank = true;
			break;
		}
	/* after a refresh, ctx->prev is what the panel is showing */
	return nonblank &&
	       !memcmp(ctx->prev, ctx->final_atomic_update, ctx->gray4_size);
}

/*
 * THE TEST.  One page's worth of fbdev damage is pending (written, its
 * deferred-io flush armed, nothing committed), then userspace makes one
 * GLOBAL_REFRESH call.
 */
static void test_one_intent_one_pass(const char *fwdir)
{
	struct drm_rect page = { 0, 0, GW, GH };
	struct harness h;
	struct rockchip_ebc_ctx *ctx = NULL;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	struct order_result r;
	unsigned int g0, p0, i0;
	bool armed_pending;
	bool queue_was_empty;

	if (!order_setup(&h, &ctx, fwdir))
		return;

	fbdev_write(&page, 0x00808080);

	spin_lock(&ctx->queue_lock);
	queue_was_empty = list_empty(&ctx->queue);
	spin_unlock(&ctx->queue_lock);
	armed_pending = helper.info->deferred_work.work.pending;
	check(armed_pending && queue_was_empty && !order_ebc->do_one_full_refresh,
	      "precondition: fbdev damage is pending in deferred-io, ctx->queue is empty, no wash armed");

	g0 = count_globals();
	p0 = count_partials();
	i0 = fake_ebc.dsp_end_irqs;
	nwakes = 0;

	r.ioctl_ret = global_refresh_ioctl(order_ebc);

	r.globals = count_globals() - g0;
	r.partials = count_partials() - p0;
	r.irqs = fake_ebc.dsp_end_irqs - i0;
	r.wake_with_stale_damage = count_stale_wakes();
	r.painted = panel_shows_new_page(ctx);

	check(r.ioctl_ret == 0, "GLOBAL_REFRESH returns 0 (%d)", r.ioctl_ret);
	check(ebc_shim.flush_delayed_work_calls == 1 &&
	      ebc_shim.fb_deferred_io_calls == 1 &&
	      ebc_shim.fb_damage_work_calls == 1 && ebc_shim.fb_dirty_calls == 1,
	      "the ioctl drained deferred-io all the way through the damage worker "
	      "(defio %lu, damage %lu, dirty %lu)",
	      ebc_shim.fb_deferred_io_calls, ebc_shim.fb_damage_work_calls,
	      ebc_shim.fb_dirty_calls);

	/* --- the claim --- */
	check(r.globals == 1 && r.partials == 0,
	      "one GLOBAL_REFRESH intent costs exactly one global refresh and ZERO "
	      "partial refreshes (globals %u, partial frames %u)",
	      r.globals, r.partials);
	check(r.irqs == 1,
	      "and exactly 1 EBC completion IRQ -- the global's single transaction "
	      "(doc/testing.md units) (%u)", r.irqs);
	check(r.wake_with_stale_damage == 0,
	      "no wake_up_process() published damage to an unarmed refresh thread "
	      "(%u of %u wakes)", r.wake_with_stale_damage, nwakes);
	check(r.painted,
	      "the wash painted the page userspace had written when it called");

	check(ebc_shim.completion_timeouts == 0 && ebc_shim.dma_violations == 0 &&
	      fake_ebc.bad_frames == 0 && fake_ebc.frames_unpowered == 0 &&
	      fake_ebc.frm_start_config_dirty == 0 && fake_ebc.event_overflow == 0,
	      "no harness violations (timeouts %lu dma %lu bad %u unpowered %u "
	      "config-dirty %u overflow %u)",
	      ebc_shim.completion_timeouts, ebc_shim.dma_violations,
	      fake_ebc.bad_frames, fake_ebc.frames_unpowered,
	      fake_ebc.frm_start_config_dirty, fake_ebc.event_overflow);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	order_teardown(&h, ctx);
}

/*
 * Control, per doc/testing.md "absence of an error is not a passing test":
 * the SAME damage, delivered the ordinary way (the deferred-io timer
 * fires, no ioctl), must cost a full PARTIAL pass and zero globals.
 * Without this, "0 partial frames" above could just mean the harness
 * cannot produce a partial frame at all.
 */
static void test_control_timer_flush_costs_a_partial_pass(const char *fwdir)
{
	struct drm_rect page = { 0, 0, GW, GH };
	struct harness h;
	struct rockchip_ebc_ctx *ctx = NULL;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned int g0, p0, i0, globals, partials, irqs;

	if (!order_setup(&h, &ctx, fwdir))
		return;

	fbdev_write(&page, 0x00808080);

	g0 = count_globals();
	p0 = count_partials();
	i0 = fake_ebc.dsp_end_irqs;
	nwakes = 0;

	/* the deferred-io timer expires: exactly what the driver's drain
	 * runs, minus the wash */
	flush_delayed_work(&helper.info->deferred_work);
	flush_work(&helper.damage_work);

	globals = count_globals() - g0;
	partials = count_partials() - p0;
	irqs = fake_ebc.dsp_end_irqs - i0;

	check(globals == 0 && partials > 1,
	      "control: the same damage flushed by the timer costs a full partial "
	      "pass and no global (globals %u, partial frames %u)",
	      globals, partials);
	check(partials == order_ebc->lut.num_phases && irqs == partials,
	      "control: that is one pass of this waveform (%u frames, %u phases) "
	      "at 1 IRQ per frame (%u)",
	      partials, order_ebc->lut.num_phases, irqs);
	check(count_stale_wakes() == 1,
	      "control: and its wake DID publish damage to an unarmed thread "
	      "(%u of %u wakes) -- the observation the ordering test rules out",
	      count_stale_wakes(), nwakes);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	order_teardown(&h, ctx);
}

/*
 * Second control: a GLOBAL_REFRESH with nothing pending is still exactly
 * one global, so the count above is not an artefact of the drain.
 */
static void test_control_no_pending_damage(const char *fwdir)
{
	struct harness h;
	struct rockchip_ebc_ctx *ctx = NULL;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned int g0, p0, globals, partials;
	int ret;

	if (!order_setup(&h, &ctx, fwdir))
		return;

	g0 = count_globals();
	p0 = count_partials();
	nwakes = 0;

	ret = global_refresh_ioctl(order_ebc);
	globals = count_globals() - g0;
	partials = count_partials() - p0;

	check(ret == 0 && globals == 1 && partials == 0,
	      "control: GLOBAL_REFRESH with no pending fbdev damage is one global, "
	      "no partial (ret %d, globals %u, partials %u)", ret, globals, partials);
	check(ebc_shim.flush_delayed_work_calls == 1 &&
	      ebc_shim.fb_deferred_io_calls == 0,
	      "control: the drain still ran, and found nothing to flush (%lu/%lu)",
	      ebc_shim.flush_delayed_work_calls, ebc_shim.fb_deferred_io_calls);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	order_teardown(&h, ctx);
}

/*
 * The barrier checks must precede the arm: an ioctl that returns an error
 * may not leave do_one_full_refresh latched for some later, unrelated
 * wake to act on.
 */
static void test_error_return_leaves_no_latched_wash(const char *fwdir)
{
	struct harness h;
	struct rockchip_ebc_ctx *ctx = NULL;
	bool saved_no_off_screen = no_off_screen;
	int saved_split = split_area_limit;
	unsigned int g0, p0;
	int ret;

	if (!order_setup(&h, &ctx, fwdir))
		return;

	g0 = count_globals();
	p0 = count_partials();

	mutex_lock(&order_ebc->barrier_lock);
	order_ebc->worker_available = false;
	mutex_unlock(&order_ebc->barrier_lock);

	ret = global_refresh_ioctl(order_ebc);
	check(ret == -ENODEV, "an unavailable worker fails the ioctl (%d)", ret);
	check(!order_ebc->do_one_full_refresh,
	      "and leaves no latched wash behind");
	check(ebc_shim.flush_delayed_work_calls == 0 &&
	      count_globals() == g0 && count_partials() == p0,
	      "and drains nothing and refreshes nothing");

	mutex_lock(&order_ebc->barrier_lock);
	order_ebc->worker_available = true;
	mutex_unlock(&order_ebc->barrier_lock);

	no_off_screen = saved_no_off_screen;
	split_area_limit = saved_split;
	order_teardown(&h, ctx);
}

/* ---------------------------------------------------------------------- */

int main(int argc, char **argv)
{
	const char *fwdir = argc > 1 ? argv[1] : "";

	fb_pixels = calloc((size_t)GW * GH, sizeof(*fb_pixels));
	if (!fb_pixels)
		return 2;

	test_defio_delay_param();

	if (!fwdir[0]) {
		printf("SKIP: waveform-gated (pass a FWDIR containing rockchip/ebc.wbf)\n");
		printf("RESULT: %s\n", failures ? "FAILED" : "skipped");
		free(fb_pixels);
		return failures ? 1 : 0;
	}

	test_fbdev_resume_barrier(fwdir);
	test_remove_clears_helper(fwdir);
	test_control_no_pending_damage(fwdir);
	test_control_timer_flush_costs_a_partial_pass(fwdir);
	test_one_intent_one_pass(fwdir);
	test_error_return_leaves_no_latched_wash(fwdir);

	free(fb_pixels);
	printf("RESULT: %s\n", failures ? "FAILED" : "ok");
	return failures ? 1 : 0;
}
