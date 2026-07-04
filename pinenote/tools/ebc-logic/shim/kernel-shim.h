/* Kernel-API shim so the verbatim rockchip_ebc.c and drm_epd_helper.c from
 * the forward-port patch compile as one host test TU (see ebc-logic-test.c
 * and ebc-refresh-test.c).
 *
 * Follows rung 1 (pinenote/tools/wbf/shim/): every kernel header the driver
 * includes is a one-line stub pointing here.  Three classes of definitions:
 *
 *  - FAITHFUL: anything the pure logic under test actually executes must
 *    match kernel semantics: list_head ops, drm_rect ops, kref, the
 *    allocators, container_of.  These are reimplemented per the kernel's
 *    documented behavior.
 *  - HARNESS: the hardware-facing seams the refresh harness executes
 *    (regmap, dma-mapping, completion, pm_runtime, kthread, irq
 *    registration).  These keep kernel-observable semantics (counting
 *    completions, a register file, a DMA handle registry) and expose their
 *    state through `ebc_shim` so a fake device (shim/fake-ebc.h) can sit
 *    behind them.  With no hooks installed they degrade to the old inert
 *    behavior, so ebc-logic-test is unaffected.
 *  - INERT: everything else only needs to compile; stubs return
 *    0/NULL/success.
 *
 * Little-endian hosts only (x86-64/aarch64): le32_to_cpu is the identity.
 * Single-TU use only: several stubs define file-scope objects.
 */
#ifndef EBC_LOGIC_KERNEL_SHIM_H
#define EBC_LOGIC_KERNEL_SHIM_H

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- basic types ------------------------------------------------------ */

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;
typedef uint16_t __le16;
typedef uint32_t __le32;
typedef uint64_t __u64;
typedef u64 dma_addr_t;
typedef s64 ktime_t;
typedef unsigned int gfp_t;
typedef int spinlock_t;

static inline u32 le32_to_cpu(__le32 v) { return v; }
static inline u16 le16_to_cpu(__le16 v) { return v; }

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define BIT(n) (1UL << (n))
#define READ_ONCE(x) (x)

#define container_of(ptr, type, member) \
	((type *)((char *)(ptr) - offsetof(type, member)))

#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))

/* The kernel's static_assert takes one argument; C11's takes two. */
#undef static_assert
#define static_assert(expr, ...) _Static_assert((expr), "" #expr)

#define unreachable() __builtin_unreachable()
#define __maybe_unused __attribute__((unused))
#define __iomem

#ifndef ENOTSUPP
#define ENOTSUPP 524 /* kernel-internal errno */
#endif

#define S_IRUGO 0444
#define S_IWUSR 0200

#define IS_ERR(ptr) ((unsigned long)(ptr) >= (unsigned long)-4095)
#define PTR_ERR(ptr) ((long)(ptr))
#define ERR_PTR(err) ((void *)(long)(err))

/* --- harness state (HARNESS; see header comment) ------------------------ */

struct device;

typedef enum { IRQ_NONE = 0, IRQ_HANDLED = 1 } irqreturn_t;
typedef irqreturn_t (*irq_handler_t)(int irq, void *dev_id);

struct ebc_shim_dma_mapping {
	u32 handle;
	void *cpu;
	/* Device-visible copy (non-coherent DMA model): populated from the
	 * CPU buffer at dma_map_single (the arch cleans caches on a
	 * TO_DEVICE map) and by dma_sync_single_for_device for the synced
	 * range only.  The fake device reads *this*, so a CPU write the
	 * driver forgets to sync is invisible to the device — exactly the
	 * arm64 failure mode shrunken syncs risk. */
	void *shadow;
	size_t size;
	bool active;
};

#define EBC_SHIM_MMIO_SIZE 0x5000u
#define EBC_SHIM_DMA_SLOTS 16
#define EBC_SHIM_DMA_BASE 0x40000000u

/* One instance per TU.  Everything zero means "old inert behavior"; the
 * refresh harness installs hooks and reads the counters.  The counters
 * are the shim's own honesty checks: a healthy driver run leaves all the
 * *_violations / completion_timeouts fields at 0. */
struct ebc_shim_state {
	/* completion (kernel counting semantics) */
	unsigned long completion_timeouts;

	/* devm_request_irq registration; a fake device raises the line by
	 * calling irq_handler(irq, irq_dev_id) */
	irq_handler_t irq_handler;
	void *irq_dev_id;

	/* kthread: creation is recorded so tests can run the thread body
	 * synchronously; park/stop are plain flags; schedule() calls the
	 * hook so a scripted test can inject work or stop the loop */
	int (*thread_fn)(void *data);
	void *thread_data;
	bool thread_parked;
	bool thread_stop;
	void (*schedule_hook)(void);

	/* pm_runtime: a refcount plus a suspended flag; the driver's real
	 * runtime callbacks are installed by the test (the shim cannot see
	 * the dev_pm_ops before the driver source is included) */
	int (*rt_resume)(struct device *dev);
	int (*rt_suspend)(struct device *dev);
	int pm_refcount;
	bool pm_suspended;

	/* clk / regulator bookkeeping (for power-discipline checks) */
	int clks_on;
	int regulators_on;

	/* regmap over one MMIO window: a RAM register file plus a write
	 * hook (the fake device).  reg is a byte offset, stride 4. */
	u32 regs[EBC_SHIM_MMIO_SIZE / 4];
	bool (*volatile_reg)(struct device *dev, unsigned int reg);
	struct device *regmap_dev;
	bool cache_only;
	void (*regmap_hook)(unsigned int reg, const u32 *vals, size_t count);
	unsigned long regmap_volatile_cache_only_writes;
	unsigned long regmap_oob;

	/* dma_map_single registry: hands out 32-bit bus handles (the EBC's
	 * window registers are 32 bits wide) and validates unmap/sync */
	struct ebc_shim_dma_mapping dma[EBC_SHIM_DMA_SLOTS];
	u32 dma_next;
	unsigned long dma_violations;

	/* iio: panel temperature in millicelsius.  Default (override unset)
	 * is 25000, the value every pre-existing test was written against. */
	bool iio_temp_override;
	int iio_temp_mC;
};

static struct ebc_shim_state ebc_shim = { .dma_next = EBC_SHIM_DMA_BASE };

static inline void ebc_shim_reset(void)
{
	int i;

	/* shadow is non-NULL only while a mapping is active */
	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++)
		free(ebc_shim.dma[i].shadow);
	memset(&ebc_shim, 0, sizeof(ebc_shim));
	ebc_shim.dma_next = EBC_SHIM_DMA_BASE;
}

/* Resolve a bus handle the driver programmed into a window register back
 * to host memory; `need` guards against a mapping smaller than what the
 * device-side consumer will read.  Returns the mapping's *shadow*, so the
 * caller (the fake device) sees only data published by dma_map_single or
 * dma_sync_single_for_device. */
static inline void *ebc_shim_dma_resolve(u32 handle, size_t need)
{
	int i;

	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++)
		if (ebc_shim.dma[i].active && ebc_shim.dma[i].handle == handle &&
		    need <= ebc_shim.dma[i].size)
			return ebc_shim.dma[i].shadow;
	ebc_shim.dma_violations++;
	return NULL;
}

/* Identify the CPU buffer behind a mapping, for test assertions ("was
 * WIN_MST1 really programmed with ctx->next's mapping?").  Never counts a
 * violation; device-side *reads* must go through ebc_shim_dma_resolve. */
static inline const void *ebc_shim_dma_cpu(u32 handle)
{
	int i;

	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++)
		if (ebc_shim.dma[i].active && ebc_shim.dma[i].handle == handle)
			return ebc_shim.dma[i].cpu;
	return NULL;
}

/* --- printing (all quiet; tests do their own reporting) ---------------- */

#define KERN_INFO ""
#define printk(...) do { } while (0)
#define pr_info(...) do { } while (0)
#define pr_warn(...) do { } while (0)
#define pr_debug(...) do { } while (0)
#define drm_err(dev, fmt, ...) fprintf(stderr, "drm_err: " fmt, ##__VA_ARGS__)
#define drm_warn(dev, ...) do { } while (0)
#define drm_info(dev, fmt, ...) \
	do { \
		if (getenv("EBC_SHIM_VERBOSE")) \
			fprintf(stderr, fmt, ##__VA_ARGS__); \
	} while (0)
#define drm_dbg(dev, ...) do { } while (0)
#define drm_dbg_core(dev, ...) do { } while (0)
#define dev_warn(dev, ...) do { } while (0)

/* --- allocators -------------------------------------------------------- */

#define GFP_KERNEL 0u
#define GFP_DMA 0u

static inline void *kmalloc(size_t size, gfp_t flags) { (void)flags; return malloc(size); }
static inline void *kzalloc(size_t size, gfp_t flags) { (void)flags; return calloc(1, size); }
static inline void kfree(const void *p) { free((void *)p); }
#define vmalloc(size) malloc(size)
#define vfree(ptr) free(ptr)

/* --- list.h (FAITHFUL: the scheduling tests execute these) ------------- */

struct list_head {
	struct list_head *next, *prev;
};

#define LIST_HEAD_INIT(name) { &(name), &(name) }
#define LIST_HEAD(name) struct list_head name = LIST_HEAD_INIT(name)

static inline void INIT_LIST_HEAD(struct list_head *list)
{
	list->next = list;
	list->prev = list;
}

static inline void __list_add(struct list_head *new,
			      struct list_head *prev,
			      struct list_head *next)
{
	next->prev = new;
	new->next = next;
	new->prev = prev;
	prev->next = new;
}

static inline void list_add(struct list_head *new, struct list_head *head)
{
	__list_add(new, head, head->next);
}

static inline void list_add_tail(struct list_head *new, struct list_head *head)
{
	__list_add(new, head->prev, head);
}

static inline void list_del(struct list_head *entry)
{
	entry->next->prev = entry->prev;
	entry->prev->next = entry->next;
	entry->next = NULL;
	entry->prev = NULL;
}

static inline int list_empty(const struct list_head *head)
{
	return head->next == head;
}

static inline int list_is_last(const struct list_head *list,
			       const struct list_head *head)
{
	return list->next == head;
}

static inline void __list_splice(const struct list_head *list,
				 struct list_head *prev,
				 struct list_head *next)
{
	struct list_head *first = list->next;
	struct list_head *last = list->prev;

	first->prev = prev;
	prev->next = first;
	last->next = next;
	next->prev = last;
}

static inline void list_splice_tail_init(struct list_head *list,
					 struct list_head *head)
{
	if (!list_empty(list)) {
		__list_splice(list, head->prev, head);
		INIT_LIST_HEAD(list);
	}
}

#define list_entry(ptr, type, member) container_of(ptr, type, member)
#define list_first_entry(ptr, type, member) \
	list_entry((ptr)->next, type, member)
#define list_next_entry(pos, member) \
	list_entry((pos)->member.next, typeof(*(pos)), member)

#define list_for_each_entry(pos, head, member) \
	for (pos = list_first_entry(head, typeof(*pos), member); \
	     &pos->member != (head); \
	     pos = list_next_entry(pos, member))

#define list_for_each_entry_safe(pos, n, head, member) \
	for (pos = list_first_entry(head, typeof(*pos), member), \
	     n = list_next_entry(pos, member); \
	     &pos->member != (head); \
	     pos = n, n = list_next_entry(n, member))

/* --- kref (FAITHFUL) ---------------------------------------------------- */

struct kref {
	unsigned int refcount;
};

static inline void kref_init(struct kref *kref) { kref->refcount = 1; }
static inline void kref_get(struct kref *kref) { kref->refcount++; }
static inline int kref_put(struct kref *kref, void (*release)(struct kref *kref))
{
	if (--kref->refcount == 0) {
		release(kref);
		return 1;
	}
	return 0;
}

/* --- locking / scheduling (INERT: single-threaded tests) --------------- */

static inline void spin_lock_init(spinlock_t *l) { *l = 0; }
static inline void spin_lock(spinlock_t *l) { (void)l; }
static inline void spin_unlock(spinlock_t *l) { (void)l; }
static inline int spin_trylock(spinlock_t *l) { (void)l; return 1; }

#define TASK_RUNNING 0u
#define TASK_IDLE 0x402u
#define TASK_DEAD 0x80u
#define set_current_state(s) do { } while (0)
#define __set_current_state(s) do { } while (0)
static inline void schedule(void)
{
	if (ebc_shim.schedule_hook)
		ebc_shim.schedule_hook();
}
static inline void usleep_range(unsigned long a, unsigned long b) { (void)a; (void)b; }
static inline void fsleep(unsigned long usecs) { (void)usecs; }

/* completion (HARNESS): kernel counting semantics.  complete() increments;
 * a successful wait consumes one.  A wait with nothing signalled is a
 * timeout — in the harness the fake device signals synchronously from
 * inside the DSP_START register write, so any sequencing bug that fails
 * to trigger it becomes a visible timeout, exactly like on hardware. */
struct completion {
	unsigned int done;
};

static inline void init_completion(struct completion *c) { c->done = 0; }
static inline void reinit_completion(struct completion *c) { c->done = 0; }
static inline void complete(struct completion *c) { c->done++; }
static inline unsigned long wait_for_completion_timeout(struct completion *c,
							unsigned long timeout)
{
	(void)timeout;
	if (c->done) {
		c->done--;
		return 1;
	}
	ebc_shim.completion_timeouts++;
	return 0;
}

#define msecs_to_jiffies(ms) ((unsigned long)(ms))

static inline ktime_t ktime_get(void) { return 0; }
static inline s64 ktime_ms_delta(ktime_t a, ktime_t b) { return a - b; }

/* --- kthread (HARNESS: recorded + flag-driven, runs synchronously) ------ */

struct task_struct {
	unsigned int __state;
};

static struct task_struct ebc_shim_task; /* single-TU shim */

static inline bool kthread_should_stop(void) { return ebc_shim.thread_stop; }
static inline bool kthread_should_park(void) { return ebc_shim.thread_parked; }
static inline void kthread_parkme(void) { }
static inline void kthread_park(struct task_struct *t)
{
	(void)t;
	ebc_shim.thread_parked = true;
}
static inline void kthread_unpark(struct task_struct *t)
{
	(void)t;
	ebc_shim.thread_parked = false;
}
static inline int kthread_stop(struct task_struct *t)
{
	(void)t;
	ebc_shim.thread_stop = true;
	return 0;
}
static inline struct task_struct *kthread_create(int (*fn)(void *), void *data,
						 const char *fmt, ...)
{
	(void)fmt;
	ebc_shim.thread_fn = fn;
	ebc_shim.thread_data = data;
	return &ebc_shim_task;
}
static inline void wake_up_process(struct task_struct *t) { (void)t; }
static inline void sched_set_fifo(struct task_struct *t) { (void)t; }

/* --- device / driver model (INERT) -------------------------------------- */

struct device_node;

struct device {
	void *driver_data;
	struct device_node *of_node;
};

static inline void *dev_get_drvdata(const struct device *dev)
{
	return dev->driver_data;
}
static inline void dev_set_drvdata(struct device *dev, void *data)
{
	dev->driver_data = data;
}
static inline const char *dev_name(const struct device *dev)
{
	(void)dev;
	return "ebc-shim";
}
#define dev_err_probe(dev, err, ...) (err)

struct platform_device {
	struct device dev;
};

static inline void platform_set_drvdata(struct platform_device *pdev, void *data)
{
	pdev->dev.driver_data = data;
}
static inline void *platform_get_drvdata(const struct platform_device *pdev)
{
	return pdev->dev.driver_data;
}
static inline int platform_get_irq(struct platform_device *pdev, unsigned int num)
{
	(void)pdev; (void)num;
	return 1;
}
static inline void *devm_platform_ioremap_resource(struct platform_device *pdev,
						   unsigned int index)
{
	static u8 ebc_shim_mmio[0x5000];
	(void)pdev; (void)index;
	return ebc_shim_mmio;
}

struct of_device_id {
	char compatible[64];
};

struct dev_pm_ops {
	int (*suspend)(struct device *dev);
	int (*resume)(struct device *dev);
	int (*runtime_suspend)(struct device *dev);
	int (*runtime_resume)(struct device *dev);
};

#define SET_SYSTEM_SLEEP_PM_OPS(s, r) .suspend = (s), .resume = (r),
#define SET_RUNTIME_PM_OPS(s, r, i) .runtime_suspend = (s), .runtime_resume = (r),

struct platform_driver {
	int (*probe)(struct platform_device *pdev);
	void (*remove)(struct platform_device *pdev);
	void (*shutdown)(struct platform_device *pdev);
	struct {
		const char *name;
		const struct of_device_id *of_match_table;
		const struct dev_pm_ops *pm;
	} driver;
};

#define module_platform_driver(drv) \
	static const struct platform_driver *ebc_shim_pdrv __maybe_unused = &(drv)

/* --- module macros ------------------------------------------------------ */

#define MODULE_AUTHOR(s) extern int ebc_shim_dummy_decl
#define MODULE_DESCRIPTION(s) extern int ebc_shim_dummy_decl
#define MODULE_LICENSE(s) extern int ebc_shim_dummy_decl
#define MODULE_FIRMWARE(s) extern int ebc_shim_dummy_decl
#define MODULE_PARM_DESC(a, b) extern int ebc_shim_dummy_decl
#define module_param(name, type, perm) extern int ebc_shim_dummy_decl
#define MODULE_DEVICE_TABLE(type, name) \
	static const void *ebc_shim_devtable_##name __maybe_unused = (name)
#define EXPORT_SYMBOL(sym)

/* --- interrupts (HARNESS: registration recorded; typedefs are above) ---- */

static inline int devm_request_irq(struct device *dev, unsigned int irq,
				   irq_handler_t handler, unsigned long flags,
				   const char *name, void *dev_id)
{
	(void)dev; (void)irq; (void)flags; (void)name;
	ebc_shim.irq_handler = handler;
	ebc_shim.irq_dev_id = dev_id;
	return 0;
}

/* --- clk / regulator (HARNESS: on/off bookkeeping) ----------------------- */

struct clk { int dummy; };

static inline struct clk *devm_clk_get(struct device *dev, const char *id)
{
	static struct clk ebc_shim_clk;
	(void)dev; (void)id;
	return &ebc_shim_clk;
}
static inline int clk_set_rate(struct clk *clk, unsigned long rate)
{
	(void)clk; (void)rate;
	return 0;
}
static inline long clk_round_rate(struct clk *clk, unsigned long rate)
{
	(void)clk;
	return (long)rate;
}
static inline int clk_prepare_enable(struct clk *clk)
{
	(void)clk;
	ebc_shim.clks_on++;
	return 0;
}
static inline void clk_disable_unprepare(struct clk *clk)
{
	(void)clk;
	ebc_shim.clks_on--;
}

struct regulator_bulk_data {
	const char *supply;
};

static inline int devm_regulator_bulk_get(struct device *dev, int num,
					  struct regulator_bulk_data *consumers)
{
	(void)dev; (void)num; (void)consumers;
	return 0;
}
static inline int regulator_bulk_enable(int num, struct regulator_bulk_data *consumers)
{
	(void)consumers;
	ebc_shim.regulators_on += num;
	return 0;
}
static inline int regulator_bulk_disable(int num, struct regulator_bulk_data *consumers)
{
	(void)consumers;
	ebc_shim.regulators_on -= num;
	return 0;
}

struct iio_channel { int dummy; };

static inline struct iio_channel *devm_iio_channel_get(struct device *dev,
						       const char *name)
{
	static struct iio_channel ebc_shim_iio;
	(void)dev; (void)name;
	return &ebc_shim_iio;
}
static inline int iio_read_channel_processed(struct iio_channel *chan, int *val)
{
	(void)chan;
	*val = ebc_shim.iio_temp_override ? ebc_shim.iio_temp_mC
					  : 25000; /* 25 C in millicelsius */
	return 0;
}

/* pm_runtime (HARNESS): refcount + suspended flag.  The test installs the
 * driver's real runtime callbacks in ebc_shim.rt_resume/rt_suspend (and
 * sets pm_suspended, matching a freshly probed device); with no hooks the
 * old always-succeed behavior applies.  pm_runtime_get is the async
 * resume request (refcount only); pm_runtime_resume is the synchronous
 * one, matching how rockchip_ebc_refresh uses the pair.  Autosuspend
 * never fires on its own — a test triggers it deliberately. */
static inline int pm_runtime_get(struct device *dev)
{
	(void)dev;
	ebc_shim.pm_refcount++;
	return 0;
}
static inline int pm_runtime_resume(struct device *dev)
{
	if (ebc_shim.pm_suspended && ebc_shim.rt_resume) {
		int ret = ebc_shim.rt_resume(dev);

		if (ret)
			return ret;
	}
	ebc_shim.pm_suspended = false;
	return 0;
}
static inline void pm_runtime_put(struct device *dev)
{
	(void)dev;
	ebc_shim.pm_refcount--;
}
static inline void pm_runtime_mark_last_busy(struct device *dev) { (void)dev; }
static inline void pm_runtime_put_autosuspend(struct device *dev)
{
	(void)dev;
	ebc_shim.pm_refcount--;
}
static inline void pm_runtime_set_autosuspend_delay(struct device *dev, int ms)
{
	(void)dev; (void)ms;
}
static inline void pm_runtime_use_autosuspend(struct device *dev) { (void)dev; }
static inline void pm_runtime_enable(struct device *dev) { (void)dev; }
static inline void pm_runtime_disable(struct device *dev) { (void)dev; }
static inline bool pm_runtime_enabled(struct device *dev) { (void)dev; return true; }
static inline bool pm_runtime_status_suspended(struct device *dev)
{
	(void)dev;
	return ebc_shim.rt_resume ? ebc_shim.pm_suspended : true;
}
static inline int pm_runtime_force_suspend(struct device *dev)
{
	if (!ebc_shim.pm_suspended && ebc_shim.rt_suspend) {
		int ret = ebc_shim.rt_suspend(dev);

		if (ret)
			return ret;
	}
	ebc_shim.pm_suspended = true;
	return 0;
}
static inline int pm_runtime_force_resume(struct device *dev)
{
	return pm_runtime_resume(dev);
}

/* --- regmap (HARNESS: RAM register file + fake-device write hook) --------
 *
 * One 0x5000-byte MMIO window (the EBC's), backed by ebc_shim.regs.
 * Every effective write lands in the register file and is then reported
 * to ebc_shim.regmap_hook, which is where shim/fake-ebc.h implements the
 * device's behavior (latching on CONFIG_DONE, frames on DSP_START,
 * write-1-to-clear INT_STATUS, raising the IRQ).  The hook may rewrite
 * ebc_shim.regs to apply device-side semantics.
 *
 * Simplification vs the kernel: no separate cache array.  cache_only is
 * tracked, and a write to a *volatile* register while cache_only counts
 * as a violation (the kernel regmap would return -EBUSY); non-volatile
 * writes land immediately, which matches the post-regcache_sync state
 * the driver relies on.  regcache_mark_dirty/sync are therefore no-ops.
 */

struct regmap { int dummy; };

enum regcache_type { REGCACHE_NONE, REGCACHE_FLAT };

struct regmap_config {
	int reg_bits;
	int reg_stride;
	int val_bits;
	bool (*volatile_reg)(struct device *dev, unsigned int reg);
	unsigned int max_register;
	enum regcache_type cache_type;
};

static inline void ebc_shim_reg_store(unsigned int reg, const u32 *vals,
				      size_t count)
{
	if (reg % 4 || (size_t)reg + count * 4 > EBC_SHIM_MMIO_SIZE) {
		ebc_shim.regmap_oob++;
		return;
	}
	if (ebc_shim.cache_only && ebc_shim.volatile_reg &&
	    ebc_shim.volatile_reg(ebc_shim.regmap_dev, reg))
		ebc_shim.regmap_volatile_cache_only_writes++;
	memcpy(&ebc_shim.regs[reg / 4], vals, count * 4);
	if (ebc_shim.regmap_hook)
		ebc_shim.regmap_hook(reg, vals, count);
}

static inline struct regmap *devm_regmap_init_mmio(struct device *dev, void *base,
						   const struct regmap_config *config)
{
	static struct regmap ebc_shim_regmap;
	(void)base;
	ebc_shim.regmap_dev = dev;
	ebc_shim.volatile_reg = config->volatile_reg;
	return &ebc_shim_regmap;
}
static inline int regmap_write(struct regmap *map, unsigned int reg, unsigned int val)
{
	u32 v = val;
	(void)map;
	ebc_shim_reg_store(reg, &v, 1);
	return 0;
}
static inline int regmap_read(struct regmap *map, unsigned int reg, unsigned int *val)
{
	(void)map;
	if (reg % 4 || reg >= EBC_SHIM_MMIO_SIZE) {
		ebc_shim.regmap_oob++;
		*val = 0;
		return -EINVAL;
	}
	*val = ebc_shim.regs[reg / 4];
	return 0;
}
static inline int regmap_update_bits(struct regmap *map, unsigned int reg,
				     unsigned int mask, unsigned int val)
{
	unsigned int old;
	u32 v;

	regmap_read(map, reg, &old);
	v = (old & ~mask) | (val & mask);
	ebc_shim_reg_store(reg, &v, 1);
	return 0;
}
static inline int regmap_bulk_write(struct regmap *map, unsigned int reg,
				    const void *val, size_t count)
{
	/* val_bits = 32: `val` is an array of `count` 32-bit values
	 * (little-endian host, so a byte buffer copies faithfully) */
	(void)map;
	ebc_shim_reg_store(reg, val, count);
	return 0;
}
static inline void regcache_cache_only(struct regmap *map, bool enable)
{
	(void)map;
	ebc_shim.cache_only = enable;
}
static inline void regcache_mark_dirty(struct regmap *map) { (void)map; }
static inline int regcache_sync(struct regmap *map) { (void)map; return 0; }

/* --- dma-mapping (HARNESS: 32-bit handle registry, non-coherent model) ----
 *
 * dma_map_single hands out 32-bit bus handles (never raw host pointers:
 * the driver truncates the handle to 32 bits when programming WIN_MST*,
 * exactly like on the real 32-bit-DMA SoC, and the fake device resolves
 * it back through ebc_shim_dma_resolve).  unmap must match an active
 * mapping's handle and size; syncs must stay within a mapping (offsets
 * into it are fine, as the dma-api allows).  Anything else counts a
 * dma_violation.
 *
 * DMA here is modelled as *non-coherent*, like the arm64 SoC: each
 * mapping keeps a shadow copy that only dma_map_single (whole buffer;
 * the arch cleans caches when mapping TO_DEVICE) and
 * dma_sync_single_for_device (the synced range) update, and the fake
 * device reads the shadow.  A CPU write that reaches the device without
 * an intervening sync is therefore a *test failure*, not a silent pass —
 * the guard that makes shrunken-sync changes (the hrdl/ayakael dma_sync
 * size fixes) provable offline.
 */

enum dma_data_direction { DMA_BIDIRECTIONAL, DMA_TO_DEVICE, DMA_FROM_DEVICE };

#define DMA_BIT_MASK(n) (((n) == 64) ? ~0ULL : ((1ULL << (n)) - 1))

static inline int dma_set_mask(struct device *dev, u64 mask)
{
	(void)dev; (void)mask;
	return 0;
}
static inline dma_addr_t dma_map_single(struct device *dev, void *ptr,
					size_t size, enum dma_data_direction dir)
{
	int i;

	(void)dev; (void)dir;
	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++) {
		struct ebc_shim_dma_mapping *m = &ebc_shim.dma[i];

		if (m->active)
			continue;
		m->shadow = malloc(size);
		if (!m->shadow)
			break;
		memcpy(m->shadow, ptr, size);
		m->active = true;
		m->cpu = ptr;
		m->size = size;
		m->handle = ebc_shim.dma_next;
		ebc_shim.dma_next += 0x01000000u;
		return m->handle;
	}
	ebc_shim.dma_violations++;
	return 0;
}
static inline void dma_unmap_single(struct device *dev, dma_addr_t addr,
				    size_t size, enum dma_data_direction dir)
{
	int i;

	(void)dev; (void)dir;
	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++) {
		struct ebc_shim_dma_mapping *m = &ebc_shim.dma[i];

		if (m->active && m->handle == addr && m->size == size) {
			free(m->shadow);
			m->shadow = NULL;
			m->active = false;
			return;
		}
	}
	ebc_shim.dma_violations++;
}
static inline int dma_mapping_error(struct device *dev, dma_addr_t addr)
{
	(void)dev;
	return addr == 0;
}
/* Find the active mapping containing [addr, addr + size); NULL (plus a
 * violation) if the range is not fully inside one mapping. */
static inline struct ebc_shim_dma_mapping *
ebc_shim_dma_find(dma_addr_t addr, size_t size)
{
	int i;

	for (i = 0; i < EBC_SHIM_DMA_SLOTS; i++) {
		struct ebc_shim_dma_mapping *m = &ebc_shim.dma[i];

		if (m->active && addr >= m->handle &&
		    addr - m->handle + size <= m->size)
			return m;
	}
	ebc_shim.dma_violations++;
	return NULL;
}
static inline void dma_sync_single_for_cpu(struct device *dev, dma_addr_t addr,
					   size_t size, enum dma_data_direction dir)
{
	(void)dev; (void)dir;
	/* The driver only maps TO_DEVICE buffers, and the device never
	 * writes them, so handing ownership back to the CPU moves no
	 * data — this just validates the range. */
	ebc_shim_dma_find(addr, size);
}
static inline void dma_sync_single_for_device(struct device *dev, dma_addr_t addr,
					      size_t size, enum dma_data_direction dir)
{
	struct ebc_shim_dma_mapping *m;

	(void)dev; (void)dir;
	m = ebc_shim_dma_find(addr, size);
	if (m) {
		size_t off = addr - m->handle;

		memcpy((char *)m->shadow + off, (const char *)m->cpu + off,
		       size);
	}
}

/* --- uaccess ------------------------------------------------------------- */

static inline unsigned long copy_from_user(void *to, const void *from,
					   unsigned long n)
{
	memcpy(to, from, n);
	return 0;
}

/* --- firmware loader: file_name is a filesystem path on the host ---------
 * If EBC_SHIM_FW_DIR is set, $EBC_SHIM_FW_DIR/<name> is tried first, so
 * the driver's own "rockchip/ebc.wbf" request resolves the way
 * /lib/firmware does on the device. */

struct firmware {
	size_t size;
	const u8 *data;
};

static inline int request_firmware(const struct firmware **fw_out,
				   const char *name, struct device *dev)
{
	const char *fw_dir = getenv("EBC_SHIM_FW_DIR");
	char fw_path[512];
	struct firmware *fw;
	long size;
	FILE *f = NULL;

	(void)dev;
	if (fw_dir) {
		snprintf(fw_path, sizeof(fw_path), "%s/%s", fw_dir, name);
		f = fopen(fw_path, "rb");
	}
	if (!f)
		f = fopen(name, "rb");
	if (!f)
		return -ENOENT;
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size <= 0) {
		fclose(f);
		return -EINVAL;
	}
	fw = calloc(1, sizeof(*fw));
	fw->data = malloc(size);
	fw->size = (size_t)size;
	if (fread((void *)fw->data, 1, fw->size, f) != fw->size) {
		fclose(f);
		free((void *)fw->data);
		free(fw);
		return -EIO;
	}
	fclose(f);
	*fw_out = fw;
	return 0;
}

static inline void release_firmware(const struct firmware *fw)
{
	if (fw) {
		free((void *)fw->data);
		free((void *)fw);
	}
}

/* --- DRM core objects ----------------------------------------------------- */

struct drm_file;
struct drm_atomic_state { int dummy; };

struct drm_mode_config_funcs;

struct drm_device {
	struct device *dev;
	struct {
		int max_width;
		int max_height;
		const struct drm_mode_config_funcs *funcs;
		bool quirk_addfb_prefer_host_byte_order;
	} mode_config;
};

typedef void (*drmm_action_fn)(struct drm_device *, void *);

static inline int drmm_add_action_or_reset(struct drm_device *dev,
					   drmm_action_fn action, void *data)
{
	/* Short-lived host tool: resources are reclaimed at exit. */
	(void)dev; (void)action; (void)data;
	return 0;
}

/* drm_rect (FAITHFUL: the scheduling logic executes these) */

struct drm_rect {
	int x1, y1, x2, y2;
};

#define DRM_RECT_FMT "%dx%d%+d%+d"
#define DRM_RECT_ARG(r) \
	((r)->x2 - (r)->x1), ((r)->y2 - (r)->y1), (r)->x1, (r)->y1

static inline int drm_rect_width(const struct drm_rect *r) { return r->x2 - r->x1; }
static inline int drm_rect_height(const struct drm_rect *r) { return r->y2 - r->y1; }
static inline bool drm_rect_visible(const struct drm_rect *r)
{
	return drm_rect_width(r) > 0 && drm_rect_height(r) > 0;
}
static inline bool drm_rect_intersect(struct drm_rect *r,
				      const struct drm_rect *clip)
{
	r->x1 = max(r->x1, clip->x1);
	r->y1 = max(r->y1, clip->y1);
	r->x2 = min(r->x2, clip->x2);
	r->y2 = min(r->y2, clip->y2);
	return drm_rect_visible(r);
}
static inline bool drm_rect_equals(const struct drm_rect *r1,
				   const struct drm_rect *r2)
{
	return r1->x1 == r2->x1 && r1->y1 == r2->y1 &&
	       r1->x2 == r2->x2 && r1->y2 == r2->y2;
}
static inline void drm_rect_translate(struct drm_rect *r, int dx, int dy)
{
	r->x1 += dx;
	r->y1 += dy;
	r->x2 += dx;
	r->y2 += dy;
}
static inline void drm_rect_fp_to_int(struct drm_rect *dst,
				      const struct drm_rect *src)
{
	dst->x1 = src->x1 >> 16;
	dst->y1 = src->y1 >> 16;
	dst->x2 = dst->x1 + (drm_rect_width(src) >> 16);
	dst->y2 = dst->y1 + (drm_rect_height(src) >> 16);
}

/* fourcc */

#define fourcc_code(a, b, c, d) \
	((u32)(a) | ((u32)(b) << 8) | ((u32)(c) << 16) | ((u32)(d) << 24))
#define DRM_FORMAT_XRGB8888 fourcc_code('X', 'R', '2', '4')
#define DRM_FORMAT_R4 fourcc_code('R', '4', ' ', ' ')
#define DRM_FORMAT_MOD_LINEAR 0ULL
#define DRM_FORMAT_MOD_INVALID 0x00ffffffffffffffULL

struct drm_format_info {
	u32 format;
	u8 cpp[4];
};

struct drm_framebuffer {
	const struct drm_format_info *format;
	unsigned int pitches[4];
};

/* modes */

#define DRM_MODE_FLAG_CLKDIV2 (1 << 13)

struct drm_display_mode {
	int clock;
	u16 hdisplay, hsync_start, hsync_end, htotal, hskew;
	u16 vdisplay, vsync_start, vsync_end, vtotal;
	u32 flags;
};

/* CRTC / plane / encoder */

struct drm_crtc_state;
struct drm_crtc_funcs;
struct drm_crtc_helper_funcs;

struct drm_crtc {
	struct drm_device *dev;
	struct drm_crtc_state *state;
};

struct drm_crtc_state {
	struct drm_crtc *crtc;
	bool enable;
	bool mode_changed;
	struct drm_display_mode adjusted_mode;
};

struct drm_plane_state;

struct drm_plane {
	struct drm_device *dev;
	struct drm_plane_state *state;
};

struct drm_plane_state {
	struct drm_crtc *crtc;
	struct drm_framebuffer *fb;
	struct drm_rect src; /* 16.16 fixed point */
	struct drm_rect dst;
};

struct iosys_map {
	void *vaddr;
};

struct drm_shadow_plane_state {
	struct drm_plane_state base;
	struct iosys_map data[4];
};

#define DRM_SHADOW_PLANE_MAX_WIDTH 4096
#define DRM_SHADOW_PLANE_MAX_HEIGHT 4096

struct drm_encoder {
	u32 possible_crtcs;
};

struct drm_bridge { int dummy; };

/* generic stub-callback type for helper fn pointers the tests never call */
typedef int (*ebc_shim_fn_t)(void);

struct drm_mode_config_funcs {
	ebc_shim_fn_t fb_create;
	ebc_shim_fn_t atomic_check;
	ebc_shim_fn_t atomic_commit;
};

static inline int drm_gem_fb_create_with_dirty(void) { return 0; }
static inline int drm_atomic_helper_check(void) { return 0; }
static inline int drm_atomic_helper_commit(void) { return 0; }

struct drm_crtc_helper_funcs {
	void (*mode_set_nofb)(struct drm_crtc *crtc);
	int (*atomic_check)(struct drm_crtc *crtc, struct drm_atomic_state *state);
	void (*atomic_flush)(struct drm_crtc *crtc, struct drm_atomic_state *state);
	void (*atomic_enable)(struct drm_crtc *crtc, struct drm_atomic_state *state);
	void (*atomic_disable)(struct drm_crtc *crtc, struct drm_atomic_state *state);
};

struct drm_crtc_funcs {
	void (*reset)(struct drm_crtc *crtc);
	void (*destroy)(struct drm_crtc *crtc);
	ebc_shim_fn_t set_config;
	ebc_shim_fn_t page_flip;
	struct drm_crtc_state *(*atomic_duplicate_state)(struct drm_crtc *crtc);
	void (*atomic_destroy_state)(struct drm_crtc *crtc,
				     struct drm_crtc_state *state);
};

struct drm_plane_helper_funcs {
	ebc_shim_fn_t begin_fb_access;
	ebc_shim_fn_t end_fb_access;
	int (*atomic_check)(struct drm_plane *plane, struct drm_atomic_state *state);
	void (*atomic_update)(struct drm_plane *plane, struct drm_atomic_state *state);
};

struct drm_plane_funcs {
	ebc_shim_fn_t update_plane;
	ebc_shim_fn_t disable_plane;
	void (*destroy)(struct drm_plane *plane);
	void (*reset)(struct drm_plane *plane);
	struct drm_plane_state *(*atomic_duplicate_state)(struct drm_plane *plane);
	void (*atomic_destroy_state)(struct drm_plane *plane,
				     struct drm_plane_state *state);
};

static inline int drm_atomic_helper_set_config(void) { return 0; }
static inline int drm_atomic_helper_page_flip(void) { return 0; }
static inline int drm_atomic_helper_update_plane(void) { return 0; }
static inline int drm_atomic_helper_disable_plane(void) { return 0; }
static inline int drm_gem_begin_shadow_fb_access(void) { return 0; }
static inline int drm_gem_end_shadow_fb_access(void) { return 0; }
static inline void drm_crtc_cleanup(struct drm_crtc *crtc) { (void)crtc; }
static inline void drm_plane_cleanup(struct drm_plane *plane) { (void)plane; }

/* atomic state accessors: the shim keeps one current state per object */

static inline struct drm_crtc_state *
drm_atomic_get_new_crtc_state(struct drm_atomic_state *state, struct drm_crtc *crtc)
{
	(void)state;
	return crtc->state;
}
static inline struct drm_plane_state *
drm_atomic_get_new_plane_state(struct drm_atomic_state *state, struct drm_plane *plane)
{
	(void)state;
	return plane->state;
}
static inline struct drm_plane_state *
drm_atomic_get_old_plane_state(struct drm_atomic_state *state, struct drm_plane *plane)
{
	(void)state;
	return plane->state;
}

#define DRM_PLANE_NO_SCALING (1 << 16)

static inline int drm_atomic_helper_check_plane_state(
	struct drm_plane_state *plane_state, const struct drm_crtc_state *crtc_state,
	int min_scale, int max_scale, bool can_position, bool can_update_disabled)
{
	(void)plane_state; (void)crtc_state; (void)min_scale; (void)max_scale;
	(void)can_position; (void)can_update_disabled;
	return 0;
}

struct drm_atomic_helper_damage_iter { int done; };

static inline void
drm_atomic_helper_damage_iter_init(struct drm_atomic_helper_damage_iter *iter,
				   const struct drm_plane_state *old_state,
				   const struct drm_plane_state *state)
{
	(void)old_state; (void)state;
	iter->done = 1;
}
static inline bool
drm_atomic_helper_damage_iter_next(struct drm_atomic_helper_damage_iter *iter,
				   struct drm_rect *rect)
{
	(void)iter; (void)rect;
	return false;
}
#define drm_atomic_for_each_plane_damage(iter, clip) \
	while (drm_atomic_helper_damage_iter_next((iter), (clip)))

static inline void __drm_atomic_helper_crtc_reset(struct drm_crtc *crtc,
						  struct drm_crtc_state *state)
{
	state->crtc = crtc;
	crtc->state = state;
}
static inline void
__drm_atomic_helper_crtc_duplicate_state(struct drm_crtc *crtc,
					 struct drm_crtc_state *state)
{
	*state = *crtc->state;
}
static inline void
__drm_atomic_helper_crtc_destroy_state(struct drm_crtc_state *state)
{
	(void)state;
}

static inline void __drm_gem_reset_shadow_plane(struct drm_plane *plane,
						struct drm_shadow_plane_state *shadow)
{
	memset(shadow, 0, sizeof(*shadow));
	plane->state = &shadow->base;
}
static inline void
__drm_gem_duplicate_shadow_plane_state(struct drm_plane *plane,
				       struct drm_shadow_plane_state *shadow)
{
	shadow->base = *plane->state;
}
static inline void
__drm_gem_destroy_shadow_plane_state(struct drm_shadow_plane_state *shadow)
{
	(void)shadow;
}

/* driver registration plumbing (INERT) */

struct file_operations { int dummy; };
#define DEFINE_DRM_GEM_FOPS(name) \
	static const struct file_operations name = { 0 }

struct drm_ioctl_desc {
	int (*func)(struct drm_device *dev, void *data, struct drm_file *file_priv);
	unsigned int flags;
};

#define DRM_AUTH 0x1u
#define DRM_COMMAND_BASE 0x40
#define DRM_COMMAND_END 0xA0
#define DRM_IOWR(nr, type) (nr)
#define DRM_IOCTL_DEF_DRV(op, _func, _flags) { .func = (_func), .flags = (_flags) }

#define DRIVER_GEM (1u << 0)
#define DRIVER_MODESET (1u << 1)
#define DRIVER_ATOMIC (1u << 2)

struct drm_driver {
	int shim_gem_ops;
	int shim_fbdev_ops;
	int major;
	int minor;
	const char *name;
	const char *desc;
	u32 driver_features;
	const struct file_operations *fops;
	const struct drm_ioctl_desc *ioctls;
	int num_ioctls;
};

#define DRM_GEM_SHMEM_DRIVER_OPS .shim_gem_ops = 1
#define DRM_FBDEV_SHMEM_DRIVER_OPS .shim_fbdev_ops = 1

#define devm_drm_dev_alloc(parent, driver, type, member) \
	({ \
		type *ebc_shim_devp = calloc(1, sizeof(type)); \
		(void)(driver); \
		if (ebc_shim_devp) \
			ebc_shim_devp->member.dev = (parent); \
		ebc_shim_devp; \
	})

static inline int drmm_mode_config_init(struct drm_device *dev)
{
	(void)dev;
	return 0;
}
static inline void drm_plane_helper_add(struct drm_plane *plane,
					const struct drm_plane_helper_funcs *funcs)
{
	(void)plane; (void)funcs;
}

#define DRM_PLANE_TYPE_PRIMARY 1

static inline int drm_universal_plane_init(struct drm_device *dev,
					   struct drm_plane *plane,
					   u32 possible_crtcs,
					   const struct drm_plane_funcs *funcs,
					   const u32 *formats,
					   unsigned int format_count,
					   const u64 *format_modifiers,
					   int type, const char *name, ...)
{
	(void)dev; (void)plane; (void)possible_crtcs; (void)funcs; (void)formats;
	(void)format_count; (void)format_modifiers; (void)type; (void)name;
	return 0;
}
static inline void drm_plane_enable_fb_damage_clips(struct drm_plane *plane)
{
	(void)plane;
}
static inline void drm_crtc_helper_add(struct drm_crtc *crtc,
				       const struct drm_crtc_helper_funcs *funcs)
{
	(void)crtc; (void)funcs;
}
static inline int drm_crtc_init_with_planes(struct drm_device *dev,
					    struct drm_crtc *crtc,
					    struct drm_plane *primary,
					    struct drm_plane *cursor,
					    const struct drm_crtc_funcs *funcs,
					    const char *name, ...)
{
	(void)dev; (void)crtc; (void)primary; (void)cursor; (void)funcs; (void)name;
	return 0;
}
static inline u32 drm_crtc_mask(const struct drm_crtc *crtc)
{
	(void)crtc;
	return 1;
}

#define DRM_MODE_ENCODER_NONE 0

static inline int drm_simple_encoder_init(struct drm_device *dev,
					  struct drm_encoder *encoder,
					  int encoder_type)
{
	(void)dev; (void)encoder; (void)encoder_type;
	return 0;
}
static inline struct drm_bridge *devm_drm_of_get_bridge(struct device *dev,
							struct device_node *node,
							unsigned int port,
							unsigned int endpoint)
{
	static struct drm_bridge ebc_shim_bridge;
	(void)dev; (void)node; (void)port; (void)endpoint;
	return &ebc_shim_bridge;
}
static inline int drm_bridge_attach(struct drm_encoder *encoder,
				    struct drm_bridge *bridge,
				    struct drm_bridge *previous,
				    unsigned int flags)
{
	(void)encoder; (void)bridge; (void)previous; (void)flags;
	return 0;
}
static inline void drm_mode_config_reset(struct drm_device *dev) { (void)dev; }
static inline int drm_dev_register(struct drm_device *dev, unsigned long flags)
{
	(void)dev; (void)flags;
	return 0;
}
static inline void drm_dev_unregister(struct drm_device *dev) { (void)dev; }
static inline void drm_client_setup(struct drm_device *dev, const void *format)
{
	(void)dev; (void)format;
}
static inline int drm_mode_config_helper_suspend(struct drm_device *dev)
{
	(void)dev;
	return 0;
}
static inline int drm_mode_config_helper_resume(struct drm_device *dev)
{
	(void)dev;
	return 0;
}
static inline void drm_atomic_helper_shutdown(struct drm_device *dev) { (void)dev; }

#endif /* EBC_LOGIC_KERNEL_SHIM_H */
