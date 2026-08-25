#import "MacVNCCaptureSession.h"

#import "ScreenCapturer.h"
#import "ReadinessPolicy.h"

/* Capturers for the current run; nil between runs. */
static NSMutableArray<ScreenCapturer *> *gCapturers;

void macVNCCaptureSessionReset(void)
{
    [gCapturers release];
    gCapturers = nil;
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
    for (ScreenCapturer *capturer in gCapturers)
        [capturer startCapture];
}

void macVNCCaptureSessionStopAndWait(void)
{
    for (ScreenCapturer *capturer in gCapturers)
        [capturer stopCaptureAndWait];
}

bool macVNCCaptureSessionWaitForFirstFrames(uint64_t timeoutNanoseconds)
{
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

bool macVNCCaptureSessionAllReady(void)
{
    for (ScreenCapturer *capturer in gCapturers)
        if (![capturer isCurrentGenerationReady])
            return false;
    return true;
}
