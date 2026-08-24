#import "MacVNCDisplayWake.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <CoreFoundation/CoreFoundation.h>

/* Persistent assertion that keeps the display awake while the server runs. */
static IOPMAssertionID macVNCDisplayAssertion = kIOPMNullAssertionID;

void macVNCWakeDisplays(void)
{
    IOPMAssertionID activityID = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("macVNC remote session"),
                                     kIOPMUserActiveLocal, &activityID);

    if (macVNCDisplayAssertion == kIOPMNullAssertionID) {
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep,
                                    kIOPMAssertionLevelOn,
                                    CFSTR("macVNC keeps display awake for remote viewing"),
                                    &macVNCDisplayAssertion);
    }
}

void macVNCReleaseDisplayAssertion(void)
{
    if (macVNCDisplayAssertion != kIOPMNullAssertionID) {
        IOPMAssertionRelease(macVNCDisplayAssertion);
        macVNCDisplayAssertion = kIOPMNullAssertionID;
    }
}
