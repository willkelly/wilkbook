// SPDX-License-Identifier: GPL-2.0
/*
 * ddr-dvfs-test — supervised Rockchip DRAM SIP DVFS test module for the
 * PineNote (RK3566, BSP bl31, DDR ATF version 0x101).
 *
 * Successor to pinenote/tools/ddr-sip-probe (which proved, read-only, that
 * this device's bl31 implements SIP_DRAM_CONFIG 0x82000008 at version
 * 0x101).  This module performs the *minimum* BSP-faithful sequence needed
 * to (a) read the firmware's supported-frequency table and (b) issue a
 * single supervised SET_RATE, so that DDR DVFS is proven (or disproven) on
 * this device before anyone writes a real devfreq driver.
 *
 * Every call shape below is copied from the Rockchip BSP develop-6.1 tree
 * (github.com/rockchip-linux/kernel), rk3568 path:
 *   drivers/devfreq/rockchip_dmc.c   rk3568_dmc_init():1864-1934
 *                                    rockchip_ddr_set_rate():340-357
 *                                    rockchip_get_freq_info():1188-1211
 *                                    rockchip_dmcfreq_wait_complete():1140-1186
 *   drivers/firmware/rockchip_sip.c  sip_smc_dram():49-53,
 *                                    sip_smc_request_share_mem():168-184,
 *                                    sip_map():130-166
 *   drivers/clk/rockchip/clk-ddr.c   v2 GET_RATE/ROUND_RATE:140-170
 *   include/linux/rockchip/rockchip_sip.h, include/soc/rockchip/rockchip_sip.h
 * See ddr-dvfs/protocol.md for the full analysis and citations.
 *
 * Safety model:
 *  - init NEVER fails: if any step errors, the module stays loaded with
 *    set_rate hard-disabled so the state is inspectable, and it remains
 *    removable.
 *  - set_rate refuses unless the module was loaded with allow_set=1, the
 *    BSP init sequence (share-mem + DRAM_INIT + GET_FREQ_INFO) succeeded,
 *    the target is an exact entry of the firmware's own table, and
 *    ROUND_RATE agrees.  An accidental write with allow_set=0 does nothing.
 *  - the ORIGINAL (boot) rate is recorded at init; rmmod restores it if a
 *    set_rate changed it.
 *  - EBC idle is an OPERATOR precondition (see ddr-dvfs/procedure.md); the
 *    module does not try to detect display state.
 *
 * No devfreq, no OPPs, no governors, no regulators, no interrupts.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/arm-smccc.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/mutex.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/ktime.h>
#include <linux/uaccess.h>

/* include/linux/rockchip/rockchip_sip.h:29-31 */
#define SIP_DRAM_CONFIG			0x82000008
#define SIP_SHARE_MEM			0x82000009
#define SIP_SIP_VERSION			0x8200000a

/* include/linux/rockchip/rockchip_sip.h:86-92 */
#define SIP_RET_SUCCESS			0
#define SIP_RET_SET_RATE_TIMEOUT	-6

/* include/linux/rockchip/rockchip_sip.h:194-206 (share_page_type_t) */
#define SHARE_PAGE_TYPE_DDR		2

/* include/soc/rockchip/rockchip_sip.h:10-24 */
#define DRAM_INIT			0x00
#define DRAM_SET_RATE			0x01
#define DRAM_ROUND_RATE			0x02
#define DRAM_GET_RATE			0x05
#define DRAM_GET_VERSION		0x08
#define DRAM_POST_SET_RATE		0x09
#define DRAM_MCU_START			0x0c
#define DRAM_GET_FREQ_INFO		0x0e

/* drivers/devfreq/rockchip_dmc.c:65 */
#define MAX_FREQ_COUNT			6
/* rk3568 requests 2 pages: rockchip_dmc.c:1884 */
#define DDR_PAGE_NUM			2
#define DDR_SHARE_SIZE			(DDR_PAGE_NUM * 4096)

/* SCREEN_NULL: include/soc/rockchip/rockchip_dmc.h:19 */
#define SCREEN_NULL			0

/*
 * Interface-parameter block at offset 0 of the DDR share page —
 * drivers/devfreq/rockchip_dmc.c:72-98, verbatim.
 */
struct share_params {
	u32 hz;
	u32 lcdc_type;
	u32 vop;
	u32 vop_dclk_mode;
	u32 sr_idle_en;
	u32 addr_mcu_el3;
	u32 wait_flag1;
	u32 wait_flag0;
	u32 complt_hwirq;
	u32 update_drv_odt_cfg;
	u32 update_deskew_cfg;
	u32 freq_count;
	u32 freq_info_mhz[MAX_FREQ_COUNT];
	u32 wait_mode;
	u32 vop_scan_line_time_ns;
};

static bool allow_set;
module_param(allow_set, bool, 0444);
MODULE_PARM_DESC(allow_set, "permit writes to debugfs set_rate (default off)");

static bool dram_init = true;
module_param(dram_init, bool, 0444);
MODULE_PARM_DESC(dram_init,
	"issue CONFIG_DRAM_INIT before GET_FREQ_INFO, as the BSP does (default on; 0 = probe GET_FREQ_INFO without it)");

static struct {
	struct mutex lock;		/* serializes all firmware calls */
	struct dentry *dir;

	volatile struct share_params *params;	/* mapped share page */
	void *map_base;			/* base vaddr actually mapped */
	phys_addr_t share_phys;
	bool map_is_vmap;		/* vmap() vs ioremap() teardown */

	unsigned long fw_version;	/* DDR ATF version (expect 0x101) */
	bool share_ok;
	bool init_ok;			/* DRAM_INIT succeeded (or skipped) */
	bool init_was_run;		/* DRAM_INIT actually issued+ok */
	bool freq_ok;

	u32 freq_count;
	u32 freq_mhz[MAX_FREQ_COUNT];

	u64 orig_rate_hz;		/* boot rate, from GET_RATE at init */
	bool orig_rate_valid;
	bool rate_changed;		/* a set_rate succeeded this insmod */

	const char *disable_reason;	/* why set_rate is refused, if so */
} st = {
	.disable_reason = "init incomplete",
};

static struct arm_smccc_res dram_smc(unsigned long a1, unsigned long a2,
				     unsigned long a3)
{
	struct arm_smccc_res res;

	/* sip_smc_dram(): rockchip_sip.c:49-53 via __invoke_sip_fn_smc:38-47 */
	arm_smccc_smc(SIP_DRAM_CONFIG, a1, a2, a3, 0, 0, 0, 0, &res);
	return res;
}

/*
 * Map the physical share page the firmware handed us.  Logic copied from
 * the BSP's sip_map() (rockchip_sip.c:130-166): if the page lives inside
 * the kernel's memory map use a non-cached vmap, otherwise ioremap.
 */
static void *ddr_share_map(phys_addr_t start, size_t size, bool *is_vmap)
{
	struct page **pages;
	phys_addr_t page_start;
	unsigned int page_count;
	unsigned int i;
	void *vaddr;

	if (!pfn_valid(__phys_to_pfn(start))) {
		*is_vmap = false;
		return ioremap(start, size);
	}

	page_start = start - offset_in_page(start);
	page_count = DIV_ROUND_UP(size + offset_in_page(start), PAGE_SIZE);

	pages = kmalloc_array(page_count, sizeof(struct page *), GFP_KERNEL);
	if (!pages)
		return NULL;
	for (i = 0; i < page_count; i++)
		pages[i] = phys_to_page(page_start + i * PAGE_SIZE);

	vaddr = vmap(pages, page_count, VM_MAP, pgprot_noncached(PAGE_KERNEL));
	kfree(pages);
	*is_vmap = true;

	return vaddr ? vaddr + offset_in_page(start) : NULL;
}

/* v2 GET_RATE: error in a0, rate (Hz) in a1 — clk-ddr.c:140-151 */
static int ddr_get_rate(u64 *hz)
{
	struct arm_smccc_res res;

	res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_GET_RATE);
	if ((long)res.a0) {
		pr_warn("ddr_dvfs_test: GET_RATE failed a0=%ld a1=0x%lx\n",
			(long)res.a0, res.a1);
		return -EIO;
	}
	*hz = res.a1;
	return 0;
}

/*
 * Perform one SET_RATE, BSP-faithfully (rockchip_ddr_set_rate():340-357 +
 * the dcf_en==2 completion path of rockchip_dmcfreq_wait_complete():
 * 1140-1186).  Caller holds st.lock and has validated the target.
 *
 * Differences from the BSP, deliberate and documented in protocol.md:
 *  - lcdc_type = SCREEN_NULL (no VOP display on this board; BSP would
 *    derive the same value here since no DRM connector exists),
 *    vop_scan_line_time_ns left 0.
 *  - the DDR-MCU completion is awaited with a fixed sleep longer than the
 *    BSP's 85 ms IRQ budget instead of the "complete" IRQ (GIC SPI 10),
 *    then POST_SET_RATE exactly as both BSP completion paths do.  We do
 *    not SMC into EL3 while the MCU sequence may be running.
 */
static int ddr_set_rate_locked(u64 target_hz)
{
	struct arm_smccc_res res;
	ktime_t t0, t1;
	u64 verify_hz = 0;
	int ret;

	st.params->hz = (u32)target_hz;
	st.params->lcdc_type = SCREEN_NULL;
	st.params->wait_flag1 = 1;
	st.params->wait_flag0 = 1;

	t0 = ktime_get();
	pr_info("ddr_dvfs_test: SET_RATE -> %llu Hz issuing SMC now (t=%lld ns)\n",
		target_hz, ktime_to_ns(t0));

	res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_SET_RATE);
	t1 = ktime_get();
	pr_info("ddr_dvfs_test: SET_RATE SMC returned a0=%ld a1=%ld after %lld us\n",
		(long)res.a0, (long)res.a1,
		ktime_us_delta(t1, t0));

	if ((long)res.a0) {
		pr_err("ddr_dvfs_test: SET_RATE rejected by firmware (a0=%ld)\n",
		       (long)res.a0);
		return -EIO;
	}

	if ((int)res.a1 == SIP_RET_SET_RATE_TIMEOUT) {
		/* Asynchronous path: change is executed by the DDR MCU.
		 * BSP: MCU_START, wait complete IRQ <=85 ms, POST_SET_RATE
		 * (rockchip_dmc.c:1157-1180). */
		pr_info("ddr_dvfs_test: firmware deferred to DDR MCU; MCU_START + 100 ms wait\n");
		res = dram_smc(0, 0, DRAM_MCU_START);
		if ((long)res.a0) {
			pr_err("ddr_dvfs_test: MCU_START failed a0=%ld; issuing POST_SET_RATE to stop MCU\n",
			       (long)res.a0);
			res = dram_smc(SHARE_PAGE_TYPE_DDR, 0,
				       DRAM_POST_SET_RATE);
			if ((long)res.a0)
				pr_err("ddr_dvfs_test: POST_SET_RATE after failed MCU_START: a0=%ld\n",
				       (long)res.a0);
			return -EIO;
		}
		/* > BSP's wait_time_out_ms = 17*5 = 85 ms (rockchip_dmc.c:1898) */
		msleep(100);
		res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_POST_SET_RATE);
		if ((long)res.a0)
			pr_err("ddr_dvfs_test: POST_SET_RATE error a0=%ld (BSP logs and continues here)\n",
			       (long)res.a0);
	}

	ret = ddr_get_rate(&verify_hz);
	t1 = ktime_get();
	if (ret) {
		pr_err("ddr_dvfs_test: GET_RATE verify failed after SET_RATE\n");
		return ret;
	}
	pr_info("ddr_dvfs_test: SET_RATE done: GET_RATE now %llu Hz (wanted %llu) total %lld us (t=%lld ns)\n",
		verify_hz, target_hz, ktime_us_delta(t1, t0), ktime_to_ns(t1));

	if (verify_hz != target_hz) {
		pr_err("ddr_dvfs_test: VERIFY MISMATCH: firmware reports %llu Hz\n",
		       verify_hz);
		/* the rate may still have changed — track reality */
		if (st.orig_rate_valid && verify_hz != st.orig_rate_hz)
			st.rate_changed = true;
		return -EREMOTEIO;
	}

	if (st.orig_rate_valid && verify_hz != st.orig_rate_hz)
		st.rate_changed = true;
	else
		st.rate_changed = false;

	return 0;
}

/* ---------------------------- debugfs ---------------------------------- */

static int freq_table_show(struct seq_file *m, void *v)
{
	u32 i;

	mutex_lock(&st.lock);
	if (!st.freq_ok) {
		seq_puts(m, "unavailable (GET_FREQ_INFO failed or not run; see dmesg)\n");
	} else {
		seq_printf(m, "freq_count %u\n", st.freq_count);
		for (i = 0; i < st.freq_count; i++)
			seq_printf(m, "%u: %u MHz\n", i, st.freq_mhz[i]);
	}
	mutex_unlock(&st.lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(freq_table);

static int cur_rate_show(struct seq_file *m, void *v)
{
	u64 hz;
	int ret;

	mutex_lock(&st.lock);
	ret = ddr_get_rate(&hz);
	mutex_unlock(&st.lock);
	if (ret)
		seq_printf(m, "GET_RATE error %d\n", ret);
	else
		seq_printf(m, "%llu Hz (%llu MHz)\n", hz,
			   div_u64(hz, 1000000));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(cur_rate);

static int status_show(struct seq_file *m, void *v)
{
	mutex_lock(&st.lock);
	seq_printf(m, "fw_version 0x%lx\n", st.fw_version);
	seq_printf(m, "share_phys 0x%llx\n", (u64)st.share_phys);
	seq_printf(m, "share_ok %d\ninit_ok %d\ninit_was_run %d\nfreq_ok %d\n",
		   st.share_ok, st.init_ok, st.init_was_run, st.freq_ok);
	seq_printf(m, "allow_set %d\n", allow_set);
	seq_printf(m, "set_enabled %d%s%s\n",
		   !st.disable_reason,
		   st.disable_reason ? " reason: " : "",
		   st.disable_reason ? st.disable_reason : "");
	if (st.orig_rate_valid)
		seq_printf(m, "orig_rate_hz %llu\n", st.orig_rate_hz);
	else
		seq_puts(m, "orig_rate_hz unknown\n");
	seq_printf(m, "rate_changed %d\n", st.rate_changed);
	mutex_unlock(&st.lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(status);

static ssize_t set_rate_write(struct file *file, const char __user *ubuf,
			      size_t count, loff_t *ppos)
{
	struct arm_smccc_res res;
	u32 mhz;
	u64 target_hz;
	u32 i;
	int ret;

	ret = kstrtou32_from_user(ubuf, count, 0, &mhz);
	if (ret)
		return ret;

	mutex_lock(&st.lock);

	if (!allow_set) {
		pr_info("ddr_dvfs_test: set_rate %u MHz REFUSED: module loaded without allow_set=1\n",
			mhz);
		ret = -EPERM;
		goto out;
	}
	if (st.disable_reason) {
		pr_info("ddr_dvfs_test: set_rate %u MHz REFUSED: %s\n",
			mhz, st.disable_reason);
		ret = -EPERM;
		goto out;
	}
	for (i = 0; i < st.freq_count; i++)
		if (st.freq_mhz[i] == mhz)
			break;
	if (i == st.freq_count) {
		pr_info("ddr_dvfs_test: set_rate %u MHz REFUSED: not in firmware freq table\n",
			mhz);
		ret = -EINVAL;
		goto out;
	}

	target_hz = (u64)mhz * 1000000;

	/* ROUND_RATE cross-check (v2: hz in page, result in a1 —
	 * clk-ddr.c:153-170).  A disagreement means the firmware would not
	 * run at exactly this rate; refuse rather than guess. */
	st.params->hz = (u32)target_hz;
	res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_ROUND_RATE);
	if ((long)res.a0 || res.a1 != target_hz) {
		pr_info("ddr_dvfs_test: set_rate %u MHz REFUSED: ROUND_RATE a0=%ld a1=%lu (wanted %llu)\n",
			mhz, (long)res.a0, res.a1, target_hz);
		ret = -EINVAL;
		goto out;
	}

	ret = ddr_set_rate_locked(target_hz);
out:
	mutex_unlock(&st.lock);
	return ret ? ret : count;
}

static const struct file_operations set_rate_fops = {
	.owner = THIS_MODULE,
	.write = set_rate_write,
};

/* ------------------------------ init ----------------------------------- */

static int __init ddr_dvfs_test_init(void)
{
	struct arm_smccc_res res;
	u64 hz;
	u32 i;

	mutex_init(&st.lock);

	pr_info("ddr_dvfs_test: init (allow_set=%d dram_init=%d); every SMC is announced before it is issued\n",
		allow_set, dram_init);

	/* 1. DRAM_GET_VERSION — known-good on this device (probe: 0x101) */
	pr_info("ddr_dvfs_test: step 1: DRAM_GET_VERSION\n");
	res = dram_smc(0, 0, DRAM_GET_VERSION);
	if ((long)res.a0) {
		pr_err("ddr_dvfs_test: GET_VERSION failed a0=%ld — refusing everything\n",
		       (long)res.a0);
		st.disable_reason = "GET_VERSION failed";
		goto register_debugfs;
	}
	st.fw_version = res.a1;
	pr_info("ddr_dvfs_test: DDR ATF version 0x%lx\n", st.fw_version);
	if (st.fw_version < 0x101)
		pr_warn("ddr_dvfs_test: version below rk3568 BSP floor 0x101 (rockchip_dmc.c:1874)\n");

	/* 2. current rate before any state is established (informational) */
	pr_info("ddr_dvfs_test: step 2: GET_RATE (pre-share-mem, informational)\n");
	res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_GET_RATE);
	pr_info("ddr_dvfs_test: GET_RATE(pre) a0=%ld a1=%lu\n",
		(long)res.a0, res.a1);

	/* 3. share memory: SIP_SHARE_MEM, 2 pages, type DDR
	 * (sip_smc_request_share_mem():168-184; rk3568_dmc_init():1884-1891) */
	pr_info("ddr_dvfs_test: step 3: SIP_SHARE_MEM %u pages type DDR\n",
		DDR_PAGE_NUM);
	arm_smccc_smc(SIP_SHARE_MEM, DDR_PAGE_NUM, SHARE_PAGE_TYPE_DDR, 0,
		      0, 0, 0, 0, &res);
	if ((long)res.a0) {
		pr_err("ddr_dvfs_test: SHARE_MEM failed a0=%ld — set_rate disabled\n",
		       (long)res.a0);
		st.disable_reason = "SHARE_MEM failed";
		goto register_debugfs;
	}
	st.share_phys = res.a1;
	pr_info("ddr_dvfs_test: share page phys 0x%llx, mapping\n",
		(u64)st.share_phys);
	st.map_base = ddr_share_map(st.share_phys, DDR_SHARE_SIZE,
				    &st.map_is_vmap);
	if (!st.map_base) {
		pr_err("ddr_dvfs_test: share page map failed — set_rate disabled\n");
		st.disable_reason = "share page map failed";
		goto register_debugfs;
	}
	st.params = (volatile struct share_params *)st.map_base;
	/* BSP zeroes the whole region before DRAM_INIT (rockchip_dmc.c:1891) */
	memset_io((void __iomem *)st.map_base, 0, DDR_SHARE_SIZE);
	st.share_ok = true;

	/* 4. DRAM_INIT with a zeroed page, exactly as rk3568_dmc_init():1916
	 * does (no DT timing exists for this SoC's share page — see
	 * protocol.md).  Skippable via dram_init=0 for a more conservative
	 * first probe. */
	if (dram_init) {
		pr_info("ddr_dvfs_test: step 4: CONFIG_DRAM_INIT (zeroed page, BSP-faithful)\n");
		res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_INIT);
		if ((long)res.a0) {
			pr_err("ddr_dvfs_test: DRAM_INIT failed a0=%ld — set_rate disabled\n",
			       (long)res.a0);
			st.disable_reason = "DRAM_INIT failed";
			goto register_debugfs;
		}
		st.init_was_run = true;
		st.init_ok = true;
		pr_info("ddr_dvfs_test: DRAM_INIT ok\n");
	} else {
		pr_info("ddr_dvfs_test: step 4: DRAM_INIT SKIPPED (dram_init=0) — set_rate will stay disabled\n");
		st.init_ok = false;
	}

	/* 5. GET_FREQ_INFO (rockchip_get_freq_info():1196-1211) */
	pr_info("ddr_dvfs_test: step 5: CONFIG_DRAM_GET_FREQ_INFO\n");
	res = dram_smc(SHARE_PAGE_TYPE_DDR, 0, DRAM_GET_FREQ_INFO);
	if ((long)res.a0) {
		pr_err("ddr_dvfs_test: GET_FREQ_INFO failed a0=%ld — set_rate disabled\n",
		       (long)res.a0);
		st.disable_reason = "GET_FREQ_INFO failed";
		goto post_freq;
	}
	st.freq_count = st.params->freq_count;
	if (st.freq_count == 0 || st.freq_count > MAX_FREQ_COUNT) {
		pr_err("ddr_dvfs_test: GET_FREQ_INFO freq_count=%u invalid (BSP accepts 1..%u) — set_rate disabled\n",
		       st.freq_count, MAX_FREQ_COUNT);
		st.freq_count = 0;
		st.disable_reason = "freq table invalid";
		goto post_freq;
	}
	for (i = 0; i < st.freq_count; i++) {
		st.freq_mhz[i] = st.params->freq_info_mhz[i];
		pr_info("ddr_dvfs_test: freq_table[%u] = %u MHz\n",
			i, st.freq_mhz[i]);
	}
	st.freq_ok = true;

post_freq:
	/* 6. record the ORIGINAL boot rate */
	pr_info("ddr_dvfs_test: step 6: GET_RATE (record original rate)\n");
	if (!ddr_get_rate(&hz)) {
		st.orig_rate_hz = hz;
		st.orig_rate_valid = true;
		pr_info("ddr_dvfs_test: original rate %llu Hz (%llu MHz)\n",
			hz, div_u64(hz, 1000000));
	} else {
		pr_err("ddr_dvfs_test: could not read original rate — set_rate disabled\n");
		if (!st.disable_reason)
			st.disable_reason = "original rate unknown";
	}

	if (st.freq_ok && st.init_ok && st.orig_rate_valid)
		st.disable_reason = NULL;	/* set_rate armed (still needs allow_set) */
	else if (st.freq_ok && !st.init_ok)
		st.disable_reason = "DRAM_INIT not run (dram_init=0)";

register_debugfs:
	st.dir = debugfs_create_dir("ddr-dvfs-test", NULL);
	if (IS_ERR_OR_NULL(st.dir)) {
		pr_err("ddr_dvfs_test: debugfs dir creation failed (%ld); state only in dmesg\n",
		       PTR_ERR(st.dir));
		st.dir = NULL;
	} else {
		debugfs_create_file("freq_table", 0400, st.dir, NULL,
				    &freq_table_fops);
		debugfs_create_file("current", 0400, st.dir, NULL,
				    &cur_rate_fops);
		debugfs_create_file("status", 0400, st.dir, NULL,
				    &status_fops);
		debugfs_create_file("set_rate", 0200, st.dir, NULL,
				    &set_rate_fops);
	}

	pr_info("ddr_dvfs_test: loaded; set_rate %s\n",
		st.disable_reason ? st.disable_reason :
		(allow_set ? "ARMED (allow_set=1)" : "disarmed (allow_set=0)"));
	return 0;
}
module_init(ddr_dvfs_test_init);

static void __exit ddr_dvfs_test_exit(void)
{
	u64 hz;

	debugfs_remove_recursive(st.dir);

	mutex_lock(&st.lock);
	if (st.rate_changed && st.orig_rate_valid && st.share_ok) {
		if (!ddr_get_rate(&hz) && hz != st.orig_rate_hz) {
			pr_info("ddr_dvfs_test: exit: rate %llu Hz differs from original %llu Hz — RESTORING (operator must have ensured EBC idle, see procedure.md)\n",
				hz, st.orig_rate_hz);
			if (ddr_set_rate_locked(st.orig_rate_hz))
				pr_err("ddr_dvfs_test: exit: RESTORE FAILED — DDR is NOT at the boot rate; do not suspend, reboot when convenient\n");
			else
				pr_info("ddr_dvfs_test: exit: original rate restored\n");
		} else {
			pr_info("ddr_dvfs_test: exit: rate already at original %llu Hz\n",
				st.orig_rate_hz);
		}
	}

	if (st.map_base) {
		if (st.map_is_vmap)
			vunmap(st.map_base - offset_in_page(st.share_phys));
		else
			iounmap((void __iomem *)st.map_base);
		st.map_base = NULL;
		st.params = NULL;
	}
	mutex_unlock(&st.lock);

	pr_info("ddr_dvfs_test: unloaded (firmware share-page registration persists until reboot; re-insmod reuses it)\n");
}
module_exit(ddr_dvfs_test_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("wilkbook");
MODULE_DESCRIPTION("Supervised Rockchip DRAM SIP DVFS test (freq table + single SET_RATE)");
