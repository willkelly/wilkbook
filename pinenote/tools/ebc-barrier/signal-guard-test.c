#include "signal-guard.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static volatile sig_atomic_t interrupted;
static volatile sig_atomic_t original_called;

static void interrupt(int signal_number)
{
    (void)signal_number;
    interrupted = 1;
}

static void original(int signal_number)
{
    (void)signal_number;
    original_called = 1;
}

int main(void)
{
    struct ebc_signal_guard guard;
    struct sigaction action = {0}, saved;
    sigset_t process_mask, term;

    CHECK(sigprocmask(SIG_SETMASK, NULL, &process_mask) == 0);
    sigemptyset(&term);
    sigaddset(&term, SIGTERM);
    CHECK(sigprocmask(SIG_UNBLOCK, &term, NULL) == 0);
    action.sa_handler = original;
    sigemptyset(&action.sa_mask);
    CHECK(sigaction(SIGTERM, &action, &saved) == 0);
    CHECK(ebc_signal_guard_begin(&guard, interrupt) == 0);
    CHECK(raise(SIGTERM) == 0);
    CHECK(interrupted == 0);
    CHECK(ebc_signal_guard_pending(&guard) == 1);
    CHECK(ebc_signal_guard_end(&guard) == 0);
    CHECK(interrupted == 0 && original_called == 0);
    CHECK(raise(SIGTERM) == 0);
    CHECK(original_called == 1 && interrupted == 0);
    CHECK(sigaction(SIGTERM, &saved, NULL) == 0);
    CHECK(sigprocmask(SIG_SETMASK, &process_mask, NULL) == 0);
    puts("signal-guard: startup cancellation and teardown tests passed");
    return 0;
}
