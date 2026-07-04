/* wbf-info: host-side inspector/test harness for PVI .wbf waveform files.
 *
 * Compiles the verbatim drm_epd_helper.c from the forward-port patch
 * (extracted at build time) against a small kernel-API shim, then loads a
 * waveform file exactly the way rockchip_ebc does on the device
 * (DRM_EPD_LUT_4BIT_PACKED, 256 max phases) and reports what the kernel
 * would see.  Output is line-oriented for run-tests.sh to assert on.
 *
 * Usage: wbf-info FILE.wbf [TEMPERATURE_C]
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

int main(int argc, char **argv)
{
	struct drm_epd_lut_file file = { 0 };
	struct drm_epd_lut lut = { 0 };
	struct drm_device dev = { 0 };
	const struct pvi_wbf_file_header *h;
	int temperature = DRM_EPD_DEFAULT_TEMPERATURE;
	int ret, i, failures = 0;

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
