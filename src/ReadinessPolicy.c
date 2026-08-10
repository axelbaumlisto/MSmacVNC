#include "ReadinessPolicy.h"

#include <assert.h>
#include <stdint.h>

MacVNCReadinessBudget
macVNCReadinessBudgetStart(uint64_t nowNanoseconds, uint64_t totalNanoseconds)
{
    uint64_t deadline = UINT64_MAX - nowNanoseconds < totalNanoseconds
        ? UINT64_MAX
        : nowNanoseconds + totalNanoseconds;
    return (MacVNCReadinessBudget){.deadlineNanoseconds = deadline};
}

uint64_t
macVNCReadinessBudgetRemaining(const MacVNCReadinessBudget *budget,
                                uint64_t nowNanoseconds)
{
    if (!budget || nowNanoseconds >= budget->deadlineNanoseconds)
        return 0;
    return budget->deadlineNanoseconds - nowNanoseconds;
}

struct timespec
macVNCReadinessRelativeWait(uint64_t remainingNanoseconds)
{
    return (struct timespec){
        .tv_sec = (time_t)(remainingNanoseconds / 1000000000ULL),
        .tv_nsec = (long)(remainingNanoseconds % 1000000000ULL),
    };
}

bool
macVNCReadinessRecordInitialResult(MacVNCReadinessPolicy *policy, bool allReady)
{
    assert(policy);
    if (policy->state != MACVNC_READINESS_WAITING)
        return false;
    if (allReady) {
        policy->state = MACVNC_READINESS_READY;
        return false;
    }
    policy->state = MACVNC_READINESS_TIMED_OUT;
    return true;
}

bool
macVNCReadinessPromoteIfReady(MacVNCReadinessPolicy *policy, bool allReady)
{
    assert(policy);
    if (policy->state != MACVNC_READINESS_TIMED_OUT || !allReady)
        return false;
    policy->state = MACVNC_READINESS_READY;
    return true;
}

bool
macVNCReadinessIsReady(const MacVNCReadinessPolicy *policy)
{
    return policy && policy->state == MACVNC_READINESS_READY;
}
