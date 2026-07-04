/* librastersim implementation.  See rastersim.h and README.md. */

#include "rastersim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------- packed Y4 buffers ---------------- */

uint8_t rs_y4_get(const uint8_t *y4, size_t pitch, int x, int y)
{
	uint8_t b = y4[(size_t)y * pitch + x / 2];

	return (x & 1) ? b >> 4 : b & 0xf;
}

void rs_y4_set(uint8_t *y4, size_t pitch, int x, int y, uint8_t gray)
{
	uint8_t *b = &y4[(size_t)y * pitch + x / 2];

	gray &= 0xf;
	if (x & 1)
		*b = (*b & 0x0f) | (uint8_t)(gray << 4);
	else
		*b = (*b & 0xf0) | gray;
}

void rs_y4_pack(uint8_t *y4, size_t y4_pitch, const uint8_t *nib,
		size_t nib_pitch, unsigned w, unsigned h)
{
	unsigned x, y;

	for (y = 0; y < h; y++) {
		const uint8_t *src = nib + (size_t)y * nib_pitch;
		uint8_t *dst = y4 + (size_t)y * y4_pitch;

		for (x = 0; x + 1 < w; x += 2)
			dst[x / 2] = (uint8_t)((src[x] & 0xf) |
					       ((src[x + 1] & 0xf) << 4));
		if (w & 1)
			dst[w / 2] = src[w - 1] & 0xf;
	}
}

void rs_y4_unpack(uint8_t *nib, size_t nib_pitch, const uint8_t *y4,
		  size_t y4_pitch, unsigned w, unsigned h)
{
	unsigned x, y;

	for (y = 0; y < h; y++) {
		const uint8_t *src = y4 + (size_t)y * y4_pitch;
		uint8_t *dst = nib + (size_t)y * nib_pitch;

		for (x = 0; x < w; x++)
			dst[x] = (x & 1) ? src[x / 2] >> 4 : src[x / 2] & 0xf;
	}
}

void rs_y4_to_gray8(uint8_t *gray8, size_t g_pitch, const uint8_t *y4,
		    size_t y4_pitch, unsigned w, unsigned h)
{
	unsigned x, y;

	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
			gray8[(size_t)y * g_pitch + x] =
				(uint8_t)(rs_y4_get(y4, y4_pitch, x, y) * 17);
}

void rs_y4_blit(uint8_t *dst, size_t dst_pitch, const uint8_t *src,
		size_t src_pitch, const rs_rect *clip)
{
	int x1 = clip->x1, x2 = clip->x2, y;
	size_t first_byte, last_byte, mid_start, mid_len;
	int odd_start = x1 & 1;
	int odd_end = x2 & 1;

	if (x1 >= x2 || clip->y1 >= clip->y2)
		return;

	first_byte = (size_t)x1 / 2;
	last_byte = (size_t)(x2 - 1) / 2;

	/* Bytes that are fully inside the clip. */
	mid_start = first_byte + (odd_start ? 1 : 0);
	mid_len = 0;
	if (last_byte + 1 > mid_start + (odd_end ? 1 : 0))
		mid_len = last_byte + 1 - (odd_end ? 1 : 0) - mid_start;

	for (y = clip->y1; y < clip->y2; y++) {
		const uint8_t *s = src + (size_t)y * src_pitch;
		uint8_t *d = dst + (size_t)y * dst_pitch;

		if (odd_start) {
			/* Pixel x1 is a high nibble; keep dst's low
			 * nibble (pixel x1-1, outside the clip). */
			d[first_byte] = (uint8_t)((d[first_byte] & 0x0f) |
						  (s[first_byte] & 0xf0));
		}
		if (mid_len)
			memcpy(d + mid_start, s + mid_start, mid_len);
		if (odd_end) {
			/* Pixel x2-1 is a low nibble; keep dst's high
			 * nibble (pixel x2, outside the clip). */
			d[last_byte] = (uint8_t)((d[last_byte] & 0xf0) |
						 (s[last_byte] & 0x0f));
		}
	}
}

/* ---------------- Gray8 -> Y4 quantization ---------------- */

void rs_quant_params_init(rs_quant_params *p)
{
	p->bw_threshold = 7;
	p->fourtone_low = 4;
	p->fourtone_mid = 7;
	p->fourtone_hi = 12;
	p->dither_invert = 0;
}

/* The driver's 4x4 ordered-dither pattern (convert_final_buf_to_target
 * and blit_fb_xrgb8888 bw_mode=1), indexed pattern[x & 3][y & 3]. */
static const int rs_dither_pattern[4][4] = {
	{ 7,  8,  2, 10},
	{12,  4, 14,  6},
	{ 3, 11,  1,  9},
	{15,  7, 13,  5},
};

static uint8_t quant_fourtone(int v4, const rs_quant_params *p)
{
	if (v4 < p->fourtone_low)
		return 0;
	if (v4 < p->fourtone_mid)
		return 5;
	if (v4 < p->fourtone_hi)
		return 10;
	return 15;
}

static int quant_fs(uint8_t *y4, size_t y4_pitch, const uint8_t *gray8,
		    size_t g_pitch, unsigned w, unsigned h)
{
	/* Floyd-Steinberg error diffusion to 16 levels, plain raster
	 * order, integer arithmetic: deterministic across platforms.
	 * q = round(v * 15 / 255); reconstruction q * 17. */
	int *err, *cur, *nxt;
	int x, y;

	err = calloc(2 * ((size_t)w + 2), sizeof(*err));
	if (!err)
		return -1;
	cur = err + 1;
	nxt = err + (w + 2) + 1;

	for (y = 0; y < (int)h; y++) {
		memset(nxt - 1, 0, (w + 2) * sizeof(*nxt));
		for (x = 0; x < (int)w; x++) {
			int v = gray8[(size_t)y * g_pitch + x] + cur[x];
			int q = (v * 15 + 127) / 255;
			int e;

			if (q < 0)
				q = 0;
			if (q > 15)
				q = 15;
			e = v - q * 17;
			rs_y4_set(y4, y4_pitch, x, y, (uint8_t)q);

			cur[x + 1] += e * 7 / 16;
			nxt[x - 1] += e * 3 / 16;
			nxt[x] += e * 5 / 16;
			nxt[x + 1] += e - e * 7 / 16 - e * 3 / 16 -
				      e * 5 / 16;
		}
		memcpy(cur - 1, nxt - 1, (w + 2) * sizeof(*cur));
	}
	free(err);
	return 0;
}

int rs_gray8_to_y4(uint8_t *y4, size_t y4_pitch, const uint8_t *gray8,
		   size_t g_pitch, unsigned w, unsigned h,
		   rs_quant_mode mode, const rs_quant_params *p)
{
	rs_quant_params defaults;
	uint8_t lo, hi;
	unsigned x, y;

	if (!p) {
		rs_quant_params_init(&defaults);
		p = &defaults;
	}
	lo = p->dither_invert ? 15 : 0;
	hi = p->dither_invert ? 0 : 15;

	if (mode == RS_QUANT_FS)
		return quant_fs(y4, y4_pitch, gray8, g_pitch, w, h);

	for (y = 0; y < h; y++) {
		for (x = 0; x < w; x++) {
			int v4 = gray8[(size_t)y * g_pitch + x] >> 4;
			uint8_t q;

			switch (mode) {
			case RS_QUANT_BW:
				/* driver bw_mode=2: >= threshold */
				q = v4 >= p->bw_threshold ? hi : lo;
				break;
			case RS_QUANT_ORDERED_BW:
				/* driver bw_mode=1 */
				q = v4 >= rs_dither_pattern[x & 3][y & 3] ?
					    hi : lo;
				break;
			case RS_QUANT_FOURTONE:
				/* driver bw_mode=3 / DU4 prep */
				q = quant_fourtone(v4, p);
				break;
			case RS_QUANT_SHIFT:
			default:
				q = (uint8_t)v4;
				break;
			}
			rs_y4_set(y4, y4_pitch, (int)x, (int)y, q);
		}
	}
	return 0;
}

/* ---------------- screen state ---------------- */

int rs_screen_init(rs_screen *s, unsigned width, unsigned height,
		   uint8_t gray)
{
	size_t size;

	s->width = width;
	s->height = height;
	s->pitch = rs_y4_pitch(width);
	size = s->pitch * height;
	s->prev = malloc(size);
	s->next = malloc(size);
	if (!s->prev || !s->next) {
		rs_screen_free(s);
		return -1;
	}
	gray &= 0xf;
	memset(s->prev, gray | (gray << 4), size);
	memset(s->next, gray | (gray << 4), size);
	return 0;
}

void rs_screen_free(rs_screen *s)
{
	free(s->prev);
	free(s->next);
	s->prev = s->next = NULL;
}

static rs_rect clamp_clip(const rs_screen *s, const rs_rect *clip)
{
	rs_rect c = *clip;

	if (c.x1 < 0)
		c.x1 = 0;
	if (c.y1 < 0)
		c.y1 = 0;
	if (c.x2 > (int)s->width)
		c.x2 = (int)s->width;
	if (c.y2 > (int)s->height)
		c.y2 = (int)s->height;
	return c;
}

void rs_screen_submit(rs_screen *s, const rs_rect *clip,
		      const uint8_t *final, size_t final_pitch)
{
	rs_rect c = clamp_clip(s, clip);

	rs_y4_blit(s->next, s->pitch, final, final_pitch, &c);
}

void rs_screen_complete(rs_screen *s, const rs_rect *clip)
{
	rs_rect c = clamp_clip(s, clip);

	rs_y4_blit(s->prev, s->pitch, s->next, s->pitch, &c);
}

/* ---------------- waveform LUT ---------------- */

static uint32_t get_le32(const uint8_t *b)
{
	return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
	       ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

int rs_wf_load(rs_wf_lut *lut, const char *path)
{
	uint8_t header[16];
	size_t size;
	FILE *f;

	memset(lut, 0, sizeof(*lut));
	f = fopen(path, "rb");
	if (!f)
		return -1;
	if (fread(header, 1, 16, f) != 16 ||
	    memcmp(header, "RSL1", 4) != 0) {
		fclose(f);
		return -1;
	}
	lut->num_phases = get_le32(header + 4);
	lut->from_levels = get_le32(header + 8);
	lut->to_levels = get_le32(header + 12);
	if (!lut->num_phases || lut->num_phases > 256 ||
	    lut->from_levels != 32 || lut->to_levels != 32) {
		fclose(f);
		return -1;
	}
	size = (size_t)lut->num_phases * 32 * 32;
	lut->codes = malloc(size);
	if (!lut->codes || fread(lut->codes, 1, size, f) != size ||
	    fgetc(f) != EOF) {
		rs_wf_free(lut);
		fclose(f);
		return -1;
	}
	fclose(f);
	for (size_t i = 0; i < size; i++)
		if (lut->codes[i] > 3) {
			rs_wf_free(lut);
			return -1;
		}
	return 0;
}

void rs_wf_free(rs_wf_lut *lut)
{
	free(lut->codes);
	lut->codes = NULL;
	lut->num_phases = 0;
}

void rs_wf_sequence_y4(const rs_wf_lut *l, unsigned from4, unsigned to4,
		       uint8_t *codes)
{
	unsigned ph;

	for (ph = 0; ph < l->num_phases; ph++)
		codes[ph] = rs_wf_code_y4(l, ph, from4, to4);
}

/* ---------------- update simulation ---------------- */

int rs_update_begin(rs_update *u, rs_screen *s, const rs_wf_lut *lut,
		    const rs_rect *clip, const uint8_t *final,
		    size_t final_pitch)
{
	u->screen = s;
	u->lut = lut;
	u->clip = clamp_clip(s, clip);
	u->frame = 0;
	u->active = 0;
	if (u->clip.x1 >= u->clip.x2 || u->clip.y1 >= u->clip.y2)
		return -1;
	rs_screen_submit(s, &u->clip, final, final_pitch);
	u->active = 1;
	return 0;
}

int rs_update_step(rs_update *u, uint8_t *drive, size_t drive_pitch)
{
	uint32_t last_phase = u->lut->num_phases - 1;
	uint32_t frame_delta = u->frame;
	const rs_screen *s = u->screen;
	int neutral, x, y;
	uint32_t phase;

	if (!u->active)
		return 0;

	/* Mirrors partial_refresh: real phases 0 .. last_phase-1, then
	 * the 0xff (zero-padded, neutral) substitute for the last two
	 * frames. */
	neutral = frame_delta >= last_phase;
	phase = neutral ? 0 : frame_delta;

	if (drive) {
		for (y = u->clip.y1; y < u->clip.y2; y++) {
			uint8_t *row = drive + (size_t)(y - u->clip.y1) *
						       drive_pitch;

			for (x = u->clip.x1; x < u->clip.x2; x++) {
				uint8_t p, n;

				if (neutral) {
					row[x - u->clip.x1] = 0;
					continue;
				}
				p = rs_y4_get(s->prev, s->pitch, x, y);
				n = rs_y4_get(s->next, s->pitch, x, y);
				row[x - u->clip.x1] =
					rs_wf_code_y4(u->lut, phase, p, n);
			}
		}
	}

	if (frame_delta > last_phase) {
		rs_screen_complete(u->screen, &u->clip);
		u->active = 0;
	}
	u->frame++;
	return 1;
}

unsigned rs_update_run(rs_update *u)
{
	unsigned frames = 0;

	while (rs_update_step(u, NULL, 0))
		frames++;
	return frames;
}
