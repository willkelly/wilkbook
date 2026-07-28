#ifndef PINENOTE_EBC_SIGNAL_GUARD_H
#define PINENOTE_EBC_SIGNAL_GUARD_H

#include <signal.h>

struct ebc_signal_guard {
    sigset_t original_mask;
    sigset_t blocked_signals;
    sigset_t acknowledgement_mask;
    struct sigaction original_actions[3];
    unsigned int installed_actions;
    int active;
};

int ebc_signal_guard_begin(struct ebc_signal_guard *guard,
                           void (*handler)(int));
int ebc_signal_guard_pending(const struct ebc_signal_guard *guard);
int ebc_signal_guard_end(struct ebc_signal_guard *guard);

#endif
