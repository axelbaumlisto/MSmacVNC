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

int main(void)
{
    test_total_deadline_budget();

    puts("readiness policy tests passed");
    return 0;
}
