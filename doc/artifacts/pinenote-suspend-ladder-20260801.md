# Supervised suspend ladder session — 2026-08-01

Rung 1 PASS, rung 2 mechanics PASS / acceptance FAIL (EBC resume defect),
ladder stopped before deep. Companion to doc/power-management.md and the
doc/status.md entry of the same date.

**Evidence caveat**: the raw rung-2 ground-truth/dmesg files were lost to
a failed scp before device cleanup (the operator error is recorded in
doc/status.md). Every load-bearing value below was captured live in the
session transcript before the loss; the full first-attempt (abort) dmesg
is preserved verbatim at the end.

## Key captures (live session excerpts)

```
attempt 1 (abort):  PM: suspend entry (s2idle) @624.43 -> exit @629.93 (5.5s, dwc3 veto)
  dwc3: wait for SETUP phase timed out / failed to suspend: error -11
  post: vcom 0->1 users, v3p3 1->2, vposneg 0->2, TPS ENABLE 2f->3f
  post: damage unserviced (0 frames), reader boot repaint 0 frames

attempt 2 (clean):  PM: suspend entry (s2idle) @152.79 -> exit @177.50 (24.7s)
  alarm: 1785607180 armed at now=1785607155 (+25s absolute epoch)
  dwc3 window: clean (gadget UDC unbound pre-suspend)
  TPS regs pre/post: identical except ENABLE 2f->3f (EBC rail re-enable)
  regulators: vcom 0->1 users, v3p3 1->2, vposneg 0->2 (same leak, clean cycle)
  EBC resume path: rockchip_ebc_suspend @152.82; plane_reset/ctx_release/ctx_free @177.33
  beacon + post band writes: 0 frames each; user confirms nothing appeared on glass
```

## Full dmesg, attempt 1 session (abort + aftermath)

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x412fd050]
[    0.000000] Linux version 7.0.11 (guix@guix) (aarch64-linux-gnu-gcc (GCC) 14.3.0, GNU ld (GNU Binutils) 2.44) #1 SMP PREEMPT_RT 1
[    0.000000] Machine model: Pine64 PineNote v1.2
[    0.000000] printk: debug: ignoring loglevel setting.
[    0.000000] earlycon: uart0 at MMIO32 0x00000000fe660000 (options '1500000n8')
[    0.000000] printk: legacy bootconsole [uart0] enabled
[    0.000000] efi: UEFI not found.
[    0.000000] OF: reserved mem: 0x000000000010f000..0x000000000010f0ff (0 KiB) nomap non-reusable shmem@10f000
[    0.000000] cma: Reserved 16 MiB at 0x00000000ee800000
[    0.000000] psci: probing for conduit method from DT.
[    0.000000] psci: PSCIv1.1 detected in firmware.
[    0.000000] psci: Using standard PSCI v0.2 function IDs
[    0.000000] psci: Trusted OS migration not required
[    0.000000] psci: SMC Calling Convention v1.2
[    0.000000] Zone ranges:
[    0.000000]   DMA      [mem 0x0000000000200000-0x00000000efffffff]
[    0.000000]   DMA32    empty
[    0.000000]   Normal   empty
[    0.000000] Movable zone start for each node
[    0.000000] Early memory node ranges
[    0.000000]   node   0: [mem 0x0000000000200000-0x00000000083fffff]
[    0.000000]   node   0: [mem 0x0000000009400000-0x00000000efffffff]
[    0.000000] Initmem setup node 0 [mem 0x0000000000200000-0x00000000efffffff]
[    0.000000] On node 0, zone DMA: 512 pages in unavailable ranges
[    0.000000] On node 0, zone DMA: 4096 pages in unavailable ranges
[    0.000000] percpu: Embedded 29 pages/cpu s79152 r8192 d31440 u118784
[    0.000000] pcpu-alloc: s79152 r8192 d31440 u118784 alloc=29*4096
[    0.000000] pcpu-alloc: [0] 0 [0] 1 [0] 2 [0] 3 
[    0.000000] Detected VIPT I-cache on CPU0
[    0.000000] CPU features: detected: GICv3 CPU interface
[    0.000000] CPU features: detected: Virtualization Host Extensions
[    0.000000] CPU features: kernel page table isolation disabled by kernel configuration
[    0.000000] CPU features: detected: ARM errata 1165522, 1319367, or 1530923
[    0.000000] alternatives: applying boot alternatives
[    0.000000] Kernel command line: root=PNGuixRoot gnu.system=/gnu/store/kd4yy9njn54qbh6g3a1m5yp4r2wpc9k1-system gnu.load=/gnu/store/kd4yy9njn54qbh6g3a1m5yp4r2wpc9k1-system/boot ignore_loglevel rw rootwait earlycon console=tty0 console=ttyS2,1500000n8 brcmfmac.feature_disable=0x82000 vt.global_cursor_default=0 fw_devlink=off
[    0.000000] printk: log buffer data + meta data: 262144 + 917504 = 1179648 bytes
[    0.000000] Dentry cache hash table entries: 524288 (order: 10, 4194304 bytes, linear)
[    0.000000] Inode-cache hash table entries: 262144 (order: 9, 2097152 bytes, linear)
[    0.000000] software IO TLB: SWIOTLB bounce buffer size adjusted to 3MB
[    0.000000] software IO TLB: area num 4.
[    0.000000] software IO TLB: SWIOTLB bounce buffer size roundup to 4MB
[    0.000000] software IO TLB: mapped [mem 0x00000000ea18c000-0x00000000ea58c000] (4MB)
[    0.000000] Built 1 zonelists, mobility grouping on.  Total pages: 978432
[    0.000000] mem auto-init: stack:all(zero), heap alloc:off, heap free:off
[    0.000000] SLUB: HWalign=64, Order=0-3, MinObjects=0, CPUs=4, Nodes=1
[    0.000000] ftrace: allocating 39616 entries in 156 pages
[    0.000000] ftrace: allocated 156 pages with 4 groups
[    0.000000] rcu: Preemptible hierarchical RCU implementation.
[    0.000000] rcu: 	RCU event tracing is enabled.
[    0.000000] rcu: 	RCU priority boosting: priority 1 delay 500 ms.
[    0.000000] rcu: 	RCU_SOFTIRQ processing moved to rcuc kthreads.
[    0.000000] 	No expedited grace period (rcu_normal_after_boot).
[    0.000000] 	Trampoline variant of Tasks RCU enabled.
[    0.000000] 	Rude variant of Tasks RCU enabled.
[    0.000000] 	Tracing variant of Tasks RCU enabled.
[    0.000000] rcu: RCU calculated value of scheduler-enlistment delay is 100 jiffies.
[    0.000000] RCU Tasks: Setting shift to 2 and lim to 1 rcu_task_cb_adjust=1 rcu_task_cpu_ids=4.
[    0.000000] RCU Tasks Rude: Setting shift to 2 and lim to 1 rcu_task_cb_adjust=1 rcu_task_cpu_ids=4.
[    0.000000] NR_IRQS: 64, nr_irqs: 64, preallocated irqs: 0
[    0.000000] GIC: enabling workaround for GICv3: non-coherent attribute
[    0.000000] GICv3: GIC: Using split EOI/Deactivate mode
[    0.000000] GICv3: 320 SPIs implemented
[    0.000000] GICv3: 0 Extended SPIs implemented
[    0.000000] GICv3: MBI range [296:319]
[    0.000000] GICv3: Using MBI frame 0x00000000fd410000
[    0.000000] Root IRQ handler: gic_handle_irq
[    0.000000] GICv3: GICv3 features: 16 PPIs
[    0.000000] GICv3: GICD_CTLR.DS=0, SCR_EL3.FIQ=1
[    0.000000] GICv3: CPU0: found redistributor 0 region 0:0x00000000fd460000
[    0.000000] ITS [mem 0xfd440000-0xfd45ffff]
[    0.000000] GIC: enabling workaround for ITS: Rockchip erratum RK3568002
[    0.000000] GIC: enabling workaround for ITS: non-coherent attribute
[    0.000000] ITS@0x00000000fd440000: allocated 8192 Devices @5c0000 (indirect, esz 8, psz 64K, shr 0)
[    0.000000] ITS@0x00000000fd440000: allocated 32768 Interrupt Collections @5d0000 (flat, esz 2, psz 64K, shr 0)
[    0.000000] ITS: using cache flushing for cmd queue
[    0.000000] GICv3: using LPI property table @0x00000000005e0000
[    0.000000] GIC: using cache flushing for LPI property table
[    0.000000] GICv3: CPU0: using allocated LPI pending table @0x00000000005f0000
[    0.000000] rcu: srcu_init: Setting srcu_struct sizes based on contention.
[    0.000000] arch_timer: cp15 timer running at 24.00MHz (phys).
[    0.000000] clocksource: arch_sys_counter: mask: 0xffffffffffffff max_cycles: 0x588fe9dc0, max_idle_ns: 440795202592 ns
[    0.000001] sched_clock: 56 bits at 24MHz, resolution 41ns, wraps every 4398046511097ns
[    0.000937] Console: colour dummy device 80x25
[    0.000997] printk: legacy console [tty0] enabled
[    0.001064] Calibrating delay loop (skipped), value calculated using timer frequency.. 48.00 BogoMIPS (lpj=24000)
[    0.001081] pid_max: default: 32768 minimum: 301
[    0.001475] Mount-cache hash table entries: 8192 (order: 4, 65536 bytes, linear)
[    0.001512] Mountpoint-cache hash table entries: 8192 (order: 4, 65536 bytes, linear)
[    0.002134] VFS: Finished mounting rootfs on nullfs
[    0.006244] rcu: Hierarchical SRCU implementation.
[    0.006262] rcu: 	Max phase no-delay instances is 400.
[    0.050007] Timer migration: 1 hierarchy levels; 8 children per group; 1 crossnode level
[    0.065570] EFI services will not be available.
[    0.066660] smp: Bringing up secondary CPUs ...
[    0.068931] Detected VIPT I-cache on CPU1
[    0.069107] GICv3: CPU1: found redistributor 100 region 0:0x00000000fd480000
[    0.069132] GICv3: CPU1: using allocated LPI pending table @0x0000000000600000
[    0.069197] CPU1: Booted secondary processor 0x0000000100 [0x412fd050]
[    0.073738] Detected VIPT I-cache on CPU2
[    0.073910] GICv3: CPU2: found redistributor 200 region 0:0x00000000fd4a0000
[    0.073932] GICv3: CPU2: using allocated LPI pending table @0x0000000000610000
[    0.073988] CPU2: Booted secondary processor 0x0000000200 [0x412fd050]
[    0.078528] Detected VIPT I-cache on CPU3
[    0.078700] GICv3: CPU3: found redistributor 300 region 0:0x00000000fd4c0000
[    0.078724] GICv3: CPU3: using allocated LPI pending table @0x0000000000620000
[    0.078781] CPU3: Booted secondary processor 0x0000000300 [0x412fd050]
[    0.079004] smp: Brought up 1 node, 4 CPUs
[    0.079017] SMP: Total of 4 processors activated.
[    0.079022] CPU: All CPU(s) started at EL2
[    0.079028] CPU features: detected: 32-bit EL0 Support
[    0.079034] CPU features: detected: Data cache clean to the PoU not required for I/D coherence
[    0.079040] CPU features: detected: Common not Private translations
[    0.079045] CPU features: detected: CRC32 instructions
[    0.079055] CPU features: detected: RCpc load-acquire (LDAPR)
[    0.079060] CPU features: detected: LSE atomic instructions
[    0.079066] CPU features: detected: Privileged Access Never
[    0.079071] CPU features: detected: RAS Extension Support
[    0.079079] CPU features: detected: XNX
[    0.079085] CPU features: detected: Speculative Store Bypassing Safe (SSBS)
[    0.088861] alternatives: applying system-wide alternatives
[    0.094195] CPU features: detected: ICV_DIR_EL1 trapping
[    0.095391] Memory: 3777792K/3913728K available (12096K kernel code, 2520K rwdata, 3288K rodata, 1920K init, 506K bss, 113472K reserved, 16384K cma-reserved)
[    0.098958] devtmpfs: initialized
[    0.123573] clocksource: jiffies: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 1911260446275000 ns
[    0.123640] posixtimers hash table entries: 2048 (order: 5, 81920 bytes, linear)
[    0.123791] futex hash table entries: 1024 (65536 bytes on 1 NUMA nodes, total 64 KiB, linear).
[    0.124236] 27632 pages in range for non-PLT usage
[    0.124248] 519152 pages in range for PLT usage
[    0.126048] DMI not present or invalid.
[    0.127926] NET: Registered PF_NETLINK/PF_ROUTE protocol family
[    0.130565] DMA: preallocated 512 KiB GFP_KERNEL|GFP_DMA pool for atomic allocations
[    0.133795] thermal_sys: Registered thermal governor 'fair_share'
[    0.133806] thermal_sys: Registered thermal governor 'bang_bang'
[    0.133812] thermal_sys: Registered thermal governor 'step_wise'
[    0.133816] thermal_sys: Registered thermal governor 'user_space'
[    0.133821] thermal_sys: Registered thermal governor 'power_allocator'
[    0.136380] cpuidle: using governor menu
[    0.136715] ASID allocator initialised with 65536 entries
[    0.138414] Serial: AMBA PL011 UART driver
[    0.162790] gpio gpiochip0: Static allocation of GPIO base is deprecated, use dynamic allocation.
[    0.164122] rockchip-gpio fdd60000.gpio: probed /pinctrl/gpio@fdd60000
[    0.164789] gpio gpiochip1: Static allocation of GPIO base is deprecated, use dynamic allocation.
[    0.165524] rockchip-gpio fe740000.gpio: probed /pinctrl/gpio@fe740000
[    0.166111] gpio gpiochip2: Static allocation of GPIO base is deprecated, use dynamic allocation.
[    0.166929] rockchip-gpio fe750000.gpio: probed /pinctrl/gpio@fe750000
[    0.167586] gpio gpiochip3: Static allocation of GPIO base is deprecated, use dynamic allocation.
[    0.168258] rockchip-gpio fe760000.gpio: probed /pinctrl/gpio@fe760000
[    0.168791] gpio gpiochip4: Static allocation of GPIO base is deprecated, use dynamic allocation.
[    0.169471] rockchip-gpio fe770000.gpio: probed /pinctrl/gpio@fe770000
[    0.174797] HugeTLB: registered 1.00 GiB page size, pre-allocated 0 pages
[    0.174815] HugeTLB: 0 KiB vmemmap can be freed for a 1.00 GiB page
[    0.174824] HugeTLB: registered 32.0 MiB page size, pre-allocated 0 pages
[    0.174829] HugeTLB: 0 KiB vmemmap can be freed for a 32.0 MiB page
[    0.174836] HugeTLB: registered 2.00 MiB page size, pre-allocated 0 pages
[    0.174841] HugeTLB: 0 KiB vmemmap can be freed for a 2.00 MiB page
[    0.174848] HugeTLB: registered 64.0 KiB page size, pre-allocated 0 pages
[    0.174852] HugeTLB: 0 KiB vmemmap can be freed for a 64.0 KiB page
[    0.177422] fbcon: Taking over console
[    0.177911] iommu: Default domain type: Passthrough
[    0.187693] usbcore: registered new interface driver usbfs
[    0.189585] usbcore: registered new interface driver hub
[    0.190451] usbcore: registered new device driver usb
[    0.192571] pps_core: LinuxPPS API ver. 1 registered
[    0.192582] pps_core: Software ver. 5.3.6 - Copyright 2005-2007 Rodolfo Giometti <giometti@linux.it>
[    0.192608] PTP clock support registered
[    0.192827] scmi_core: SCMI protocol bus registered
[    0.196961] vgaarb: loaded
[    0.197486] clocksource: Switched to clocksource arch_sys_counter
[    0.198403] VFS: Disk quotas dquot_6.6.0
[    0.198455] VFS: Dquot-cache hash table entries: 512 (order 0, 4096 bytes)
[    0.217758] NET: Registered PF_INET protocol family
[    0.218170] IP idents hash table entries: 65536 (order: 7, 524288 bytes, linear)
[    0.222737] tcp_listen_portaddr_hash hash table entries: 2048 (order: 5, 81920 bytes, linear)
[    0.222838] Table-perturb hash table entries: 65536 (order: 6, 262144 bytes, linear)
[    0.222862] TCP established hash table entries: 32768 (order: 6, 262144 bytes, linear)
[    0.223407] TCP bind hash table entries: 32768 (order: 10, 2621440 bytes, linear)
[    0.226297] TCP: Hash tables configured (established 32768 bind 32768)
[    0.226669] UDP hash table entries: 2048 (order: 7, 327680 bytes, linear)
[    0.227072] UDP-Lite hash table entries: 2048 (order: 7, 327680 bytes, linear)
[    0.227808] NET: Registered PF_UNIX/PF_LOCAL protocol family
[    0.227905] PCI: CLS 0 bytes, default 64
[    0.228269] Unpacking initramfs...
[    0.232741] Initialise system trusted keyrings
[    0.233816] workingset: timestamp_bits=46 max_order=20 bucket_order=0
[    0.235240] SGI XFS with ACLs, security attributes, scrub, repair, no debug enabled
[    0.238086] Key type asymmetric registered
[    0.238106] Asymmetric key parser 'x509' registered
[    0.238573] io scheduler bfq registered
[    0.255948] dma-pl330 fe530000.dma-controller: Loaded driver for PL330 DMAC-241330
[    0.255975] dma-pl330 fe530000.dma-controller: 	DBUFF-128x8bytes Num_Chans-8 Num_Peri-32 Num_Events-16
[    0.263081] dma-pl330 fe550000.dma-controller: Loaded driver for PL330 DMAC-241330
[    0.263104] dma-pl330 fe550000.dma-controller: 	DBUFF-128x8bytes Num_Chans-8 Num_Peri-32 Num_Events-16
[    0.264612] rockchip-suspend-mode rockchip-suspend: DORMANT policy core bound; activation compiled out
[    0.266011] Serial: 8250/16550 driver, 4 ports, IRQ sharing disabled
[    0.272463] fe650000.serial: ttyS1 at MMIO 0xfe650000 (irq = 24, base_baud = 1500000) is a 16550A
[    0.272853] serial serial0: tty port ttyS1 registered
[    0.275038] fe660000.serial: ttyS2 at MMIO 0xfe660000 (irq = 25, base_baud = 1500000) is a 16550A
[    0.276198] printk: legacy console [ttyS2] enabled
[    0.276212] printk: legacy bootconsole [uart0] disabled
[    0.282859] platform fdea0000.video-codec: Adding to iommu group 0
[    0.285829] platform fdee0000.video-codec: Adding to iommu group 1
[    0.290345] loop: module loaded
[    0.298637] usbcore: registered new interface driver usbserial_generic
[    0.298699] usbserial: USB Serial support registered for generic
[    0.299065] i2c_dev: i2c /dev entries driver
[    0.302848] fan53555-regulator 0-001c: FAN53555 Option[12] Rev[15] Detected!
[    0.405783] boost: Bringing 4700000uV into 5000000-5000000uV
[    0.419010] input: rk805 pwrkey as /devices/platform/fdd40000.i2c/i2c-0/0-0020/rk805-pwrkey.2.auto/input/input0
[    0.433190] rk808-rtc rk808-rtc.3.auto: registered as rtc0
[    0.436138] rk808-rtc rk808-rtc.3.auto: setting system clock to 2026-08-01T17:20:17 UTC (1785604817)
[    0.450962] lm3630a_bl 3-0036: LM3630A backlight register OK.
[    0.495672] sdhci: Secure Digital Host Controller Interface driver
[    0.495689] sdhci: Copyright(c) Pierre Ossman
[    0.495694] Synopsys Designware Multimedia Card Interface Driver
[    0.496670] sdhci-pltfm: SDHCI platform and OF driver helper
[    0.499722] dwmmc_rockchip fe2c0000.mmc: IDMAC supports 32-bit address mode.
[    0.499805] dwmmc_rockchip fe2c0000.mmc: Using internal DMA controller.
[    0.499820] dwmmc_rockchip fe2c0000.mmc: Version ID is 270a
[    0.500319] dwmmc_rockchip fe2c0000.mmc: DW MMC controller at irq 61,32 bit host data width,256 deep fifo
[    0.501795] arm-scmi arm-scmi.7.auto: Using scmi_smc_transport
[    0.501817] arm-scmi arm-scmi.7.auto: SCMI max-rx-timeout: 30ms / max-msg-size: 104bytes / max-msg: 20
[    0.502119] scmi_protocol scmi_dev.1: Enabled polling mode TX channel - prot_id:16
[    0.502770] arm-scmi arm-scmi.7.auto: SCMI Notifications - Core Enabled.
[    0.502861] arm-scmi arm-scmi.7.auto: Malformed reply - real_sz:8  calc_sz:4  (loop_num_ret:3)
[    0.502875] arm-scmi arm-scmi.7.auto: SCMI Protocol v2.0 'rockchip:' Firmware version 0x0
[    0.502965] arm-scmi arm-scmi.7.auto: Enabling SCMI Quirk [quirk_clock_rates_triplet_out_of_spec]
[    0.505069] hid: raw HID events driver (C) Jiri Kosina
[    0.505416] usbcore: registered new interface driver usbhid
[    0.505426] usbhid: USB HID core driver
[    0.511005] NET: Registered PF_INET6 protocol family
[    0.512677] dwmmc_rockchip fe2c0000.mmc: allocated mmc-pwrseq
[    0.512705] mmc_host mmc1: card is non-removable.
[    0.516212] Segment Routing with IPv6
[    0.516417] In-situ OAM (IOAM) with IPv6
[    0.516649] NET: Registered PF_PACKET protocol family
[    0.529394] registered taskstats version 1
[    0.529425] Loading compiled-in X.509 certificates
[    0.530276] mmc_host mmc1: Bus speed (slot 0) = 375000Hz (slot req 400000Hz, actual 375000HZ div = 0)
[    0.623591] input: gpio-keys as /devices/platform/gpio-keys/input/input1
[    0.667870] clk: Disabling unused clocks
[    0.668769] PM: genpd: Disabling unused power domains
[    0.669709] mmc_host mmc1: Bus speed (slot 0) = 150000000Hz (slot req 150000000Hz, actual 150000000HZ div = 0)
[    0.815552] dwmmc_rockchip fe2c0000.mmc: Successfully tuned phase to 222
[    0.826688] mmc1: new UHS-I speed SDR104 SDIO card at address 0001
[    0.874678] Freeing initrd memory: 12544K
[    0.875207] dw-apb-uart fe660000.serial: forbid DMA for kernel console
[    0.900774] mmc0: SDHCI controller on fe310000.mmc [fe310000.mmc] using ADMA
[    0.905358] Freeing unused kernel memory: 1920K
[    0.905624] Run /init as init process
[    0.905636]   with arguments:
[    0.905642]     /init
[    0.905648]   with environment:
[    0.905652]     HOME=/
[    0.905657]     TERM=linux
[    1.020226] sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
[    1.020309] sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
[    1.020323] sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
[    1.021911] mmc0: new HS200 MMC card at address 0001
[    1.022924] mmcblk0: mmc0:0001 AKJ21X 115 GiB
[    1.025769]  mmcblk0: p1 p2 p3 p4 p5 p6 p7
[    1.027407] mmcblk0boot0: mmc0:0001 AKJ21X 4.00 MiB
[    1.028979] mmcblk0boot1: mmc0:0001 AKJ21X 4.00 MiB
[    1.030594] mmcblk0rpmb: mmc0:0001 AKJ21X 4.00 MiB, chardev (248:0)
[    1.361419] hwmon hwmon4: temp1_input not attached to any thermal zone
[    1.416962] panel-simple panel: Expected bpc in {6,8} but got: 4
[    1.417012] panel-simple panel: supply power not found, using dummy regulator
[    1.952333] rockchip-drm display-subsystem: [drm:0xffff80007953564c] *ERROR* No available vop found for display-subsystem.
[    2.291650] rockchip_ebc_probe start
[    2.300263] rockchip-ebc fdec0000.ebc: [drm] Loaded 4-bit PVI waveform version 0x19
[    2.302389] ebc: rockchip_ebc_plane_reset
[    2.305521] [drm] Initialized rockchip-ebc 0.3.0 for fdec0000.ebc on minor 0
[    2.439681] Console: switching to colour frame buffer device 234x87
[    2.448869] rockchip-ebc fdec0000.ebc: using zero-initialized flat cache, this may cause unexpected behavior
[    2.603992] rockchip-ebc fdec0000.ebc: [drm] fb0: rockchip-ebcdrm frame buffer device
[    2.604194] rockchip-ebc fdec0000.ebc: Direct firmware load for rockchip/rockchip_ebc_default_screen.bin failed with error -2
[    2.813303] EXT4-fs (mmcblk0p6): mounted filesystem 70c4c247-0bbd-3a2e-f332-95ba70c4c247 r/w with ordered data mode. Quota mode: none.
[    5.004517] random: crng init done
[    7.056157] shepherd[1]: GNU Shepherd 1.0.9 (Guile 3.0.9, Fibers < 1.4, aarch64-unknown-linux-gnu)
[    7.056687] shepherd[1]: bit-count is deprecated.  Use bitvector-count, or a loop over array-ref if array support is needed.
[    7.057581] shepherd[1]: scm_bitvector_length is deprecated.  Use scm_c_bitvector_length instead.
[    7.058063] shepherd[1]: Starting service root...
[    7.058978] shepherd[1]: Service root started.
[    7.059335] shepherd[1]: Service root running with value #<<process> id: 1 command: #f>.
[    7.060196] shepherd[1]: Service root has been started.
[    7.065207] shepherd[1]: starting services...
[    7.065842] shepherd[1]: Configuration successfully loaded from '/gnu/store/1i2vv19a8rnkq9ddasnpwsnxv4apmm83-shepherd.conf'.
[    7.103131] shepherd[1]: Starting service root-file-system...
[    7.103787] shepherd[1]: Starting service host-name...
[    7.108723] shepherd[1]: Starting service pam...
[    7.110053] shepherd[1]: Starting service sysctl...
[    7.111883] shepherd[1]: Starting service log-rotation...
[    7.112882] shepherd[1]: Starting service loopback...
[    7.115313] shepherd[1]: Service root-file-system started.
[    7.115897] shepherd[1]: Service host-name started.
[    7.118090] shepherd[1]: Service pam started.
[    7.118597] shepherd[1]: Service log-rotation started.
[    7.119711] shepherd[1]: Service root-file-system running with value #t.
[    7.120986] shepherd[1]: Service host-name running with value "pinenote-reader".
[    7.122563] shepherd[1]: Service pam running with value #t.
[    7.123076] shepherd[1]: Service log-rotation running with value #<timer #<<calendar-event> seconds: (0) minutes: (0) hours: (22) days-of-month: (1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31) months: (1 2 3 4 5 6 7 8 9 10 11 12) days-of-week: (0)> #<procedure rotation ()> ffffa7079560>.
[    7.124272] shepherd[1]: Service root-file-system has been started.
[    7.125334] shepherd[1]: Service host-name has been started.
[    7.126459] shepherd[1]: Service pam has been started.
[    7.127139] shepherd[1]: Service log-rotation has been started.
[    7.128878] shepherd[1]: [sysctl] fs.protected_hardlinks = 1
[    7.130198] shepherd[1]: [sysctl] fs.protected_symlinks = 1
[    7.131457] shepherd[1]: Service sysctl started.
[    7.132091] shepherd[1]: Service sysctl running with value #t.
[    7.134089] shepherd[1]: Service sysctl has been started.
[    7.156179] shepherd[1]: Starting service udev...
[    7.187791] udevd[139]: starting version 3.2.14
[    7.234431] udevd[139]: starting eudev-3.2.14
[    7.660590] udevd[139]: no sender credentials received, message ignored
[    7.679645] shepherd[1]: waiting for udevd...
[    7.687668] shepherd[1]: [iirba8ppyfr8ns4gjpxs4k1b2vzajyf9-set-up-network] Waiting for network device 'lo'...
[    7.688651] shepherd[1]: Registering new logger for udev.
[    7.692457] shepherd[1]: Service loopback started.
[    7.694410] shepherd[1]: Service loopback running with value #t.
[    7.695691] shepherd[1]: Service loopback has been started.
[    7.819125] mc: Linux media interface: v0.10
[    7.871749] videodev: Linux video capture interface: v2.00
[    7.996640] rockchip-rga fdeb0000.rga: HW Version: 0x03.02
[    7.997109] rockchip-rga fdeb0000.rga: Registered rockchip-rga as /dev/video0
[    8.014992] i2c_hid_of 1-0009: supply vddl not found, using dummy regulator
[    8.031061] cfg80211: Loading compiled-in X.509 certificates for regulatory database
[    8.042345] hantro-vpu fdea0000.video-codec: registered rockchip,rk3568-vpu-dec as /dev/video1
[    8.043688] hantro-vpu fdee0000.video-codec: registered rockchip,rk3568-vepu-enc as /dev/video2
[    8.230466] input: w9013 2D1F:0095 Stylus as /devices/platform/fe5a0000.i2c/i2c-1/1-0009/0018:2D1F:0095.0001/input/input2
[    8.233008] input: w9013 2D1F:0095 as /devices/platform/fe5a0000.i2c/i2c-1/1-0009/0018:2D1F:0095.0001/input/input3
[    8.238982] hid-generic 0018:2D1F:0095.0001: input,hidraw0: I2C HID v1.00 Device [w9013 2D1F:0095] on 1-0009
[    8.271294] Loaded X.509 cert 'sforshee: 00b28ddf47aef9cea7'
[    8.271829] Loaded X.509 cert 'wens: 61c038651aabdcf94bd0ac7ff06c7248db18c600'
[    8.278783] cyttsp5 5-0024: supply vddio not found, using dummy regulator
[    8.304936] faux_driver regulatory: Direct firmware load for regulatory.db.p7s failed with error -2
[    8.304963] cfg80211: loaded regulatory.db is malformed or signature is missing/invalid
[    8.317342] input: adc-keys as /devices/platform/adc-keys/input/input6
[    8.334168] st-accel-i2c 5-0018: mounting matrix not found: using identity...
[    8.340573] st-accel-i2c 5-0018: interrupts on the falling edge or active low level
[    8.370769] Bluetooth: Core ver 2.22
[    8.370874] NET: Registered PF_BLUETOOTH protocol family
[    8.370879] Bluetooth: HCI device and connection manager initialized
[    8.370898] Bluetooth: HCI socket layer initialized
[    8.370905] Bluetooth: L2CAP socket layer initialized
[    8.370919] Bluetooth: SCO socket layer initialized
[    8.378169] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43455-sdio for chip BCM4345/6
[    8.401056] Bluetooth: HCI UART driver ver 2.3
[    8.401075] Bluetooth: HCI UART protocol H4 registered
[    8.401395] Bluetooth: HCI UART protocol Broadcom registered
[    8.513196] input: ws8100_pen as /devices/platform/spi-gpio/spi_master/spi4/spi4.0/input/input7
[    8.520861] mousedev: PS/2 mouse device common for all mice
[    8.651040] brcmfmac: brcmf_c_process_txcap_blob: no txcap_blob available (err=-2)
[    8.653028] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/6 wl0: Apr 15 2021 03:03:20 version 7.45.234 (4ca95bb CY) FWID 01-996384e2
[    8.756030] Bluetooth: hci0: BCM: chip id 107
[    8.758490] Bluetooth: hci0: BCM: features 0x2f
[    8.784522] Bluetooth: hci0: BCM4345C0
[    8.784542] Bluetooth: hci0: BCM4345C0 (003.001.025) build 0000
[    8.788204] Bluetooth: hci0: BCM4345C0 'brcm/BCM4345C0.pine64,pinenote-v1.2.hcd' Patch
[    8.896558] power_supply ws8100_pen: driver failed to report `status' property: -74
[    9.186243] input input5: Parameters are specified but the axis 53 is not set up
[    9.186264] input input5: Parameters are specified but the axis 54 is not set up
[    9.186270] input input5: Parameters are specified but the axis 58 is not set up
[    9.186589] input: cyttsp5 as /devices/platform/fe5e0000.i2c/i2c-5/5-0024/input/input5
[    9.614258] EXT4-fs (mmcblk0p7): mounted filesystem 73e99bbd-f1cc-4afb-8371-d7c8bf8dd009 r/w with ordered data mode. Quota mode: none.
[   10.025141] 8021q: 802.1Q VLAN Support v1.8
[   10.103999] dwc3 fcc00000.usb: failed to enable ep0out
[   10.422468] input: wilkbook-orientation as /devices/virtual/input/input8
[   11.955948] Console: switching to colour dummy device 80x25
[   15.940280] Bluetooth: hci0: BCM: features 0x2f
[   15.966285] Bluetooth: hci0: BCM43455 37.4MHz Raspberry Pi 3+-0190
[   15.966306] Bluetooth: hci0: BCM4345C0 (003.001.025) build 0382
[   30.695702] vbat_4g: disabling
[   30.696401] vdd_gpu_npu: disabling
[   30.698202] vdda_0v9_ldo: disabling
[   30.700088] vccio_sd: disabling
[   30.703884] vposneg: disabling
[   61.473271] input: wilkbook-optics as /devices/virtual/input/input9
[   63.967985] Console: switching to colour frame buffer device 234x87
[   65.319391] Console: switching to colour dummy device 80x25
[  528.976030] Console: switching to colour frame buffer device 234x87
[  532.219115] Console: switching to colour dummy device 80x25
[  569.546573] PM: suspend entry (deep)
[  569.546993] Filesystems sync: 0.000 seconds
[  569.547079] Freezing user space processes
[  569.548216] Freezing user space processes completed (elapsed 0.001 seconds)
[  569.548228] OOM killer disabled.
[  569.548230] Freezing remaining freezable tasks
[  569.549608] Freezing remaining freezable tasks completed (elapsed 0.001 seconds)
[  569.549615] PM: suspend debug: Waiting for 5 second(s).
[  574.695740] OOM killer enabled.
[  574.695766] Restarting tasks: Starting
[  574.697846] Restarting tasks: Done
[  574.698016] PM: suspend exit
[  624.430052] PM: suspend entry (s2idle)
[  624.434070] Filesystems sync: 0.003 seconds
[  624.434189] Freezing user space processes
[  624.435767] Freezing user space processes completed (elapsed 0.001 seconds)
[  624.435778] OOM killer disabled.
[  624.435780] Freezing remaining freezable tasks
[  624.437120] Freezing remaining freezable tasks completed (elapsed 0.001 seconds)
[  624.437129] printk: Suspending console(s) (use no_console_suspend to debug)
[  624.454976] rockchip_ebc_suspend
[  625.591551] dwc3 fcc00000.usb: wait for SETUP phase timed out
[  625.593114] dwc3 fcc00000.usb: failed to set STALL on ep0out
[  625.594660] dwc3 fcc00000.usb: ep0 out start transfer failed: -110
[  629.701975] dwc3 fcc00000.usb: failed to enable ep0out
[  629.704055] dwc3 fcc00000.usb: PM: dpm_run_callback(): dwc3_plat_suspend returns -11
[  629.704092] dwc3 fcc00000.usb: PM: failed to suspend: error -11
[  629.704234] PM: Some devices failed to suspend, or early wake event detected
[  629.760146] ebc: rockchip_ebc_plane_reset
[  629.760571] ebc: rockchip_ebc_ctx_release
[  629.760585] EBC: rockchip_ebc_ctx_free
[  629.914303] PM: resume devices took 0.210 seconds
[  629.926610] OOM killer enabled.
[  629.926620] Restarting tasks: Starting
[  629.928230] Restarting tasks: Done
[  629.928351] PM: suspend exit
[  629.989482] sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
[  629.989578] sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
[  629.989593] sdhci-dwcmshc fe310000.mmc: Can't reduce the clock below 52MHz in HS200/HS400 mode
[  632.059408] brcmfmac: brcmf_set_channel: set chanspec 0x100c fail, reason -52
[  632.061360] brcmfmac: brcmf_set_channel: set chanspec 0x100d fail, reason -52
[  632.063123] brcmfmac: brcmf_set_channel: set chanspec 0x100e fail, reason -52
[  632.064629] brcmfmac: brcmf_set_channel: set chanspec 0xd022 fail, reason -52
[  632.175604] brcmfmac: brcmf_set_channel: set chanspec 0xd026 fail, reason -52
[  632.286602] brcmfmac: brcmf_set_channel: set chanspec 0xd02a fail, reason -52
[  632.400449] brcmfmac: brcmf_set_channel: set chanspec 0xd02e fail, reason -52
[  632.512445] brcmfmac: brcmf_set_channel: set chanspec 0xd034 fail, reason -52
[  632.514026] brcmfmac: brcmf_set_channel: set chanspec 0xd038 fail, reason -52
[  632.515273] brcmfmac: brcmf_set_channel: set chanspec 0xd03c fail, reason -52
```
