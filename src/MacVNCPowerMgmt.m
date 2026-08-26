#import "MacVNCPowerMgmt.h"
#import "MacVNCDisplayWake.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#include <pthread.h>
#include <stdatomic.h>
#include "FirstFrameBudget.h" /* macVNCMonotonicNow() — shared monotonic clock */

/*
 * Keep the Mac awake while a remote session is active.
 *
 * This used to save kPMMinutesToDim/kPMMinutesToSleep and write zeros over
 * them - GLOBAL Energy Saver settings with no per-process owner. Three ways to
 * lose the saved values, each leaving the machine on "never sleep" forever:
 * a crash, a force-quit, and the app's own Restart (the relauncher spawns the
 * successor before the predecessor finishes its up-to-5s-per-display capture
 * teardown, so the successor's dimmingInit snapshotted the zero its
 * predecessor had written).
 *
 * An IOPMAssertion fixes all three at once: it is reference-counted inside one
 * process and the kernel drops it when the process dies, whatever the cause.
 * The same API family as MacVNCDisplayWake's user-activity nudge; that module
 * deliberately does NOT hold a persistent assertion, this one does - they do
 * different jobs.
 */

static pthread_mutex_t power_mutex = PTHREAD_MUTEX_INITIALIZER;
static IOPMAssertionID sleepAssertion = kIOPMNullAssertionID;
static rfbBool initialized = FALSE;

/* Kept for API compatibility; both flags now only decide whether an assertion
   is created at all. There is no dim-prevention assertion on macOS, so
   preventDimming is honoured by undim()'s activity nudge alone. */
static rfbBool preventDimming = FALSE;
static rfbBool preventSleep = TRUE;

void macVNCSetPowerPolicy(rfbBool dim, rfbBool sleep)
{
    preventDimming = dim;
    preventSleep = sleep;
}

/* Idempotent: safe to call twice (a restart overlapping a slow predecessor). */
int
dimmingInit(void)
{
    pthread_mutex_lock(&power_mutex);
    if (initialized) {
        pthread_mutex_unlock(&power_mutex);
        return 0;
    }

    if (!preventSleep) {
        initialized = TRUE;
        pthread_mutex_unlock(&power_mutex);
        return 0;
    }

    IOPMAssertionID id = kIOPMNullAssertionID;
    IOReturn rc = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep,
                                              kIOPMAssertionLevelOn,
                                              CFSTR("macVNC remote session"),
                                              &id);
    if (rc != kIOReturnSuccess) {
        pthread_mutex_unlock(&power_mutex);
        return -1;
    }

    sleepAssertion = id;
    initialized = TRUE;
    pthread_mutex_unlock(&power_mutex);
    return 0;
}

int
undim(void)
{
    /* Throttle: runs on every keystroke/mouse-move. The activity nudge lights
       the display and resets the idle timer, which also covers dimming; there
       is no separate dim aggressiveness to poke any more. */
    static const uint64_t kUndimMinIntervalNs = 1000000000ULL; /* 1s */
    static _Atomic uint64_t lastUndimNs = 0;
    uint64_t now = macVNCMonotonicNow();
    uint64_t last = atomic_load_explicit(&lastUndimNs, memory_order_relaxed);
    if (last != 0 && now - last < kUndimMinIntervalNs)
        return 0;
    atomic_store_explicit(&lastUndimNs, now, memory_order_relaxed);

    macVNCWakeDisplays();
    return 0;
}

int
dimmingShutdown(void)
{
    pthread_mutex_lock(&power_mutex);
    if (initialized && sleepAssertion != kIOPMNullAssertionID)
        IOPMAssertionRelease(sleepAssertion);
    sleepAssertion = kIOPMNullAssertionID;
    initialized = FALSE;
    pthread_mutex_unlock(&power_mutex);
    return 0;
}
