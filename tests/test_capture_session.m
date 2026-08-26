#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCCaptureSession.h"
#import "ScreenCapturer.h"
#import <CoreGraphics/CoreGraphics.h>
#include <string.h>

static bool acceptFrame(const MacVNCDisplayGeometry *geometry,
                        const uint8_t *pixels, size_t stride,
                        int width, int height)
{
    (void)geometry; (void)pixels; (void)stride; (void)width; (void)height;
    return true;
}

static void noteFailure(bool likelyPermissionDenial)
{
    (void)likelyPermissionDenial;
}

/*
 * The capture-stream set for one server run.
 *
 * The behaviour worth pinning is the empty and the restart case: mac.m used to
 * iterate a raw array in five places, and a run that failed before creating any
 * capturer had to be handled correctly at each of them.
 */
int main(void)
{
    @autoreleasepool {
        /* A fresh process owns no streams. */
        macVNCCaptureSessionReset();
        assert(macVNCCaptureSessionCount() == 0);

        /* Every operation must be safe on an empty set: this is the state of a
           run that failed during ScreenInit, and stop is then called on the
           failure path. */
        macVNCCaptureSessionStart();
        macVNCCaptureSessionStopAndWait();

        /* No streams means nothing to wait for - vacuously ready, which is what
           lets a failed run tear down instead of blocking for the timeout. */
        assert(macVNCCaptureSessionWaitForFirstFrames(1000) == true);

        /* A NON-empty session: without this every assertion above also holds
           for a Build that does nothing. Building touches no TCC and starts no
           capture - Start does, and is deliberately not called. */
        MacVNCDisplayLayout layout;
        memset(&layout, 0, sizeof(layout));
        layout.count = 2;
        layout.width = 100;
        layout.height = 50;
        for (size_t i = 0; i < 2; ++i) {
            layout.displays[i].input.displayID = CGMainDisplayID();
            layout.displays[i].input.pixelWidth = 50;
            layout.displays[i].input.pixelHeight = 50;
            layout.displays[i].framebufferX = (int)i * 50;
        }

        assert(macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure));
        /* One stream PER display: a Build that stopped after the first would
           silently capture only one monitor. */
        assert(macVNCCaptureSessionCount() == 2);

        /* Rebuilding REPLACES rather than appends - otherwise every restart
           would accumulate the previous run's streams, and each would keep
           capturing its display. Checked with a DIFFERENT display count so an
           appending implementation cannot coincide with the right number. */
        MacVNCDisplayLayout single;
        memset(&single, 0, sizeof(single));
        single.count = 1;
        single.width = 50;
        single.height = 50;
        single.displays[0].input.displayID = CGMainDisplayID();
        single.displays[0].input.pixelWidth = 50;
        single.displays[0].input.pixelHeight = 50;
        assert(macVNCCaptureSessionBuild(&single, 30, acceptFrame, noteFailure));
        assert(macVNCCaptureSessionCount() == 1);
        assert(macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure));
        assert(macVNCCaptureSessionCount() == 2);

        /* Refused inputs must leave NO session installed. */
        assert(macVNCCaptureSessionBuild(&layout, 30, NULL, noteFailure) == false);
        assert(macVNCCaptureSessionCount() == 0);
        assert(macVNCCaptureSessionBuild(NULL, 30, acceptFrame, noteFailure) == false);
        MacVNCDisplayLayout empty;
        memset(&empty, 0, sizeof(empty));
        assert(macVNCCaptureSessionBuild(&empty, 30, acceptFrame, noteFailure) == false);
        assert(macVNCCaptureSessionCount() == 0);

        assert(macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure));

        /* Reset releases the previous set - the one MRC operation in the module.
           Running it twice also proves it is idempotent between runs. */
        macVNCCaptureSessionReset();
        assert(macVNCCaptureSessionCount() == 0);
        macVNCCaptureSessionReset();
        assert(macVNCCaptureSessionCount() == 0);

        printf("test_capture_session: all assertions passed\n");
    }
    return 0;
}
