#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>
#include <unistd.h>

/* Read the system's own list scoped to THIS process: the assertions must be
   OBSERVABLE, not just tracked in our own variables (an implementation that
   never created them passes every variable check). Scoped because the
   installed macVNC legitimately holds its own two while a test runs. */
static int ourAssertionCount(void)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd),
             "pmset -g assertions | grep 'pid %d(' | grep -c 'macVNC remote session'",
             (int)getpid());
    FILE *f = popen(cmd, "r");
    if (!f) return -1;
    int n = 0;
    if (fscanf(f, "%d", &n) != 1) n = -1;
    pclose(f);
    return n;
}

#include "MacVNCPowerMgmt.h"

/*
 * The power module whose failure mode is a GLOBAL machine setting ("never
 * sleeps again", or "screen goes dark mid-session"). Until this file existed
 * it had no ctest target at all - every body could have been `return 0;`.
 */

int main(void)
{
    @autoreleasepool {
        /* Disabled policy: init must succeed and create nothing (idempotent). */
        macVNCSetPowerPolicy(FALSE, FALSE);
        assert(dimmingInit() == 0);
        assert(dimmingInit() == 0);
        /* Double shutdown must not double-release. */
        assert(dimmingShutdown() == 0);
        assert(dimmingShutdown() == 0);

        /* Default policy: both assertions creatable and OBSERVABLE system-wide. */
        macVNCSetPowerPolicy(TRUE, TRUE);
        assert(dimmingInit() == 0);
        assert(ourAssertionCount() >= 2); /* system sleep + display sleep, ours */
        assert(dimmingShutdown() == 0);
        assert(ourAssertionCount() == 0);
        assert(dimmingShutdown() == 0);
        assert(ourAssertionCount() == 0);

        /* undim() before init: no nudge, and the throttle window NOT consumed
           (a shipped RELEASE_NOTES entry once promised exactly this). */
        macVNCResetUndimCountForTesting();
        assert(undim() == -1);
        assert(macVNCUndimNudgeCountForTesting() == 0);

        /* After init: first call nudges, second within 1s is throttled. */
        macVNCSetPowerPolicy(FALSE, FALSE);
        assert(dimmingInit() == 0);
        assert(undim() == 0);
        assert(macVNCUndimNudgeCountForTesting() == 1);
        assert(undim() == 0);
        assert(macVNCUndimNudgeCountForTesting() == 1);
        assert(dimmingShutdown() == 0);

        puts("test_power_mgmt: all assertions passed");
    }
    return 0;
}
