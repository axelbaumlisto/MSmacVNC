#pragma once

#include <stdbool.h>

/*
 * When macVNC asks the kernel to stop sleeping on lid close, and in what order
 * the side effects must happen.
 *
 * Split out of the IOKit adapter because every interesting rule here is a
 * decision, not a system call, and because the system call it drives is one we
 * cannot check afterwards. The kernel's answer is worthless
 * (RootDomainUserClient.cpp assigns kIOReturnSuccess unconditionally after
 * setClamShellSleepDisable) and the resulting mask is never republished into
 * the registry, so there is no gate of the kind the curtain window has. What
 * can be tested is exactly what lives in this file.
 *
 * The bit itself is global, shared with powerd, not reference counted, and NOT
 * cleared when the setting process dies. That last property is the same hazard
 * MacVNCPowerMgmt.h describes for the old kPMMinutesToSleep code - a crash used
 * to leave the Mac on "never sleep" forever - which is why arming is paired
 * with a persisted marker and why the ordering below is a correctness rule
 * rather than a detail.
 */

typedef enum {
    MacVNCClamshellActionNone = 0,
    MacVNCClamshellActionArm,
    MacVNCClamshellActionDisarm,
    /* Drop a stale record without touching the kernel. Needed because a marker
       is not proof that the bit is set: the mask is zeroed at boot while the
       marker survives on disk, so a marker from an earlier boot describes a bit
       that no longer exists and must not be "cleared". */
    MacVNCClamshellActionForgetMarker
} MacVNCClamshellAction;

typedef struct {
    /* The user asked for closed-display mode in Preferences. */
    bool preferenceEnabled;
    /* At least one authenticated viewer is being served right now. Arming for
       the lifetime of the LISTENER instead would pin a "never sleep on lid
       close" bit for weeks under Start at Login - the same mistake the power
       assertions were moved off of. */
    bool viewerConnected;
    /* The power adaptor is attached. A lid-shut machine that refuses to sleep
       on battery cooks itself in a bag; on the adaptor the worst case is
       wasted electricity. It also keeps us strictly additive to macOS, whose
       own rule needs an external display AND wall power. */
    bool onWallPower;
    /* The app has decided to quit. Its own term rather than something folded
       into viewerConnected, because it is a different fact and the quit window
       is exactly when a late connection must NOT be able to re-arm: the
       second-chance disarm sits behind a teardown the quit path may abandon on
       a timeout, so an arm accepted here can survive the process. */
    bool terminating;
    /* What WE last successfully told the kernel. Not a reading of the kernel:
       no such reading exists. */
    bool armed;
} MacVNCClamshellInputs;

MacVNCClamshellAction macVNCClamshellDecide(MacVNCClamshellInputs inputs);

/*
 * What to do at launch about a marker found on disk.
 *
 * "A marker exists" is NOT enough to justify a kernel call, and this is the
 * most important correction in this file. The bit is shared and uncounted, so
 * clearing it on the strength of an anonymous marker breaks other software:
 * after a reboot the marker is stale (the mask was zeroed at boot), and if the
 * user has since armed Amphetamine's closed-display mode, launching macVNC
 * would cancel it. Equally, this project routinely runs a second instance on
 * another port with the SAME bundle id and therefore the SAME defaults domain,
 * where a bare marker would make every new instance disarm the live one.
 *
 * So the marker records WHO wrote it and in WHICH boot, and recovery is a
 * three-way decision:
 *   - not our boot          -> the bit is already gone; just drop the record
 *   - our boot, owner alive -> another live session owns it; hands off
 *   - our boot, owner gone  -> that run died armed; this is the real recovery
 */
MacVNCClamshellAction macVNCClamshellRecoveryAction(bool markerPresent,
                                                    bool sameBootSession,
                                                    bool ownerAlive);

/*
 * The side effects, injected so the ordering rule can be tested without IOKit.
 * setKernelDisable returns 0 on success. setMarker persists synchronously.
 */
typedef struct {
    /* Returns false when the record could not be persisted. That answer is
       load-bearing: an unrecordable marker means an unrecoverable bit, so the
       arming path refuses rather than proceeding. */
    bool (*setMarker)(void *context, bool present);
    int (*setKernelDisable)(void *context, bool disable);
    void *context;
} MacVNCClamshellEffects;

/*
 * Performs `action` and returns the resulting armed state.
 *
 * Order is the whole point. Going up: marker FIRST, then the kernel call.
 * Coming down: kernel call FIRST, then clear the marker. A crash in either gap
 * then leaves a marker with no bit set, which costs one harmless extra disarm
 * at the next launch. The reverse order leaves the bit set with nothing
 * recording that we set it, and that is unrecoverable short of a reboot.
 *
 * A failed kernel call on the way up leaves the marker in place rather than
 * rolling it back: we cannot tell a rejected call from a delivered one, so the
 * only safe assumption is that the bit may be set. A marker that could not be
 * WRITTEN is the opposite case and refuses the arm outright - there the bit is
 * known not to have been requested yet.
 */
bool macVNCClamshellApply(MacVNCClamshellAction action, bool armed,
                          const MacVNCClamshellEffects *effects);
