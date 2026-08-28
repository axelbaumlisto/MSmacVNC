#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import "MacVNCCaptureSession.h"
#import "DisplayLayout.h"
#import "FirstFrameBudget.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static _Atomic unsigned framesSeen = 0;
static bool acceptFrame(const MacVNCDisplayGeometry *geometry,
                        const uint8_t *pixels, size_t stride,
                        int width, int height,
                        const MacVNCDirtyHint *hint)
{
    (void)geometry; (void)pixels; (void)stride; (void)width; (void)height;
    (void)hint;
    atomic_fetch_add(&framesSeen, 1);
    return true;
}
static _Atomic bool permissionDenied = false;
static void noteFailure(bool likelyPermissionDenial)
{
    /* ScreenCaptureKit -3801 = the OS refused capture for THIS binary: the test
       runs under ctest/terminal, which has no Screen Recording grant. Not a
       code failure - the same flow passes inside the installed app. */
    if (likelyPermissionDenial)
        atomic_store(&permissionDenied, true);
}

/* Round-12 keep-warm regression probe: after StopAndWait, a re-Start must deliver
   frames again. The keep-warm path runs exactly StopAndWait -> Start without a
   Reset, and in production the second start produced NO frames (the client sat
   on the placeholder forever). This test goes red if that regresses. */
int main(void)
{
    @autoreleasepool {
        macVNCCaptureSessionReset();

        CGDirectDisplayID ids[8]; CGDisplayCount n = 0;
        assert(CGGetActiveDisplayList(8, ids, &n) == kCGErrorSuccess);
        assert(n > 0);

        MacVNCDisplayInput in = { .displayID = ids[0] };
        in.logicalWidth = (double)CGDisplayPixelsWide(ids[0]);
        in.logicalHeight = (double)CGDisplayPixelsHigh(ids[0]);
        in.pixelWidth = (int)CGDisplayPixelsWide(ids[0]);
        in.pixelHeight = (int)CGDisplayPixelsHigh(ids[0]);
        MacVNCDisplayLayout layout;
        assert(macVNCBuildDisplayLayout(&in, 1, &layout));
        assert(macVNCCaptureSessionBuild(&layout, 5, acceptFrame, noteFailure));

        /* Round 1: start, expect frames. */
        macVNCCaptureSessionStart();
        BOOL got1 = macVNCCaptureSessionWaitForFirstFrames(5ULL * NSEC_PER_SEC);
        if (!got1 && atomic_load(&permissionDenied)) {
            puts("test_capture_restart: SKIP (no Screen Recording grant for "
                 "the test binary; the flow is verified in the installed app)");
            macVNCCaptureSessionStopAndWait();
            macVNCCaptureSessionReset();
            return 77;
        }
        assert(got1);
        atomic_store(&framesSeen, 0);
        usleep(500000);
        unsigned round1 = atomic_load(&framesSeen);
        printf("round1 frames: %u\n", round1);
        assert(round1 > 0);

        /* StopAndWait WITHOUT Reset - exactly the keep-warm sequence. */
        macVNCCaptureSessionStopAndWait();

        /* Round 2: re-Start on the same session. */
        macVNCCaptureSessionStart();
        BOOL got = macVNCCaptureSessionWaitForFirstFrames(5ULL * NSEC_PER_SEC);
        atomic_store(&framesSeen, 0);
        usleep(500000);
        unsigned round2 = atomic_load(&framesSeen);
        printf("round2 frames: %u firstFrames=%d\n", round2, (int)got);
    FILE *rf = fopen("/tmp/cap_restart_result.txt", "w");
    if (rf) { fprintf(rf, "round1=%u round2=%u firstFrames=%d\n", round1, round2, (int)got); fclose(rf); }
        assert(got);
        assert(round2 > 0);   /* RED in the broken build */

        macVNCCaptureSessionStopAndWait();
        macVNCCaptureSessionReset();
        puts("test_capture_restart: all assertions passed");
    }
    return 0;
}
