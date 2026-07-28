#ifndef EBC_LOGIC_UAPI_DRM_H
#define EBC_LOGIC_UAPI_DRM_H

#include <stdbool.h>
#include <stdint.h>

typedef uint32_t __u32;
typedef uint64_t __u64;
typedef int32_t __s32;

#define DRM_COMMAND_BASE 0x40
#define DRM_IOWR(nr, type) (nr)

#endif
