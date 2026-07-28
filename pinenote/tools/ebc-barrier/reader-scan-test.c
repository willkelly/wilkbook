#include "reader-scan.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static struct dirent fake_entry;

static struct dirent *entry_result(DIR *directory)
{
    (void)directory;
    return &fake_entry;
}

static struct dirent *eof_result(DIR *directory)
{
    (void)directory;
    return NULL;
}

static struct dirent *error_result(DIR *directory)
{
    (void)directory;
    errno = EIO;
    return NULL;
}

int main(void)
{
    struct dirent *entry;

    errno = ENOMEM;
    CHECK(ebc_reader_scan_next(NULL, entry_result, &entry) == 1);
    CHECK(entry == &fake_entry);
    errno = ENOMEM;
    CHECK(ebc_reader_scan_next(NULL, eof_result, &entry) == 0);
    CHECK(entry == NULL);
    CHECK(ebc_reader_scan_next(NULL, error_result, &entry) == -EIO);
    CHECK(entry == NULL);
    puts("reader-scan: EOF and enumeration errors are distinct");
    return 0;
}
