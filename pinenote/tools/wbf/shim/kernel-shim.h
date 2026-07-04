/* Minimal kernel-API shim so drm_epd_helper.c (verbatim from the
 * forward-port patch) compiles as a host tool.  Little-endian hosts only
 * (x86-64/aarch64) — le32_to_cpu is the identity. */
#ifndef WBF_KERNEL_SHIM_H
#define WBF_KERNEL_SHIM_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint16_t __le16;
typedef uint32_t __le32;

static inline u32 le32_to_cpu(__le32 v) { return v; }
static inline u16 le16_to_cpu(__le16 v) { return v; }

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

/* The kernel's static_assert takes one argument; C11's takes two. */
#undef static_assert
#define static_assert(expr, ...) _Static_assert((expr), "" #expr)

#define unreachable() __builtin_unreachable()

#ifndef ENOTSUPP
#define ENOTSUPP 524 /* kernel-internal errno */
#endif

#define max(a, b) ((a) > (b) ? (a) : (b))

/* --- firmware loader: file_name is a filesystem path on the host --- */

struct firmware {
	size_t size;
	const u8 *data;
};

struct device;

static inline int request_firmware(const struct firmware **fw_out,
				   const char *name, struct device *dev)
{
	struct firmware *fw;
	long size;
	FILE *f = fopen(name, "rb");

	(void)dev;
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

/* --- DRM device and managed-resource stubs --- */

struct drm_device {
	struct device *dev;
};

typedef void (*wbf_drmm_action)(struct drm_device *, void *);

static inline int drmm_add_action_or_reset(struct drm_device *dev,
					   wbf_drmm_action action, void *data)
{
	/* Short-lived host tool: resources are reclaimed at exit. */
	(void)dev; (void)action; (void)data;
	return 0;
}

/* --- printing --- */

#define drm_err(dev, fmt, ...) \
	fprintf(stderr, "error: " fmt, ##__VA_ARGS__)
#define drm_info(dev, fmt, ...) \
	fprintf(stdout, fmt, ##__VA_ARGS__)
#define drm_dbg_core(dev, fmt, ...) \
	do { \
		if (getenv("WBF_DEBUG")) \
			fprintf(stderr, "dbg: " fmt, ##__VA_ARGS__); \
	} while (0)

/* --- allocators --- */

#define vmalloc(size) malloc(size)
#define vfree(ptr) free(ptr)

/* --- module macros --- */

#define EXPORT_SYMBOL(sym)
#define MODULE_AUTHOR(s)
#define MODULE_DESCRIPTION(s)
#define MODULE_LICENSE(s)

#endif /* WBF_KERNEL_SHIM_H */
