#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>
#include <unistd.h>

/* Read the system's own list scoped to THIS process: the assertions must be
   OBSERVABLE, not just tracked in our own variables (an implementation that
   never created them passes every variable check). Scoped because the
   installed macVNC legitimately holds its own two while a test runs. */
static int countNamed(const char *name)
{
    char cmd[320];
    snprintf(cmd, sizeof(cmd),
             "pmset -g assertions | grep 'pid %d(' | grep -c '%s'",
             (int)getpid(), name);
    FILE *f = popen(cmd, "r");
    if (!f) return -1;
    int n = 0;
    if (fscanf(f, "%d", &n) != 1) n = -1;
    pclose(f);
    return n;
}

/* The session pair, named for the run they belong to. */
static int ourAssertionCount(void) { return countNamed("macVNC remote session"); }

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

    
        /* Keep-awake: the pair held while the SERVER runs, not while a viewer
           watches. Observed through pmset, not through our own variables - an
           implementation that never created them passes every variable check.

           It exists because the machine was configured to lock the moment the
           display turns off, and two accidents were hiding that: a leaked
           UserIsActive assertion in macVNC and a caffeinate agent. Removing
           both meant every remote connection landed on the macOS login screen. */
        assert(!macVNCKeepDisplayAwakeIsHeld());
        assert(countNamed("macVNC keep display awake") == 0);

        macVNCSetKeepDisplayAwake(TRUE);
        assert(macVNCKeepDisplayAwakeIsHeld());
        /* Two: preventing display sleep keeps the panel lit, preventing idle
           system sleep keeps the machine reachable at all. */
        assert(countNamed("macVNC keep display awake") == 2);

        /* Idempotent: asking again must not stack a second pair. */
        macVNCSetKeepDisplayAwake(TRUE);
        assert(countNamed("macVNC keep display awake") == 2);

        macVNCSetKeepDisplayAwake(FALSE);
        assert(!macVNCKeepDisplayAwakeIsHeld());
        assert(countNamed("macVNC keep display awake") == 0);
        /* Releasing twice must not fault or resurrect them. */
        macVNCSetKeepDisplayAwake(FALSE);
        assert(countNamed("macVNC keep display awake") == 0);

    puts("test_power_mgmt: all assertions passed");
    }
    return 0;
}
