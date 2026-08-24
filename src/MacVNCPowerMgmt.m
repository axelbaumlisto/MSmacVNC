#import "MacVNCPowerMgmt.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach_init.h>
#include <mach/mach_port.h>
#include "ReadinessPolicy.h" /* macVNCReadinessNow() — shared monotonic clock */

static rfbBool preventDimming = FALSE;
static rfbBool preventSleep   = TRUE;

void macVNCSetPowerPolicy(rfbBool dim, rfbBool sleep)
{
    preventDimming = dim;
    preventSleep   = sleep;
}

static pthread_mutex_t  dimming_mutex;
static unsigned long    dim_time;
static unsigned long    sleep_time;
static mach_port_t      master_dev_port;
static io_connect_t     power_mgt;
static rfbBool          initialized      = FALSE;
static rfbBool          dim_time_saved   = FALSE;
static rfbBool          sleep_time_saved = FALSE;

static int
saveDimSettings(void)
{
    if (IOPMGetAggressiveness(power_mgt, kPMMinutesToDim, &dim_time) != kIOReturnSuccess)
        return -1;
    dim_time_saved = TRUE;
    return 0;
}

static int
restoreDimSettings(void)
{
    if (!dim_time_saved)
        return -1;
    if (IOPMSetAggressiveness(power_mgt, kPMMinutesToDim, dim_time) != kIOReturnSuccess)
        return -1;
    dim_time_saved = FALSE;
    dim_time = 0;
    return 0;
}

static int
saveSleepSettings(void)
{
    if (IOPMGetAggressiveness(power_mgt, kPMMinutesToSleep, &sleep_time) != kIOReturnSuccess)
        return -1;
    sleep_time_saved = TRUE;
    return 0;
}

static int
restoreSleepSettings(void)
{
    if (!sleep_time_saved)
        return -1;
    if (IOPMSetAggressiveness(power_mgt, kPMMinutesToSleep, sleep_time) != kIOReturnSuccess)
        return -1;
    sleep_time_saved = FALSE;
    sleep_time = 0;
    return 0;
}

/* Release everything dimmingInit acquired. Safe to call partially-initialised. */
static void releasePowerResources(void)
{
    if (power_mgt) {
        IOServiceClose(power_mgt);
        power_mgt = 0;
    }
    if (master_dev_port) {
        mach_port_deallocate(mach_task_self(), master_dev_port);
        master_dev_port = 0;
    }
}

int
dimmingInit(void)
{
    /* Idempotent: a prior run must be torn down before re-initialising, so we
       never re-init the mutex or leak the IOKit connection across restarts. */
    if (initialized)
        return 0;

    pthread_mutex_init(&dimming_mutex, NULL);

#if __MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_VERSION_12_0
    if (IOMainPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#else
    if (IOMasterPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#endif
        goto FAILURE;

    if (!(power_mgt = IOPMFindPowerManagement(master_dev_port)))
        goto FAILURE;

    if (preventDimming) {
        if (saveDimSettings() < 0)
            goto FAILURE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToDim, 0) != kIOReturnSuccess)
            goto FAILURE;
    }

    if (preventSleep) {
        if (saveSleepSettings() < 0)
            goto FAILURE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToSleep, 0) != kIOReturnSuccess)
            goto FAILURE;
    }

    initialized = TRUE;
    return 0;

FAILURE:
    /* Roll back everything acquired so a later retry starts clean and no
       IOKit connection / mach port / mutex leaks. */
    releasePowerResources();
    pthread_mutex_destroy(&dimming_mutex);
    return -1;
}

int
undim(void)
{
    /* Throttle: undim() runs on every keystroke/mouse-move. Doing 3 IOKit
       round-trips per input event under the lock is wasteful, so skip if we
       nudged within the last second. */
    static const uint64_t kUndimMinIntervalNs = 1000000000ULL; /* 1s */
    static _Atomic uint64_t lastUndimNs = 0;
    uint64_t now = macVNCReadinessNow();
    uint64_t last = atomic_load_explicit(&lastUndimNs, memory_order_relaxed);
    if (last != 0 && now - last < kUndimMinIntervalNs)
        return 0;
    atomic_store_explicit(&lastUndimNs, now, memory_order_relaxed);

    int result = -1;

    pthread_mutex_lock(&dimming_mutex);

    if (!initialized)
        goto DONE;

    if (!preventDimming) {
        if (saveDimSettings() < 0)
            goto DONE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToDim, 0) != kIOReturnSuccess)
            goto DONE;
        if (restoreDimSettings() < 0)
            goto DONE;
    }

    if (!preventSleep) {
        if (saveSleepSettings() < 0)
            goto DONE;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToSleep, 0) != kIOReturnSuccess)
            goto DONE;
        if (restoreSleepSettings() < 0)
            goto DONE;
    }

    result = 0;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
}

int
dimmingShutdown(void)
{
    int result = -1;

    if (!initialized)
        return 0;

    pthread_mutex_lock(&dimming_mutex);
    if (dim_time_saved)
        if (restoreDimSettings() < 0)
            goto DONE;
    if (sleep_time_saved)
        if (restoreSleepSettings() < 0)
            goto DONE;

    result = 0;

 DONE:
    /* Release the IOKit connection + mach port acquired in dimmingInit so a
       later restart does not leak them; then drop the mutex we created. */
    releasePowerResources();
    initialized = FALSE;
    pthread_mutex_unlock(&dimming_mutex);
    pthread_mutex_destroy(&dimming_mutex);
    return result;
}
