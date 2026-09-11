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
 * capturer so they cannot drift apart.
 *
 * Counts time the machine spent ASLEEP: measured directly on this project's
 * own deployment target (macOS 26.6.2) - CLOCK_MONOTONIC advanced by exactly
 * as much as mach_continuous_time() did across 20 real sleep events (2354.2s
 * total), while mach_absolute_time()/CLOCK_UPTIME_RAW did not advance at all
 * during those same gaps. That is the right clock for callers measuring
 * against a dispatch_source timer (dispatch timers are themselves scheduled
 * in continuous/sleep-inclusive time, so a deadline compared with THIS clock
 * agrees with when such a timer actually fires - see the keep-warm timer in
 * mac.m) or a wait that can only ever elapse while the machine is awake
 * anyway (a client's first-frame wait: the network connection carrying it
 * could not survive a system sleep in the first place, so which clock is used
 * there is moot). Established, unrelated callers (MacVNCCurtainController's
 * heartbeat, MacVNCPowerMgmt's assertion timing, MacVNCCurtainEventTap's idle
 * tracking) all rely on this existing, sleep-inclusive meaning - changing it
 * here would silently change theirs too. A caller that instead wants ELAPSED
 * AWAKE TIME, where a long sleep must not masquerade as however many seconds
 * of real silence, wants macVNCUptimeNow() below, not this. */
uint64_t macVNCMonotonicNow(void);

/* Current CLOCK_UPTIME_RAW time in nanoseconds - like macVNCMonotonicNow(),
 * but EXCLUDING time the machine spent asleep (see the measurement in that
 * function's comment). For the capture-liveness watchdog only: silence
 * measured against THIS clock cannot mistake "the Mac slept for ten minutes"
 * for "the capture stream has been dead for ten minutes" and force an
 * unnecessary re-arm on the very first tick after every wake. Not a drop-in
 * replacement for macVNCMonotonicNow() - see that function's comment for the
 * established callers that need the sleep-inclusive clock instead. */
uint64_t macVNCUptimeNow(void);

/* Creates one total monotonic deadline shared by every display wait. */
MacVNCFirstFrameBudget macVNCFirstFrameBudgetStart(uint64_t nowNanoseconds,
                                                 uint64_t totalNanoseconds);

/* Returns the remaining total budget, clamped to zero after the deadline. */
uint64_t macVNCFirstFrameBudgetRemaining(const MacVNCFirstFrameBudget *budget,
                                        uint64_t nowNanoseconds);

/* Converts a remaining monotonic budget to Darwin's relative condition wait. */
struct timespec macVNCRelativeWaitFromNanoseconds(uint64_t remainingNanoseconds);
