#ifndef PINENOTE_EBC_ACK_WAIT_H
#define PINENOTE_EBC_ACK_WAIT_H

#include <signal.h>

int ebc_barrier_wait_for_ack(int fd, const sigset_t *wait_mask,
                             volatile sig_atomic_t *interrupted);

#endif
