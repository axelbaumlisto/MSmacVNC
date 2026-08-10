#pragma once

#include <stdbool.h>

typedef enum {
    MACVNC_READINESS_WAITING = 0,
    MACVNC_READINESS_TIMED_OUT,
    MACVNC_READINESS_READY,
} MacVNCReadinessState;

typedef struct {
    MacVNCReadinessState state;
} MacVNCReadinessPolicy;

/* Records the initial bounded wait result. Returns true exactly once when a
   timeout warning should be emitted. */
bool macVNCReadinessRecordInitialResult(MacVNCReadinessPolicy *policy, bool allReady);

/* Promotes a timed-out client after late frames arrive. Returns true exactly
   once when a recovery diagnostic should be emitted. */
bool macVNCReadinessPromoteIfReady(MacVNCReadinessPolicy *policy, bool allReady);

bool macVNCReadinessIsReady(const MacVNCReadinessPolicy *policy);
