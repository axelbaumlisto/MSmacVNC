#include "ReadinessPolicy.h"

#include <assert.h>
#include <stdio.h>

static void test_total_deadline_budget(void)
{
    const uint64_t second = 1000000000ULL;
    MacVNCReadinessBudget budget = macVNCReadinessBudgetStart(10 * second,
                                                              3 * second);
    assert(macVNCReadinessBudgetRemaining(&budget, 10 * second) == 3 * second);
    assert(macVNCReadinessBudgetRemaining(&budget, 11 * second) == 2 * second);
    assert(macVNCReadinessBudgetRemaining(&budget, 12999999999ULL) == 1);
    assert(macVNCReadinessBudgetRemaining(&budget, 13 * second) == 0);
    assert(macVNCReadinessBudgetRemaining(&budget, 14 * second) == 0);
    assert(macVNCReadinessBudgetRemaining(NULL, 0) == 0);

    MacVNCReadinessBudget saturated = macVNCReadinessBudgetStart(UINT64_MAX - 1, 3);
    assert(saturated.deadlineNanoseconds == UINT64_MAX);
    assert(macVNCReadinessBudgetRemaining(&saturated, UINT64_MAX - 1) == 1);

    struct timespec zero = macVNCReadinessRelativeWait(0);
    assert(zero.tv_sec == 0 && zero.tv_nsec == 0);
    struct timespec subsecond = macVNCReadinessRelativeWait(999999999ULL);
    assert(subsecond.tv_sec == 0 && subsecond.tv_nsec == 999999999L);
    struct timespec split = macVNCReadinessRelativeWait(3000000001ULL);
    assert(split.tv_sec == 3 && split.tv_nsec == 1);
}

int main(void)
{
    test_total_deadline_budget();

    MacVNCReadinessPolicy immediate = {0};
    assert(!macVNCReadinessIsReady(&immediate));
    assert(!macVNCReadinessRecordInitialResult(&immediate, true));
    assert(macVNCReadinessIsReady(&immediate));
    assert(!macVNCReadinessRecordInitialResult(&immediate, false));

    MacVNCReadinessPolicy delayed = {0};
    assert(macVNCReadinessRecordInitialResult(&delayed, false));
    assert(!macVNCReadinessRecordInitialResult(&delayed, false));
    assert(!macVNCReadinessPromoteIfReady(&delayed, false));
    assert(!macVNCReadinessIsReady(&delayed));
    assert(macVNCReadinessPromoteIfReady(&delayed, true));
    assert(macVNCReadinessIsReady(&delayed));
    assert(!macVNCReadinessPromoteIfReady(&delayed, true));

    puts("readiness policy tests passed");
    return 0;
}
