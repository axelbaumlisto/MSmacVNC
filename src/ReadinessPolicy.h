#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

typedef enum {
    MACVNC_READINESS_WAITING = 0,
    MACVNC_READINESS_TIMED_OUT,
    MACVNC_READINESS_READY,
} MacVNCReadinessState;

typedef struct {
    MacVNCReadinessState state;
} MacVNCReadinessPolicy;

typedef struct {
    uint64_t deadlineNanoseconds;
} MacVNCReadinessBudget;

/* Creates one total monotonic deadline shared by every display wait. */
MacVNCReadinessBudget macVNCReadinessBudgetStart(uint64_t nowNanoseconds,
                                                 uint64_t totalNanoseconds);

/* Returns the remaining total budget, clamped to zero after the deadline. */
uint64_t macVNCReadinessBudgetRemaining(const MacVNCReadinessBudget *budget,
                                        uint64_t nowNanoseconds);

/* Converts a remaining monotonic budget to Darwin's relative condition wait. */
struct timespec macVNCReadinessRelativeWait(uint64_t remainingNanoseconds);

/* Records the initial bounded wait result. Returns true exactly once when a
   timeout warning should be emitted. */
bool macVNCReadinessRecordInitialResult(MacVNCReadinessPolicy *policy, bool allReady);

/* Promotes a timed-out client after late frames arrive. Returns true exactly
   once when a recovery diagnostic should be emitted. */
bool macVNCReadinessPromoteIfReady(MacVNCReadinessPolicy *policy, bool allReady);

bool macVNCReadinessIsReady(const MacVNCReadinessPolicy *policy);
