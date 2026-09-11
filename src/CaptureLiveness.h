#pragma once

#include <stdbool.h>
#include <stdint.h>

/*
 * Whether a stream that is technically "running" is actually delivering
 * frames.
 *
 * Measured, not imagined: on 2026-09-10 the desk changed shape, SCStream went
 * silent - no `didStopWithError`, no frame - and macVNC served viewers a
 * 42-hour-old canvas until someone restarted the app by hand. A still screen
 * is not the failure mode this guards against: ScreenCaptureKit keeps
 * delivering frames at the configured rate whether or not pixels changed, so
 * silence itself is the signal, not the picture.
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
 * The six ordered rules:
 *  1. no client, or captures not running -> Alive (nothing to watch; this is
 *     what keeps a display that idled itself to sleep with nobody watching
 *     out of the loop - the discarded design's 3am wake cycle looked exactly
 *     like this rule inverted);
 *  2. no frame yet and within the grace window -> Alive (a cold start, not a
 *     dead stream);
 *  3. a frame (or the start, if none has arrived) within the silence window
 *     -> Alive;
 *  4. a re-arm already in flight within the cooldown window -> Alive (one
 *     re-arm at a time, so the watchdog cannot queue a StopAndWait behind
 *     another every second a stream stays dead);
 *  5. the re-arm budget for this silence is spent -> GiveUp;
 *  6. otherwise -> Rearm.
 */
MacVNCCaptureLivenessVerdict macVNCResolveCaptureLiveness(
    const MacVNCCaptureLivenessInput *input,
    const MacVNCCaptureLivenessLimits *limits);
