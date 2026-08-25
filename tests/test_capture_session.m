#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCCaptureSession.h"
#import "ScreenCapturer.h"
#import <CoreGraphics/CoreGraphics.h>

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
        assert(macVNCCaptureSessionAllReady() == true);

        /* nil is rejected rather than stored: a nil in the set would silently
           reduce the number of displays actually captured. */
        assert(macVNCCaptureSessionAdd(nil) == false);
        assert(macVNCCaptureSessionCount() == 0);

        /* A NON-empty set: without this every assertion above also holds for an
           implementation whose Add does nothing. Constructing a ScreenCapturer
           touches no ScreenCaptureKit and no TCC - capture only starts on
           -startCapture, which is deliberately not called here. */
        ScreenCapturer *capturer =
            [[ScreenCapturer alloc] initWithDisplay:CGMainDisplayID()
                             captureFramesPerSecond:30
                                       frameHandler:^BOOL(CMSampleBufferRef b) {
                                           (void)b; return YES;
                                       }
                                       errorHandler:^(NSError *e) { (void)e; }];
        assert(capturer != nil);
        assert(macVNCCaptureSessionAdd(capturer) == true);
        assert(macVNCCaptureSessionCount() == 1);

        /* The session retains, so our release is not the last one. Over-release
           here would crash; failing to retain would leave a dangling capturer. */
        assert(capturer.retainCount >= 2);
        [capturer release];
        assert(macVNCCaptureSessionCount() == 1);

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
