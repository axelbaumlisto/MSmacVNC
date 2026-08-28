#pragma once

#include <stdbool.h>
#include <stdint.h>

/*
 * When to ignore the capture source's dirty-rectangle hint and composite a
 * display in full.
 *
 * This is the rule that makes trusting a hint safe: if ScreenCaptureKit ever
 * under-reports what it repainted, the affected region would stay stale on the
 * client forever. A periodic full sweep bounds that to the interval.
 *
 * It lives in its own module because it is a POLICY, and policies in this
 * codebase are pure and tested rather than buried in a callback where the only
 * way to exercise them is to run a real capture stream and wait.
 */
typedef struct {
    uint64_t intervalNanoseconds;
    uint64_t nextSweepNanoseconds; /* 0 after init: the first frame sweeps */
} MacVNCSweepSchedule;

/** Interval 0 means "sweep every frame"; the first call always sweeps. */
void macVNCSweepScheduleInit(MacVNCSweepSchedule *schedule,
                             uint64_t intervalNanoseconds);

/*
 * True when this frame must be composited in full. Rearms the deadline from
 * `now`, so a display that stops delivering frames does not accumulate a debt
 * of sweeps it then runs back to back.
 */
bool macVNCSweepScheduleDueAt(MacVNCSweepSchedule *schedule, uint64_t now);
