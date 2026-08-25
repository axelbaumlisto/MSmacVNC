#import "MacVNCCaptureSession.h"

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

bool macVNCCaptureSessionAdd(ScreenCapturer *capturer)
{
    if (!capturer)
        return false;
    if (!gCapturers)
        gCapturers = [[NSMutableArray alloc] init];
    [gCapturers addObject:capturer];
    return true;
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

bool macVNCCaptureSessionAllReady(void)
{
  @autoreleasepool {
    for (ScreenCapturer *capturer in gCapturers)
        if (![capturer isCurrentGenerationReady])
            return false;
    return true;
  }
}
