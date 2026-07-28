#ifndef PINENOTE_EBC_READER_SCAN_H
#define PINENOTE_EBC_READER_SCAN_H

#include <dirent.h>

typedef struct dirent *(*ebc_readdir_fn)(DIR *directory);

int ebc_reader_scan_next(DIR *directory, ebc_readdir_fn next,
                         struct dirent **entry);

#endif
