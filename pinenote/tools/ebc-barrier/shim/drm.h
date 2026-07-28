#ifndef PINENOTE_EBC_BARRIER_DRM_SHIM_H
#define PINENOTE_EBC_BARRIER_DRM_SHIM_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/ioctl.h>

typedef uint32_t __u32;
typedef unsigned long long __u64;
typedef int32_t __s32;

#define DRM_COMMAND_BASE 0x40
#define DRM_IOWR(nr, type) _IOWR('d', nr, type)

#endif
