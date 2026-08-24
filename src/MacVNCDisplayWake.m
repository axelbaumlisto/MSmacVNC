#import "MacVNCDisplayWake.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <CoreFoundation/CoreFoundation.h>

/*
 * Wake the display on demand. We deliberately do NOT hold a persistent
 * NoDisplaySleep assertion (that would behave like a built-in caffeinate).
 * Declaring local user activity lights up a sleeping/dimmed screen and resets
 * the idle timer, which is enough to recover a black remote screen on connect.
 *
 * Apple's guidance is to pass the SAME assertion ID back into repeated
 * IOPMAssertionDeclareUserActivity calls (it updates the existing activity
 * instead of creating a new assertion each time) and to release it when done.
 */
static IOPMAssertionID macVNCUserActivityID = kIOPMNullAssertionID;

void macVNCWakeDisplays(void)
{
    IOPMAssertionDeclareUserActivity(CFSTR("macVNC remote session"),
                                     kIOPMUserActiveLocal, &macVNCUserActivityID);
}

void macVNCReleaseDisplayAssertion(void)
{
    if (macVNCUserActivityID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(macVNCUserActivityID);
        macVNCUserActivityID = kIOPMNullAssertionID;
    }
}
