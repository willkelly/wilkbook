/* wbf-info: host-side inspector/test harness for PVI .wbf waveform files.
 *
 * Compiles the verbatim drm_epd_helper.c from the forward-port patch
 * (extracted at build time) against a small kernel-API shim, then loads a
 * waveform file exactly the way rockchip_ebc does on the device
 * (DRM_EPD_LUT_4BIT_PACKED, 256 max phases) and reports what the kernel
 * would see.  Output is line-oriented for run-tests.sh to assert on.
 *
 * Usage: wbf-info FILE.wbf [TEMPERATURE_C]
 *        wbf-info --dump-lut WAVEFORM_NAME TEMP_C OUTFILE FILE.wbf
 *
 * The --dump-lut mode writes the decoded LUT for one (waveform, temperature)
 * pair in the RSL1 format consumed by pinenote/tools/rastersim (see that
 * README for the format and for how the axis order was derived from
 * pvi_wbf_decode_lut / drm_epd_lut_convert / rockchip_ebc_blit_direct).
 */

/* Include the driver source directly so private pvi_wbf_* helpers are
 * testable. */
#include "drm_epd_helper.c"

#define EBC_MAX_PHASES 256 /* mirrors rockchip_ebc.c */

static const char *const waveform_names[DRM_EPD_WF_MAX] = {
	[DRM_EPD_WF_RESET] = "RESET",
	[DRM_EPD_WF_A2] = "A2",
	[DRM_EPD_WF_DU] = "DU",
	[DRM_EPD_WF_DU4] = "DU4",
	[DRM_EPD_WF_GC16] = "GC16",
	[DRM_EPD_WF_GCC16] = "GCC16",
	[DRM_EPD_WF_GL16] = "GL16",
	[DRM_EPD_WF_GLR16] = "GLR16",
	[DRM_EPD_WF_GLD16] = "GLD16",
};

static void print_xwia(const struct drm_epd_lut_file *file)
{
	/* xwia points at a length-prefixed ASCII description. */
	const u8 *xwia = pvi_wbf_apply_offset(file, &file->header->xwia);

	if (!xwia) {
		printf("xwia: (unreadable)\n");
		return;
	}
	printf("xwia: %.*s\n", xwia[0], (const char *)xwia + 1);
}

/* --- --dump-lut: export one decoded (waveform, temperature) LUT --- */

static int lookup_waveform(const char *name)
{
	int i;

	for (i = 0; i < DRM_EPD_WF_MAX; i++)
		if (waveform_names[i] && !strcmp(waveform_names[i], name))
			return i;
	return -1;
}

static void put_le32(FILE *f, u32 v)
{
	u8 b[4] = { v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24 };

	fwrite(b, 1, 4, f);
}

/*
 * RSL1 dump format (all little-endian):
 *   u32 magic 0x314C5352 ("RSL1")
 *   u32 num_phases
 *   u32 from_levels (32)
 *   u32 to_levels   (32)
 *   u8  codes[num_phases][from][to], values 0..3 (1=darken, 2=lighten)
 *
 * Axis order: pvi_wbf_decode_lut fills the DRM_EPD_LUT_5BIT buffer as
 * buf[phase*0x400 + x*0x20 + y] (x is the raw stream's fast axis; the
 * decode transposes it to stride 0x20).  drm_epd_lut_convert packs even
 * (x, y) pairs into the 4BIT_PACKED buffer as u32 word[phase*16 + x/2]
 * bit 2*(y/2).  The semantic labels are pinned by the waveform content
 * itself (see pinenote/tools/rastersim/README.md): the final non-neutral
 * drive of every sequence is a function of y alone (darken for y=0,
 * lighten for y=31), DU only drives pairs with y in {0,31}, and A2's two
 * driven pairs use 1=darken/2=lighten in the standard PVI polarity.
 * Hence x == FROM (prev) and y == TO (next):
 *
 *   5BIT:        buf[phase*0x400 + from5*0x20 + to5]
 *   4BIT_PACKED: word[phase*16 + prev4] >> (2*next4)   (hardware view)
 *
 * Note rockchip_ebc_blit_direct reads word[next] >> (2*prev), i.e. the
 * TRANSPOSE of the file semantics.  That software-LUT path is unused on
 * the PineNote (direct_mode=0; the EBC hardware indexes the LUT itself
 * from the prev/next window buffers), so the dump follows the file/
 * hardware semantics, not blit_direct's variable names.  The cross-check
 * below verifies the byte-level relation between the two buffers the
 * driver actually builds, independent of labels.
 */
static int dump_lut(const char *mode_name, int temperature,
		    const char *outpath, const char *wbf_path)
{
	struct drm_epd_lut_file file = { 0 };
	struct drm_epd_lut lut5 = { 0 }, lut4 = { 0 };
	struct drm_device dev = { 0 };
	const u32 *packed;
	unsigned int phase, from, to;
	int wf, ret;
	FILE *out;

	wf = lookup_waveform(mode_name);
	if (wf < 0) {
		fprintf(stderr, "FAIL: unknown waveform '%s'\n", mode_name);
		return 2;
	}

	ret = drmm_epd_lut_file_init(&dev, &file, wbf_path);
	if (ret) {
		fprintf(stderr, "FAIL: lut_file_init: %d\n", ret);
		return 1;
	}

	/* Decode twice: full 32x32 5-bit matrix for the dump, plus the
	 * driver's own 4BIT_PACKED view for the axis cross-check. */
	ret = drmm_epd_lut_init(&file, &lut5, DRM_EPD_LUT_5BIT,
				EBC_MAX_PHASES);
	if (!ret)
		ret = drmm_epd_lut_init(&file, &lut4, DRM_EPD_LUT_4BIT_PACKED,
					EBC_MAX_PHASES);
	if (ret) {
		fprintf(stderr, "FAIL: lut_init: %d\n", ret);
		return 1;
	}

	ret = drm_epd_lut_set_temperature(&lut5, temperature);
	if (ret >= 0)
		ret = drm_epd_lut_set_temperature(&lut4, temperature);
	if (ret < 0) {
		fprintf(stderr, "FAIL: set_temperature(%d): %d\n",
			temperature, ret);
		return 1;
	}

	ret = drm_epd_lut_set_waveform(&lut5, wf);
	if (ret >= 0)
		ret = drm_epd_lut_set_waveform(&lut4, wf);
	if (ret < 0) {
		fprintf(stderr, "FAIL: set_waveform(%s): %d\n", mode_name,
			ret);
		return 1;
	}

	if (!lut5.num_phases || lut5.num_phases != lut4.num_phases) {
		fprintf(stderr, "FAIL: phase mismatch (5bit=%u packed=%u)\n",
			lut5.num_phases, lut4.num_phases);
		return 1;
	}

	printf("dump-lut: mode=%s temp=%d temp_index=%d phases=%u\n",
	       mode_name, temperature, lut5.temp_index, lut5.num_phases);

	/* Cross-check the 5BIT buffer against the 4BIT_PACKED buffer: u32
	 * word[phase*16 + from4] bit 2*to4 must equal the even-even 5BIT
	 * entry (Y4 gray g maps to 5-bit index 2*g, which is also how the
	 * driver's Y4 prev/next buffers index the packed LUT). */
	packed = (const u32 *)lut4.buf;
	for (phase = 0; phase < lut4.num_phases; phase++) {
		for (from = 0; from < 16; from++) {
			u32 word = packed[phase * 16 + from];

			for (to = 0; to < 16; to++) {
				u8 c4 = (word >> (to << 1)) & 0x3;
				u8 c5 = lut5.buf[phase * 0x400 +
						 (from * 2) * 0x20 + to * 2];

				if (c4 != c5) {
					fprintf(stderr,
						"FAIL: axis crosscheck phase=%u from=%u to=%u packed=%u 5bit=%u\n",
						phase, from, to, c4, c5);
					return 1;
				}
			}
		}
	}
	printf("dump-lut: crosscheck-4bit-packed: ok (%u phases x 16x16)\n",
	       lut4.num_phases);

	/* The driver writes phase 0xff for the tail frames of every area
	 * and relies on the padding beyond num_phases being neutral. */
	for (phase = lut4.num_phases * 64;
	     phase < (unsigned int)EBC_MAX_PHASES * 64; phase++) {
		if (lut4.buf[phase]) {
			fprintf(stderr, "FAIL: nonzero LUT padding at %u\n",
				phase);
			return 1;
		}
	}
	printf("dump-lut: padding-neutral: ok\n");

	out = fopen(outpath, "wb");
	if (!out) {
		fprintf(stderr, "FAIL: cannot open %s\n", outpath);
		return 1;
	}
	fwrite("RSL1", 1, 4, out);
	put_le32(out, lut5.num_phases);
	put_le32(out, 32);
	put_le32(out, 32);
	/* The decoded 5BIT buffer is already [phase][from][to]. */
	fwrite(lut5.buf, 1, (size_t)lut5.num_phases * 0x400, out);
	if (fflush(out) != 0 || ferror(out)) {
		fprintf(stderr, "FAIL: write error on %s\n", outpath);
		fclose(out);
		return 1;
	}
	fclose(out);
	printf("dump-lut: wrote %s (%u bytes)\n", outpath,
	       16 + lut5.num_phases * 32 * 32);
	printf("RESULT: ok\n");
	return 0;
}

int main(int argc, char **argv)
{
	struct drm_epd_lut_file file = { 0 };
	struct drm_epd_lut lut = { 0 };
	struct drm_device dev = { 0 };
	const struct pvi_wbf_file_header *h;
	int temperature = DRM_EPD_DEFAULT_TEMPERATURE;
	int ret, i, failures = 0;

	if (argc >= 2 && !strcmp(argv[1], "--dump-lut")) {
		if (argc != 6) {
			fprintf(stderr,
				"usage: %s --dump-lut WAVEFORM_NAME TEMP_C OUTFILE FILE.wbf\n",
				argv[0]);
			return 2;
		}
		return dump_lut(argv[2], atoi(argv[3]), argv[4], argv[5]);
	}

	if (argc < 2) {
		fprintf(stderr, "usage: %s FILE.wbf [TEMPERATURE_C]\n",
			argv[0]);
		return 2;
	}
	if (argc > 2)
		temperature = atoi(argv[2]);

	ret = drmm_epd_lut_file_init(&dev, &file, argv[1]);
	if (ret) {
		fprintf(stderr, "FAIL: lut_file_init: %d\n", ret);
		return 1;
	}
	h = file.header;

	printf("file_size: %u (fw size %zu)\n", le32_to_cpu(h->file_size),
	       file.fw->size);
	printf("checksum_stored: 0x%08x\n", le32_to_cpu(h->checksum));
	printf("serial: %u\n", le32_to_cpu(h->serial));
	printf("run_type: 0x%02x fpl_platform: 0x%02x fpl_lot: %u\n",
	       h->run_type, h->fpl_platform, le16_to_cpu(h->fpl_lot));
	printf("mode_version: 0x%02x\n", h->mode_version);
	printf("wf: version 0x%02x subversion 0x%02x type 0x%02x rev 0x%02x\n",
	       h->wf_version, h->wf_subversion, h->wf_type, h->wf_rev);
	printf("panel_size: %u amepd_part_number: %u\n", h->panel_size,
	       h->amepd_part_number);
	printf("frame_rate: bcd 0x%02x hex %u\n", h->frame_rate_bcd,
	       h->frame_rate_hex);
	printf("vcom_offset: %u\n", h->vcom_offset);
	printf("mode_count: %u\n", h->mode_count);
	printf("lut_format: %s\n",
	       file.mode_info->format == DRM_EPD_LUT_5BIT ? "5BIT" :
	       file.mode_info->format == DRM_EPD_LUT_5BIT_PACKED ? "5BIT_PACKED" :
	       file.mode_info->format == DRM_EPD_LUT_4BIT_PACKED ? "4BIT_PACKED" :
	       "4BIT");
	print_xwia(&file);

	printf("temp_range_count: %u\n", h->temp_range_count);
	for (i = 0; i < h->temp_range_count; i++)
		printf("temp_bin %d: >= %u C\n", i, h->temp_range_table[i]);

	/* Temperature index behavior, including the below-first-bin edge
	 * (returns -1, which set_temperature turns into -ENOENT — the
	 * driver keeps the old LUT in that case). */
	printf("temp_index(%d): %d\n", temperature,
	       pvi_wbf_get_temp_index(&file, temperature));
	printf("temp_index_below_first: %d\n",
	       pvi_wbf_get_temp_index(&file, h->temp_range_table[0] - 1));
	printf("temp_index_above_last: %d\n",
	       pvi_wbf_get_temp_index(&file, 127));

	/* Initialize the LUT exactly like rockchip_ebc does. */
	ret = drmm_epd_lut_init(&file, &lut, DRM_EPD_LUT_4BIT_PACKED,
				EBC_MAX_PHASES);
	if (ret) {
		fprintf(stderr, "FAIL: lut_init: %d\n", ret);
		return 1;
	}
	printf("lut_init: ok (RESET mode_index=%d temp_index=%d phases=%u)\n",
	       lut.mode_index, lut.temp_index, lut.num_phases);

	ret = drm_epd_lut_set_temperature(&lut, temperature);
	if (ret < 0) {
		fprintf(stderr, "FAIL: set_temperature(%d): %d\n",
			temperature, ret);
		return 1;
	}

	/* Decode every waveform mode at the chosen temperature. */
	for (i = 0; i < DRM_EPD_WF_MAX; i++) {
		ret = drm_epd_lut_set_waveform(&lut, i);
		if (ret < 0) {
			printf("MODE %s: FAIL %d\n", waveform_names[i], ret);
			failures++;
			continue;
		}
		printf("MODE %s: index=%d phases=%u\n", waveform_names[i],
		       lut.mode_index, lut.num_phases);
	}

	/* Decode GC16 across every temperature bin. */
	for (i = 0; i < h->temp_range_count; i++) {
		int t = h->temp_range_table[i];

		ret = drm_epd_lut_set_waveform(&lut, DRM_EPD_WF_GC16);
		if (ret < 0)
			failures++;
		ret = drm_epd_lut_set_temperature(&lut, t);
		if (ret < 0) {
			printf("GC16 bin %d (%d C): FAIL %d\n", i, t, ret);
			failures++;
			continue;
		}
		printf("GC16 bin %d (%d C): temp_index=%d phases=%u\n",
		       i, t, lut.temp_index, lut.num_phases);
	}

	if (failures) {
		printf("RESULT: %d failures\n", failures);
		return 1;
	}
	printf("RESULT: ok\n");
	return 0;
}
