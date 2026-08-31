#import "MacVNCPowerMgmt.h"
#import "MacVNCDisplayWake.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#include <pthread.h>
#include <stdatomic.h>
#include "FirstFrameBudget.h" /* macVNCMonotonicNow() — shared monotonic clock */

/*
 * Keep the machine awake for the duration of a remote SESSION.
 *
 * This used to save kPMMinutesToDim/kPMMinutesToSleep and write zeros over
 * them - GLOBAL Energy Saver settings with no per-process owner. Three ways to
 * lose the saved values, each leaving the machine on "never sleep" forever: a
 * crash, a force-quit, and the app's own Restart (the relauncher spawns the
 * successor before the predecessor finishes its capture teardown, so the
 * successor snapshotted the zero its predecessor had written).
 *
 * IOPMAssertions fix all three: reference-counted inside one process, dropped
 * by the kernel when the process dies. Called from reconcileCaptureState() -
 * created when the first client connects, released when the last leaves - so
 * an idle listener with "Start at Login" does not pin the Mac awake either.
 * vncServerStopLocked() releases as an idempotent backstop.
 *
 * Two assertions, not one: NoIdleSleep keeps the SYSTEM from sleeping;
 * PreventUserIdleDisplaySleep keeps the DISPLAY lit. The old code zeroed
 * kPMMinutesToDim for exactly the second effect, and a passive viewer (no
 * input, so no undim() nudge) would otherwise watch the screen go dark.
 */

static pthread_mutex_t power_mutex = PTHREAD_MUTEX_INITIALIZER;
static IOPMAssertionID sleepAssertion = kIOPMNullAssertionID;
static IOPMAssertionID displayAssertion = kIOPMNullAssertionID;
static rfbBool initialized = FALSE;

/* preventSleep creates the no-idle-sleep assertion; preventDimming the
   display one. Both read under power_mutex (the setter writes them there too:
   an unlocked setter racing the reader used to be benign only by luck). */
static rfbBool preventDimming = TRUE;
static rfbBool preventSleep = TRUE;

void macVNCSetPowerPolicy(rfbBool dim, rfbBool sleep)
{
    pthread_mutex_lock(&power_mutex);
    preventDimming = dim;
    preventSleep = sleep;
    pthread_mutex_unlock(&power_mutex);
}

/* Idempotent: safe to call twice (a reconnecting client, a restart). */
int
dimmingInit(void)
{
    pthread_mutex_lock(&power_mutex);
    if (initialized) {
        pthread_mutex_unlock(&power_mutex);
        return 0;
    }

    IOReturn rc;
    if (preventSleep) {
        rc = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep,
                                         kIOPMAssertionLevelOn,
                                         CFSTR("macVNC remote session"),
                                         &sleepAssertion);
        if (rc != kIOReturnSuccess)
            sleepAssertion = kIOPMNullAssertionID;
    }
    if (preventDimming) {
        rc = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep,
                                         kIOPMAssertionLevelOn,
                                         CFSTR("macVNC remote session"),
                                         &displayAssertion);
        if (rc != kIOReturnSuccess)
            displayAssertion = kIOPMNullAssertionID;
    }

    /* Failure to create an assertion is not fatal - the session still works;
       the machine may just sleep sooner than configured. Report it so the
       caller can log, but only when we created nothing we were asked to. */
    int result = 0;
    if ((preventSleep && sleepAssertion == kIOPMNullAssertionID) ||
        (preventDimming && displayAssertion == kIOPMNullAssertionID))
        result = -1;

    initialized = TRUE;
    pthread_mutex_unlock(&power_mutex);
    return result;
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
static _Atomic unsigned gUndimNudgeCount = 0;
unsigned macVNCUndimNudgeCountForTesting(void) { return atomic_load(&gUndimNudgeCount); }
void macVNCResetUndimCountForTesting(void) { atomic_store(&gUndimNudgeCount, 0); }
#define NOTE_UNDIM_NUDGE() atomic_fetch_add(&gUndimNudgeCount, 1)
#else
#define NOTE_UNDIM_NUDGE() do {} while (0)
#endif

int
undim(void)
{
    /* Throttle: runs on every keystroke/mouse-move. The activity nudge lights
       the display and resets the idle timer; with a display assertion held it
       is mostly redundant, but it also covers the window before a client
       authenticated and captures started. */
    static const uint64_t kUndimMinIntervalNs = 1000000000ULL; /* 1s */
    static _Atomic uint64_t lastUndimNs = 0;
    uint64_t now = macVNCMonotonicNow();
    uint64_t last = atomic_load_explicit(&lastUndimNs, memory_order_relaxed);
    if (last != 0 && now - last < kUndimMinIntervalNs)
        return 0;

    pthread_mutex_lock(&power_mutex);
    if (!initialized) {
        /* Consume nothing: an uninitialised call must not block the next one
           (the shipped RELEASE_NOTES once promised exactly this). */
        pthread_mutex_unlock(&power_mutex);
        return -1;
    }
    pthread_mutex_unlock(&power_mutex);

    atomic_store_explicit(&lastUndimNs, now, memory_order_relaxed);
    NOTE_UNDIM_NUDGE();
    macVNCWakeDisplays();
    return 0;
}

int
dimmingShutdown(void)
{
    pthread_mutex_lock(&power_mutex);
    if (sleepAssertion != kIOPMNullAssertionID)
        IOPMAssertionRelease(sleepAssertion);
    if (displayAssertion != kIOPMNullAssertionID)
        IOPMAssertionRelease(displayAssertion);
    sleepAssertion = kIOPMNullAssertionID;
    displayAssertion = kIOPMNullAssertionID;
    initialized = FALSE;
    pthread_mutex_unlock(&power_mutex);
    return 0;
}



/*
 * Keep-awake: the pair held while the SERVER runs, not while a viewer watches.
 *
 * Two assertions, for the same reason the session pair is two: preventing
 * display sleep keeps the panel lit, preventing idle SYSTEM sleep keeps the
 * machine reachable at all. Named differently from the session pair so that
 * `pmset -g assertions` - and the test that reads it - can tell which is which.
 */
static IOPMAssertionID keepDisplayAssertion = kIOPMNullAssertionID;
static IOPMAssertionID keepSystemAssertion = kIOPMNullAssertionID;

void
macVNCSetKeepDisplayAwake(rfbBool enabled)
{
    pthread_mutex_lock(&power_mutex);
    if (enabled) {
        if (keepDisplayAssertion == kIOPMNullAssertionID &&
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep,
                                        kIOPMAssertionLevelOn,
                                        CFSTR("macVNC keep display awake"),
                                        &keepDisplayAssertion) != kIOReturnSuccess)
            keepDisplayAssertion = kIOPMNullAssertionID;
        if (keepSystemAssertion == kIOPMNullAssertionID &&
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep,
                                        kIOPMAssertionLevelOn,
                                        CFSTR("macVNC keep display awake"),
                                        &keepSystemAssertion) != kIOReturnSuccess)
            keepSystemAssertion = kIOPMNullAssertionID;
    } else {
        if (keepDisplayAssertion != kIOPMNullAssertionID)
            IOPMAssertionRelease(keepDisplayAssertion);
        if (keepSystemAssertion != kIOPMNullAssertionID)
            IOPMAssertionRelease(keepSystemAssertion);
        keepDisplayAssertion = kIOPMNullAssertionID;
        keepSystemAssertion = kIOPMNullAssertionID;
    }
    pthread_mutex_unlock(&power_mutex);
}

rfbBool
macVNCKeepDisplayAwakeIsHeld(void)
{
    pthread_mutex_lock(&power_mutex);
    rfbBool held = keepDisplayAssertion != kIOPMNullAssertionID;
    pthread_mutex_unlock(&power_mutex);
    return held;
}
