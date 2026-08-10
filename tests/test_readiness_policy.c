#include "ReadinessPolicy.h"

#include <assert.h>
#include <stdio.h>

int main(void)
{
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
