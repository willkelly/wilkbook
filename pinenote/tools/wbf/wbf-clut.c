/* wbf-clut: compile a PVI .wbf waveform into hrdl's CLUT0002 table.
 *
 * hrdl's direct-mode rockchip_ebc request_firmware()s
 * "rockchip/custom_wf.bin" and FAILS PROBE with -EINVAL when it is
 * absent (doc/direct-mode-adoption.md D1/D4).  Upstream compiles that
 * file on the device with wbf_to_custom.py, which needs Python + numpy;
 * our reader image has no interpreter but KOReader's bundled luajit, so
 * the compiler has to be a C binary.  This is that binary.
 *
 * Usage: wbf-clut [-v] INPUT.wbf OUTPUT.bin
 *
 * The .wbf DECODE half is not reimplemented here: this file #includes the
 * verbatim drm_epd_helper.c extracted from the forward-port patch (the
 * same source wbf-info compiles and cross-checks) and drives its private
 * drm_epd_lut_update() directly.  What is new is only the run-length
 * summarise + CLUT0002 serialisation on top of it.
 *
 * THE OUTPUT IS PER-DEVICE CALIBRATION DATA.  custom_wf.bin is ebc.wbf in
 * another encoding; it is never committed, never bundled, and CI rejects
 * both by name and by magic.  Compile it from the device's own waveform.
 *
 * ==================== FIDELITY, NOT CORRECTNESS ====================
 *
 * The gate on this tool is BYTE-IDENTICAL output to wbf_to_custom.py, so
 * two upstream bugs are reproduced deliberately.  Do not "fix" them here:
 * a fix changes the shipped waveform and breaks the gate that is the only
 * evidence this compiler is right at all.  Both are written up in
 * doc/driver-findings-report.md and queued in doc/upstream-register.md.
 *
 * QUIRK 1 - "remove suffix" always drops exactly one entry.  The Python is
 *
 *     _last_idx = [x[0] for x in enumerate(reversed(summary))
 *                  if x[0] != 0][0]
 *     summary = summary[:-_last_idx]
 *
 * where x[0] is the ENUMERATE INDEX, not the tuple's phase.  The filter
 * therefore keeps indices 1,2,3,... and [0] is always 1, i.e. plain
 * summary[:-1] whatever the trailing entry holds.  It was meant to be
 * x[1][0] != 0 (trim trailing zero-runs).  It also raises IndexError on a
 * single-entry summary; we refuse the same input rather than invent a
 * behaviour the reference does not have.
 *
 * QUIRK 2 - the 32->16 downsample is lossy AND order-dependent.  The
 * polarisation table is 32x32 (src,dst) but cells are addressed
 * [src>>1][dst>>1], so four (src,dst) pairs collide on every cell and the
 * later write wins.  Worse, a write does not clear the cell first: a short
 * sequence landing on a cell an earlier row filled with a longer one
 * leaves that row's tail bytes in place, 0x20 end marker included.
 * Iteration order is load-bearing, so it is pinned here: ascending
 * i = 0..1023 with src = i % 32, dst = i / 32, exactly the order
 * itertools.product(range(32), range(32))[:, ::-1] produces.  The
 * -DWBF_CLUT_MUTATIONS self-test build can invert it, and the
 * differential requires the inverted output to DIFFER.
 * ===================================================================
 */

/* Include the driver source directly, the way wbf-info does, so the
 * private pvi_wbf_ and drm_epd_lut_update helpers are reachable. */
#include "drm_epd_helper.c"

#define EBC_MAX_PHASES	256	/* mirrors rockchip_ebc.c */

#define SEQ_SHIFT	6			/* wbf_to_custom.py SEQ_SHIFT */
#define SEQ_LEN		(1 << SEQ_SHIFT)	/* 64 */
#define CELLS		16			/* 32 states >> 1 */
#define STATES		32
#define ROWS		(STATES * STATES)	/* 1024 (src, dst) pairs */
#define PHASE_STRIDE	0x400			/* DRM_EPD_LUT_5BIT phase */
#define WF_COUNT	6			/* len(WfIdx) */
#define MAX_RUNS	(EBC_MAX_PHASES + 8)

/* 4 + 4 + 6 + 16*16*64 = 16398 */
#define LUT_BYTES	(4 + 4 + WF_COUNT + CELLS * CELLS * SEQ_LEN)
#define FILE_HEADER	12			/* "CLUT0002" + u32 n_luts */

/* wbf_to_custom.py's WfIdx, in enum order.  The order is the file format:
 * offsets[] is indexed by it and the offset cursor advances in it. */
enum wf_idx {
	WF_DU = 0,
	WF_DU4 = 1,
	WF_GL16 = 2,
	WF_GC16 = 3,
	WF_INIT = 4,
	WF_IDLE = 5,	/* no sequences of its own; takes the final offset */
};
#define WF_REAL 5	/* WF_IDLE is last and carries no table */

static const struct {
	const char *name;
	enum drm_epd_waveform waveform;
} wf_table[WF_REAL] = {
	[WF_DU]   = { "DU",   DRM_EPD_WF_DU },
	[WF_DU4]  = { "DU4",  DRM_EPD_WF_DU4 },
	[WF_GL16] = { "GL16", DRM_EPD_WF_GL16 },
	[WF_GC16] = { "GC16", DRM_EPD_WF_GC16 },
	/* wbf_to_custom.py reads INIT from mode index 0, which is what the
	 * driver calls RESET.  Both resolve to 0 for mode_version 0x19. */
	[WF_INIT] = { "INIT", DRM_EPD_WF_RESET },
};

/* --class-source=TARGET:SOURCE remaps which decoded mode's sequences a
 * CLUT class slot carries.  Identity by default, which is the
 * byte-identical-to-reference path; any remap is an EXPERIMENT knob for
 * the direct-mode display study (doc/direct-mode-adoption.md P4): the
 * driver picks a class by per-pixel hint, so e.g. GL16:GC16 makes
 * ordinary Y4 page turns drive the shorter, punchier GC16 sequences.
 * The output stays a structurally valid CLUT either way -- offsets are
 * computed from the SOURCE lengths -- but it no longer matches the
 * reference compiler, so the differential gate only runs the identity
 * path.  Never ship a remapped table as a default; it is per-experiment
 * calibration on top of per-device calibration. */
static int class_source[WF_REAL] = { WF_DU, WF_DU4, WF_GL16, WF_GC16,
				     WF_INIT };

static int wf_by_name(const char *name, size_t len)
{
	int w;

	for (w = 0; w < WF_REAL; w++)
		if (strlen(wf_table[w].name) == len &&
		    !strncmp(wf_table[w].name, name, len))
			return w;
	return -1;
}

struct run {
	u8 phase;
	u8 count;
};

struct row_summary {
	u16 src;		/* 0..31, raw 5-bit state */
	u16 dst;		/* 0..31 */
	u16 len;		/* runs kept (after QUIRK 1's drop) */
	struct run runs[MAX_RUNS];
};

struct mode_summary {
	struct row_summary *rows;	/* non-neutral rows, ascending i */
	unsigned int count;
	unsigned int max_len;
};

/* Self-test-only mutations.  Compiled out of the shipping binary entirely
 * (-DWBF_CLUT_MUTATIONS is set by the host Makefile's selftest target
 * only), so the device can never be handed one by accident, and the
 * differential asserts the shipping binary REFUSES the flags. */
#ifdef WBF_CLUT_MUTATIONS
static int mutate_keep_suffix;		/* skip QUIRK 1's unconditional drop */
static int mutate_collision_first_wins;	/* invert QUIRK 2's write order */
static int mutate_axis_swap;		/* read the sequence transposed */
#else
#define mutate_keep_suffix		0
#define mutate_collision_first_wins	0
#define mutate_axis_swap		0
#endif

static int verbose;

static void put_le32(u8 *p, u32 v)
{
	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
	p[2] = (v >> 16) & 0xff;
	p[3] = (v >> 24) & 0xff;
}

/*
 * table_summarise() from wbf_to_custom.py, transliterated.  Returns 1 if
 * the row contributes a summary, 0 if the row is all-neutral (the Python
 * drops it before summarising: `if full_seq.sum() > 0'), negative on the
 * inputs the reference cannot express.
 */
static int summarise_row(const u8 *seq, unsigned int phases,
			 struct row_summary *out)
{
	unsigned int i, count = 0, len = 0;
	unsigned long sum = 0;
	int current = -1;

	for (i = 0; i < phases; i++)
		sum += seq[i];
	if (sum == 0)
		return 0;

	for (i = 0; i < phases; i++) {
		int p = seq[i];

		/* Split on a phase change or at 31 repeats (the repeat field
		 * is 5 bits).  `current != -1' keeps the very first sample
		 * from emitting a bogus run. */
		if ((current != -1 && current != p) || count == 31) {
			if (len >= MAX_RUNS)
				return -1;
			out->runs[len].phase = (u8)current;
			out->runs[len].count = (u8)count;
			len++;
			count = 0;
		}
		/* Drop the leading zero-run: it only delays the sequence.
		 * Python tests `not summary', i.e. nothing emitted yet. */
		if (len == 0 && p == 0)
			continue;
		current = p;
		count++;
	}
	if (count > 0) {
		if (len >= MAX_RUNS)
			return -1;
		out->runs[len].phase = (u8)current;
		out->runs[len].count = (u8)count;
		len++;
	}

	/* QUIRK 1 (see the header comment): summary[:-1], unconditionally. */
	if (!mutate_keep_suffix) {
		if (len < 2) {
			fprintf(stderr,
				"FAIL: single-entry summary at src=%u dst=%u; wbf_to_custom.py raises IndexError there, so no reference behaviour exists to match\n",
				out->src, out->dst);
			return -1;
		}
		len--;
	}

	out->len = (u16)len;
	return 1;
}

/* Decode one (mode, temperature) LUT and summarise all 1024 rows. */
static int summarise_mode(struct drm_epd_lut *lut, int mode_index,
			  int temp_index, struct mode_summary *ms)
{
	u8 seq[EBC_MAX_PHASES];
	unsigned int i, phases;
	int ret;

	ret = drm_epd_lut_update(lut, mode_index, temp_index);
	if (ret) {
		fprintf(stderr, "FAIL: decode mode=%d temp=%d: %d\n",
			mode_index, temp_index, ret);
		return -1;
	}
	phases = lut->num_phases;
	if (phases == 0 || phases > EBC_MAX_PHASES) {
		fprintf(stderr, "FAIL: mode=%d temp=%d decoded %u phases\n",
			mode_index, temp_index, phases);
		return -1;
	}

	ms->count = 0;
	ms->max_len = 0;
	/* QUIRK 2: ascending i is the collision order.  src is the fast
	 * axis, matching prev_next_prefix's reversed itertools.product. */
	for (i = 0; i < ROWS; i++) {
		unsigned int src = i % STATES, dst = i / STATES;
		unsigned int p, a = src, b = dst;
		struct row_summary *row = &ms->rows[ms->count];

		if (mutate_axis_swap) {
			a = dst;
			b = src;
		}
		for (p = 0; p < phases; p++)
			seq[p] = lut->buf[p * PHASE_STRIDE + a * STATES + b];

		row->src = (u16)src;
		row->dst = (u16)dst;
		ret = summarise_row(seq, phases, row);
		if (ret < 0)
			return -1;
		if (ret == 0)
			continue;
		if (row->len > ms->max_len)
			ms->max_len = row->len;
		ms->count++;
	}
	if (ms->count == 0) {
		/* max() over an empty list; the Python raises. */
		fprintf(stderr,
			"FAIL: mode=%d temp=%d has no non-neutral rows\n",
			mode_index, temp_index);
		return -1;
	}
	return 0;
}

/* Serialise one temperature bin: CustomWfTemp.__init__ + tobytes(). */
static int build_temp_lut(struct mode_summary *ms, int temp_lower,
			  int temp_upper, int temp_index, u8 *out)
{
	u8 (*cells)[CELLS][SEQ_LEN];
	unsigned int offsets[WF_COUNT];
	unsigned int cursor = 1;	/* cell index 0 stays zero */
	int w;

	for (w = 0; w < WF_REAL; w++) {
		offsets[w] = cursor;
		cursor += ms[class_source[w]].max_len;
	}
	offsets[WF_IDLE] = cursor;	/* takes it, does not advance it */

	put_le32(out, (u32)temp_lower);
	put_le32(out + 4, (u32)temp_upper);
	for (w = 0; w < WF_COUNT; w++) {
		if (offsets[w] > 0xff) {
			fprintf(stderr,
				"FAIL: offset %u for wf %d exceeds the u8 field\n",
				offsets[w], w);
			return -1;
		}
		out[8 + w] = (u8)offsets[w];
	}

	cells = (u8 (*)[CELLS][SEQ_LEN])(out + 8 + WF_COUNT);
	memset(cells, 0, (size_t)CELLS * CELLS * SEQ_LEN);

	for (w = 0; w < WF_REAL; w++) {
		const struct mode_summary *src = &ms[class_source[w]];
		unsigned int off = offsets[w], n = src->count, k;

		if (verbose)
			printf("clut: lut=%d mode=%s from=%s rows=%u maxlen=%u offset=%u\n",
			       temp_index, wf_table[w].name,
			       wf_table[class_source[w]].name, n,
			       src->max_len, off);
		if (off + src->max_len > SEQ_LEN) {
			fprintf(stderr,
				"FAIL: wf %s at bin %d needs %u cells past %u; the reference raises there\n",
				wf_table[w].name, temp_index, src->max_len,
				(unsigned int)SEQ_LEN);
			return -1;
		}
		for (k = 0; k < n; k++) {
			unsigned int r = mutate_collision_first_wins ?
					 n - 1 - k : k;
			const struct row_summary *row = &src->rows[r];
			u8 *cell = cells[row->src >> 1][row->dst >> 1];
			unsigned int j;

			/* QUIRK 2: later writes overwrite earlier ones and
			 * never clear the cell first. */
			for (j = 0; j < row->len; j++)
				cell[off + j] =
					(u8)(((row->runs[j].phase & 3) << 6) |
					     (row->runs[j].count & 0x1f));
			if (row->len)
				cell[off + row->len - 1] |= 0x20;
		}
	}

	if (verbose)
		printf("clut: lut=%d temp_lower=%d temp_upper=%d offsets=%u,%u,%u,%u,%u,%u\n",
		       temp_index, temp_lower, temp_upper, offsets[0],
		       offsets[1], offsets[2], offsets[3], offsets[4],
		       offsets[5]);
	return 0;
}

static int write_output(const char *path, const u8 *buf, size_t size)
{
	size_t len = strlen(path);
	char *tmp = malloc(len + 5);
	FILE *f;

	if (!tmp)
		return -1;
	memcpy(tmp, path, len);
	memcpy(tmp + len, ".tmp", 5);

	f = fopen(tmp, "wb");
	if (!f) {
		fprintf(stderr, "FAIL: cannot open %s\n", tmp);
		free(tmp);
		return -1;
	}
	if (fwrite(buf, 1, size, f) != size || fflush(f) != 0 || ferror(f)) {
		fprintf(stderr, "FAIL: write error on %s\n", tmp);
		fclose(f);
		remove(tmp);
		free(tmp);
		return -1;
	}
	fclose(f);
	/* Replace atomically: a half-written CLUT is a -EINVAL probe
	 * failure, i.e. a device with no display at all. */
	if (rename(tmp, path) != 0) {
		fprintf(stderr, "FAIL: cannot rename %s -> %s\n", tmp, path);
		remove(tmp);
		free(tmp);
		return -1;
	}
	free(tmp);
	return 0;
}

static void usage(const char *argv0)
{
	fprintf(stderr, "usage: %s [-v] [--class-source=TARGET:SOURCE]... INPUT.wbf OUTPUT.bin\n", argv0);
	fprintf(stderr,
		"       TARGET/SOURCE in DU, DU4, GL16, GC16, INIT; remaps which\n"
		"       decoded mode a CLUT class slot carries (display-study knob;\n"
		"       identity is the byte-identical reference path)\n");
#ifdef WBF_CLUT_MUTATIONS
	fprintf(stderr,
		"       SELF-TEST BUILD: --mutate=drop-suffix-off|collision-first-wins|axis-swap\n");
#endif
}

int main(int argc, char **argv)
{
	struct drm_epd_lut_file file = { 0 };
	struct drm_epd_lut lut = { 0 };
	struct drm_device dev = { 0 };
	struct mode_summary ms[WF_REAL] = { 0 };
	const struct pvi_wbf_file_header *h;
	const char *in_path = NULL, *out_path = NULL;
	unsigned int n_luts, t;
	size_t size;
	u8 *out;
	int i, w, ret;

	for (i = 1; i < argc; i++) {
		const char *arg = argv[i];

		if (!strcmp(arg, "-v") || !strcmp(arg, "--verbose")) {
			verbose = 1;
		} else if (!strncmp(arg, "--class-source=", 15)) {
			const char *spec = arg + 15;
			const char *colon = strchr(spec, ':');
			int tgt, src;

			if (!colon || colon == spec || !colon[1]) {
				fprintf(stderr,
					"FAIL: --class-source wants TARGET:SOURCE, got '%s'\n",
					spec);
				return 2;
			}
			tgt = wf_by_name(spec, (size_t)(colon - spec));
			src = wf_by_name(colon + 1, strlen(colon + 1));
			if (tgt < 0 || src < 0) {
				fprintf(stderr,
					"FAIL: unknown class in '%s' (DU, DU4, GL16, GC16, INIT)\n",
					spec);
				return 2;
			}
			class_source[tgt] = src;
#ifdef WBF_CLUT_MUTATIONS
		} else if (!strcmp(arg, "--mutate=drop-suffix-off")) {
			mutate_keep_suffix = 1;
		} else if (!strcmp(arg, "--mutate=collision-first-wins")) {
			mutate_collision_first_wins = 1;
		} else if (!strcmp(arg, "--mutate=axis-swap")) {
			mutate_axis_swap = 1;
#endif
		} else if (arg[0] == '-' && arg[1]) {
			fprintf(stderr, "FAIL: unknown option '%s'\n", arg);
			usage(argv[0]);
			return 2;
		} else if (!in_path) {
			in_path = arg;
		} else if (!out_path) {
			out_path = arg;
		} else {
			usage(argv[0]);
			return 2;
		}
	}
	if (!in_path || !out_path) {
		usage(argv[0]);
		return 2;
	}

	ret = drmm_epd_lut_file_init(&dev, &file, in_path);
	if (ret) {
		fprintf(stderr, "FAIL: lut_file_init(%s): %d\n", in_path, ret);
		return 1;
	}
	h = file.header;

	/* wbf_to_custom.py refuses anything but mode version 0x19, and its
	 * mode->index map is hard-coded for it.  The driver's table happens
	 * to agree there (RESET=0, DU=1, GC16=2, GL16=3, DU4=7) but not for
	 * every other version, so accepting one would silently produce a
	 * CLUT no reference can confirm. */
	if (h->mode_version != 0x19) {
		fprintf(stderr,
			"FAIL: mode version 0x%02x; only 0x19 has a verified reference\n",
			h->mode_version);
		return 1;
	}

	/* temp_range_count is stored off by one (like mode_count): the raw
	 * byte is 13 and the file carries 14 ranges delimited by 15
	 * temperatures.  wbf_to_custom.py adds the one; the kernel's
	 * pvi_wbf_get_temp_index does not, so the driver never reaches the
	 * top bin (doc/driver-findings-report.md). */
	n_luts = (unsigned int)h->temp_range_count + 1;
	if (n_luts < 2) {
		fprintf(stderr, "FAIL: %u temperature ranges\n", n_luts);
		return 1;
	}
	/* n_luts ranges need n_luts + 1 delimiters at offset 0x30.  The
	 * driver's header validation only bounds file_size, so a short file
	 * with a plausible header would read past the blob here; the Python
	 * throws on the same input rather than reading garbage. */
	if (sizeof(*h) + n_luts + 1 > file.fw->size) {
		fprintf(stderr,
			"FAIL: %u temperature delimiters do not fit in a %zu-byte file\n",
			n_luts + 1, file.fw->size);
		return 1;
	}

	ret = drmm_epd_lut_init(&file, &lut, DRM_EPD_LUT_5BIT, EBC_MAX_PHASES);
	if (ret) {
		fprintf(stderr, "FAIL: lut_init: %d\n", ret);
		return 1;
	}

	for (w = 0; w < WF_REAL; w++) {
		ms[w].rows = calloc(ROWS, sizeof(*ms[w].rows));
		if (!ms[w].rows) {
			fprintf(stderr, "FAIL: out of memory\n");
			return 1;
		}
	}

	size = FILE_HEADER + (size_t)n_luts * LUT_BYTES;
	out = calloc(1, size);
	if (!out) {
		fprintf(stderr, "FAIL: out of memory\n");
		return 1;
	}
	memcpy(out, "CLUT0002", 8);
	put_le32(out + 8, n_luts);

	for (t = 0; t < n_luts; t++) {
		u8 *lut_out = out + FILE_HEADER + (size_t)t * LUT_BYTES;

		for (w = 0; w < WF_REAL; w++) {
			int mode_index = pvi_wbf_get_mode_index(
				&file, wf_table[w].waveform);

			if (mode_index < 0) {
				fprintf(stderr, "FAIL: no mode index for %s\n",
					wf_table[w].name);
				return 1;
			}
			if (summarise_mode(&lut, mode_index, (int)t, &ms[w]))
				return 1;
			if (verbose)
				printf("clut: lut=%u mode=%s mode_index=%d phases=%u\n",
				       t, wf_table[w].name, mode_index,
				       lut.num_phases);
		}
		if (build_temp_lut(ms, h->temp_range_table[t],
				   h->temp_range_table[t + 1], (int)t, lut_out))
			return 1;
	}

	if (write_output(out_path, out, size))
		return 1;

	printf("clut: wrote %s (%zu bytes, %u temperature bins)\n", out_path,
	       size, n_luts);
	printf("RESULT: ok\n");
	return 0;
}
