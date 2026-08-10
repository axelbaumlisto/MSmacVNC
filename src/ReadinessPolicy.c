#include "ReadinessPolicy.h"

#include <assert.h>

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
