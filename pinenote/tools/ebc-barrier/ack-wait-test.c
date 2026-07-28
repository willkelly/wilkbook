#include "ack-wait.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static volatile sig_atomic_t interrupted;

static void interrupt(int signal_number)
{
    (void)signal_number;
    interrupted = 1;
}

static void install_handler(void)
{
    struct sigaction action = {0};

    action.sa_handler = interrupt;
    sigemptyset(&action.sa_mask);
    CHECK(sigaction(SIGUSR1, &action, NULL) == 0);
}

static void masks(sigset_t *original, sigset_t *wait_mask)
{
    sigset_t blocked;

    sigemptyset(&blocked);
    sigaddset(&blocked, SIGUSR1);
    CHECK(sigprocmask(SIG_BLOCK, &blocked, original) == 0);
    *wait_mask = *original;
    sigdelset(wait_mask, SIGUSR1);
}

static void pending_before_wait(void)
{
    sigset_t original, wait_mask;
    int descriptors[2];

    interrupted = 0;
    masks(&original, &wait_mask);
    CHECK(pipe(descriptors) == 0);
    CHECK(raise(SIGUSR1) == 0);
    CHECK(interrupted == 0);
    CHECK(ebc_barrier_wait_for_ack(descriptors[0], &wait_mask, &interrupted) == -EINTR);
    CHECK(interrupted == 1);
    close(descriptors[0]);
    close(descriptors[1]);
    CHECK(sigprocmask(SIG_SETMASK, &original, NULL) == 0);
}

static void delivered_while_waiting(void)
{
    sigset_t original, wait_mask;
    int descriptors[2], status;
    pid_t child;

    interrupted = 0;
    masks(&original, &wait_mask);
    CHECK(pipe(descriptors) == 0);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        usleep(20000);
        _exit(kill(getppid(), SIGUSR1) == 0 ? 0 : 1);
    }
    CHECK(ebc_barrier_wait_for_ack(descriptors[0], &wait_mask, &interrupted) == -EINTR);
    CHECK(interrupted == 1);
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(descriptors[0]);
    close(descriptors[1]);
    CHECK(sigprocmask(SIG_SETMASK, &original, NULL) == 0);
}

static void input_cases(void)
{
    sigset_t original, wait_mask;
    int descriptors[2];
    char input;

    for (input = '\n'; input != 0; input = input == '\n' ? 'x' : 0) {
        interrupted = 0;
        masks(&original, &wait_mask);
        CHECK(pipe(descriptors) == 0);
        CHECK(write(descriptors[1], &input, 1) == 1);
        CHECK(ebc_barrier_wait_for_ack(descriptors[0], &wait_mask, &interrupted) ==
              (input == '\n' ? 0 : -EINVAL));
        close(descriptors[0]);
        close(descriptors[1]);
        CHECK(sigprocmask(SIG_SETMASK, &original, NULL) == 0);
    }

    interrupted = 0;
    masks(&original, &wait_mask);
    CHECK(pipe(descriptors) == 0);
    close(descriptors[1]);
    CHECK(ebc_barrier_wait_for_ack(descriptors[0], &wait_mask, &interrupted) == -EIO);
    close(descriptors[0]);
    CHECK(sigprocmask(SIG_SETMASK, &original, NULL) == 0);
}

int main(void)
{
    install_handler();
    pending_before_wait();
    delivered_while_waiting();
    input_cases();
    puts("ack-wait: all tests passed");
    return 0;
}
