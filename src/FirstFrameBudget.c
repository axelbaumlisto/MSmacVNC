#include "FirstFrameBudget.h"

#include <assert.h>
#include <stdint.h>
#include <time.h>

uint64_t
macVNCMonotonicNow(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

MacVNCFirstFrameBudget
macVNCFirstFrameBudgetStart(uint64_t nowNanoseconds, uint64_t totalNanoseconds)
{
    uint64_t deadline = UINT64_MAX - nowNanoseconds < totalNanoseconds
        ? UINT64_MAX
        : nowNanoseconds + totalNanoseconds;
    return (MacVNCFirstFrameBudget){.deadlineNanoseconds = deadline};
}

uint64_t
macVNCFirstFrameBudgetRemaining(const MacVNCFirstFrameBudget *budget,
                                uint64_t nowNanoseconds)
{
    if (!budget || nowNanoseconds >= budget->deadlineNanoseconds)
        return 0;
    return budget->deadlineNanoseconds - nowNanoseconds;
}

struct timespec
macVNCRelativeWaitFromNanoseconds(uint64_t remainingNanoseconds)
{
    return (struct timespec){
        .tv_sec = (time_t)(remainingNanoseconds / 1000000000ULL),
        .tv_nsec = (long)(remainingNanoseconds % 1000000000ULL),
    };
}



