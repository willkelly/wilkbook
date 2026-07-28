#include "signal-guard.h"

#include <errno.h>
#include <string.h>
#include <time.h>

static const int guarded_signals[] = { SIGINT, SIGTERM, SIGHUP };

static int negative_errno(void)
{
    return errno == 0 ? -EIO : -errno;
}

int ebc_signal_guard_begin(struct ebc_signal_guard *guard,
                           void (*handler)(int))
{
    struct sigaction action;
    sigset_t blocked;
    unsigned int i;
    int result;

    memset(guard, 0, sizeof(*guard));
    sigemptyset(&blocked);
    for (i = 0; i < sizeof(guarded_signals) / sizeof(guarded_signals[0]); i++)
        sigaddset(&blocked, guarded_signals[i]);
    if (sigprocmask(SIG_BLOCK, &blocked, &guard->original_mask) != 0)
        return negative_errno();
    guard->blocked_signals = blocked;

    memset(&action, 0, sizeof(action));
    action.sa_handler = handler;
    sigemptyset(&action.sa_mask);
    for (i = 0; i < sizeof(guarded_signals) / sizeof(guarded_signals[0]); i++) {
        if (sigaction(guarded_signals[i], &action,
                      &guard->original_actions[i]) != 0) {
            result = negative_errno();
            while (guard->installed_actions > 0) {
                unsigned int index = --guard->installed_actions;
                sigaction(guarded_signals[index],
                          &guard->original_actions[index], NULL);
            }
            if (sigprocmask(SIG_SETMASK, &guard->original_mask, NULL) != 0)
                return negative_errno();
            return result;
        }
        guard->installed_actions++;
    }
    guard->acknowledgement_mask = guard->original_mask;
    for (i = 0; i < sizeof(guarded_signals) / sizeof(guarded_signals[0]); i++)
        sigdelset(&guard->acknowledgement_mask, guarded_signals[i]);
    guard->active = 1;
    return 0;
}

int ebc_signal_guard_pending(const struct ebc_signal_guard *guard)
{
    sigset_t pending;
    unsigned int i;

    if (!guard->active)
        return -EINVAL;
    if (sigpending(&pending) != 0)
        return negative_errno();
    for (i = 0; i < sizeof(guarded_signals) / sizeof(guarded_signals[0]); i++) {
        if (sigismember(&pending, guarded_signals[i]) == 1)
            return 1;
    }
    return 0;
}

int ebc_signal_guard_end(struct ebc_signal_guard *guard)
{
    struct timespec no_wait = {0, 0};
    unsigned int i;
    int result = 0;

    if (!guard->active)
        return -EINVAL;
    while (sigtimedwait(&guard->blocked_signals, NULL, &no_wait) >= 0)
        ;
    if (errno != EAGAIN)
        result = negative_errno();
    for (i = guard->installed_actions; i > 0; i--) {
        unsigned int index = i - 1;
        if (sigaction(guarded_signals[index],
                      &guard->original_actions[index], NULL) != 0 && result == 0)
            result = negative_errno();
    }
    if (sigprocmask(SIG_SETMASK, &guard->original_mask, NULL) != 0 && result == 0)
        result = negative_errno();
    guard->installed_actions = 0;
    guard->active = 0;
    return result;
}
