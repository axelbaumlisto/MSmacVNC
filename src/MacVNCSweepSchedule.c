#include "MacVNCSweepSchedule.h"

void
macVNCSweepScheduleInit(MacVNCSweepSchedule *schedule,
                        uint64_t intervalNanoseconds)
{
    if (!schedule)
        return;
    schedule->intervalNanoseconds = intervalNanoseconds;
    /* Deadline 0 is what makes the first frame of a run sweep unconditionally:
       nothing on the canvas can be trusted yet, whatever the hint claims. */
    schedule->nextSweepNanoseconds = 0;
}

bool
macVNCSweepScheduleDueAt(MacVNCSweepSchedule *schedule, uint64_t now)
{
    if (!schedule)
        return true; /* no schedule to consult: never skip pixels */

    if (now < schedule->nextSweepNanoseconds)
        return false;

    /* Rearm from NOW, not from the missed deadline: a display that went quiet
       for a minute owes one sweep, not a minute's worth. */
    schedule->nextSweepNanoseconds = now + schedule->intervalNanoseconds;
    return true;
}
