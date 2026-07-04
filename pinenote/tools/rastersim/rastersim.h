/* librastersim — Gray8->Y4 raster ops and EPD waveform simulator.
 *
 * Host-first seed of the PineNote reader render pipeline (roadmap track
 * 4, offline testing ladder rung 3).  Plain C99, no dependencies, no
 * global state, so it can move on-device later.  It models the
 * rockchip_ebc driver's *bookkeeping* (Y4 buffer layout, quantization
 * modes, prev/next damage semantics, LUT drive sequences) — not
 * electrophoretic optics.  See README.md.
 */
#ifndef RASTERSIM_H
#define RASTERSIM_H

#include <stddef.h>
#include <stdint.h>

/* ---------------- rectangles ---------------- */

/* Half-open [x1,x2) x [y1,y2), like the kernel's drm_rect. */
typedef struct rs_rect {
	int x1, y1, x2, y2;
} rs_rect;

/* ---------------- packed Y4 buffers ----------------
 *
 * 2 pixels per byte; the LOW nibble is the even (left) x pixel and the
 * HIGH nibble is the odd x pixel, matching the layout of rockchip_ebc's
 * prev/next buffers (blit_direct reads `b & 0xf` for pixel x and
 * `b >> 4` for pixel x+1).  Gray convention: 0 = black, 15 = white.
 */

static inline size_t rs_y4_pitch(unsigned width)
{
	return ((size_t)width + 1) / 2;
}

uint8_t rs_y4_get(const uint8_t *y4, size_t pitch, int x, int y);
void rs_y4_set(uint8_t *y4, size_t pitch, int x, int y, uint8_t gray);

/* Pack/unpack between packed Y4 and one-byte-per-pixel nibbles (0..15).
 * rs_y4_pack masks input values to 4 bits. */
void rs_y4_pack(uint8_t *y4, size_t y4_pitch, const uint8_t *nib,
		size_t nib_pitch, unsigned w, unsigned h);
void rs_y4_unpack(uint8_t *nib, size_t nib_pitch, const uint8_t *y4,
		  size_t y4_pitch, unsigned w, unsigned h);

/* Expand packed Y4 to Gray8 (v * 17, so 0->0 and 15->255). */
void rs_y4_to_gray8(uint8_t *gray8, size_t g_pitch, const uint8_t *y4,
		    size_t y4_pitch, unsigned w, unsigned h);

/* Copy `clip` from src to dst; both are packed Y4 buffers addressed in
 * the same coordinate space (the driver's blit_pixels model: next <-
 * final, prev <- next).  Nibbles outside the clip are preserved on BOTH
 * odd edges.  Note: the driver's rockchip_ebc_blit_pixels only preserves
 * the dst nibble at an odd x2 edge; at an odd x1 edge it copies the
 * source's out-of-clip low nibble instead (see README).  This library
 * implements the correct-composition semantics. */
void rs_y4_blit(uint8_t *dst, size_t dst_pitch, const uint8_t *src,
		size_t src_pitch, const rs_rect *clip);

/* ---------------- Gray8 -> Y4 quantization ----------------
 *
 * Thresholds mirror the rockchip_ebc module parameters and are applied
 * to the 4-bit value (g >> 4), with the driver's exact comparison
 * directions.  Defaults match the driver defaults.
 */

typedef struct rs_quant_params {
	int bw_threshold;   /* driver bw_threshold, default 7  */
	int fourtone_low;   /* driver fourtone_low_threshold, default 4  */
	int fourtone_mid;   /* driver fourtone_mid_threshold, default 7  */
	int fourtone_hi;    /* driver fourtone_hi_threshold, default 12 */
	int dither_invert;  /* driver bw_dither_invert, default 0 */
} rs_quant_params;

void rs_quant_params_init(rs_quant_params *p);

typedef enum rs_quant_mode {
	RS_QUANT_SHIFT,      /* g >> 4 */
	RS_QUANT_BW,         /* driver bw_mode=2: (g>>4) >= bw_threshold */
	RS_QUANT_ORDERED_BW, /* driver bw_mode=1: 4x4 ordered dither */
	RS_QUANT_FOURTONE,   /* driver bw_mode=3: thresholds to 0/5/10/15 */
	RS_QUANT_FS,         /* Floyd-Steinberg error diffusion, 16 levels */
} rs_quant_mode;

/* Quantize a Gray8 buffer into a packed Y4 buffer.  p == NULL uses
 * defaults.  Returns 0, or -1 on allocation failure (RS_QUANT_FS needs
 * two error rows).  Deterministic for all modes. */
int rs_gray8_to_y4(uint8_t *y4, size_t y4_pitch, const uint8_t *gray8,
		   size_t g_pitch, unsigned w, unsigned h,
		   rs_quant_mode mode, const rs_quant_params *p);

/* ---------------- screen state (damage model) ----------------
 *
 * Mirrors the driver's rockchip_ebc_ctx prev/next semantics:
 *   - submit: next[clip] = final[clip]   (partial_refresh, frame_delta 0)
 *   - complete: prev[clip] = next[clip]  (after the last phase)
 */

typedef struct rs_screen {
	unsigned width, height;
	size_t pitch;   /* packed Y4 bytes per row */
	uint8_t *prev;  /* display contents before the in-flight update */
	uint8_t *next;  /* display contents after it */
} rs_screen;

int rs_screen_init(rs_screen *s, unsigned width, unsigned height,
		   uint8_t gray);
void rs_screen_free(rs_screen *s);

/* `final` is a full-frame packed Y4 buffer (the driver's ctx->final);
 * only the clip region is read.  The clip is clamped to the screen. */
void rs_screen_submit(rs_screen *s, const rs_rect *clip,
		      const uint8_t *final, size_t final_pitch);
void rs_screen_complete(rs_screen *s, const rs_rect *clip);

/* ---------------- waveform LUT (RSL1 dumps) ----------------
 *
 * Loads the output of `wbf-info --dump-lut` (see that tool and README
 * for the format and the from/to axis derivation).  codes[phase][from]
 * [to] with 5-bit from/to indices; drive codes: 0 = neutral, 1 = darken,
 * 2 = lighten (polarity as pinned from the PineNote waveform), 3 unused
 * in the PineNote file.
 */

typedef struct rs_wf_lut {
	uint32_t num_phases;
	uint32_t from_levels; /* 32 */
	uint32_t to_levels;   /* 32 */
	uint8_t *codes;       /* [phase][from][to] */
} rs_wf_lut;

int rs_wf_load(rs_wf_lut *lut, const char *path);
void rs_wf_free(rs_wf_lut *lut);

static inline uint8_t rs_wf_code(const rs_wf_lut *l, unsigned phase,
				 unsigned from5, unsigned to5)
{
	return l->codes[((size_t)phase * l->from_levels + from5) *
			l->to_levels + to5];
}

/* Y4 gray -> 5-bit LUT index mapping used by the driver: gray g indexes
 * 5-bit state 2*g (drm_epd_lut_convert keeps only the even 5-bit rows
 * and columns for the 4BIT_PACKED LUT the hardware consumes). */
static inline uint8_t rs_wf_code_y4(const rs_wf_lut *l, unsigned phase,
				    unsigned from4, unsigned to4)
{
	return rs_wf_code(l, phase, from4 * 2, to4 * 2);
}

/* Full decoded drive sequence for one Y4 transition: codes[0 ..
 * num_phases-1]. */
void rs_wf_sequence_y4(const rs_wf_lut *l, unsigned from4, unsigned to4,
		       uint8_t *codes);

/* ---------------- update simulation ----------------
 *
 * Steps one damage area through a refresh the way the driver's
 * partial_refresh frame loop does:
 *   frame 0            next[clip] = final[clip]; emit phase 0
 *   frame f < N-1      emit LUT phase f for each pixel's (prev, next)
 *   frame N-1 and N    emit neutral (the driver substitutes phase 0xff,
 *                      which is zero padding, relying on the last real
 *                      phase being all-neutral — true for the PineNote
 *                      waveform, see README)
 *   after frame N      prev[clip] = next[clip]; done
 * Total frames emitted: num_phases + 1.
 */

typedef struct rs_update {
	rs_screen *screen;
	const rs_wf_lut *lut;
	rs_rect clip;
	uint32_t frame;
	int active;
} rs_update;

/* Begins the update (performs the submit).  Returns 0, or -1 on an
 * empty clip. */
int rs_update_begin(rs_update *u, rs_screen *s, const rs_wf_lut *lut,
		    const rs_rect *clip, const uint8_t *final,
		    size_t final_pitch);

/* Emit one frame.  If `drive` is non-NULL it receives one code byte per
 * clip pixel (row-major, rows spaced `drive_pitch` bytes, row width
 * clip->x2 - clip->x1).  Returns 1 if a frame was emitted, 0 if the
 * update had already completed. */
int rs_update_step(rs_update *u, uint8_t *drive, size_t drive_pitch);

/* Run to completion; returns the number of frames emitted. */
unsigned rs_update_run(rs_update *u);

#endif /* RASTERSIM_H */
