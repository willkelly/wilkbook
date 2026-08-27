/* wbf-clut-diff: the decode-fidelity differ (doc/status.md 2026-08-27).
 *
 * The direct driver's residue measured ~2x the shipping driver's at
 * matched temperature, drive time, VCOM, and (belief-join-verified)
 * bookkeeping -- playing the SAME .wbf.  The last untested link is the
 * decode: shipping plays drm_epd_helper's 4BIT_PACKED LUT through the
 * EBC hardware engine; direct plays wbf-clut's run-length CLUT through
 * the NEON advance.  This tool diffs the two DELIVERED sequences for
 * every (temperature bin, mode slot, from-gray, to-gray).
 *
 * Reference side: the verbatim drm_epd_helper.c (same extraction as
 * wbf-info), read exactly as wbf-info --dump-lut reads it:
 *
 *   code(phase, from, to) = (packed_word[phase*16 + from] >> (2*to)) & 3
 *
 * CLUT side: an INDEPENDENT walker over the compiled CLUT0002 file,
 * mirroring the kernel engine's semantics byte for byte
 * (rockchip_ebc_blit_neon.c: cell = lut[(prev<<10) + (next<<6) + outer];
 * count = cell & 0x1f, is_last = cell & 0x20, code = cell >> 6) --
 * deliberately NOT reusing wbf-clut's writer, so a writer bug cannot
 * hide from its own inverse.
 *
 * Known suspect class this hunts (wbf-clut.c QUIRK 2): the compiler
 * collapses four 5-bit rows into each 4-bit cell (src>>1, dst>>1) with
 * last-write-wins and NO cell clear, while the shipping hardware reads
 * only the even-even 5-bit row -- so a divergent odd row can win a
 * cell, and a shorter later row can leave a longer earlier row's stale
 * tail phases in place.
 *
 * Verdict classes per cell:
 *   DRIVE mismatch  -- a nonzero code differs at some phase, or drive
 *                      extends past the reference's num_phases.  The
 *                      class that moves ink.  CRITICAL.
 *   LENGTH info     -- drives agree everywhere but the sequences end at
 *                      different phase counts (all-neutral difference).
 *                      Scheduling-visible only.
 *
 * Usage: wbf-clut-diff FILE.wbf CLUT.bin [-v]
 *   -v prints every mismatching cell (first 40 per slot otherwise 8).
 * Exit: 0 = no DRIVE mismatches anywhere; 1 = drive mismatches found;
 *       2 = usage/read errors.
 */

#include "drm_epd_helper.c"

#include <stdint.h>

#define EBC_MAX_PHASES 256	/* mirrors rockchip_ebc.c */

#define CLUT_MAGIC	"CLUT0002"
#define CLUT_HEADER	12	/* magic + u32 n_luts */
#define CLUT_SEQ_SHIFT	6	/* ROCKCHIP_EBC_CUSTOM_WF_SEQ_SHIFT */
#define CLUT_SEQ_LEN	(1 << CLUT_SEQ_SHIFT)
#define CLUT_SLOTS	6	/* DU DU4 GL16 GC16 INIT WAITING */
#define CLUT_BIN_SIZE	(8 + CLUT_SLOTS + 16 * 16 * CLUT_SEQ_LEN)

/* CLUT slot -> the waveform the identity compile put there.  WAITING
 * (slot 5) is synthetic (kernel-rebuilt for redraw_delay) and skipped. */
static const struct {
	const char *name;
	enum drm_epd_waveform wf;
} slots[] = {
	{ "DU",   DRM_EPD_WF_DU },
	{ "DU4",  DRM_EPD_WF_DU4 },
	{ "GL16", DRM_EPD_WF_GL16 },
	{ "GC16", DRM_EPD_WF_GC16 },
	{ "INIT", DRM_EPD_WF_RESET },
};

static int verbose;

static u32 get_le32(const u8 *p)
{
	return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) |
	       ((u32)p[3] << 24);
}

/* Expand one CLUT cell's run-length rows exactly as the kernel walks
 * them.  Returns the expanded length (capped at max), or -1 on a
 * malformed sequence (no is_last inside SEQ_LEN rows with nonzero
 * content -- the kernel would misbehave there too). */
static int walk_cell(const u8 *bin_lut, unsigned int offset,
		     unsigned int from, unsigned int to, u8 *seq,
		     unsigned int max)
{
	unsigned int outer = offset, len = 0;

	for (;;) {
		u8 cell;
		unsigned int count, code, j;

		if (outer >= CLUT_SEQ_LEN)
			return -1;
		cell = bin_lut[(from << (4 + CLUT_SEQ_SHIFT)) +
			       (to << CLUT_SEQ_SHIFT) + outer];
		count = cell & 0x1f;
		code = cell >> 6;
		/* An all-zero first cell is the empty sequence (a pair the
		 * mode never drives); zero count with is_last clear and no
		 * code is otherwise the same emptiness mid-walk. */
		if (!cell && len == 0)
			return 0;
		for (j = 0; j < count && len < max; j++)
			seq[len++] = (u8)code;
		if (cell & 0x20)
			return (int)len;
		outer++;
	}
}

struct slot_report {
	unsigned int drive_cells;
	unsigned int shift_cells;
	unsigned int length_cells;
	unsigned int shown;
};

/* SHIFT class: the CLUT sequence equals the reference with leading and
 * trailing NEUTRAL phases stripped -- same pulses, delivered earlier.
 * Bounded effect: per-pixel optics identical in isolation; co-scheduled
 * pixels de-synchronize and the transition completes early.  CONTENT
 * class (reported below) is different pulses -- the odd-row collision
 * signature, the class that moves ink. */
static int shift_equivalent(const u8 *clut_seq, unsigned int clut_len,
			    const u8 *ref_seq, unsigned int ref_len)
{
	unsigned int lead = 0, tail = ref_len;

	while (lead < ref_len && !ref_seq[lead])
		lead++;
	while (tail > lead && !ref_seq[tail - 1])
		tail--;
	if (tail - lead != clut_len)
		return 0;
	return memcmp(ref_seq + lead, clut_seq, clut_len) == 0;
}

static void report_cell(struct slot_report *r, const char *kind,
			unsigned int bin, const char *slot,
			unsigned int from, unsigned int to,
			const u8 *clut_seq, int clut_len,
			const u8 *ref_seq, unsigned int ref_len)
{
	unsigned int limit = verbose ? 40 : 8, i;

	if (r->shown >= limit) {
		if (r->shown == limit)
			printf("    ... (further cells suppressed; -v for more)\n");
		r->shown++;
		return;
	}
	r->shown++;
	printf("  %s bin=%u slot=%s from=%u to=%u clut_len=%d ref_len=%u\n",
	       kind, bin, slot, from, to, clut_len, ref_len);
	printf("    clut:");
	for (i = 0; i < (unsigned int)clut_len; i++)
		printf("%u", clut_seq[i]);
	printf("\n    ref :");
	for (i = 0; i < ref_len; i++)
		printf("%u", ref_seq[i]);
	printf("\n");
}

int main(int argc, char **argv)
{
	struct drm_epd_lut_file file = { 0 };
	struct drm_epd_lut lut = { 0 }, lut5 = { 0 };
	struct drm_device dev = { 0 };
	const char *wbf_path = NULL, *clut_path = NULL;
	u8 *clut;
	long clut_size;
	u32 n_luts;
	FILE *f;
	unsigned int bin, s;
	unsigned int total_drive = 0, total_length = 0, total_cells = 0;
	unsigned int total_shift = 0;
	int ret, i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v"))
			verbose = 1;
		else if (!wbf_path)
			wbf_path = argv[i];
		else if (!clut_path)
			clut_path = argv[i];
	}
	if (!wbf_path || !clut_path) {
		fprintf(stderr, "usage: %s FILE.wbf CLUT.bin [-v]\n", argv[0]);
		return 2;
	}

	f = fopen(clut_path, "rb");
	if (!f) {
		fprintf(stderr, "FAIL: cannot open %s\n", clut_path);
		return 2;
	}
	fseek(f, 0, SEEK_END);
	clut_size = ftell(f);
	fseek(f, 0, SEEK_SET);
	clut = malloc((size_t)clut_size);
	if (!clut || fread(clut, 1, (size_t)clut_size, f) != (size_t)clut_size) {
		fprintf(stderr, "FAIL: cannot read %s\n", clut_path);
		return 2;
	}
	fclose(f);

	if (clut_size < CLUT_HEADER || memcmp(clut, CLUT_MAGIC, 8) != 0) {
		fprintf(stderr, "FAIL: %s has no %s magic\n", clut_path,
			CLUT_MAGIC);
		return 2;
	}
	n_luts = get_le32(clut + 8);
	if (clut_size != CLUT_HEADER + (long)n_luts * CLUT_BIN_SIZE) {
		fprintf(stderr,
			"FAIL: size %ld != header + %u x %u (layout drift?)\n",
			clut_size, n_luts, (unsigned int)CLUT_BIN_SIZE);
		return 2;
	}
	printf("clut: %u temperature bins, %ld bytes\n", n_luts, clut_size);

	ret = drmm_epd_lut_file_init(&dev, &file, wbf_path);
	if (ret) {
		fprintf(stderr, "FAIL: lut_file_init: %d\n", ret);
		return 2;
	}
	ret = drmm_epd_lut_init(&file, &lut, DRM_EPD_LUT_4BIT_PACKED,
				EBC_MAX_PHASES);
	if (!ret)
		ret = drmm_epd_lut_init(&file, &lut5, DRM_EPD_LUT_5BIT,
					EBC_MAX_PHASES);
	if (ret) {
		fprintf(stderr, "FAIL: lut_init: %d\n", ret);
		return 2;
	}

	for (bin = 0; bin < n_luts; bin++) {
		const u8 *blk = clut + CLUT_HEADER + bin * CLUT_BIN_SIZE;
		u32 temp_lower = get_le32(blk);
		const u8 *offsets = blk + 8;
		const u8 *bin_lut = blk + 8 + CLUT_SLOTS;

		ret = drm_epd_lut_set_temperature(&lut, (int)temp_lower);
		if (ret >= 0)
			ret = drm_epd_lut_set_temperature(&lut5,
							  (int)temp_lower);
		if (ret < 0) {
			fprintf(stderr,
				"FAIL: set_temperature(%u) for bin %u: %d\n",
				temp_lower, bin, ret);
			return 2;
		}
		if ((unsigned int)lut.temp_index != bin) {
			fprintf(stderr,
				"FAIL: temp %u C resolves to reference bin %d, CLUT bin %u -- bin boundary drift\n",
				temp_lower, lut.temp_index, bin);
			return 2;
		}

		for (s = 0; s < sizeof(slots) / sizeof(slots[0]); s++) {
			struct slot_report rep = { 0 };
			const u32 *packed;
			unsigned int from, to;

			ret = drm_epd_lut_set_waveform(&lut, slots[s].wf);
			if (ret >= 0)
				ret = drm_epd_lut_set_waveform(&lut5,
							       slots[s].wf);
			if (ret < 0) {
				fprintf(stderr,
					"FAIL: set_waveform(%s) bin %u: %d\n",
					slots[s].name, bin, ret);
				return 2;
			}
			packed = (const u32 *)lut.buf;

			for (from = 0; from < 16; from++) {
				for (to = 0; to < 16; to++) {
					u8 clut_seq[CLUT_SEQ_LEN * 32];
					u8 ref_seq[EBC_MAX_PHASES];
					int clut_len;
					unsigned int p, cmp;
					int drive_bad = 0;

					total_cells++;
					clut_len = walk_cell(bin_lut,
							     offsets[s], from,
							     to, clut_seq,
							     sizeof(clut_seq));
					if (clut_len < 0) {
						printf("  MALFORMED bin=%u slot=%s from=%u to=%u (no is_last)\n",
						       bin, slots[s].name,
						       from, to);
						rep.drive_cells++;
						total_drive++;
						continue;
					}
					for (p = 0; p < lut.num_phases; p++)
						ref_seq[p] = (u8)((packed[p * 16 + from] >> (to << 1)) & 0x3);

					/* Drive comparison over the union
					 * of both lengths, zero-padded. */
					cmp = (unsigned int)clut_len > lut.num_phases ?
					      (unsigned int)clut_len : lut.num_phases;
					for (p = 0; p < cmp; p++) {
						u8 a = p < (unsigned int)clut_len ?
						       clut_seq[p] : 0;
						u8 b = p < lut.num_phases ?
						       ref_seq[p] : 0;
						if (a != b) {
							drive_bad = 1;
							break;
						}
					}
					if (drive_bad &&
					    shift_equivalent(clut_seq,
							     (unsigned int)clut_len,
							     ref_seq,
							     lut.num_phases)) {
						rep.shift_cells++;
						total_shift++;
					} else if (drive_bad) {
						/* Attribute: which 5-bit
						 * neighbor row (the four
						 * that collide into this
						 * 4-bit cell) does the CLUT
						 * sequence actually match,
						 * shift-tolerantly? */
						const char *attr = "NONE";
						unsigned int df, dt;

						for (df = 0; df < 2; df++)
							for (dt = 0; dt < 2; dt++) {
								u8 nb[EBC_MAX_PHASES];
								unsigned int q;

								for (q = 0; q < lut5.num_phases && q < EBC_MAX_PHASES; q++)
									nb[q] = lut5.buf[q * 0x400 + (from * 2 + df) * 0x20 + (to * 2 + dt)];
								if (shift_equivalent(clut_seq, (unsigned int)clut_len, nb, lut5.num_phases)) {
									static char buf[32];
									snprintf(buf, sizeof(buf), "5bit(%u,%u)", from * 2 + df, to * 2 + dt);
									attr = buf;
									df = dt = 2;
								}
							}
						rep.drive_cells++;
						total_drive++;
						if (rep.shown < (unsigned int)(verbose ? 40 : 8))
							printf("  [winner: %s]\n", attr);
						report_cell(&rep, "CONTENT",
							    bin, slots[s].name,
							    from, to, clut_seq,
							    clut_len, ref_seq,
							    lut.num_phases);
					} else if ((unsigned int)clut_len !=
						   lut.num_phases &&
						   clut_len != 0) {
						/* zero-length CLUT vs all-
						 * neutral ref is the normal
						 * undriven-pair encoding,
						 * not worth a line. */
						rep.length_cells++;
						total_length++;
					}
				}
			}
			printf("bin %2u %-5s phases=%3u content=%u shift=%u length_only=%u\n",
			       bin, slots[s].name, lut.num_phases,
			       rep.drive_cells, rep.shift_cells,
			       rep.length_cells);
		}
	}

	printf("\nTOTAL: %u cells, %u CONTENT divergent, %u shift-equivalent, %u length-only\n",
	       total_cells, total_drive, total_shift, total_length);
	printf("RESULT: %s\n", total_drive ? "CONTENT-DIVERGENCE" : "ok");
	free(clut);
	return total_drive ? 1 : 0;
}
