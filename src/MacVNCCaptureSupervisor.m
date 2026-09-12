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

/*
 * gLastFrameNs is indexed by the `displayIndex` a frame's MacVNCCaptureFrameOrigin
 * carries - the same position within the layout its session was Built
 * against (MacVNCCaptureSession.m mints one origin per display, in loop
 * order). A callback whose session is no longer the current one is rejected
 * by its `generation` (see MacVNCLayoutRegistry.c's session-generation
 * counter) before compositeCapturedFrame ever reaches this array, so an
 * index here is always live-session-fresh, never a stale session's position
 * reinterpreted against the current one. 0 means "no frame yet for that
 * slot" - macVNCUptimeNow() never returns 0, so it doubles as a safe
 * sentinel with no separate bool needed alongside it. This array,
 * gCapturesStartedNs and gLastRearmNs are ALL stamped with macVNCUptimeNow(),
 * never a sleep-inclusive clock: the watchdog measures elapsed AWAKE time,
 * so a long system sleep is never mistaken for a dead stream (see
 * macVNCUptimeNow()'s own comment for the measurement that established
 * this).
 */
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
   separately from the success-only counter above - see FIX-A/audit item 1
   and B4's integration test, which is the one place these are read. */
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

/*
 * FIX-D: the watchdog above only ever reacts to SILENCE, and a display that
 * is RESIZED rather than silenced never produces any - ScreenCapturer.m pins
 * SCStreamConfiguration.width/height at Build time, so a reconfigured display
 * keeps delivering frames, just rescaled to the OLD dimensions, forever.
 * Measured on the installed build (2026-09-12): changing the built-in
 * display's mode mid-session produced 753 client updates and ZERO re-arms
 * while the canvas stayed stuck at the pre-change 5552x2715 composite size -
 * see .pi/plans/capture-liveness.md. This timer is the other half of
 * liveness: react to macOS's OWN notice that something about the screens
 * changed, instead of waiting to notice its effect.
 *
 * Queue-confined like gCaptureLivenessTimer above: only ever created,
 * rescheduled or read from the hooks' queue, so no lock guards it.
 * Deliberately REUSED across an entire notification burst rather than
 * cancelled-and-recreated per call (unlike the one-shot keep-warm timer in
 * mac.m, which only ever arms once per stop transition): rescheduling an
 * already-armed dispatch timer source via dispatch_source_set_timer() is
 * exactly how a debounce coalesces a burst into one firing, and the source
 * lives for the rest of the process once first created rather than being
 * torn down between bursts.
 */
static dispatch_source_t gDeskShapeDebounceTimer;

/*
 * How long to wait after the LAST NSApplicationDidChangeScreenParameters
 * notification before actually re-reading the desk.
 *
 * Not the first notification: macOS fires this notification once per
 * attached display as a reconfiguration settles, sometimes more than once per
 * display while resolution/scaling negotiation is still in progress, so
 * reading immediately risks reading a HALF-settled desk and rebuilding onto
 * geometry that is itself about to change again. 500ms is long enough to
 * coalesce that burst (measured reconfiguration bursts on this machine
 * complete well under it) and short enough that a real change still resolves
 * far inside the watchdog's own ~10s recovery budget, so this path is
 * strictly faster than falling back on silence detection, never slower.
 */
#define MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS (500ULL * NSEC_PER_MSEC)

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Counts every DEBOUNCED firing (i.e. every time the notification burst
   actually gets re-evaluated), regardless of what it decides - the one
   number that lets a test tell "a burst of N notifications produced ONE
   evaluation" from "produced N". */
static _Atomic unsigned gDeskShapeRecheckCount = 0;
unsigned macVNCDeskShapeRecheckCountForTesting(void)
{ return atomic_load(&gDeskShapeRecheckCount); }
/* 0 = use the shipped 500ms; matches mac.m's gCaptureKeepWarmOverrideNs's
   sentinel style. Without this a test exercising the debounce would need to
   either wait out the real 500ms (slow but not wrong) or never observe a
   SECOND, separate firing within a bounded test budget. */
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

/*
 * The MOST RECENT stamp over the displays actually in the layout.
 *
 * This used to be the MINIMUM - "one dead panel of two must be caught, not
 * averaged away by a lively one" - on the assumption that ScreenCaptureKit
 * keeps delivering frames at the configured rate whether or not pixels
 * changed. Measured false in production (2026-09-12): a two-display desk
 * where the user worked on only one panel produced NINE re-arms in about two
 * minutes on the IDLE panel's stale stamp alone, tearing down and rebuilding
 * BOTH displays' capture every ~10s while the active display's session was
 * healthy and its viewer was receiving real frames the whole time
 * (end-of-session stats for that run: 3144 ZRLE events, 1547
 * FramebufferUpdate requests). A display with nothing to redraw simply does
 * not get a new sample buffer - see the corrected claim in
 * CaptureLiveness.h and .pi/plans/capture-liveness.md.
 *
 * Silence must therefore mean "NO display in the layout is producing
 * frames", which is the MAXIMUM stamp, not the minimum. This deliberately
 * gives up catching "one of several displays went dead while the rest keep
 * working" - that is a different, narrower failure this function no longer
 * detects. Adding it back would need its own, more conservative mechanism
 * (a much longer per-display threshold, re-arming only the affected display)
 * and is left undone on purpose - see .pi/plans/capture-liveness.md, which
 * this comment's production measurement was written into.
 */
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

/*
 * The ONE write point for "a frame arrived" from compositeCapturedFrame -
 * see CaptureLiveness.h. I7: exactly the two atomic ops the hot path did
 * inline before this module existed, no more, no lock, no dispatch.
 *
 * The call reaching this function is the liveness signal, independent of
 * whatever compositeCapturedFrame's own size check decides afterwards: a
 * stream delivering wrong-sized frames is a different bug from one that
 * stopped delivering anything, and only the watchdog cares about the
 * latter. Caller has already validated `displayIndex` against the current
 * layout's count before calling this.
 */
void
macVNCCaptureSupervisorNoteFrame(size_t displayIndex)
{
    atomic_store(&gLastFrameNs[displayIndex], macVNCUptimeNow());
    /* A delivered frame from ANY display proves the stream that produced it
       is alive again, so whatever re-arm count a PRIOR silence ran up no
       longer describes the current situation - without this reset a stream
       that recovers on its own after two re-arms would need only one more
       silent minute to hit maxRearms and GiveUp.

       This reset and silence share the EXACT same trigger, by construction:
       silence is freshestFrameStamp(), the MAXIMUM stamp over the layout's
       displays, and this line is the only writer of any display's stamp -
       so on any tick where this store just ran, the NEXT watchdog read of
       freshestFrameStamp() is already recent, and CaptureLiveness.c's own
       silence rule reports Alive before rearmsSinceFrame is ever consulted.
       The only way rearmsSinceFrame can climb to maxRearms and reach GiveUp
       is a stretch where NO display delivers a frame for the whole
       grace+silence+maxRearms*cooldown budget - and across exactly that
       stretch this store never runs, so nothing rescues the counter.

       Bounded, not absolute: captureLivenessWatchdogFired() reads
       freshestFrameStamp() and rearmsSinceFrame as two SEPARATE lock-free
       loads (see its `input` snapshot), not one atomic transaction, so a
       frame that lands on the capture-callback thread between those two
       reads pairs a now-stale timestamp (read before the frame) with a
       just-cleared counter (reset by the frame that landed after). That
       reads as MORE silence than is true for exactly one watchdog tick,
       which can cost at most one spurious re-arm - the next tick reads both
       values fresh again, so this cannot compound, and true silence (no
       frame arriving during the ENTIRE window) is untouched by it: GiveUp
       remains reachable within maxRearms+1 attempts, never blocked, only
       possibly delayed by one.

       Before the MIN-to-MAX fix on freshestFrameStamp(), this same
       unconditional reset was the other half of a measured production bug:
       silence was judged by the OLDEST (idle display's) stamp while this
       reset fired on the NEWEST (working display's) frame, so the two
       disagreed - the working display's frames kept clearing a counter that
       the idle display's silence kept trying to raise, twelve re-arms in
       two minutes, GiveUp never reached. Fixing the silence definition
       alone already closes that: it was never a separate defect in the
       reset, just a mismatch between what "silence" and what "reset" each
       looked at. */
    atomic_store(&gRearmsSinceFrame, 0);
}

void
macVNCCaptureSupervisorNoteCapturesStarted(void)
{
    for (size_t i = 0; i < MACVNC_MAX_DISPLAYS; ++i)
        atomic_store(&gLastFrameNs[i], 0);
    atomic_store(&gCapturesStartedNs, macVNCUptimeNow());
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

    MacVNCCaptureLivenessLimits limits = captureLivenessLimits();
    switch (macVNCResolveCaptureLiveness(&input, &limits)) {
    case MacVNCCaptureAlive:
        return;
    case MacVNCCaptureRearm: {
        uint64_t sinceActivity = input.nowNs -
            (input.lastFrameNs ? input.lastFrameNs : input.capturesStartedNs);
        rfbLog("No capture frames for %.1f s; re-arming display captures%s\n",
               (double)sinceActivity / 1e9, gHooks.permissionHintSuffix());
        if (!gHooks.rearm()) {
            /* Bookkeeping advances on failure too, not only on success below -
               this was the bug a whole-diff audit caught: leaving
               gLastRearmNs/gRearmsSinceFrame untouched here meant the very
               next 1Hz tick saw the SAME inputs it just saw, resolved to
               Rearm again, failed again, forever - maxRearms and GiveUp were
               unreachable on exactly the path most likely to need them (a
               re-read or rebuild that keeps failing the same way). A failed
               attempt is still an attempt and must count toward the cap.
               The immediate report below is kept ON TOP of that, not instead
               of it: same layout, same call ScreenInit already trusted at
               startup, now failing mid-run - there is nothing left to retry
               into THIS attempt, so telling the user now rather than after
               more silent cooldown cycles is still right. If this report is
               swallowed by a stale/duplicate check upstream, the advanced
               counters here are what still gets an honest GiveUp out within
               the budget. */
            atomic_store(&gLastRearmNs, macVNCUptimeNow());
            atomic_fetch_add(&gRearmsSinceFrame, 1);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
            atomic_fetch_add(&gCaptureRearmFailureCount, 1);
#endif
            /* B5: LOG this attempt, do not ALERT for it. reportFailure()
               is what turns into an NSAlert (or a KeepServing/StopServer
               decision) in AppDelegate, and with a failed attempt now
               individually counted (the block above), calling it here too
               would mean up to maxRearms distinct alerts inside one ~30s
               budget for a condition that is, until the LAST attempt, still
               recoverable - the exact opposite of "invisible when it works".
               The honest shape: an intermediate failed attempt is a LOG
               event; only GiveUp below is a USER event. Bookkeeping still
               advances above regardless, so GiveUp remains reachable within
               the same budget whether or not anyone is watching the log. */
            rfbErr("Re-arm attempt %u/%u failed; retrying after the cooldown\n",
                   atomic_load(&gRearmsSinceFrame), limits.maxRearms);
            return;
        }
        atomic_store(&gLastRearmNs, macVNCUptimeNow());
        atomic_fetch_add(&gRearmsSinceFrame, 1);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        atomic_fetch_add(&gCaptureRearmCount, 1);
#endif
        return;
    }
    case MacVNCCaptureGiveUp:
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        atomic_fetch_add(&gCaptureGiveUpCount, 1);
#endif
        rfbLog("Display captures did not recover after %u re-arm(s); "
               "reporting a capture failure%s\n", limits.maxRearms,
               gHooks.permissionHintSuffix());
        gHooks.reportFailure();
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

/*
 * The decision half of FIX-D: given a FRESH re-read of the desk, rebuild
 * ONLY if it actually differs from what is currently published.
 *
 * Split out from the debounce handler below so a test can drive this exact
 * decision (via macVNCForceDeskShapeDifferentForTesting) without needing to
 * physically reconfigure a display or fake a CoreGraphics read -
 * gHooks.rearm() (mac.m's rearmCaptures()) performs its OWN independent
 * re-read when it actually rebuilds, so an equal-in-practice `fresh` here
 * still only ever leads to a real, live-desk-accurate rebuild, never a
 * fabricated one.
 *
 * An equal layout does nothing and logs nothing, exactly as a desk that never
 * changed deserves: this function runs on every settled notification burst,
 * which on a machine nobody is reconfiguring is silence the rest of the time.
 */
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

    /* Named here, distinctly from rearmCaptures()'s own "rebuilding the
       composite canvas" line: that line says WHAT happened (a new canvas of
       a given size), this one says WHY a rebuild is starting at all and what
       the comparison that triggered it looked like - the two are read
       together, not as duplicates of each other, the same way
       captureLivenessWatchdogFired's "No capture frames for Xs" line and
       rearmCaptures()'s own logging already coexist for the silence path. */
    rfbLog("Display configuration changed: canvas %dx%d -> %dx%d; re-arming display captures\n",
          live ? live->width : 0, live ? live->height : 0,
          fresh->width, fresh->height);

    /* The return value matters here exactly as much as it does in
       captureLivenessWatchdogFired()'s own Rearm case: a failed rebuild
       triggered by a real reconfiguration is not silently swallowed just
       because THIS trigger is a notification rather than measured silence -
       reportFailure() is the same one path every other capture failure
       already goes through (KeepServing/StopServer decided there, never
       here). Deliberately NOT gCaptureRearmCount/gRearmsSinceFrame/
       gLastRearmNs - those belong to the SILENCE-driven watchdog's own
       cooldown/maxRearms budget, and folding a shape-driven rearm into that
       counter would let an unrelated cause (a display reconfiguring several
       times in a row) push the silence watchdog toward a GiveUp it did not
       earn. This trigger gets its own counters - see
       gDeskShapeRebuildCount/gDeskShapeRebuildFailureCount. */
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
