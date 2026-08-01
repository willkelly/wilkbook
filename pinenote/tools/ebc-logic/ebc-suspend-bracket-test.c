/* ebc-suspend-bracket-test: pins the 2026-08-01 system-sleep bracket.
 *
 * Hardware finding (os2, two reproductions -- doc/status.md 2026-08-01):
 * the DRM helper invokes atomic_disable only for an ACTIVE CRTC and
 * atomic_enable only for an active commit, while the mode_changed-gated
 * ctx swap in atomic_check always runs across a system sleep.  A blanked
 * fbdev CRTC therefore had its ctx freed under a never-parked refresh
 * thread, whose per-unpark ctx re-read never re-ran: every later refresh
 * was a silent zero-frame no-op that still power-cycled the rails.
 *
 * The fix routes both CRTC hooks through idempotent helpers that the
 * system PM callbacks also call unconditionally:
 *   rockchip_ebc_quiesce_worker() -- park once, poison-if-pending once;
 *   rockchip_ebc_wake_worker()    -- recompute worker_available, unpark
 *                                    only when a ctx exists.
 * This test drives those helpers directly (single-TU verbatim driver,
 * same pattern as the starvation test) and pins:
 *   1. quiesce parks exactly once; a second quiesce is a no-op;
 *   2. wake unparks and re-arms worker_available; double wake is safe;
 *   3. a pending barrier generation poisons exactly once, and the
 *      poison logs (the 2026-08-01 observability line);
 *   4. wake with no ctx must NOT unpark (the outer-loop top would
 *      dereference NULL) and must leave the bracket in place;
 *   5. poison gates worker_available across a wake, but the unpark
 *      itself still happens (the thread must be able to reach its
 *      parkme/poison handling).
 *
 * Build/run: wired into the ebc-logic Makefile `check` target; not
 * waveform-gated (no refresh machinery is exercised).
 */

#include "drm_epd_helper.c"	/* verbatim, satisfies rockchip_ebc.c */
#include "rockchip_ebc.c"	/* verbatim driver under test */

#include <stdio.h>

static int failures;
#define check(cond, msg) do { \
	if (cond) printf("PASS: %s\n", (msg)); \
	else { printf("FAIL: %s\n", (msg)); failures++; } \
} while (0)

int main(void)
{
	static struct rockchip_ebc ebc; /* zero-initialized */
	unsigned int unparks;

	mutex_init(&ebc.barrier_lock);
	init_waitqueue_head(&ebc.barrier_wait);
	ebc.refresh_thread = &ebc_shim_task;

	/* --- 1. park exactly once, idempotent --- */
	check(!ebc.worker_parked && !ebc_shim.thread_parked,
	      "bracket starts open");
	rockchip_ebc_quiesce_worker(&ebc);
	check(ebc.worker_parked && ebc_shim.thread_parked,
	      "quiesce parks the worker and records the bracket");
	check(!ebc.worker_available, "quiesce clears worker_available");
	check(!ebc.barrier_poison, "clean quiesce does not poison");
	rockchip_ebc_quiesce_worker(&ebc);
	check(ebc.worker_parked && ebc_shim.thread_parked,
	      "second quiesce is a no-op (no double park)");

	/* --- 2. wake unparks and re-arms --- */
	unparks = ebc_shim.kthread_unpark_calls;
	rockchip_ebc_wake_worker(&ebc, true);
	check(!ebc.worker_parked && !ebc_shim.thread_parked,
	      "wake clears the bracket and unparks");
	check(ebc.worker_available, "wake re-arms worker_available");
	check(ebc_shim.kthread_unpark_calls == unparks + 1,
	      "wake unparked exactly once");
	rockchip_ebc_wake_worker(&ebc, true);
	check(ebc.worker_available && !ebc.worker_parked,
	      "double wake is safe");

	/* --- 3. pending generation poisons exactly once --- */
	ebc.requested_generation = 5;
	ebc.completed_generation = 4;
	rockchip_ebc_quiesce_worker(&ebc);
	check(ebc.barrier_poison == -ENODEV,
	      "quiesce with a pending generation poisons -ENODEV");
	check(ebc.worker_parked,
	      "poisoning quiesce still parks (no generation left behind)");
	ebc.barrier_poison = 0; /* observe: second quiesce must not re-poison */
	rockchip_ebc_quiesce_worker(&ebc);
	check(ebc.barrier_poison == 0,
	      "second quiesce does not re-poison (bracket guard)");
	ebc.requested_generation = ebc.completed_generation;

	/* --- 4. wake without a ctx must not unpark --- */
	unparks = ebc_shim.kthread_unpark_calls;
	rockchip_ebc_wake_worker(&ebc, false);
	check(ebc_shim.kthread_unpark_calls == unparks,
	      "ctx-less wake does not unpark");
	check(ebc.worker_parked && ebc_shim.thread_parked,
	      "ctx-less wake leaves the bracket in place");
	check(!ebc.worker_available,
	      "ctx-less wake leaves worker_available false");

	/* --- 5. poison gates availability but not the unpark --- */
	ebc.barrier_poison = -EIO;
	unparks = ebc_shim.kthread_unpark_calls;
	rockchip_ebc_wake_worker(&ebc, true);
	check(ebc_shim.kthread_unpark_calls == unparks + 1,
	      "poisoned wake still unparks the thread");
	check(!ebc.worker_available,
	      "poisoned wake keeps worker_available false");
	check(!ebc.worker_parked, "poisoned wake clears the bracket");

	printf("RESULT: %s\n", failures ? "FAILED" : "ok");
	return failures ? 1 : 0;
}
