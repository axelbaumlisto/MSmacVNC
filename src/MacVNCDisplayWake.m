#import "MacVNCDisplayWake.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <CoreFoundation/CoreFoundation.h>

/*
 * Wake the display on demand. We deliberately do NOT hold a persistent
 * NoDisplaySleep assertion (that would behave like a built-in caffeinate).
 * Declaring local user activity lights up a sleeping/dimmed screen and resets
 * the idle timer, which is enough to recover a black remote screen on connect.
 */
void macVNCWakeDisplays(void)
{
    IOPMAssertionID activityID = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("macVNC remote session"),
                                     kIOPMUserActiveLocal, &activityID);
}

void macVNCReleaseDisplayAssertion(void)
{
    /* No persistent assertion is held; nothing to release. */
}
