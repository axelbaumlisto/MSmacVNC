#import "MacVNCCaptureSession.h"

#include <ScreenCaptureKit/ScreenCaptureKit.h>

#import "MacVNCSweepSchedule.h"
#import "ScreenCapturer.h"
#import "FirstFrameBudget.h"

/* Capturers for the current run; nil between runs. */
static NSMutableArray<ScreenCapturer *> *gCapturers;

/*
 * Upper bound on dirty rectangles taken from one frame. Past this many, the
 * per-rect bookkeeping costs more than the full sweep it is meant to avoid,
 * so we stop reading and let the compositor scan everything. Measured frames
 * on a two-display desktop average ~13 rects.
 */
#define MACVNC_MAX_HINT_RECTS 32

/* How often a display is composited in full regardless of the hint. */
#define MACVNC_FULL_SWEEP_INTERVAL_NS (5ULL * NSEC_PER_SEC)

/*
 * Read ScreenCaptureKit's own list of repainted rectangles off the frame.
 *
 * Returns 0 - meaning "no usable hint, sweep everything" - when the metadata
 * is absent, malformed, or longer than we are willing to process. The caller
 * must treat 0 as a full sweep, never as "nothing changed": a frame whose
 * rects we failed to read still carries pixels.
 */
static size_t
extractDirtyRects(CMSampleBufferRef sampleBuffer,
                  MacVNCDirtyRect *out,
                  size_t capacity)
{
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0)
        return 0;

    CFDictionaryRef info = CFArrayGetValueAtIndex(attachments, 0);
    if (!info)
        return 0;

    CFArrayRef rects =
        CFDictionaryGetValue(info, (CFStringRef)SCStreamFrameInfoDirtyRects);
    if (!rects)
        return 0;

    CFIndex count = CFArrayGetCount(rects);
    if (count <= 0 || (size_t)count > capacity)
        return 0;

    for (CFIndex i = 0; i < count; ++i) {
        CGRect rect = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                CFArrayGetValueAtIndex(rects, i), &rect))
            return 0; /* malformed entry: distrust the whole list */
        rect = CGRectIntegral(rect); /* whole pixels; the grid is integral */
        out[i].x = (int)CGRectGetMinX(rect);
        out[i].y = (int)CGRectGetMinY(rect);
        out[i].width = (int)CGRectGetWidth(rect);
        out[i].height = (int)CGRectGetHeight(rect);
    }
    return (size_t)count;
}

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
        /* Per-display, per-block state. Each loop iteration creates a fresh
           block, so displays cannot share (or race on) the deadline; frames
           of one display are delivered serially, so it needs no lock. */
        __block MacVNCSweepSchedule sweepSchedule;
        macVNCSweepScheduleInit(&sweepSchedule, MACVNC_FULL_SWEEP_INTERVAL_NS);
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

                MacVNCDirtyRect rectStorage[MACVNC_MAX_HINT_RECTS];
                MacVNCDirtyHint hint = { rectStorage, 0 };
                hint.count = extractDirtyRects(sampleBuffer, rectStorage,
                                               MACVNC_MAX_HINT_RECTS);

                /* An empty hint means "sweep everything" - see
                   MacVNCSweepSchedule for why that must happen periodically. */
                if (macVNCSweepScheduleDueAt(&sweepSchedule,
                                             clock_gettime_nsec_np(CLOCK_MONOTONIC)))
                    hint.count = 0;

                CVPixelBufferLockBaseAddress(pixelBuffer,
                                             kCVPixelBufferLock_ReadOnly);
                bool accepted = frameHandler(
                    geometry,
                    CVPixelBufferGetBaseAddress(pixelBuffer),
                    CVPixelBufferGetBytesPerRow(pixelBuffer),
                    (int)CVPixelBufferGetWidth(pixelBuffer),
                    (int)CVPixelBufferGetHeight(pixelBuffer),
                    &hint);
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
    MacVNCFirstFrameBudget budget =
        macVNCFirstFrameBudgetStart(macVNCMonotonicNow(), timeoutNanoseconds);

    for (ScreenCapturer *capturer in gCapturers) {
        uint64_t remaining =
            macVNCFirstFrameBudgetRemaining(&budget, macVNCMonotonicNow());
        if (remaining == 0)
            return false;
        if (![capturer waitForFirstFrameWithTimeout:
                 (NSTimeInterval)remaining / NSEC_PER_SEC])
            return false;
    }
    return true;
  }
}

