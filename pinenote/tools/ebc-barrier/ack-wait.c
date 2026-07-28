#include "ack-wait.h"

#include <errno.h>
#include <sys/select.h>
#include <unistd.h>

static int negative_errno(void)
{
    return errno == 0 ? -EIO : -errno;
}

int ebc_barrier_wait_for_ack(int fd, const sigset_t *wait_mask,
                             volatile sig_atomic_t *interrupted)
{
    fd_set readable;
    char byte;
    int rc;
    ssize_t count;

    if (*interrupted)
        return -EINTR;

    FD_ZERO(&readable);
    FD_SET(fd, &readable);
    rc = pselect(fd + 1, &readable, NULL, NULL, NULL, wait_mask);
    if (rc < 0)
        return errno == EINTR && *interrupted ? -EINTR : negative_errno();
    if (rc != 1 || !FD_ISSET(fd, &readable))
        return -EIO;

    do {
        count = read(fd, &byte, 1);
    } while (count < 0 && errno == EINTR && !*interrupted);
    if (*interrupted)
        return -EINTR;
    if (count == 1 && byte == '\n')
        return 0;
    return count == 0 ? -EIO : count < 0 ? negative_errno() : -EINVAL;
}
