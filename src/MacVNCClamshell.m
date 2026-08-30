#import "MacVNCClamshell.h"
#import "MacVNCClamshellMarker.h"
#import "MacVNCClamshellPolicy.h"
#import "MacVNCDefaultsKeys.h"
#import "mac.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/pwr_mgt/IOPMLibDefs.h>

#include <pthread.h>
#include <stdatomic.h>
#include <rfb/rfb.h>

/*
 * Closed-display mode's device half: ask the system, and drive the lifecycle.
 *
 * The decisions live in MacVNCClamshellPolicy (pure C) and the persisted record
 * in MacVNCClamshellMarker. What is left here is what only this file can do -
 * the kernel call, the power source, the run loop, and the one mutex.
 */

/* Leaf lock. Nothing taken under it calls back into another macVNC lock. */
static pthread_mutex_t clamshellMutex = PTHREAD_MUTEX_INITIALIZER;
static bool gArmed = false;
static bool gStarted = false;

/*
 * Set once the app has decided to quit, and never cleared.
 *
 * Termination disarms while the listener may still be accepting, so without
 * this a viewer completing authentication during the quit window would re-arm
 * through reconcileCaptureState - and the second-chance disarm in
 * vncServerStopLocked sits behind the very teardown the quit path is allowed to
 * abandon on a timeout. The result would be the bit set at exit.
 */
static atomic_bool gTerminating = false;


/*
 * kPMSetClamshellSleepState is 12 in the public SDK header IOPMLibDefs.h. The
 * user client takes one scalar and needs no entitlement
 * (RootDomainUserClient.cpp: checkScalarInputCount = 1, checkEntitlement =
 * NULL), which is why this works from a plain Developer ID app.
 *
 * The result is not evidence: the dispatcher assigns kIOReturnSuccess after
 * calling setClamShellSleepDisable, whatever that did. We can only report the
 * things we CAN see - opening the connection and delivering the message.
 */
static int
setKernelDisable(void *context, bool disable)
{
    (void)context;
    io_service_t rootDomain = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (rootDomain == IO_OBJECT_NULL)
        return -1;

    io_connect_t connection = IO_OBJECT_NULL;
    IOReturn opened = IOServiceOpen(rootDomain, mach_task_self(), 0, &connection);
    IOObjectRelease(rootDomain);
    if (opened != kIOReturnSuccess || connection == IO_OBJECT_NULL)
        return -1;

    uint64_t input = disable ? 1 : 0;
    IOReturn sent = IOConnectCallScalarMethod(
        connection, kPMSetClamshellSleepState, &input, 1, NULL, NULL);
    IOServiceClose(connection);

    return sent == kIOReturnSuccess ? 0 : -1;
}

static bool
writeMarker(void *context, bool present)
{
    (void)context;
    return macVNCClamshellMarkerWrite(present);
}

static MacVNCClamshellEffects
realEffects(void)
{
    MacVNCClamshellEffects effects;
    effects.setMarker = writeMarker;
    effects.setKernelDisable = setKernelDisable;
    effects.context = NULL;
    return effects;
}

static bool
onWallPower(void)
{
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob == NULL) {
        /* Unknown power state must not arm: the precondition exists to stop a
           lid-shut laptop cooking on battery, and "I could not tell" is not
           "it is plugged in". */
        return false;
    }
    CFStringRef source = IOPSGetProvidingPowerSourceType(blob);
    bool ac = source != NULL &&
              CFStringCompare(source, CFSTR(kIOPMACPowerKey), 0) ==
                  kCFCompareEqualTo;
    CFRelease(blob);
    return ac;
}

/* Caller must hold clamshellMutex. Failures are reported by whichever component
   failed - the marker says so itself - so this only narrates state changes. */
static void
applyLocked(MacVNCClamshellAction action)
{
    if (action == MacVNCClamshellActionNone)
        return;

    MacVNCClamshellEffects effects = realEffects();
    bool before = gArmed;
    gArmed = macVNCClamshellApply(action, gArmed, &effects);
    if (gArmed != before)
        rfbLog("Closed-display mode %s\n",
               gArmed ? "armed (lid close will not sleep this Mac while a "
                        "viewer is connected)"
                      : "released");
}

void
macVNCClamshellReevaluate(void)
{
    @autoreleasepool {
        MacVNCClamshellInputs inputs;

        pthread_mutex_lock(&clamshellMutex);
        /* Sampled UNDER the lock. Read before it, a thread that then blocked
           behind a multi-millisecond apply (a cfprefsd round trip plus three
           IOKit calls) could apply a stale decision last and leave the state
           contradicting the world. */
        inputs.preferenceEnabled =
            [NSUserDefaults.standardUserDefaults boolForKey:MacVNCKeyClamshell];

        /* Nothing to decide when the feature is off and we hold nothing:
           macVNCClamshellDecide() answers None for every combination of the
           remaining terms. Worth short-circuiting rather than "optimising
           later", because this runs on the client connect and disconnect path
           of every user - including the overwhelming majority who never enable
           closed-display mode - and IOPSCopyPowerSourcesInfo() below is a real
           round trip. Leaving it in made a connect measurably slower and broke
           a timing witness in test_capture_gate. */
        if (!inputs.preferenceEnabled && !gArmed) {
            pthread_mutex_unlock(&clamshellMutex);
            return;
        }

        inputs.viewerConnected = atomic_load(&vncConnectedClients) > 0;
        inputs.onWallPower = onWallPower();
        inputs.terminating = atomic_load(&gTerminating);
        inputs.armed = gArmed;
        applyLocked(macVNCClamshellDecide(inputs));
        pthread_mutex_unlock(&clamshellMutex);
    }
}

static void
powerSourceChanged(void *context)
{
    (void)context;
    /* Unplugging the adaptor while the lid is shut is precisely the case the
       wall-power precondition exists for, so this notification is part of the
       safety story rather than a refinement of it. */
    macVNCClamshellReevaluate();
}

void
macVNCClamshellStart(void)
{
    @autoreleasepool {
        pthread_mutex_lock(&clamshellMutex);
        if (gStarted) {
            pthread_mutex_unlock(&clamshellMutex);
            return;
        }
        gStarted = true;

        MacVNCClamshellMarkerState marker = macVNCClamshellMarkerRead();
        MacVNCClamshellAction recovery = macVNCClamshellRecoveryAction(
            marker.present, marker.sameBootSession, marker.ownerAlive);
        if (recovery == MacVNCClamshellActionDisarm) {
            rfbLog("Closed-display mode was left armed by a previous run; "
                   "clearing\n");
            gArmed = true; /* so the disarm path runs and clears the record */
        } else if (recovery == MacVNCClamshellActionForgetMarker) {
            rfbLog("Discarding a closed-display record from an earlier boot "
                   "(the setting did not survive the restart)\n");
        }
        applyLocked(recovery);
        pthread_mutex_unlock(&clamshellMutex);

        /* COMMON modes, not the default mode only. In the default mode this
           source stops firing while a menu is tracked or Preferences is modal,
           and "unplugging releases it" is a safety promise rather than a
           nicety. The same mistake is already documented for the menu timer in
           AppDelegate. */
        CFRunLoopSourceRef source =
            IOPSNotificationCreateRunLoopSource(powerSourceChanged, NULL);
        if (source != NULL) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            CFRelease(source);
        } else {
            rfbLog("Power source notifications unavailable; closed-display mode "
                   "will not react to the adaptor being unplugged\n");
        }

        macVNCClamshellReevaluate();
    }
}

void
macVNCClamshellReleaseForServerStop(void)
{
    @autoreleasepool {
        pthread_mutex_lock(&clamshellMutex);
        /* Only what WE hold. The bit has no reference count and is shared with
           powerd and with apps like Amphetamine, so a path that cleared it
           regardless would silently cancel theirs. A record on disk we did not
           write belongs to another process or another boot, and Start has
           already dealt with those. */
        if (gArmed)
            applyLocked(MacVNCClamshellActionDisarm);
        pthread_mutex_unlock(&clamshellMutex);
    }
}

void
macVNCClamshellShutdown(void)
{
    /* Latched FIRST, and only here. This used to live in the shared release
       path, which every server stop runs - so pressing Stop and then Start in
       the menu disabled closed-display mode for the rest of the app's life,
       with nothing said and no way back short of quitting. The latch belongs to
       termination alone, because termination is the only stop that is not
       meant to be undone. */
    atomic_store(&gTerminating, true);
    macVNCClamshellReleaseForServerStop();
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
bool
macVNCClamshellIsTerminatingForTesting(void)
{
    return atomic_load(&gTerminating);
}
#endif

