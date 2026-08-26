#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

/*
 * ONE deadline for "wait until every display has produced its first frame",
 * shared across displays: a per-display timeout would multiply a client's wait
 * by the number of monitors.
 *
 * Named for what it is. It was called ReadinessPolicy while it also held a
 * three-state machine (WAITING / TIMED_OUT / READY) whose every transition
 * produced a log line and nothing else - no caller branched on the state. That
 * machine is gone; a name promising policy over three arithmetic helpers only
 * suggested there is more here than there is.
 */

typedef struct {
    uint64_t deadlineNanoseconds;
} MacVNCFirstFrameBudget;

/* Current CLOCK_MONOTONIC time in nanoseconds — the clock the readiness
 * budget is measured against. Single source for both the server core and the
 * capturer so they cannot drift apart. */
uint64_t macVNCMonotonicNow(void);

/* Creates one total monotonic deadline shared by every display wait. */
MacVNCFirstFrameBudget macVNCFirstFrameBudgetStart(uint64_t nowNanoseconds,
                                                 uint64_t totalNanoseconds);

/* Returns the remaining total budget, clamped to zero after the deadline. */
uint64_t macVNCFirstFrameBudgetRemaining(const MacVNCFirstFrameBudget *budget,
                                        uint64_t nowNanoseconds);

/* Converts a remaining monotonic budget to Darwin's relative condition wait. */
struct timespec macVNCRelativeWaitFromNanoseconds(uint64_t remainingNanoseconds);
