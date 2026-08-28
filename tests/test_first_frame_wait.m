/*
 * The first-frame wait must end when the answer is known - not when the budget
 * runs out.
 *
 * A client that has just authenticated is held back until every display has
 * produced a frame, because that wait is what keeps viewers from painting
 * their own "no data" placeholder. The budget for it is 8 seconds. If capture
 * FAILS, those 8 seconds are pure dead air: no frame is coming, and the answer
 * was available in milliseconds.
 *
 * This test pins the early wake-up. It works in either environment:
 *   - under ctest the binary has no Screen Recording grant, so the stream
 *     errors out almost immediately and the wait must return false fast;
 *   - inside the app frames arrive and the wait must return true fast.
 * Either way it must NOT consume the budget, so the assertion is on elapsed
 * time, not on the outcome.
 */

#import <Foundation/Foundation.h>

#include <assert.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdio.h>

#import "MacVNCCaptureSession.h"
#import "TestDisplayLayout.h"

static bool
acceptFrame(const MacVNCDisplayGeometry *geometry, const uint8_t *pixels,
            size_t stride, int width, int height, const MacVNCDirtyHint *hint)
{
    (void)geometry; (void)pixels; (void)stride;
    (void)width; (void)height; (void)hint;
    return true;
}

static void
noteFailure(bool likelyPermissionDenial)
{
    (void)likelyPermissionDenial;
}

static double
secondsSince(uint64_t start)
{
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0)
        mach_timebase_info(&timebase);
    uint64_t elapsed = mach_absolute_time() - start;
    return (double)elapsed * timebase.numer / timebase.denom / 1e9;
}

int
main(void)
{
    @autoreleasepool {
        macVNCCaptureSessionReset();

        MacVNCDisplayLayout layout;
        if (!testBuildSingleDisplayLayout(&layout)) {
            puts("test_first_frame_wait: SKIP (no usable display)");
            return 77;
        }

        if (!macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure)) {
            puts("test_first_frame_wait: SKIP (capture session unavailable)");
            return 77;
        }

        const uint64_t budgetSeconds = 8;
        macVNCCaptureSessionStart();

        uint64_t start = mach_absolute_time();
        bool ready =
            macVNCCaptureSessionWaitForFirstFrames(budgetSeconds * NSEC_PER_SEC);
        double elapsed = secondsSince(start);

        printf("first-frame wait: %s after %.2f s (budget %llu s)\n",
               ready ? "READY" : "NOT READY", elapsed,
               (unsigned long long)budgetSeconds);

        macVNCCaptureSessionStopAndWait();
        macVNCCaptureSessionReset();

        /* Half the budget is a deliberately loose bound: the point is that the
           wait is driven by events, not by the clock running out. */
        assert(elapsed < (double)budgetSeconds / 2.0);
        puts("test_first_frame_wait: all assertions passed");
    }
    return 0;
}
