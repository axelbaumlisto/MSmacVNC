#pragma once

#include <stdbool.h>
#include <stdint.h>

/*
 * Whether a stream that is technically "running" is actually delivering
 * frames.
 *
 * Measured, not imagined: on 2026-09-10 the desk changed shape, SCStream went
 * silent - no `didStopWithError`, no frame - and macVNC served viewers a
 * 42-hour-old canvas until someone restarted the app by hand.
 *
 * `lastFrameNs` must be the FRESHEST activity across every display this run
 * is watching, never any one display's own stamp in isolation and never the
 * oldest of several. Measured false, on 2026-09-12, one commit after this
 * module first shipped: an idle display with nothing to redraw simply does
 * not get a new sample buffer from ScreenCaptureKit - a still screen and a
 * dead stream look identical FOR THAT ONE DISPLAY. On a desk with several
 * displays, silence is only real when NONE of them are producing anything;
 * the caller (`mac.m`'s `freshestFrameStamp()`) owns turning several
 * per-display timestamps into the single `lastFrameNs` this module reads,
 * exactly so this module itself never has to know how many displays that
 * was or which one changed - it only ever asks "is the freshest of whatever
 * I was handed too old", which is what makes the rule below correct
 * regardless of how many displays fed it.
 *
 * Pure on purpose: this module knows nothing of ScreenCaptureKit,
 * LibVNCServer or CoreGraphics, and no wall clock - time enters as `nowNs`,
 * the same seam macVNCMonotonicNow() already provides everywhere else. The
 * caller owns the wait, the retry and the failure report; this only decides
 * whether one is due.
 */

typedef struct {
    uint64_t graceNs;    /* after a start, before silence counts   */
    uint64_t silenceNs;  /* no frame for this long = not alive     */
    uint64_t cooldownNs; /* minimum spacing between re-arms        */
    unsigned maxRearms;  /* then stop lying and report the failure */
} MacVNCCaptureLivenessLimits;

/*
 * Shipped limits, named rather than inlined so a changed default cannot be
 * silent - the test asserts these exact values. A dead stream is either alive
 * again or honestly reported within about 35s (6s grace + 4s silence + up to
 * 3 cooldown windows of 10s each).
 */
#define MACVNC_CAPTURE_LIVENESS_GRACE_NANOSECONDS (6ULL * 1000000000ULL)
#define MACVNC_CAPTURE_LIVENESS_SILENCE_NANOSECONDS (4ULL * 1000000000ULL)
#define MACVNC_CAPTURE_LIVENESS_COOLDOWN_NANOSECONDS (10ULL * 1000000000ULL)
#define MACVNC_CAPTURE_LIVENESS_MAX_REARMS 3u

typedef struct {
    bool     capturesRunning;
    bool     clientsConnected;
    /* Is any display CURRENTLY active (CGGetActiveDisplayList > 0), read at
       the same moment as the rest of this snapshot? A denied/failed power
       assertion (dimmingInit()) lets the display idle-sleep with a client
       still connected - ScreenCaptureKit then goes silent for a legitimate
       reason this watchdog must not confuse with the dead-stream bug it
       exists to catch: rearming a sleeping display cannot wake it, and
       burning the whole re-arm budget on it only delays the moment the
       machine's OWN wake, not a rebuild, actually fixes the picture. */
    bool     anyDisplayActive;
    uint64_t nowNs;
    uint64_t lastFrameNs;       /* 0 = no frame has arrived yet            */
    uint64_t capturesStartedNs;
    uint64_t lastRearmNs;       /* 0 = never re-armed this run             */
    unsigned rearmsSinceFrame;
} MacVNCCaptureLivenessInput;

typedef enum {
    MacVNCCaptureAlive,
    MacVNCCaptureRearm,
    MacVNCCaptureGiveUp
} MacVNCCaptureLivenessVerdict;

/*
 * The seven ordered rules:
 *  1. no client, or captures not running -> Alive (nothing to watch; this is
 *     what keeps a display that idled itself to sleep with nobody watching
 *     out of the loop - the discarded design's 3am wake cycle looked exactly
 *     like this rule inverted);
 *  2. no display currently active -> Alive (a DIFFERENT, legitimate reason
 *     for silence than rule 1: a client IS watching, but the screen it would
 *     watch is asleep - most often a denied power assertion, not a broken
 *     capture. Re-arming cannot wake a display, so trying is wasted budget;
 *     the machine's own wake is what actually fixes this, and the frame that
 *     follows will reset every counter the normal way);
 *  3. no frame yet and within the grace window -> Alive (a cold start, not a
 *     dead stream);
 *  4. a frame (or the start, if none has arrived) within the silence window
 *     -> Alive;
 *  5. a re-arm already in flight within the cooldown window -> Alive (one
 *     re-arm at a time, so the watchdog cannot queue a StopAndWait behind
 *     another every second a stream stays dead);
 *  6. the re-arm budget for this silence is spent -> GiveUp;
 *  7. otherwise -> Rearm.
 */
MacVNCCaptureLivenessVerdict macVNCResolveCaptureLiveness(
    const MacVNCCaptureLivenessInput *input,
    const MacVNCCaptureLivenessLimits *limits);
