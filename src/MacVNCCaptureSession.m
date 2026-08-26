#import "MacVNCCaptureSession.h"

#include <ScreenCaptureKit/ScreenCaptureKit.h>

#import "ScreenCapturer.h"
#import "ReadinessPolicy.h"

/* Capturers for the current run; nil between runs. */
static NSMutableArray<ScreenCapturer *> *gCapturers;

void macVNCCaptureSessionReset(void)
{
  @autoreleasepool {
    /* A capturer whose work never quiesced is dropped from the set but NOT
       released: freeing its queues would be a use-after-free from the callback
       still running inside it. Leaking one on an already-degraded shutdown is
       cheaper than a crash. See -[ScreenCapturer isSafeToDeallocate]. */
    for (ScreenCapturer *capturer in gCapturers) {
        if (![capturer isSafeToDeallocate]) {
            [capturer retain];  /* ownership moves to the deliberate leak */
            NSLog(@"macVNC: leaking a capturer with stuck capture work");
        }
    }
    [gCapturers release];
    gCapturers = nil;
  }
}

bool macVNCCaptureSessionBuild(const MacVNCDisplayLayout *layout,
                               int captureFramesPerSecond,
                               MacVNCCaptureFrameHandler frameHandler,
                               MacVNCCaptureFailureHandler failureHandler)
{
  @autoreleasepool {
    /* Drop any previous session FIRST, whatever happens next. A failed rebuild
       must not leave the old run's streams installed: the caller then believes
       it has no session while stale streams still hold their displays. */
    macVNCCaptureSessionReset();

    if (!layout || layout->count == 0 || !frameHandler)
        return false;

    /* Classifying the error belongs here, with the framework that defines the
       codes; the server core must not need SCStreamError to decide whether a
       permission is missing. */
    void (^errorHandler)(NSError *) = ^(NSError *error) {
        NSLog(@"macVNC: screen capture error: %@", error.description);
        bool likelyPermissionDenial =
            [error.domain isEqualToString:SCStreamErrorDomain] &&
            (error.code == SCStreamErrorUserDeclined ||
             error.code == SCStreamErrorMissingEntitlements);
        if (failureHandler)
            failureHandler(likelyPermissionDenial);
    };

    NSMutableArray<ScreenCapturer *> *built =
        [[[NSMutableArray alloc] initWithCapacity:layout->count] autorelease];

    for (size_t i = 0; i < layout->count; ++i) {
        /* Points into the caller's layout, which outlives the session: mac.m
           keeps it in the run's private state. */
        const MacVNCDisplayGeometry *geometry = &layout->displays[i];
        ScreenCapturer *capturer = [[ScreenCapturer alloc]
            initWithDisplay:geometry->input.displayID
            captureFramesPerSecond:captureFramesPerSecond
            frameHandler:^BOOL(CMSampleBufferRef sampleBuffer) {
                /* Unwrap ScreenCaptureKit here so the consumer sees only
                   pixels: it has no business locking a CVPixelBuffer. */
                CVPixelBufferRef pixelBuffer =
                    CMSampleBufferGetImageBuffer(sampleBuffer);
                if (!pixelBuffer)
                    return YES; /* nothing to composite; not retryable */

                CVPixelBufferLockBaseAddress(pixelBuffer,
                                             kCVPixelBufferLock_ReadOnly);
                bool accepted = frameHandler(
                    geometry,
                    CVPixelBufferGetBaseAddress(pixelBuffer),
                    CVPixelBufferGetBytesPerRow(pixelBuffer),
                    (int)CVPixelBufferGetWidth(pixelBuffer),
                    (int)CVPixelBufferGetHeight(pixelBuffer));
                CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                               kCVPixelBufferLock_ReadOnly);
                return accepted ? YES : NO;
            }
            errorHandler:errorHandler];
        if (!capturer) {
            NSLog(@"macVNC: could not initialize capture for display %u",
                  geometry->input.displayID);
            return false;   /* `built` autoreleases; no session installed */
        }
        [built addObject:capturer];
        [capturer release];
    }

    gCapturers = [built retain];
    return true;
  }
}

size_t macVNCCaptureSessionCount(void)
{
    return gCapturers.count;
}

void macVNCCaptureSessionStart(void)
{
    /* Client threads come from LibVNCServer pthreads, which have no autorelease
       pool; anything autoreleased below (NSLog formatting, error.description)
       would leak permanently with "autoreleased with no pool in place". */
    @autoreleasepool {
    for (ScreenCapturer *capturer in gCapturers)
        [capturer startCapture];
    }
}

void macVNCCaptureSessionStopAndWait(void)
{
    /* Client threads come from LibVNCServer pthreads, which have no autorelease
       pool; anything autoreleased below (NSLog formatting, error.description)
       would leak permanently with "autoreleased with no pool in place". */
    @autoreleasepool {
    for (ScreenCapturer *capturer in gCapturers)
        [capturer stopCaptureAndWait];
    }
}

bool macVNCCaptureSessionWaitForFirstFrames(uint64_t timeoutNanoseconds)
{
  @autoreleasepool {
    /* One budget for the whole set: a per-display timeout would make a
       two-monitor Mac keep the client waiting twice as long. */
    MacVNCReadinessBudget budget =
        macVNCReadinessBudgetStart(macVNCReadinessNow(), timeoutNanoseconds);

    for (ScreenCapturer *capturer in gCapturers) {
        uint64_t remaining =
            macVNCReadinessBudgetRemaining(&budget, macVNCReadinessNow());
        if (remaining == 0)
            return false;
        if (![capturer waitForFirstFrameWithTimeout:
                 (NSTimeInterval)remaining / NSEC_PER_SEC])
            return false;
    }
    return true;
  }
}

