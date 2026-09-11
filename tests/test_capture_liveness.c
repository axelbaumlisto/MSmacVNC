/*
 * Whether a technically-running capture stream is actually alive.
 *
 * Silence is not the same failure as an error: on 2026-09-10 SCStream went
 * quiet after the desk changed shape, delivered no frame and reported none,
 * and macVNC served viewers a 42-hour-old canvas until somebody restarted it
 * by hand. These assertions are the six-rule decision that replaces "wait for
 * an error that never comes" with "notice the frames stopped".
 */

#include <assert.h>
#include <stdio.h>

#include "CaptureLiveness.h"

#define NS_PER_SEC 1000000000ULL
/* An arbitrary nonzero epoch, like the real monotonic clock's uptime base -
   using 0 as "now" would let a lastRearmNs/capturesStartedNs sentinel value
   of 0 collide with a real timestamp in these tests. */
#define BASE_NS (1000ULL * NS_PER_SEC)

static MacVNCCaptureLivenessLimits
shippedLimits(void)
{
    MacVNCCaptureLivenessLimits limits = {
        .graceNs    = MACVNC_CAPTURE_LIVENESS_GRACE_NANOSECONDS,
        .silenceNs  = MACVNC_CAPTURE_LIVENESS_SILENCE_NANOSECONDS,
        .cooldownNs = MACVNC_CAPTURE_LIVENESS_COOLDOWN_NANOSECONDS,
        .maxRearms  = MACVNC_CAPTURE_LIVENESS_MAX_REARMS,
    };
    return limits;
}

static void
testShippedConstantsMatchThePlan(void)
{
    /* Pinned so a change of default cannot be silent: grace 6s (first-frame
       budget is 5s), silence 4s (120 missed frames at 30fps), cooldown 10s,
       three re-arms before GiveUp. */
    assert(MACVNC_CAPTURE_LIVENESS_GRACE_NANOSECONDS == 6ULL * NS_PER_SEC);
    assert(MACVNC_CAPTURE_LIVENESS_SILENCE_NANOSECONDS == 4ULL * NS_PER_SEC);
    assert(MACVNC_CAPTURE_LIVENESS_COOLDOWN_NANOSECONDS == 10ULL * NS_PER_SEC);
    assert(MACVNC_CAPTURE_LIVENESS_MAX_REARMS == 3u);
}

static void
testIdleServerIsAlwaysAlive(void)
{
    /* No client: nothing below is a reason to act however stale the state -
       this is what keeps a display that idled itself to sleep with nobody
       watching out of the loop, unlike the discarded design's 3am wake
       cycle. */
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = true,
        .clientsConnected  = false,
        .nowNs             = BASE_NS + 1000ULL * NS_PER_SEC,
        .lastFrameNs       = BASE_NS,   /* stale */
        .capturesStartedNs = BASE_NS,
        .lastRearmNs       = 0,
        .rearmsSinceFrame  = 99,        /* would GiveUp if a client were here */
    };
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureAlive);
}

static void
testCapturesNotRunningIsAlive(void)
{
    /* Nothing to watch: captures are stopped (keep-warm window elapsed, or no
       client ever connected), so silence here is expected, not a symptom. */
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = false,
        .clientsConnected  = true,
        .nowNs             = BASE_NS + 1000ULL * NS_PER_SEC,
        .lastFrameNs       = 0,
        .capturesStartedNs = 0,
        .lastRearmNs       = 0,
        .rearmsSinceFrame  = 0,
    };
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureAlive);
}

static void
testGraceWindowBeforeFirstFrame(void)
{
    /* Cold start: measured 1.3-2.1s for two displays, more with a sleeping
       panel. No frame yet at 5s must not be mistaken for a dead stream. */
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = true,
        .clientsConnected  = true,
        .nowNs             = BASE_NS + 5ULL * NS_PER_SEC,
        .lastFrameNs       = 0,
        .capturesStartedNs = BASE_NS,
        .lastRearmNs       = 0,
        .rearmsSinceFrame  = 0,
    };
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureAlive);

    /* Past grace with still no frame: silence is now measured from the
       start, and once it too elapses this must stop reading as "warming up"
       and start reading as "dead". */
    input.nowNs = BASE_NS + 11ULL * NS_PER_SEC; /* 6s grace + 4s silence + 1s */
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureRearm);
}

static void
testSilenceThresholdBoundary(void)
{
    /* Just under the silence window is alive; at or over it is not - the
       task's own wording for this boundary. */
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = true,
        .clientsConnected  = true,
        .lastFrameNs       = BASE_NS + 20ULL * NS_PER_SEC,
        .capturesStartedNs = BASE_NS,
        .lastRearmNs       = 0,
        .rearmsSinceFrame  = 0,
    };

    input.nowNs = input.lastFrameNs + limits.silenceNs - 1;
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureAlive);

    input.nowNs = input.lastFrameNs + limits.silenceNs;
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureRearm);
}

static void
testCooldownBlocksSecondRearm(void)
{
    /* One re-arm in flight per window: without this the 1Hz watchdog would
       queue a StopAndWait behind another StopAndWait every second a stream
       stays dead, each one waiting out ScreenCaptureKit's own teardown. */
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    uint64_t lastFrame = BASE_NS + 20ULL * NS_PER_SEC;
    uint64_t rearmedAt = lastFrame + limits.silenceNs;
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = true,
        .clientsConnected  = true,
        .lastFrameNs       = lastFrame,
        .capturesStartedNs = BASE_NS,
        .lastRearmNs       = rearmedAt,
        .rearmsSinceFrame  = 1,
        .nowNs             = rearmedAt + limits.cooldownNs - 1,
    };
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureAlive);

    input.nowNs = rearmedAt + limits.cooldownNs;
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureRearm);
}

static void
testMaxRearmsExhaustedGivesUp(void)
{
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    uint64_t lastFrame = BASE_NS + 20ULL * NS_PER_SEC;
    uint64_t rearmedAt = lastFrame + limits.silenceNs;
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = true,
        .clientsConnected  = true,
        .lastFrameNs       = lastFrame,
        .capturesStartedNs = BASE_NS,
        .lastRearmNs       = rearmedAt,
        .rearmsSinceFrame  = limits.maxRearms,
        .nowNs             = rearmedAt + limits.cooldownNs,
    };
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureGiveUp);
}

static void
testFreshFrameResetsRearmCounter(void)
{
    /* mac.m resets rearmsSinceFrame at the same site that stamps the frame
       arrival (compositeCapturedFrame). This asserts the resolver's half of
       that contract: given a reset counter and a fresh lastFrameNs, a later
       silence is read as a first offence, not a continuation of a run that
       would otherwise already have hit GiveUp. */
    MacVNCCaptureLivenessLimits limits = shippedLimits();
    uint64_t recoveredFrame = BASE_NS + 500ULL * NS_PER_SEC;
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = true,
        .clientsConnected  = true,
        .lastFrameNs       = recoveredFrame,
        .capturesStartedNs = BASE_NS,
        .lastRearmNs       = recoveredFrame - 20ULL * NS_PER_SEC, /* the re-arm that produced it, well outside the cooldown window by now */
        .rearmsSinceFrame  = 0,   /* reset by the frame that just arrived */
        .nowNs             = recoveredFrame + limits.silenceNs,
    };
    assert(macVNCResolveCaptureLiveness(&input, &limits) == MacVNCCaptureRearm);
}

int
main(void)
{
    testShippedConstantsMatchThePlan();
    testIdleServerIsAlwaysAlive();
    testCapturesNotRunningIsAlive();
    testGraceWindowBeforeFirstFrame();
    testSilenceThresholdBoundary();
    testCooldownBlocksSecondRearm();
    testMaxRearmsExhaustedGivesUp();
    testFreshFrameResetsRearmCounter();

    puts("test_capture_liveness: all assertions passed");
    return 0;
}
