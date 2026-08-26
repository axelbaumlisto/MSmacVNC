#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

/*
 * The shared deadline for "wait until every display has produced a frame".
 *
 * There used to be a three-state machine here as well (WAITING / TIMED_OUT /
 * READY). Every transition it made produced a log line and nothing else: no
 * caller ever branched on the state, and the one function that read it threw
 * its answer away. Keeping it meant displayHook ran on every framebuffer update
 * of every client, taking the client lock and dispatch_sync-ing onto each
 * capturer's state queue, to print a sentence.
 */

typedef struct {
    uint64_t deadlineNanoseconds;
} MacVNCReadinessBudget;

/* Current CLOCK_MONOTONIC time in nanoseconds — the clock the readiness
 * budget is measured against. Single source for both the server core and the
 * capturer so they cannot drift apart. */
uint64_t macVNCReadinessNow(void);

/* Creates one total monotonic deadline shared by every display wait. */
MacVNCReadinessBudget macVNCReadinessBudgetStart(uint64_t nowNanoseconds,
                                                 uint64_t totalNanoseconds);

/* Returns the remaining total budget, clamped to zero after the deadline. */
uint64_t macVNCReadinessBudgetRemaining(const MacVNCReadinessBudget *budget,
                                        uint64_t nowNanoseconds);

/* Converts a remaining monotonic budget to Darwin's relative condition wait. */
struct timespec macVNCReadinessRelativeWait(uint64_t remainingNanoseconds);
