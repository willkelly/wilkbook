/* ebc-dump-grab — on-device EXTRACT_FBS grabber (PineNote, debug kernel).
 *
 * One DRM_IOCTL_ROCKCHIP_EBC_EXTRACT_FBS into a prefaulted buffer,
 * written out as an EBCDUMP1 container (ebc-dump-format.h) for the
 * host-side ebc-dump decoder and optics/analyze.py join.  Works ONLY
 * against the linux-pinenote-debug kernel (the primary kernel stubs
 * the ioctl with -EOPNOTSUPP; that case exits with a clear message).
 *
 * Usage:
 *   ebc-dump-grab [-d /dev/dri/cardN] [--verify] [--planes LIST] OUT
 *
 * Without -d the EBC card is resolved by driver name
 * (DRIVER=rockchip-ebc in /sys/class/drm/cardN/device/uevent): the
 * index is not stable across images -- panfrost takes card0 on the
 * direct-mode image, and this ioctl aimed at the GPU is a malformed
 * GPU job (2026-08-25 glass session).
 *
 *   --verify      two back-to-back ioctls; if byte-identical, sets the
 *                 container's verified-stable flag (proves the panel
 *                 was quiescent, giving the coherence the kernel's
 *                 deliberately lock-free copy does not)
 *   --planes LIST comma-separated subset of prev,next,final,phase0,
 *                 phase1 (unlisted planes are NULLed in the ioctl and
 *                 zero-filled in the container)
 *
 * The container's reflected flag is read from the live
 * /sys/module/rockchip_ebc/parameters/panel_reflection.
 *
 * This is deliberately self-contained (no libdrm): the ioctl number
 * and argument struct are ABI, frozen in our
 * include/uapi/drm/rockchip_ebc_drm.h since the first shipped image.
 *
 * Cross-built for the debug image by the pinenote-ebc-dump package
 * (pinenote/packages/firmware.scm); also compiled host-side by the
 * ebc-logic Makefile purely as a build-proof (it needs a real
 * /dev/dri to do anything).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "ebc-dump-format.h"

/* DRM ioctl plumbing (matches include/uapi/drm/drm.h; self-contained so
 * the device build needs no libdrm headers). */
#define DRM_IOCTL_BASE 'd'
#define DRM_COMMAND_BASE 0x40

/* Must stay identical to struct drm_rockchip_ebc_extract_fbs in
 * include/uapi/drm/rockchip_ebc_drm.h (5 NULL-able plane pointers). */
struct drm_rockchip_ebc_extract_fbs {
	char *ptr_prev;
	char *ptr_next;
	char *ptr_final;
	char *ptr_phase1;
	char *ptr_phase2;
};

#define DRM_IOCTL_ROCKCHIP_EBC_EXTRACT_FBS \
	_IOWR(DRM_IOCTL_BASE, DRM_COMMAND_BASE + 0x02, \
	      struct drm_rockchip_ebc_extract_fbs)

#define N_PLANES 5

static const char *const plane_names[N_PLANES] = {
	"prev", "next", "final", "phase0", "phase1",
};

static uint64_t now_mono_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static bool read_panel_reflection(void)
{
	FILE *f = fopen("/sys/module/rockchip_ebc/parameters/panel_reflection",
			"r");
	int c;

	if (!f)
		return true;	/* shipped default */
	c = fgetc(f);
	fclose(f);
	return c != '0' && c != 'N';
}

static int do_extract(int fd, unsigned char *buf, const bool want[N_PLANES],
		      const size_t sz[N_PLANES])
{
	struct drm_rockchip_ebc_extract_fbs args;
	char *p[N_PLANES];
	size_t off = 0;
	int i;

	for (i = 0; i < N_PLANES; i++) {
		p[i] = want[i] ? (char *)buf + off : NULL;
		off += sz[i];
	}
	args.ptr_prev = p[0];
	args.ptr_next = p[1];
	args.ptr_final = p[2];
	args.ptr_phase1 = p[3];
	args.ptr_phase2 = p[4];
	return ioctl(fd, DRM_IOCTL_ROCKCHIP_EBC_EXTRACT_FBS, &args);
}

/* Resolve the EBC's card node by driver name via sysfs (readable
 * without root, needs no udev, and cannot make us DRM master of the
 * GPU the way probing by open() would).  DRM reserves minors 0..63
 * for card nodes.  Returns 0 and fills path, or -1 when no card is
 * bound to rockchip-ebc. */
static int find_ebc_card(char *path, size_t path_size)
{
	int n;

	for (n = 0; n <= 63; n++) {
		char uevent[64];
		char line[128];
		FILE *f;
		bool found = false;

		snprintf(uevent, sizeof(uevent),
			 "/sys/class/drm/card%d/device/uevent", n);
		f = fopen(uevent, "r");
		if (!f)
			continue;
		while (fgets(line, sizeof(line), f)) {
			if (!strcmp(line, "DRIVER=rockchip-ebc\n") ||
			    !strcmp(line, "DRIVER=rockchip-ebc")) {
				found = true;
				break;
			}
		}
		fclose(f);
		if (found) {
			snprintf(path, path_size, "/dev/dri/card%d", n);
			return 0;
		}
	}
	return -1;
}

int main(int argc, char **argv)
{
	const char *dev = NULL;
	char devbuf[32];
	const char *out = NULL;
	bool verify = false;
	bool want[N_PLANES] = { true, true, true, true, true };
	size_t sz[N_PLANES], total = 0;
	unsigned char *buf, *buf2 = NULL;
	unsigned char hdrbuf[EBC_DUMP_HEADER_SIZE];
	struct ebc_dump_header h;
	uint64_t flags = 0;
	FILE *f;
	int fd, i, arg;

	for (arg = 1; arg < argc; arg++) {
		if (!strcmp(argv[arg], "-d") && arg + 1 < argc) {
			dev = argv[++arg];
		} else if (!strcmp(argv[arg], "--verify")) {
			verify = true;
		} else if (!strcmp(argv[arg], "--planes") && arg + 1 < argc) {
			char *list = argv[++arg], *tok;

			for (i = 0; i < N_PLANES; i++)
				want[i] = false;
			for (tok = strtok(list, ","); tok;
			     tok = strtok(NULL, ",")) {
				for (i = 0; i < N_PLANES; i++)
					if (!strcmp(tok, plane_names[i]))
						break;
				if (i == N_PLANES) {
					fprintf(stderr, "unknown plane %s\n",
						tok);
					return 2;
				}
				want[i] = true;
			}
		} else if (!strcmp(argv[arg], "--help")) {
			printf("usage: ebc-dump-grab [-d /dev/dri/cardN] "
			       "[--verify] [--planes LIST] OUT\n");
			return 0;
		} else if (!out) {
			out = argv[arg];
		} else {
			fprintf(stderr, "usage: ebc-dump-grab [-d DEV] "
					"[--verify] [--planes LIST] OUT\n");
			return 2;
		}
	}
	if (!out) {
		fprintf(stderr, "usage: ebc-dump-grab [-d DEV] [--verify] "
				"[--planes LIST] OUT\n");
		return 2;
	}

	h.width = EBC_DUMP_PN_WIDTH;
	h.height = EBC_DUMP_PN_HEIGHT;
	h.gray4_size = h.width * h.height / 2;
	h.phase_size = h.width * h.height;
	for (i = 0; i < N_PLANES; i++) {
		sz[i] = i < 3 ? h.gray4_size : h.phase_size;
		total += sz[i];
	}

	if (!dev) {
		/* No -d given: resolve the EBC card by driver name (the
		 * index is not stable across images). */
		if (find_ebc_card(devbuf, sizeof(devbuf)) == 0)
			dev = devbuf;
		else
			dev = "/dev/dri/by-path/platform-fdec0000.ebc-card";
	}
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		/* by-path fallback: the EBC is the only display-port DRM
		 * device on the PineNote */
		fd = open("/dev/dri/by-path/platform-fdec0000.ebc-card",
			  O_RDWR);
	}
	if (fd < 0) {
		fprintf(stderr, "ebc-dump-grab: cannot open %s: %s\n", dev,
			strerror(errno));
		return 1;
	}

	/* MAP_POPULATE prefaults the whole buffer so the in-kernel
	 * copy_to_user services no page faults (minimizes the dump
	 * window; see the debug patch's locking notes). */
	buf = mmap(NULL, total, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
	if (buf == MAP_FAILED) {
		fprintf(stderr, "ebc-dump-grab: mmap: %s\n", strerror(errno));
		return 1;
	}
	memset(buf, 0, total);

	h.t_mono_ns = now_mono_ns();
	if (do_extract(fd, buf, want, sz) != 0) {
		if (errno == EOPNOTSUPP || errno == ENOTSUP) {
			fprintf(stderr, "ebc-dump-grab: EXTRACT_FBS is stubbed "
					"on this kernel — boot the "
					"linux-pinenote-debug image\n");
			return 3;
		}
		fprintf(stderr, "ebc-dump-grab: EXTRACT_FBS: %s\n",
			strerror(errno));
		return 1;
	}

	if (verify) {
		buf2 = mmap(NULL, total, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
		if (buf2 == MAP_FAILED) {
			fprintf(stderr, "ebc-dump-grab: mmap(verify): %s\n",
				strerror(errno));
			return 1;
		}
		memset(buf2, 0, total);
		if (do_extract(fd, buf2, want, sz) != 0) {
			fprintf(stderr, "ebc-dump-grab: EXTRACT_FBS(verify): %s\n",
				strerror(errno));
			return 1;
		}
		if (memcmp(buf, buf2, total) == 0) {
			flags |= EBC_DUMP_F_VERIFIED_STABLE;
		} else {
			fprintf(stderr, "ebc-dump-grab: double-dump differs — "
					"panel active; dump is honestly torn "
					"(verified-stable flag not set)\n");
		}
	}
	if (read_panel_reflection())
		flags |= EBC_DUMP_F_REFLECTED;
	h.flags = flags;

	f = fopen(out, "wb");
	if (!f) {
		fprintf(stderr, "ebc-dump-grab: cannot write %s: %s\n", out,
			strerror(errno));
		return 1;
	}
	ebc_dump_header_write(hdrbuf, &h);
	if (fwrite(hdrbuf, 1, sizeof(hdrbuf), f) != sizeof(hdrbuf) ||
	    fwrite(buf, 1, total, f) != total) {
		fprintf(stderr, "ebc-dump-grab: short write to %s\n", out);
		fclose(f);
		return 1;
	}
	fclose(f);
	printf("ebc-dump-grab: wrote %s (%zu bytes%s)\n", out,
	       (size_t)EBC_DUMP_HEADER_SIZE + total,
	       (flags & EBC_DUMP_F_VERIFIED_STABLE) ? ", verified stable" : "");

	munmap(buf, total);
	if (buf2)
		munmap(buf2, total);
	close(fd);
	return 0;
}
