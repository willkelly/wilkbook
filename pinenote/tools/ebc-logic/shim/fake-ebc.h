/* fake-ebc: behavioral model of the RK3566 EBC block, sitting behind the
 * shim regmap (see kernel-shim.h "HARNESS") so the *verbatim* driver's
 * refresh machine can execute against it on the host.  Include AFTER
 * rockchip_ebc.c — it uses the driver's own EBC_* register definitions,
 * so the model can never drift from the register map the driver uses.
 *
 * The device contract implemented here is the one enumerated in
 * doc/ebc-harness-spike.md §2, derived from the driver and the RK3566
 * TRM:
 *
 *   - config registers are write-and-store; a CONFIG_DONE write latches
 *     them (a DSP_FRM_START while unlatched config is pending is counted
 *     as a discipline violation, not honored);
 *   - a DSP_START write with DSP_FRM_START runs a refresh: in LUT mode
 *     DSP_FRM_TOTAL+1 sequential phases over the whole window, in
 *     three-window mode exactly one frame with per-pixel phase indices
 *     read from WIN_MST2; per pixel the 2-bit drive code is looked up in
 *     the LUT *as uploaded into the LUT registers* (so the upload path is
 *     part of what's tested), indexed [phase][next][prev] with prev/next
 *     read via WIN_MST0/WIN_MST1 through the shim DMA registry;
 *   - DSP_DIFF_MODE turns prev==next pixels neutral;
 *   - completion is one DSP_END_INT_ST bit raised through the driver's
 *     own registered IRQ handler (synchronously, inside the triggering
 *     register write — no threads); INT_STATUS is write-1-to-clear.
 *
 * Honesty limit (doc/ebc-harness-spike.md §4): this validates that the
 * driver is consistent with our understanding of the silicon, not the
 * silicon itself.  Concurrency is also not modeled — the device finishes
 * "instantly", so races the driver tolerates by design (e.g. the prev
 * blit against the last, neutral phase) never overlap here.  Direct mode
 * (software-LUT polarity data in the windows) is not modeled; it is off
 * in the shipped configuration and its blit path is rung-2/3 territory.
 */
#ifndef EBC_LOGIC_FAKE_EBC_H
#define EBC_LOGIC_FAKE_EBC_H

#define FAKE_EBC_MAX_EVENTS 4096

/* One record per DSP_FRM_START write (one per hardware frame in
 * three-window mode; one per whole refresh in LUT mode). */
struct fake_ebc_event {
	u32 dsp_start;		/* the written value (frm_total, out_low, …) */
	u32 epd_ctrl;		/* latched */
	u32 dsp_ctrl;		/* latched */
	u32 win_act;		/* latched */
	u32 mst0, mst1, mst2;	/* latched bus handles */
	const void *prev_cpu;	/* CPU buffers behind the window mappings
				 * (identification only — the device reads
				 * the mappings' shadows; NULL if bad) */
	const void *next_cpu;
	const void *phase_cpu;
	bool lut_mode;
	bool three_win;
	bool diff;
	u32 first_hw_frame;	/* index of its first plane in hw_frames */
	u32 planes;		/* 1 in three-win mode, frm_total+1 in LUT mode */
};

struct fake_ebc {
	/* geometry of the aggregate arrays (from WIN_ACT at frame time) */
	unsigned width, height;

	/* per-pixel aggregates over the device's whole life */
	u32 *drive_count;	/* number of non-neutral codes seen */
	u32 *last_drive_frame;	/* hw frame index of the last one */
	s32 *pulse;		/* +1 per lighten (code 2), -1 per darken (1) */
	u8 *last_phase_idx;	/* previous frame's phase index (0xff idle) */

	/* optional full drive-code recording (small screens only):
	 * seq[frame * width * height + pixel] = code */
	bool record_seq;
	u8 *seq;
	u32 seq_frames;		/* capacity actually allocated */

	/* event log */
	struct fake_ebc_event ev[FAKE_EBC_MAX_EVENTS];
	u32 nev;

	/* counters (a healthy run: everything below stays 0 except
	 * hw_frames / dsp_end_irqs / lut_uploads / config_done_writes /
	 * out_low_writes) */
	u32 hw_frames;			/* planes processed */
	u32 dsp_end_irqs;
	u32 lut_uploads;		/* bulk writes to EBC_LUT_DATA */
	u32 config_done_writes;
	u32 out_low_writes;
	u32 frm_start_config_dirty;	/* FRM_START with unlatched config */
	u32 frames_unpowered;		/* frame while clocks/power/cache off */
	u32 bad_frames;			/* window handle did not resolve */
	u32 conflicts;			/* per-pixel phase-index regressions */
	u32 event_overflow;

	bool config_dirty;		/* config written since CONFIG_DONE */
	u32 latched[EBC_SHIM_MMIO_SIZE / 4];	/* latched config copy */

	/* test hook: runs while the device "refreshes" (inside the
	 * driver's DSP_START write, i.e. exactly when a concurrent
	 * atomic_update could run on hardware) */
	void (*on_frm_start)(u32 hw_frame);

	/* test hook: called once per honored DSP_FRM_START after the
	 * window mappings resolve and before any plane runs.  prev/next
	 * (and phase_buf in three-window mode; NULL in LUT mode) are the
	 * device-visible shadow buffers — the census point for tools that
	 * want to account per-refresh work (ebc-replay). */
	void (*on_event)(const struct fake_ebc_event *ev, const u8 *prev,
			 const u8 *next, const u8 *phase_buf);
};

static struct fake_ebc fake_ebc;

static void fake_ebc_free(void)
{
	free(fake_ebc.drive_count);
	free(fake_ebc.last_drive_frame);
	free(fake_ebc.pulse);
	free(fake_ebc.last_phase_idx);
	free(fake_ebc.seq);
}

static void fake_ebc_reset(void)
{
	fake_ebc_free();
	memset(&fake_ebc, 0, sizeof(fake_ebc));
}

static void fake_ebc_geometry(unsigned w, unsigned h)
{
	size_t npix = (size_t)w * h;

	if (fake_ebc.width == w && fake_ebc.height == h)
		return;
	free(fake_ebc.drive_count);
	free(fake_ebc.last_drive_frame);
	free(fake_ebc.pulse);
	free(fake_ebc.last_phase_idx);
	fake_ebc.width = w;
	fake_ebc.height = h;
	fake_ebc.drive_count = calloc(npix, sizeof(u32));
	fake_ebc.last_drive_frame = calloc(npix, sizeof(u32));
	fake_ebc.pulse = calloc(npix, sizeof(s32));
	fake_ebc.last_phase_idx = malloc(npix);
	memset(fake_ebc.last_phase_idx, 0xff, npix);
	if (fake_ebc.record_seq && !fake_ebc.seq) {
		fake_ebc.seq_frames = 1024;
		fake_ebc.seq = calloc((size_t)fake_ebc.seq_frames * npix, 1);
	}
}

/* The LUT exactly as the driver uploaded it into the LUT registers.
 * DRM_EPD_LUT_4BIT_PACKED: u32 word[phase*16 + prev], bit pair 2*next —
 * the axis assignment pinned by rung 1/3's crosscheck against the 5BIT
 * decode ([phase][from][to]) and by the hardware-validated stack.  Note
 * this is deliberately NOT what rockchip_ebc_blit_direct does: that
 * (unused, direct_mode=off) path reads the LUT transposed — the rung 3
 * quirk finding, which this model's WBF differential re-confirms. */
static u8 fake_ebc_lut_code(unsigned int phase, unsigned int next,
			    unsigned int prev)
{
	u32 word = ebc_shim.regs[EBC_LUT_DATA / 4 + phase * 16 + prev];

	return (word >> (next * 2)) & 0x3;
}

static u8 fake_ebc_y4(const u8 *buf, size_t pitch, unsigned int x, unsigned int y)
{
	u8 b = buf[y * pitch + x / 2];

	return (x & 1) ? b >> 4 : b & 0xf;
}

/* Process one hardware frame (one plane of drive codes).  In LUT mode
 * `lut_phase` is the sequential phase index and `phase_buf` is NULL; in
 * three-window mode `phase_buf` holds one phase index per pixel. */
static void fake_ebc_plane(const u8 *prev, const u8 *next, const u8 *phase_buf,
			   unsigned int lut_phase, bool diff)
{
	unsigned int w = fake_ebc.width, h = fake_ebc.height;
	size_t pitch = w / 2;
	unsigned int x, y;

	for (y = 0; y < h; y++) {
		for (x = 0; x < w; x++) {
			size_t idx = (size_t)y * w + x;
			u8 p = fake_ebc_y4(prev, pitch, x, y);
			u8 n = fake_ebc_y4(next, pitch, x, y);
			u8 ph = phase_buf ? phase_buf[idx] : lut_phase;
			u8 code = fake_ebc_lut_code(ph, n, p);

			if (diff && p == n)
				code = 0;

			if (phase_buf) {
				u8 lastp = fake_ebc.last_phase_idx[idx];

				/* A live pixel's phase index only counts
				 * up; 0xff means idle/neutral on either
				 * side.  A regression is two refreshes
				 * fighting over the pixel. */
				if (ph != 0xff && lastp != 0xff && ph < lastp)
					fake_ebc.conflicts++;
				fake_ebc.last_phase_idx[idx] = ph;
			}

			if (code) {
				fake_ebc.drive_count[idx]++;
				fake_ebc.last_drive_frame[idx] = fake_ebc.hw_frames;
				fake_ebc.pulse[idx] += (code == 2) ? 1 : -1;
			}
			if (fake_ebc.seq && fake_ebc.hw_frames < fake_ebc.seq_frames)
				fake_ebc.seq[(size_t)fake_ebc.hw_frames * w * h + idx] = code;
		}
	}
	fake_ebc.hw_frames++;
}

static void fake_ebc_raise_dsp_end(void)
{
	u32 status = ebc_shim.regs[EBC_INT_STATUS / 4];

	ebc_shim.regs[EBC_INT_STATUS / 4] = status | EBC_INT_STATUS_DSP_END_INT_ST;
	fake_ebc.dsp_end_irqs++;
	/* Masked interrupts do not reach the CPU: if the driver's resume
	 * path failed to unmask DSP_END, its wait times out — visibly. */
	if (!(status & EBC_INT_STATUS_DSP_END_INT_MSK) && ebc_shim.irq_handler)
		ebc_shim.irq_handler(1, ebc_shim.irq_dev_id);
}

static void fake_ebc_frm_start(u32 val)
{
	u32 epd_ctrl = fake_ebc.latched[EBC_EPD_CTRL / 4];
	u32 dsp_ctrl = fake_ebc.latched[EBC_DSP_CTRL / 4];
	u32 win_act = fake_ebc.latched[EBC_WIN_ACT / 4];
	unsigned int w = win_act & 0xffff, h = win_act >> 16;
	bool three_win = epd_ctrl & EBC_EPD_CTRL_DSP_THREE_WIN_MODE;
	bool lut_mode = dsp_ctrl & EBC_DSP_CTRL_DSP_LUT_MODE;
	bool diff = dsp_ctrl & EBC_DSP_CTRL_DSP_DIFF_MODE;
	u32 frm_total = (val >> 2) & 0x3ff;
	const u8 *prev, *next, *phase_buf = NULL;
	u32 planes, i;

	if (fake_ebc.on_frm_start)
		fake_ebc.on_frm_start(fake_ebc.hw_frames);

	if (fake_ebc.config_dirty)
		fake_ebc.frm_start_config_dirty++;
	if (ebc_shim.cache_only || ebc_shim.clks_on < 2 ||
	    ebc_shim.regulators_on < 3)
		fake_ebc.frames_unpowered++;

	fake_ebc_geometry(w, h);

	prev = ebc_shim_dma_resolve(fake_ebc.latched[EBC_WIN_MST0 / 4],
				    (size_t)w / 2 * h);
	next = ebc_shim_dma_resolve(fake_ebc.latched[EBC_WIN_MST1 / 4],
				    (size_t)w / 2 * h);
	if (three_win)
		phase_buf = ebc_shim_dma_resolve(fake_ebc.latched[EBC_WIN_MST2 / 4],
						 (size_t)w * h);

	planes = lut_mode ? frm_total + 1 : 1;

	{
		struct fake_ebc_event evl;

		memset(&evl, 0, sizeof(evl));
		evl.dsp_start = val;
		evl.epd_ctrl = epd_ctrl;
		evl.dsp_ctrl = dsp_ctrl;
		evl.win_act = win_act;
		evl.mst0 = fake_ebc.latched[EBC_WIN_MST0 / 4];
		evl.mst1 = fake_ebc.latched[EBC_WIN_MST1 / 4];
		evl.mst2 = fake_ebc.latched[EBC_WIN_MST2 / 4];
		evl.prev_cpu = ebc_shim_dma_cpu(fake_ebc.latched[EBC_WIN_MST0 / 4]);
		evl.next_cpu = ebc_shim_dma_cpu(fake_ebc.latched[EBC_WIN_MST1 / 4]);
		evl.phase_cpu = three_win ?
			ebc_shim_dma_cpu(fake_ebc.latched[EBC_WIN_MST2 / 4]) : NULL;
		evl.lut_mode = lut_mode;
		evl.three_win = three_win;
		evl.diff = diff;
		evl.first_hw_frame = fake_ebc.hw_frames;
		evl.planes = planes;

		if (fake_ebc.nev < FAKE_EBC_MAX_EVENTS)
			fake_ebc.ev[fake_ebc.nev++] = evl;
		else
			fake_ebc.event_overflow++;

		if (!prev || !next || (three_win && !phase_buf) ||
		    (!three_win && !lut_mode)) {
			/* unresolvable windows or an unmodeled mode (direct) */
			fake_ebc.bad_frames++;
			fake_ebc_raise_dsp_end();
			return;
		}

		if (fake_ebc.on_event)
			fake_ebc.on_event(&evl, prev, next, phase_buf);
	}

	for (i = 0; i < planes; i++)
		fake_ebc_plane(prev, next, phase_buf, i, diff);

	fake_ebc_raise_dsp_end();
}

/* Write-1-to-clear semantics for INT_STATUS: CLR bits (8-11) clear the
 * matching ST bits (0-3) and read back as zero; MSK bits and the upper
 * fields store as written. */
static void fake_ebc_int_status_write(u32 val)
{
	u32 old_st = ebc_shim.regs[EBC_INT_STATUS / 4] & 0xf;
	u32 clr = (val >> 8) & 0xf;

	ebc_shim.regs[EBC_INT_STATUS / 4] =
		(val & ~0xf0fu) | (val & 0xf0) | (old_st & ~clr);
}

static void fake_ebc_regmap_hook(unsigned int reg, const u32 *vals, size_t count)
{
	if (reg == EBC_LUT_DATA && count > 1) {
		fake_ebc.lut_uploads++;
		return;
	}
	if (count != 1)
		return;

	switch (reg) {
	case EBC_CONFIG_DONE:
		if (vals[0] & EBC_CONFIG_DONE_REG_CONFIG_DONE) {
			memcpy(fake_ebc.latched, ebc_shim.regs,
			       EBC_WIN_MST2 + 4);
			fake_ebc.config_done_writes++;
			fake_ebc.config_dirty = false;
		}
		break;
	case EBC_DSP_START:
		if (vals[0] & EBC_DSP_START_DSP_OUT_LOW)
			fake_ebc.out_low_writes++;
		if (vals[0] & EBC_DSP_START_DSP_FRM_START)
			fake_ebc_frm_start(vals[0]);
		break;
	case EBC_INT_STATUS:
		fake_ebc_int_status_write(vals[0]);
		break;
	default:
		/* every other register in the window is configuration */
		if (reg <= EBC_WIN_MST2)
			fake_ebc.config_dirty = true;
		break;
	}
}

static void fake_ebc_install(void)
{
	fake_ebc_reset();
	ebc_shim.regmap_hook = fake_ebc_regmap_hook;
}

#endif /* EBC_LOGIC_FAKE_EBC_H */
