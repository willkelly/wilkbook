/* Waveform-dependent tests: run the simulator against RSL1 LUT dumps of
 * the device's own waveform (produced by `wbf-info --dump-lut`).
 *
 * Usage: sim-wbf-test GC16.lut GL16.lut A2.lut DU.lut
 *
 * INFO lines report what the real waveform actually does; the PASS/FAIL
 * assertions below them pin only properties the file itself exhibits
 * (verified against the PineNote's shipped waveform, SHA ba3d4883...,
 * 2026-07-03) — not e-ink folklore.  Notably, GC16 *does* drive
 * from==to pairs, and GL16 drives every from==to pair except white->
 * white; only A2/DU/DU4 have neutral diagonals.  See README.md.
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

static int seq_driven(const rs_wf_lut *l, unsigned from4, unsigned to4)
{
	unsigned ph;

	for (ph = 0; ph < l->num_phases; ph++)
		if (rs_wf_code_y4(l, ph, from4, to4))
			return 1;
	return 0;
}

static int last_drive(const rs_wf_lut *l, unsigned from4, unsigned to4)
{
	int ph;

	for (ph = (int)l->num_phases - 1; ph >= 0; ph--) {
		uint8_t c = rs_wf_code_y4(l, (unsigned)ph, from4, to4);

		if (c)
			return c;
	}
	return 0;
}

static void info_mode(const char *name, const rs_wf_lut *l)
{
	unsigned f, t, ph, driven = 0, diag_driven = 0;
	int last_neutral = 1, code3 = 0;

	for (f = 0; f < 16; f++)
		for (t = 0; t < 16; t++) {
			if (seq_driven(l, f, t)) {
				driven++;
				if (f == t)
					diag_driven++;
			}
		}
	for (f = 0; f < 32; f++)
		for (t = 0; t < 32; t++) {
			if (rs_wf_code(l, l->num_phases - 1, f, t))
				last_neutral = 0;
			for (ph = 0; ph < l->num_phases; ph++)
				if (rs_wf_code(l, ph, f, t) == 3)
					code3 = 1;
		}
	printf("INFO %s: phases=%u drivenY4pairs=%u/256 "
	       "from==to-driven=%u/16 last-phase-neutral=%s code3-used=%s\n",
	       name, l->num_phases, driven, diag_driven,
	       last_neutral ? "yes" : "no", code3 ? "yes" : "no");
}

/* Simulate a full-screen update from a uniform `from` frame to a
 * uniform `to` frame and validate both the drive plumbing and the state
 * model. */
static int converge_one(const rs_wf_lut *l, unsigned from4, unsigned to4)
{
	enum { W = 5, H = 3 }; /* odd width exercises nibble edges */
	uint8_t final[3 * H], drive[W * H];
	rs_rect clip = { 0, 0, W, H };
	rs_screen s;
	rs_update u;
	unsigned frame = 0, x, y;
	int ok = 1;

	if (rs_screen_init(&s, W, H, (uint8_t)from4))
		return 0;
	memset(final, (int)(to4 | to4 << 4), sizeof(final));
	if (rs_update_begin(&u, &s, l, &clip, final, rs_y4_pitch(W))) {
		rs_screen_free(&s);
		return 0;
	}

	while (rs_update_step(&u, drive, W)) {
		/* Every pixel's emitted code must equal the LUT row for
		 * (from, to) at this phase, with the driver's neutral
		 * substitution for the last two frames. */
		uint8_t want = frame >= l->num_phases - 1 ? 0 :
			       rs_wf_code_y4(l, frame, from4, to4);

		for (y = 0; y < H && ok; y++)
			for (x = 0; x < W; x++)
				if (drive[y * W + x] != want) {
					ok = 0;
					break;
				}
		frame++;
	}
	if (frame != l->num_phases + 1)
		ok = 0;

	/* State model must land on `to` everywhere. */
	for (y = 0; y < H; y++)
		for (x = 0; x < W; x++)
			if (rs_y4_get(s.prev, s.pitch, (int)x, (int)y) !=
				    to4 ||
			    rs_y4_get(s.next, s.pitch, (int)x, (int)y) !=
				    to4)
				ok = 0;
	rs_screen_free(&s);
	return ok;
}

int main(int argc, char **argv)
{
	static const char *const names[4] = { "GC16", "GL16", "A2", "DU" };
	rs_wf_lut lut[4];
	unsigned i, f, t, bad;

	if (argc != 5) {
		fprintf(stderr,
			"usage: %s GC16.lut GL16.lut A2.lut DU.lut\n",
			argv[0]);
		return 2;
	}
	for (i = 0; i < 4; i++) {
		if (rs_wf_load(&lut[i], argv[i + 1])) {
			fprintf(stderr, "FAIL: cannot load %s\n",
				argv[i + 1]);
			return 1;
		}
		check(lut[i].num_phases > 0 && lut[i].from_levels == 32 &&
		      lut[i].to_levels == 32,
		      "%s: valid RSL1 header (%u phases)", names[i],
		      lut[i].num_phases);
		info_mode(names[i], &lut[i]);
	}

	/* --- GC16: full (from, to) convergence sweep --- */
	bad = 0;
	for (f = 0; f < 16; f++)
		for (t = 0; t < 16; t++)
			if (!converge_one(&lut[0], f, t))
				bad++;
	check(bad == 0, "GC16: all 256 (from,to) updates converge to 'to' "
	      "with LUT-exact drive codes (%u bad)", bad);

	/* A quick convergence spot-check on the other modes' plumbing
	 * (state-model convergence is mode-independent bookkeeping). */
	check(converge_one(&lut[2], 15, 0) && converge_one(&lut[2], 0, 15),
	      "A2: B/W transitions converge");

	/* --- Pinned waveform-family properties (all verified against
	 * the real file first; see INFO lines above) --- */

	/* The driver's phase-0xff trick requires the last decoded phase
	 * to be all-neutral. */
	for (i = 0; i < 4; i++) {
		int neutral = 1;

		for (f = 0; f < 32; f++)
			for (t = 0; t < 32; t++)
				if (rs_wf_code(&lut[i],
					       lut[i].num_phases - 1, f, t))
					neutral = 0;
		check(neutral, "%s: last decoded phase is all-neutral "
		      "(driver 0xff substitution is sound)", names[i]);
	}

	/* GC16 drives every pair — including from==to (contradicts the
	 * folklore that unchanged pixels are untouched; the driver
	 * relies on diff_mode masking for that). */
	bad = 0;
	for (f = 0; f < 16; f++)
		for (t = 0; t < 16; t++)
			if (!seq_driven(&lut[0], f, t))
				bad++;
	check(bad == 0, "GC16: all 256 Y4 pairs driven, even from==to "
	      "(%u neutral)", bad);

	/* GL16: white->white is the only neutral pair. */
	bad = 0;
	for (f = 0; f < 16; f++)
		for (t = 0; t < 16; t++) {
			int want = !(f == 15 && t == 15);

			if (seq_driven(&lut[1], f, t) != want)
				bad++;
		}
	check(bad == 0, "GL16: exactly white->white neutral, all other "
	      "pairs driven (%u mismatches)", bad);

	/* A2: only the two B/W transitions are driven; everything
	 * involving intermediate grays (and both diagonals) is neutral. */
	bad = 0;
	for (f = 0; f < 16; f++)
		for (t = 0; t < 16; t++) {
			int want = (f == 0 && t == 15) ||
				   (f == 15 && t == 0);

			if (seq_driven(&lut[2], f, t) != want)
				bad++;
		}
	check(bad == 0, "A2: driven pairs are exactly 0->15 and 15->0 "
	      "(%u mismatches)", bad);

	/* DU: drives any gray to black or white only (to in {0,15},
	 * from anything, diagonal neutral). */
	bad = 0;
	for (f = 0; f < 16; f++)
		for (t = 0; t < 16; t++) {
			int want = (t == 0 || t == 15) && f != t;

			if (seq_driven(&lut[3], f, t) != want)
				bad++;
		}
	check(bad == 0, "DU: driven pairs are exactly any->{0,15}, "
	      "diagonal neutral (%u mismatches)", bad);

	/* Drive polarity (pins the from/to axis orientation): every
	 * sequence targeting black ends with a darken (1); every one
	 * targeting white ends with a lighten (2).  A transposed LUT
	 * dump fails this immediately. */
	bad = 0;
	for (i = 0; i < 2; i++) /* GC16, GL16 */
		for (f = 0; f < 16; f++) {
			int lb = last_drive(&lut[i], f, 0);
			int lw = last_drive(&lut[i], f, 15);

			if (lb != 1)
				bad++;
			/* GL16 15->15 is neutral (0) by design. */
			if (lw != 2 && !(i == 1 && f == 15))
				bad++;
		}
	check(bad == 0, "GC16/GL16: sequences end darken for to=0, "
	      "lighten for to=15 (%u mismatches)", bad);

	for (i = 0; i < 4; i++)
		rs_wf_free(&lut[i]);

	if (failures) {
		printf("RESULT: %d failures\n", failures);
		return 1;
	}
	printf("RESULT: ok\n");
	return 0;
}
