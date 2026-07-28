#include "reader-scan.h"

#include <errno.h>
#include <stddef.h>

int ebc_reader_scan_next(DIR *directory, ebc_readdir_fn next,
                         struct dirent **entry)
{
    errno = 0;
    *entry = next(directory);
    if (*entry != NULL)
        return 1;
    if (errno != 0)
        return -errno;
    return 0;
}
