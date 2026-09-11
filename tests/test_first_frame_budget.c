#include "FirstFrameBudget.h"

#include <assert.h>
#include <stdio.h>

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

/* Cannot literally sleep the machine in a unit test, but the defining
   relationship between the two clocks is checkable without doing that:
   CLOCK_MONOTONIC counts everything CLOCK_UPTIME_RAW counts PLUS however long
   the machine has slept since boot, so it can never read behind it - equal
   only on a machine that has never slept since boot, strictly ahead on any
   real one. This is the same fact measured directly (2354.2s of accumulated
   sleep across 20 events) that justified adding macVNCUptimeNow() at all. */
static void test_uptime_excludes_sleep_monotonic_does_not(void)
{
    uint64_t uptimeBefore = macVNCUptimeNow();
    uint64_t monotonicBefore = macVNCMonotonicNow();
    assert(uptimeBefore > 0);
    assert(monotonicBefore >= uptimeBefore);

    uint64_t uptimeAfter = macVNCUptimeNow();
    uint64_t monotonicAfter = macVNCMonotonicNow();
    assert(uptimeAfter >= uptimeBefore);
    assert(monotonicAfter >= monotonicBefore);
    assert(monotonicAfter >= uptimeAfter);
}

int main(void)
{
    test_total_deadline_budget();
    test_uptime_excludes_sleep_monotonic_does_not();

    puts("readiness policy tests passed");
    return 0;
}
