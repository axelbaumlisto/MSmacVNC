#pragma once

#include "DisplayLayout.h"

#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Ownership of "is the capture stream actually alive", extracted from mac.m
 * (.pi/plans/core-decomposition.md, step 8) so the watchdog/desk-shape
 * mechanics that used to live as seventeen bare globals in the server core
 * have one file that owns them and one API that reaches them. This is a PURE
 * MOVE (invariant I1): every rule below is unchanged from what mac.m did
 * before this file existed - see MacVNCCaptureSupervisor.m for the WHY
 * comments (silence is the FRESHEST stamp, a failed re-arm still counts
 * toward the cap, the 500ms desk-shape debounce, the reset-reset TOCTOU
 * note), moved here rather than rewritten.
 *
 * What this module does NOT own, on purpose:
 *   - `rfbScreen`/`frameBufferOne` - `rearmCaptures()` stays in mac.m, and is
 *     injected here as the `rearm` hook, so this file never touches
 *     LibVNCServer's screen or canvas.
 *   - `captureControlMutex` - this module is not thread-safe on its own; its
 *     callers hold that lock exactly where mac.m always has (Arm/Disarm from
 *     reconcileCaptureState/startCapturesForNewClient/vncServerDropCaptures/
 *     vncServerStopLocked, all under the lock, matching the mutex order
 *     (I3) unchanged). Where a decision needs to know `gCapturesRunning` or
 *     "is a client connected" - state that DOES live behind that lock - it
 *     asks through the injected `snapshot` hook, which mac.m implements by
 *     taking the lock itself; this module never acquires it directly.
 *   - the desk itself: `readDeskLayoutWithoutWaking` and `anyDisplayActive`
 *     are injected probes into CoreGraphics/mac.m, not owned here.
 *   - the published layout and capture-session generation: those belong to
 *     MacVNCLayoutRegistry (step 7), read here directly since both are pure,
 *     dependency-free peers, not something that needs injecting.
 */

typedef struct {
    /* The existing gCaptureStopQueue, not a new one - every timer and
       callback this module creates runs there, exactly as today. */
    dispatch_queue_t queue;
    /* mac.m's rearmCaptures(): stop, re-read the desk, rebuild - same shape
       or a canvas swap. Returns false on any failure; this module does not
       care which failure, only that the attempt still counts. */
    bool (*rearm)(void);
    /* mac.m's reportCaptureFailure(false) - the one existing path that turns
       into KeepServing/StopServer/an alert in AppDelegate. */
    void (*reportFailure)(void);
    /* The non-waking desk probe (mac.m's resolveDeskLayoutWithoutWaking with
       logEnumeration=false) - never wakes a sleeping display, matching the
       reasoning in mac.m's own rearmCaptures() and deskShapeDebounceFired. */
    bool (*readDeskLayoutWithoutWaking)(MacVNCDisplayLayout *out);
    /* CGGetActiveDisplayList(...) > 0, read at the same moment as the rest
       of a watchdog tick's snapshot - see CaptureLiveness.h rule 2. */
    bool (*anyDisplayActive)(void);
    /* `*capturesRunning`/`*clientsConnected`, read under captureControlMutex
       by mac.m's implementation - the only way this module ever learns
       either without taking that lock itself. */
    void (*snapshot)(bool *capturesRunning, bool *clientsConnected);
    /* mac.m's permissionHintSuffix(): "" or a hint that Screen Recording is
       not granted, appended to the watchdog's own log lines. Kept as an
       injected hook rather than a direct call so this module never needs to
       know about macVNCCaptureAllowed - that policy is not capture
       supervision, it belongs to whoever owns the permission gate. */
    const char *(*permissionHintSuffix)(void);
} MacVNCCaptureSupervisorHooks;

/* Called once, at server start, before anything below can run. */
void macVNCCaptureSupervisorConfigure(const MacVNCCaptureSupervisorHooks *hooks);

/*
 * The ONE write point for "a frame arrived" from compositeCapturedFrame -
 * stamps this display's liveness and clears the silence-driven re-arm
 * counter, exactly the two atomic ops the hot path did inline before this
 * module existed (I7: no more, no lock, no dispatch here). Caller
 * (compositeCapturedFrame) has already validated `displayIndex` against the
 * current layout's count before calling this - see MacVNCCaptureSupervisor.m.
 */
void macVNCCaptureSupervisorNoteFrame(size_t displayIndex);

/*
 * Captures just (re)started against a layout that may be brand new to this
 * run - reset every display's stamp and the grace-window anchor, so a
 * previous run's silence (or lack of frames) is never this run's problem.
 * Called from rearmCaptures() (mac.m, unconditionally, every call) and from
 * startCapturesForNewClient()'s non-rebuild branch (mac.m) - the two places
 * that used to run this same loop inline.
 */
void macVNCCaptureSupervisorNoteCapturesStarted(void);

/*
 * Arm the watchdog: reset the re-arm cooldown bookkeeping (gLastRearmNs=0,
 * gRearmsSinceFrame=0 - the one place mac.m used to do this inline, right
 * before starting the timer) and create+resume the 1Hz timer if it is not
 * already running. Caller must serialise calls the same way mac.m always
 * has - under captureControlMutex, alongside the gCapturesRunning write it
 * pairs with.
 */
void macVNCCaptureSupervisorArm(void);
/* Caller must serialise calls the same way mac.m always has - under
   captureControlMutex. Idempotent: disarming an unarmed supervisor is a
   no-op, matching stopCaptureLivenessWatchdog()'s own guard. */
void macVNCCaptureSupervisorDisarm(void);

/*
 * FIX-D's entry point from mac.m's vncServerNoteDeskShapeMayHaveChanged(),
 * AFTER that function's own "no client connected" gate - the gate stays
 * exactly where it is today (mac.m), this only ever runs once a caller has
 * already decided a re-evaluation might matter. Debounces a notification
 * burst into one evaluation ~500ms after the LAST call, on `queue`.
 */
void macVNCCaptureSupervisorNoteDeskShapeMayHaveChanged(void);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Everything below is test-only, moved verbatim from mac.h - see each
   original comment's history in MacVNCCaptureSupervisor.m. */

unsigned macVNCCaptureRearmCountForTesting(void);
/* Counts a FAILED rearmCaptures() attempt, and a GiveUp resolution,
   separately from the success-only counter above - see FIX-A/audit item 1
   and B4's integration test, which is the one place these are read. */
unsigned macVNCCaptureRearmFailureCountForTesting(void);
unsigned macVNCCaptureGiveUpCountForTesting(void);

uint64_t macVNCLastFrameTimestampForTesting(size_t displayIndex);

/* 0 = no override, same sentinel style as gCaptureKeepWarmOverrideNs.
   maxRearms is not overridable: a test can already reach it by advancing
   through cooldown windows, and a zero override would be ambiguous between
   "unset" and "give up on the first attempt". */
void macVNCSetCaptureLivenessLimitsForTesting(uint64_t graceNs, uint64_t silenceNs,
                                              uint64_t cooldownNs);

/* FIX-D test hooks - see vncServerNoteDeskShapeMayHaveChanged() in mac.h. */
void macVNCSetDeskShapeDebounceForTesting(uint64_t ns);
/* Counts every DEBOUNCED firing (i.e. every time the notification burst
   actually gets re-evaluated), regardless of what it decides - the one
   number that lets a test tell "a burst of N notifications produced ONE
   evaluation" from "produced N". */
unsigned macVNCDeskShapeRecheckCountForTesting(void);
/* Forces evaluateDeskShapeForRearm() to treat the freshly re-read desk as
   DIFFERENT from the published layout, without needing to fake a
   MacVNCDisplayLayout or physically reconfigure a display. */
void macVNCForceDeskShapeDifferentForTesting(bool force);
/* Counts evaluateDeskShapeForRearm()'s own rearmCaptures() outcome,
   DELIBERATELY separate from macVNCCaptureRearmCountForTesting() - a
   shape-driven rearm must not share the silence watchdog's cooldown/
   maxRearms bookkeeping. */
unsigned macVNCDeskShapeRebuildCountForTesting(void);
unsigned macVNCDeskShapeRebuildFailureCountForTesting(void);

/* Zeroes every counter above - the supervisor's half of
   macVNCResetCaptureStateForTesting(), which stays in mac.h/mac.m because it
   also resets lifecycle-owned counters this module knows nothing about. */
void macVNCCaptureSupervisorResetForTesting(void);
#endif
