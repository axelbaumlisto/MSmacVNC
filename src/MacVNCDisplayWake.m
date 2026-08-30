#import "MacVNCDisplayWake.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <CoreFoundation/CoreFoundation.h>

#include <pthread.h>

/*
 * Wake the display on demand.
 *
 * We deliberately do NOT hold a PreventUserIdleDisplaySleep assertion here -
 * that is MacVNCPowerMgmt's job and its lifetime is the session. What this
 * module holds is the UserIsActive assertion that
 * IOPMAssertionDeclareUserActivity creates, and it must be released when the
 * last viewer leaves: held indefinitely it is indistinguishable from a
 * built-in caffeinate, which is exactly what was measured on a live machine
 * before this was fixed.
 *
 * Apple's guidance is to pass the SAME assertion ID back into repeated
 * IOPMAssertionDeclareUserActivity calls - it updates the existing activity
 * instead of creating a new assertion each time - and to release it when done.
 */

/* Leaf lock: undim() runs on client threads while the capture reconciler
   releases from the keep-warm timer's queue. The ID was previously a bare
   static shared across both. */
static pthread_mutex_t wakeMutex = PTHREAD_MUTEX_INITIALIZER;
static IOPMAssertionID macVNCUserActivityID = kIOPMNullAssertionID;

void macVNCWakeDisplays(void)
{
    pthread_mutex_lock(&wakeMutex);
    IOPMAssertionDeclareUserActivity(CFSTR("macVNC remote session"),
                                     kIOPMUserActiveLocal, &macVNCUserActivityID);
    pthread_mutex_unlock(&wakeMutex);
}

void macVNCReleaseDisplayAssertion(void)
{
    pthread_mutex_lock(&wakeMutex);
    if (macVNCUserActivityID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(macVNCUserActivityID);
        macVNCUserActivityID = kIOPMNullAssertionID;
    }
    pthread_mutex_unlock(&wakeMutex);
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
bool macVNCDisplayWakeIsHoldingForTesting(void)
{
    pthread_mutex_lock(&wakeMutex);
    bool held = macVNCUserActivityID != kIOPMNullAssertionID;
    pthread_mutex_unlock(&wakeMutex);
    return held;
}
#endif
