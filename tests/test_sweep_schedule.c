/*
 * The periodic full sweep is the safety net under the dirty-rectangle hint:
 * if the capture source ever under-reports what it repainted, the affected
 * region stays wrong on the client until the next sweep. These assertions pin
 * exactly when that sweep happens.
 */

#include <assert.h>
#include <stdio.h>

#include "MacVNCSweepSchedule.h"

int
main(void)
{
    const uint64_t interval = 5000; /* arbitrary units; the module is pure */
    MacVNCSweepSchedule schedule;
    macVNCSweepScheduleInit(&schedule, interval);

    /* The first frame of a run always sweeps: nothing on the canvas can be
       trusted yet, whatever the hint says. */
    assert(macVNCSweepScheduleDueAt(&schedule, 1000));

    /* Inside the interval the hint is allowed to do its job. */
    assert(!macVNCSweepScheduleDueAt(&schedule, 1001));
    assert(!macVNCSweepScheduleDueAt(&schedule, 5999));

    /* Exactly ON the deadline counts as due - the bound is inclusive, so a
       slow frame clock cannot postpone the sweep indefinitely. */
    assert(macVNCSweepScheduleDueAt(&schedule, 6000));
    assert(!macVNCSweepScheduleDueAt(&schedule, 6001));

    /* A display that goes quiet owes ONE sweep, not one per missed interval:
       the deadline rearms from now, so a long gap cannot produce a burst of
       back-to-back full sweeps. */
    assert(macVNCSweepScheduleDueAt(&schedule, 1000000));
    assert(!macVNCSweepScheduleDueAt(&schedule, 1000001));
    assert(!macVNCSweepScheduleDueAt(&schedule, 1004999));
    assert(macVNCSweepScheduleDueAt(&schedule, 1005000));

    /* Interval 0 means every frame is a full sweep - the safe degenerate case,
       never "no sweeps at all". */
    MacVNCSweepSchedule always;
    macVNCSweepScheduleInit(&always, 0);
    for (uint64_t t = 0; t < 5; ++t)
        assert(macVNCSweepScheduleDueAt(&always, t));

    /* Re-init returns a used schedule to "first frame sweeps", which is what a
       capture restart needs: the canvas may be stale from the previous run. */
    macVNCSweepScheduleInit(&schedule, interval);
    assert(macVNCSweepScheduleDueAt(&schedule, 1005001));

    /* A missing schedule must fail SAFE: sweep, never skip pixels. */
    assert(macVNCSweepScheduleDueAt(NULL, 0));

    puts("test_sweep_schedule: all assertions passed");
    return 0;
}
