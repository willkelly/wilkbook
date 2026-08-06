// SPDX-License-Identifier: GPL-2.0
/*
 * ddr-sip-probe — strictly read-only probe of the Rockchip SIP interface
 * in bl31, for the PineNote (RK3566) go/no-go question: "does this
 * device's trusted firmware implement the DRAM-frequency SIP interface
 * (0x82000008) at all, and what version does it report?"
 *
 * Issues exactly three SMCs, all of them version/info *queries*:
 *
 *   1. SIP_ATF_VERSION   (0x82000001, args 0,0,0)
 *   2. SIP_SIP_VERSION   (0x8200000a, args 0,0,0)
 *   3. SIP_DRAM_CONFIG   (0x82000008, args 0,0,CONFIG_DRAM_GET_VERSION)
 *
 * No SET_* subfunction, no SHARE_MEM setup, no state, no sysfs.  Per
 * SMCCC, an unimplemented function ID returns SMC_UNK (-1) harmlessly.
 * init prints the raw a0..a3 of each call and returns -ENODEV so the
 * module never stays loaded.
 *
 * Constants and calling convention taken verbatim from the Rockchip BSP:
 *   include/linux/rockchip/rockchip_sip.h (function IDs, SIP_RET_*)
 *   include/soc/rockchip/rockchip_sip.h   (DRAM subfunction codes)
 *   drivers/firmware/rockchip_sip.c       sip_smc_dram():
 *       arm_smccc_smc(SIP_DRAM_CONFIG, arg0, arg1, arg2, 0, 0, 0, 0, &res)
 *   drivers/devfreq/rockchip_dmc.c        GET_VERSION call shape:
 *       sip_smc_dram(0, 0, ROCKCHIP_SIP_CONFIG_DRAM_GET_VERSION)
 *       -> res.a0 == 0 on success, DDR ATF version in res.a1
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/arm-smccc.h>

/* include/linux/rockchip/rockchip_sip.h */
#define SIP_ATF_VERSION			0x82000001
#define SIP_DRAM_CONFIG			0x82000008
#define SIP_SIP_VERSION			0x8200000a

/* include/soc/rockchip/rockchip_sip.h */
#define ROCKCHIP_SIP_CONFIG_DRAM_GET_VERSION	0x08

static void ddr_sip_probe_one(const char *name, unsigned long fid,
			      unsigned long a1, unsigned long a2,
			      unsigned long a3)
{
	struct arm_smccc_res res;

	arm_smccc_smc(fid, a1, a2, a3, 0, 0, 0, 0, &res);
	pr_info("ddr_sip_probe: %s fid=0x%08lx args=(0x%lx,0x%lx,0x%lx) -> a0=0x%lx a1=0x%lx a2=0x%lx a3=0x%lx\n",
		name, fid, a1, a2, a3, res.a0, res.a1, res.a2, res.a3);
}

static int __init ddr_sip_probe_init(void)
{
	pr_info("ddr_sip_probe: read-only Rockchip SIP version queries (no SET calls, no share-mem)\n");

	ddr_sip_probe_one("ATF_VERSION", SIP_ATF_VERSION, 0, 0, 0);
	ddr_sip_probe_one("SIP_VERSION", SIP_SIP_VERSION, 0, 0, 0);
	ddr_sip_probe_one("DRAM_GET_VERSION", SIP_DRAM_CONFIG,
			  0, 0, ROCKCHIP_SIP_CONFIG_DRAM_GET_VERSION);

	pr_info("ddr_sip_probe: a0=0 => implemented (version in a1); a0=0xffffffffffffffff (SMC_UNK) => not implemented; done, refusing to stay loaded\n");
	return -ENODEV;	/* query-only: never remain resident */
}
module_init(ddr_sip_probe_init);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("wilkbook");
MODULE_DESCRIPTION("Read-only Rockchip DRAM SIP version probe (fails init by design)");
