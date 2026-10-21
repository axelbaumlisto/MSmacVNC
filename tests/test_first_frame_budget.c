#include "FirstFrameBudget.h"

#include <assert.h>
#include <stdio.h>
#include <time.h>

static void test_total_deadline_budget(void)
{
    const uint64_t second = 1000000000ULL;
    MacVNCFirstFrameBudget budget = macVNCFirstFrameBudgetStart(10 * second,
                                                              3 * second);
    assert(macVNCFirstFrameBudgetRemaining(&budget, 10 * second) == 3 * second);
    assert(macVNCFirstFrameBudgetRemaining(&budget, 11 * second) == 2 * second);
    assert(macVNCFirstFrameBudgetRemaining(&budget, 12999999999ULL) == 1);
    assert(macVNCFirstFrameBudgetRemaining(&budget, 13 * second) == 0);
    assert(macVNCFirstFrameBudgetRemaining(&budget, 14 * second) == 0);
    assert(macVNCFirstFrameBudgetRemaining(NULL, 0) == 0);

    MacVNCFirstFrameBudget saturated = macVNCFirstFrameBudgetStart(UINT64_MAX - 1, 3);
    assert(saturated.deadlineNanoseconds == UINT64_MAX);
    assert(macVNCFirstFrameBudgetRemaining(&saturated, UINT64_MAX - 1) == 1);

    struct timespec zero = macVNCRelativeWaitFromNanoseconds(0);
    assert(zero.tv_sec == 0 && zero.tv_nsec == 0);
    struct timespec subsecond = macVNCRelativeWaitFromNanoseconds(999999999ULL);
    assert(subsecond.tv_sec == 0 && subsecond.tv_nsec == 999999999L);
    struct timespec split = macVNCRelativeWaitFromNanoseconds(3000000001ULL);
    assert(split.tv_sec == 3 && split.tv_nsec == 1);
}

/* The epoch question and the rate question are different questions.

   CLOCK_MONOTONIC's epoch on Darwin is documented as "an arbitrary point", and
   measured here it can sit several seconds BEHIND CLOCK_UPTIME_RAW (11314.6 s
   vs 11320.8 s on this Mac), so comparing the two readings is not a property
   of anything - an earlier version of this test asserted monotonic >= uptime
   and failed after the machine had slept. What IS a property: both clocks tick
   at the same rate while the machine is awake, which is what lets the budget
   code treat a nanosecond of one as a nanosecond of the other.

   The sleep semantics themselves cannot be observed without sleeping, so they
   stay documented in FirstFrameBudget.h rather than asserted here. */
static void test_uptime_excludes_sleep_monotonic_does_not(void)
{
    uint64_t uptimeBefore = macVNCUptimeNow();
    uint64_t monotonicBefore = macVNCMonotonicNow();
    assert(uptimeBefore > 0);
    assert(monotonicBefore > 0);

    struct timespec pause = {0, 20 * 1000 * 1000};   /* 20 ms of real work */
    nanosleep(&pause, NULL);

    uint64_t uptimeAfter = macVNCUptimeNow();
    uint64_t monotonicAfter = macVNCMonotonicNow();
    assert(uptimeAfter > uptimeBefore);
    assert(monotonicAfter > monotonicBefore);

    uint64_t uptimeDelta = uptimeAfter - uptimeBefore;
    uint64_t monotonicDelta = monotonicAfter - monotonicBefore;
    uint64_t slower = uptimeDelta < monotonicDelta ? uptimeDelta : monotonicDelta;
    uint64_t faster = uptimeDelta < monotonicDelta ? monotonicDelta : uptimeDelta;
    /* Same rate: the two deltas differ only by how much the reads themselves
       jitter, never by a multiple. A clock that paused or counted sleep would
       break this by the sleep length. */
    assert(faster - slower < 20 * 1000 * 1000);
}

int main(void)
{
    test_total_deadline_budget();
    test_uptime_excludes_sleep_monotonic_does_not();

    puts("readiness policy tests passed");
    return 0;
}
