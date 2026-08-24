#import "MacVNCPowerMgmt.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#include <pthread.h>
#include <mach/mach_init.h>

rfbBool preventDimming = FALSE;
rfbBool preventSleep   = TRUE;

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

int
dimmingInit(void)
{
    pthread_mutex_init(&dimming_mutex, NULL);

#if __MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_VERSION_12_0
    if (IOMainPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#else
    if (IOMasterPort(bootstrap_port, &master_dev_port) != kIOReturnSuccess)
#endif
        return -1;

    if (!(power_mgt = IOPMFindPowerManagement(master_dev_port)))
        return -1;

    if (preventDimming) {
        if (saveDimSettings() < 0)
            return -1;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToDim, 0) != kIOReturnSuccess)
            return -1;
    }

    if (preventSleep) {
        if (saveSleepSettings() < 0)
            return -1;
        if (IOPMSetAggressiveness(power_mgt, kPMMinutesToSleep, 0) != kIOReturnSuccess)
            return -1;
    }

    initialized = TRUE;
    return 0;
}

int
undim(void)
{
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
    initialized = FALSE;

 DONE:
    pthread_mutex_unlock(&dimming_mutex);
    return result;
}
