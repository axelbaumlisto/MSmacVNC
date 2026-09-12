#import "MacVNCCaptureSupervisor.h"

#import "MacVNCLayoutRegistry.h"
#import "CaptureLiveness.h"
#import "FirstFrameBudget.h"

#include <rfb/rfb.h>
#include <stdatomic.h>

/*
 * See MacVNCCaptureSupervisor.h for what this file does NOT own and why
 * (rfbScreen/frameBufferOne, captureControlMutex, the desk itself - all
 * reached through the hooks below). Everything here is a PURE MOVE from
 * mac.m (.pi/plans/core-decomposition.md, step 8); the WHY comments on each
 * piece of state are unchanged from where they used to live inline.
 */

static MacVNCCaptureSupervisorHooks gHooks;

void
macVNCCaptureSupervisorConfigure(const MacVNCCaptureSupervisorHooks *hooks)
{
    gHooks = *hooks;
}

/* Indexed by a frame's `displayIndex` (MacVNCCaptureFrameOrigin), always
 * live-session-fresh - a stale session's callback is rejected by its
 * `generation` before reaching this array. 0 = "no frame yet"
 * (macVNCUptimeNow() never returns 0). Stamped with macVNCUptimeNow(), never
 * a sleep-inclusive clock, so a long system sleep is never mistaken for a
 * dead stream - see ARCHITECTURE.md § FirstFrameBudget for the measurement
 * that established this. */
static _Atomic uint64_t gLastFrameNs[MACVNC_MAX_DISPLAYS];
/* When the currently running captures were told to start - the watchdog's
   grace-period anchor and, absent any frame yet, its silence anchor too. */
static _Atomic uint64_t gCapturesStartedNs = 0;
static _Atomic uint64_t gLastRearmNs = 0;
static _Atomic unsigned gRearmsSinceFrame = 0;
/* Armed and disarmed by mac.m's reconcileCaptureState() and its stop paths,
   always under captureControlMutex alongside the gCapturesRunning write
   they pair with - a plain (non-atomic) pointer toggled from more than one
   call site would otherwise race between one thread's disarm and another's
   re-arm. mac.m still owns that lock (I3); this module only ever assumes
   its callers serialise Arm/Disarm the same way they always have. */
static dispatch_source_t gCaptureLivenessTimer;
#if defined(MACVNC_ENABLE_TEST_HOOKS)
static _Atomic unsigned gCaptureRearmCount = 0;
/* Counts a FAILED rearmCaptures() attempt, and a GiveUp resolution,
   separately from the success-only counter above - see ARCHITECTURE.md
   § CaptureLiveness (the first follow-up's item 1) and
   `capture_liveness_rearm_failure`, the one test that reads these. */
static _Atomic unsigned gCaptureRearmFailureCount = 0;
static _Atomic unsigned gCaptureGiveUpCount = 0;
/* 0 = no override, same sentinel style as mac.m's gCaptureKeepWarmOverrideNs.
   maxRearms is not overridable: a test can already reach it by advancing
   through cooldown windows, and a zero override would be ambiguous between
   "unset" and "give up on the first attempt". */
static _Atomic uint64_t gCaptureLivenessGraceOverrideNs = 0;
static _Atomic uint64_t gCaptureLivenessSilenceOverrideNs = 0;
static _Atomic uint64_t gCaptureLivenessCooldownOverrideNs = 0;
void macVNCSetCaptureLivenessLimitsForTesting(uint64_t graceNs, uint64_t silenceNs,
                                              uint64_t cooldownNs)
{
    atomic_store(&gCaptureLivenessGraceOverrideNs, graceNs);
    atomic_store(&gCaptureLivenessSilenceOverrideNs, silenceNs);
    atomic_store(&gCaptureLivenessCooldownOverrideNs, cooldownNs);
}
#endif

/* FIX-D: closes the one gap silence-based watchdog cannot see - a display
 * RESIZED rather than silenced keeps delivering frames at the OLD
 * dimensions forever (measured: zero re-arms, canvas stuck at the pre-change
 * size - see ARCHITECTURE.md § CaptureLiveness). Reacts to macOS's own
 * reconfiguration notice instead. Queue-confined like gCaptureLivenessTimer:
 * no lock needed. REUSED across a notification burst rather than
 * recreated - rescheduling an armed timer IS the debounce. */
static dispatch_source_t gDeskShapeDebounceTimer;

/* Wait after the LAST screen-parameters notification before re-reading the
 * desk - not the first, since a reconfiguration fires this several times as
 * it settles. 500ms coalesces a measured burst while staying well inside the
 * watchdog's own ~10s recovery budget - see ARCHITECTURE.md § CaptureLiveness
 * (FIX-D). */
#define MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS (500ULL * NSEC_PER_MSEC)

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Counts every DEBOUNCED firing - lets a test tell "a burst of N
   notifications produced ONE evaluation" from "produced N". */
static _Atomic unsigned gDeskShapeRecheckCount = 0;
unsigned macVNCDeskShapeRecheckCountForTesting(void)
{ return atomic_load(&gDeskShapeRecheckCount); }
/* 0 = use the shipped 500ms; lets a test observe a second, separate firing
   without waiting out the real debounce. */
static _Atomic uint64_t gDeskShapeDebounceOverrideNs = 0;
void macVNCSetDeskShapeDebounceForTesting(uint64_t ns)
{ atomic_store(&gDeskShapeDebounceOverrideNs, ns); }
/* Forces evaluateDeskShapeForRearm() below to treat the freshly re-read desk
   as DIFFERENT from the published layout, without needing to fake a
   MacVNCDisplayLayout or physically reconfigure a display: a test can prove
   "differing layout => exactly one rebuild" against the ALREADY-tested
   rearmCaptures() (via the injected `rearm` hook) by forcing the one
   decision this file adds - the rest of the rebuild path is real
   ScreenCaptureKit/LibVNCServer work, unmocked. */
static _Atomic bool gForceDeskShapeDifferentForTesting = false;
void macVNCForceDeskShapeDifferentForTesting(bool force)
{ atomic_store(&gForceDeskShapeDifferentForTesting, force); }
/* Counts evaluateDeskShapeForRearm()'s own rearmCaptures() outcome,
   DELIBERATELY separate from gCaptureRearmCount - see that function's own
   comment for why a shape-driven rearm must not share the silence
   watchdog's cooldown/maxRearms bookkeeping. */
static _Atomic unsigned gDeskShapeRebuildCount = 0;
unsigned macVNCDeskShapeRebuildCountForTesting(void)
{ return atomic_load(&gDeskShapeRebuildCount); }
static _Atomic unsigned gDeskShapeRebuildFailureCount = 0;
unsigned macVNCDeskShapeRebuildFailureCountForTesting(void)
{ return atomic_load(&gDeskShapeRebuildFailureCount); }
#endif

/* The MOST RECENT stamp over the displays in the layout - the MAXIMUM, not
 * the MINIMUM this used to be. Measured false in production: an idle
 * display simply gets no new sample buffer, so the minimum made ANY idle
 * display look like a dead stream forever (9 re-arms/2 min on a healthy
 * session). This deliberately gives up catching "one of several displays
 * died while the rest keep working" - see ARCHITECTURE.md § CaptureLiveness
 * (FIX-C) for the measurement and why that gap is left open on purpose. */
static uint64_t
freshestFrameStamp(void)
{
    const MacVNCDisplayLayout *layout = macVNCLayoutRegistryCurrent();
    if (layout->count == 0)
        return 0;
    uint64_t freshest = 0;
    for (size_t i = 0; i < layout->count; ++i) {
        uint64_t stamp = atomic_load(&gLastFrameNs[i]);
        if (stamp > freshest)
            freshest = stamp;
    }
    return freshest;
}

static MacVNCCaptureLivenessLimits
captureLivenessLimits(void)
{
    MacVNCCaptureLivenessLimits limits = {
        .graceNs    = MACVNC_CAPTURE_LIVENESS_GRACE_NANOSECONDS,
        .silenceNs  = MACVNC_CAPTURE_LIVENESS_SILENCE_NANOSECONDS,
        .cooldownNs = MACVNC_CAPTURE_LIVENESS_COOLDOWN_NANOSECONDS,
        .maxRearms  = MACVNC_CAPTURE_LIVENESS_MAX_REARMS,
    };
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    uint64_t override;
    if ((override = atomic_load(&gCaptureLivenessGraceOverrideNs)) != 0)
        limits.graceNs = override;
    if ((override = atomic_load(&gCaptureLivenessSilenceOverrideNs)) != 0)
        limits.silenceNs = override;
    if ((override = atomic_load(&gCaptureLivenessCooldownOverrideNs)) != 0)
        limits.cooldownNs = override;
#endif
    return limits;
}

/* The ONE write point for "a frame arrived" - I7: exactly the two atomic ops
 * the hot path did inline before this module existed, no lock, no dispatch.
 * Independent of compositeCapturedFrame's own size check: a wrong-sized
 * frame is a different bug from a stopped stream, and only the watchdog
 * cares about the latter. */
void
macVNCCaptureSupervisorNoteFrame(size_t displayIndex)
{
    atomic_store(&gLastFrameNs[displayIndex], macVNCUptimeNow());
    /* A delivered frame from ANY display proves the stream is alive again,
       so a PRIOR silence's re-arm count no longer describes the current
       situation. Shares the EXACT same trigger as silence itself
       (freshestFrameStamp() is the MAXIMUM over these same stamps), so a
       tick that resets this is, by construction, a tick where the next
       silence check already reports Alive first. See ARCHITECTURE.md
       § CaptureLiveness (FIX-C) for the TOCTOU bound on this and the
       production bug it replaced. */
    atomic_store(&gRearmsSinceFrame, 0);
}

void
macVNCCaptureSupervisorNoteCapturesStarted(void)
{
    for (size_t i = 0; i < MACVNC_MAX_DISPLAYS; ++i)
        atomic_store(&gLastFrameNs[i], 0);
    atomic_store(&gCapturesStartedNs, macVNCUptimeNow());
}

static MacVNCCaptureLivenessInput
buildLivenessInput(bool capturesRunning, bool clientsConnected)
{
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = capturesRunning,
        .clientsConnected  = clientsConnected,
        .anyDisplayActive  = gHooks.anyDisplayActive(),
        .nowNs             = macVNCUptimeNow(),
        .lastFrameNs       = freshestFrameStamp(),
        .capturesStartedNs = atomic_load(&gCapturesStartedNs),
        .lastRearmNs       = atomic_load(&gLastRearmNs),
        .rearmsSinceFrame  = atomic_load(&gRearmsSinceFrame),
    };
    return input;
}

/* Bookkeeping advances on a failed rearm too, not only on success below - a
 * failed attempt is still an attempt and must count toward maxRearms, or
 * GiveUp is unreachable on exactly the path most likely to need it. Only
 * GiveUp itself (not an intermediate failed attempt) calls reportFailure() -
 * see ARCHITECTURE.md § CaptureLiveness (the first follow-up's item 1 and
 * the second follow-up's item 4) for the full reasoning. */
static void
handleRearm(const MacVNCCaptureLivenessInput *input, const MacVNCCaptureLivenessLimits *limits)
{
    uint64_t sinceActivity = input->nowNs -
        (input->lastFrameNs ? input->lastFrameNs : input->capturesStartedNs);
    rfbLog("No capture frames for %.1f s; re-arming display captures%s\n",
           (double)sinceActivity / 1e9, gHooks.permissionHintSuffix());
    if (!gHooks.rearm()) {
        atomic_store(&gLastRearmNs, macVNCUptimeNow());
        atomic_fetch_add(&gRearmsSinceFrame, 1);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        atomic_fetch_add(&gCaptureRearmFailureCount, 1);
#endif
        rfbErr("Re-arm attempt %u/%u failed; retrying after the cooldown\n",
               atomic_load(&gRearmsSinceFrame), limits->maxRearms);
        return;
    }
    atomic_store(&gLastRearmNs, macVNCUptimeNow());
    atomic_fetch_add(&gRearmsSinceFrame, 1);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(&gCaptureRearmCount, 1);
#endif
}

static void
handleGiveUp(const MacVNCCaptureLivenessLimits *limits)
{
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(&gCaptureGiveUpCount, 1);
#endif
    rfbLog("Display captures did not recover after %u re-arm(s); "
           "reporting a capture failure%s\n", limits->maxRearms,
           gHooks.permissionHintSuffix());
    gHooks.reportFailure();
}

/* Silence looks identical whether the stream is genuinely dead or Screen
   Recording access was revoked/never granted - see CaptureLiveness.h rule 2
   and mac.m's permissionHintSuffix hook, which supplies the log-line hint
   without this file ever needing to know macVNCCaptureAllowed exists. */
static void
captureLivenessWatchdogFired(void)
{
    bool capturesRunning, clientsConnected;
    gHooks.snapshot(&capturesRunning, &clientsConnected);
    MacVNCCaptureLivenessInput input = buildLivenessInput(capturesRunning, clientsConnected);
    MacVNCCaptureLivenessLimits limits = captureLivenessLimits();

    switch (macVNCResolveCaptureLiveness(&input, &limits)) {
    case MacVNCCaptureAlive:
        return;
    case MacVNCCaptureRearm:
        handleRearm(&input, &limits);
        return;
    case MacVNCCaptureGiveUp:
        handleGiveUp(&limits);
        return;
    }
}

void
macVNCCaptureSupervisorArm(void)
{
    /* Reset the cooldown bookkeeping BEFORE the "already armed" guard below,
       matching mac.m's own call order exactly: startCapturesForNewClient()
       always reset gLastRearmNs/gRearmsSinceFrame unconditionally, right
       before what is now this call - see MacVNCCaptureSupervisor.h. In
       practice this function's only caller only ever reaches the timer
       branch on a fresh arm (gCapturesRunning was false, and every stop
       path calls Disarm() before that transition), so the reset and the
       guarded create/resume below are, as before, effectively one event. */
    atomic_store(&gLastRearmNs, 0);
    atomic_store(&gRearmsSinceFrame, 0);
    if (gCaptureLivenessTimer)
        return;
    gCaptureLivenessTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gHooks.queue);
    dispatch_source_set_timer(gCaptureLivenessTimer,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC, NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(gCaptureLivenessTimer, ^{
        captureLivenessWatchdogFired();
    });
    dispatch_resume(gCaptureLivenessTimer);
}

void
macVNCCaptureSupervisorDisarm(void)
{
    if (!gCaptureLivenessTimer)
        return;
    dispatch_source_cancel(gCaptureLivenessTimer);
    dispatch_release(gCaptureLivenessTimer);
    gCaptureLivenessTimer = NULL;
}

/* FIX-D's decision half: rebuild ONLY if a fresh re-read differs from what
 * is published. Split from the debounce handler so a test can drive this
 * exact decision (macVNCForceDeskShapeDifferentForTesting) without faking a
 * CoreGraphics read - gHooks.rearm() still does its own independent re-read
 * when it rebuilds. An equal layout does nothing and logs nothing. See
 * ARCHITECTURE.md § CaptureLiveness (FIX-D). */
static void
evaluateDeskShapeForRearm(const MacVNCDisplayLayout *fresh)
{
    const MacVNCDisplayLayout *live = macVNCLayoutRegistryCurrent();
    bool equal = live != NULL && macVNCDisplayLayoutsEqual(live, fresh);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    if (atomic_load(&gForceDeskShapeDifferentForTesting))
        equal = false;
#endif
    if (equal)
        return;

    /* WHY a rebuild starts, distinct from rearmCaptures()'s own "rebuilding
       the composite canvas" (WHAT happened) - the two are read together. */
    rfbLog("Display configuration changed: canvas %dx%d -> %dx%d; re-arming display captures\n",
          live ? live->width : 0, live ? live->height : 0,
          fresh->width, fresh->height);

    /* Own counters, deliberately NOT the silence watchdog's - folding a
       shape-driven rearm into gRearmsSinceFrame would let a display that
       reconfigures repeatedly push the silence watchdog toward an unearned
       GiveUp. A failed rebuild still reports through the same
       reportFailure() every other trigger uses. See ARCHITECTURE.md
       § CaptureLiveness (FIX-D). */
    bool rebuilt = gHooks.rearm();
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(rebuilt ? &gDeskShapeRebuildCount : &gDeskShapeRebuildFailureCount, 1);
#endif
    if (!rebuilt) {
        rfbErr("Could not rebuild display captures after a display configuration change\n");
        gHooks.reportFailure();
    }
}

/*
 * Queue-confined: the debounce timer's event handler, so this only ever
 * runs on the one queue rearmCaptures() has always required.
 */
static void
deskShapeDebounceFired(void)
{
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(&gDeskShapeRecheckCount, 1);
#endif
    bool capturesRunning, clientsConnected;
    gHooks.snapshot(&capturesRunning, &clientsConnected);
    if (!capturesRunning || !clientsConnected)
        return; /* nothing running to rebuild, or the last client left while
                    this was in flight - the next connect reads the desk
                    fresh regardless (startCapturesForNewClient). */

    /* Re-read the desk WITHOUT waking it - the same call and the same
       reasoning as rearmCaptures()'s own re-read: a notification implies a
       real reconfiguration happened, not that any display needs waking.
       This is a PROBE, only ever used to compare against the published
       layout below - most notifications turn out equal, and rearmCaptures()
       below already does its own logged re-read the moment this comparison
       finds a real difference, so logging here too would print the same
       display list twice for one real change and once for nothing on every
       notification that changed nothing at all. */
    MacVNCDisplayLayout fresh;
    if (!gHooks.readDeskLayoutWithoutWaking(&fresh)) {
        rfbErr("Could not re-read the desk after a display configuration change\n");
        return;
    }
    evaluateDeskShapeForRearm(&fresh);
}

void
macVNCCaptureSupervisorNoteDeskShapeMayHaveChanged(void)
{
    dispatch_async(gHooks.queue, ^{
        if (!gDeskShapeDebounceTimer) {
            gDeskShapeDebounceTimer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gHooks.queue);
            dispatch_source_set_event_handler(gDeskShapeDebounceTimer, ^{
                deskShapeDebounceFired();
            });
            dispatch_resume(gDeskShapeDebounceTimer);
        }
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        uint64_t debounce = atomic_load(&gDeskShapeDebounceOverrideNs);
        if (debounce == 0)
            debounce = MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS;
#else
        uint64_t debounce = MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS;
#endif
        /* Rescheduling an ALREADY-armed source restarts its deadline rather
           than stacking a second firing - this is the coalescing itself: a
           burst of N calls inside one debounce window produces exactly one
           firing, timed from the LAST call, not the first. */
        dispatch_source_set_timer(gDeskShapeDebounceTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)debounce),
            DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
    });
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
unsigned
macVNCCaptureRearmCountForTesting(void)
{
    return atomic_load(&gCaptureRearmCount);
}

unsigned
macVNCCaptureRearmFailureCountForTesting(void)
{
    return atomic_load(&gCaptureRearmFailureCount);
}

unsigned
macVNCCaptureGiveUpCountForTesting(void)
{
    return atomic_load(&gCaptureGiveUpCount);
}

/* The per-display liveness timestamp gLastFrameNs holds, so a test can prove
   a rejected synthetic frame left it untouched rather than merely hoping a
   non-observable return value implies it. 0 = never stamped, same sentinel
   convention as the production field this reads. */
uint64_t
macVNCLastFrameTimestampForTesting(size_t displayIndex)
{
    if (displayIndex >= MACVNC_MAX_DISPLAYS)
        return 0;
    return atomic_load(&gLastFrameNs[displayIndex]);
}

void
macVNCCaptureSupervisorResetForTesting(void)
{
    atomic_store(&gCaptureRearmCount, 0);
    atomic_store(&gCaptureRearmFailureCount, 0);
    atomic_store(&gCaptureGiveUpCount, 0);
    atomic_store(&gDeskShapeRecheckCount, 0);
    atomic_store(&gForceDeskShapeDifferentForTesting, false);
    atomic_store(&gDeskShapeRebuildCount, 0);
    atomic_store(&gDeskShapeRebuildFailureCount, 0);
}
#endif
