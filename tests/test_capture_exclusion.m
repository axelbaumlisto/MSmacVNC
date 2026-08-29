#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#import "MacVNCCaptureSession.h"

/*
 * The curtain's capture seam, from the SESSION's side.
 *
 * Two things are pinned here that the curtain's own test cannot reach, because
 * it drives a fake exclusion:
 *
 * 1. Every request is answered exactly once, on the MAIN thread, and answered
 *    with FAILURE when there is no stream that confirmed the swap. The curtain
 *    orders windows in that callback, which is main-thread-only work, and it
 *    treats "no answer" as a timeout - so a lost or duplicated answer is a
 *    curtain that hangs or one that raises twice.
 *
 * 2. Requests from the MAIN thread survive a session being built and reset
 *    underneath them from another thread. That pair is not exotic: it is
 *    "stop the server" against "lift the curtain", and the main thread is the
 *    one thread rfbShutdownServer never joins, so the argument that lets the
 *    other readers of the stream list run lock-free does not cover it. The
 *    unlocked version of this code copied a list another thread was releasing.
 *
 * The second part is a STRESS, not a proof: a data race has no deterministic
 * failure. It is written to be meaningful under a race detector
 * (-fsanitize=thread) and to crash reliably-ish on a retain of freed memory,
 * while its assertions - every request answered, none answered on the wrong
 * thread, none reporting success - hold deterministically either way.
 */

static bool acceptFrame(const MacVNCDisplayGeometry *geometry,
                        const uint8_t *pixels, size_t stride,
                        int width, int height,
                        const MacVNCDirtyHint *hint)
{
    (void)geometry; (void)pixels; (void)stride;
    (void)width; (void)height; (void)hint;
    return true;
}

static void noteFailure(bool likelyPermissionDenial)
{
    (void)likelyPermissionDenial;
}

static _Atomic int gAnswers;
static _Atomic int gAnswersOffMainThread;
static _Atomic int gAnswersReportingSuccess;

static void noteAnswer(void *context, bool success)
{
    (void)context;
    if (![NSThread isMainThread])
        atomic_fetch_add(&gAnswersOffMainThread, 1);
    if (success)
        atomic_fetch_add(&gAnswersReportingSuccess, 1);
    atomic_fetch_add(&gAnswers, 1);
}

/* Answers are delivered to the main QUEUE, so a test that never runs the main
   run loop would see none of them. */
static BOOL pumpMainQueueUntilAnswers(int target, NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (atomic_load(&gAnswers) < target && deadline.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop]
                runMode:NSDefaultRunLoopMode
             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    return atomic_load(&gAnswers) >= target;
}

static void fillLayout(MacVNCDisplayLayout *layout, size_t displays)
{
    memset(layout, 0, sizeof(*layout));
    layout->count = displays;
    layout->width = (int)displays * 50;
    layout->height = 50;
    for (size_t i = 0; i < displays; ++i) {
        layout->displays[i].input.displayID = CGMainDisplayID();
        layout->displays[i].input.pixelWidth = 50;
        layout->displays[i].input.pixelHeight = 50;
        layout->displays[i].framebufferX = (int)i * 50;
    }
}

static void testEmptySessionAnswersFailureOnTheMainThread(void)
{
    macVNCCaptureSessionReset();
    assert(macVNCCaptureSessionCount() == 0);

    macVNCCaptureSessionSetSelfExcluded(true, noteAnswer, NULL);
    assert(pumpMainQueueUntilAnswers(1, 5.0));
    /* "Nothing to exclude" is a failure: with no live stream a raised curtain
       shows the local user black and the remote party nothing. */
    assert(atomic_load(&gAnswersReportingSuccess) == 0);
    assert(atomic_load(&gAnswersOffMainThread) == 0);

    /* Exactly once: a second delivery would raise a curtain the caller has
       already been told about. Pumping longer must not produce one. */
    (void)pumpMainQueueUntilAnswers(2, 0.3);
    assert(atomic_load(&gAnswers) == 1);
}

static void testBuiltSessionAnswersEveryRequest(void)
{
    MacVNCDisplayLayout layout;
    fillLayout(&layout, 2);
    assert(macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure));
    assert(macVNCCaptureSessionCount() == 2);

    int before = atomic_load(&gAnswers);
    static const int kRequests = 25;
    for (int i = 0; i < kRequests; ++i)
        macVNCCaptureSessionSetSelfExcluded(i % 2 == 0, noteAnswer, NULL);

    assert(pumpMainQueueUntilAnswers(before + kRequests, 10.0));
    assert(atomic_load(&gAnswers) == before + kRequests);
    /* Capture was never started, so no stream can confirm a swap; every answer
       must say so rather than defaulting to success. */
    assert(atomic_load(&gAnswersReportingSuccess) == 0);
    assert(atomic_load(&gAnswersOffMainThread) == 0);

    macVNCCaptureSessionReset();
}

static void testRequestsSurviveConcurrentRebuild(void)
{
    static const int kCycles = 200;
    int before = atomic_load(&gAnswers);

    dispatch_queue_t lifecycle =
        dispatch_queue_create("test.capture-exclusion.lifecycle", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);

    /* The lifecycle role: build and reset the session over and over, exactly as
       a server start/stop pair does from AppDelegate's serial queue. */
    dispatch_async(lifecycle, ^{
        for (int i = 0; i < kCycles; ++i) {
            @autoreleasepool {
                MacVNCDisplayLayout layout;
                fillLayout(&layout, (i % 2) + 1);
                macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure);
                macVNCCaptureSessionReset();
            }
        }
        dispatch_semaphore_signal(finished);
    });

    /* The curtain role: request an exclusion from the main thread while that
       happens, and keep draining the main queue so answers land. */
    for (int i = 0; i < kCycles; ++i) {
        macVNCCaptureSessionSetSelfExcluded(i % 2 == 0, noteAnswer, NULL);
        (void)pumpMainQueueUntilAnswers(before + i + 1, 0.002);
    }

    while (dispatch_semaphore_wait(finished, DISPATCH_TIME_NOW) != 0)
        (void)pumpMainQueueUntilAnswers(before + kCycles, 0.05);
    dispatch_release(finished);
    dispatch_release(lifecycle);

    /* Not one request may be lost: the curtain would sit in its Raising state
       until the timeout for each one that is. */
    assert(pumpMainQueueUntilAnswers(before + kCycles, 15.0));
    assert(atomic_load(&gAnswers) == before + kCycles);
    assert(atomic_load(&gAnswersOffMainThread) == 0);
    assert(atomic_load(&gAnswersReportingSuccess) == 0);

    macVNCCaptureSessionReset();
    assert(macVNCCaptureSessionCount() == 0);
}

/*
 * The exclusion belongs to ONE session, and a session that was rebuilt is not
 * excluding anything - however many times it was asked before.
 *
 * This is the state the curtain's ordering rules otherwise forbid: windows up
 * while the stream carries them again. Nothing reports it, so it has to be
 * ASKED, which is what macVNCCaptureSessionSelfExcluded() is for.
 */
static void testExclusionDoesNotSurviveARebuild(void)
{
    macVNCCaptureSessionReset();
    assert(!macVNCCaptureSessionSelfExcluded());

    MacVNCDisplayLayout layout;
    fillLayout(&layout, 1);
    assert(macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure));
    /* Build always constructs the DEFAULT filter. */
    assert(!macVNCCaptureSessionSelfExcluded());

    int before = atomic_load(&gAnswers);
    macVNCCaptureSessionSetSelfExcluded(true, noteAnswer, NULL);
    assert(pumpMainQueueUntilAnswers(before + 1, 5.0));
    /* Capture was never started, so no stream confirmed the swap - and a swap
       that was not confirmed must not be reported as an exclusion in place,
       or a curtain would stay up on the strength of it. */
    assert(!macVNCCaptureSessionSelfExcluded());

    macVNCCaptureSessionReset();
    assert(!macVNCCaptureSessionSelfExcluded());
}

/*
 * The OTHER unjoined caller, and the reason every reader now snapshots under
 * the lock: mac.m's capture keep-warm timer runs on gCaptureStopQueue, which
 * nothing joins, and calls StopAndWait() and Count() after dropping
 * captureControlMutex - so it can overlap the Reset inside vncServerStopLocked,
 * which nils and releases the very list those two were enumerating.
 *
 * Like the rebuild stress above this is a STRESS, not a proof: it is written
 * to be meaningful under -fsanitize=thread, while its assertions hold
 * deterministically either way.
 */
static void testStopQueueReadersSurviveAConcurrentStop(void)
{
    static const int kCycles = 300;
    dispatch_queue_t lifecycle =
        dispatch_queue_create("test.capture-exclusion.lifecycle2", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t stopQueue =
        dispatch_queue_create("test.capture-exclusion.stop", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t lifecycleDone = dispatch_semaphore_create(0);
    dispatch_semaphore_t stopDone = dispatch_semaphore_create(0);

    dispatch_async(lifecycle, ^{
        for (int i = 0; i < kCycles; ++i) {
            @autoreleasepool {
                MacVNCDisplayLayout layout;
                fillLayout(&layout, (i % 2) + 1);
                macVNCCaptureSessionBuild(&layout, 30, acceptFrame, noteFailure);
                macVNCCaptureSessionReset();
            }
        }
        dispatch_semaphore_signal(lifecycleDone);
    });

    dispatch_async(stopQueue, ^{
        for (int i = 0; i < kCycles; ++i) {
            macVNCCaptureSessionStopAndWait();
            /* The count is only ever 0, 1 or 2 here; what matters is that
               reading it never touches a list another thread just freed. */
            assert(macVNCCaptureSessionCount() <= 2);
        }
        dispatch_semaphore_signal(stopDone);
    });

    dispatch_semaphore_wait(lifecycleDone, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(stopDone, DISPATCH_TIME_FOREVER);
    dispatch_release(lifecycleDone);
    dispatch_release(stopDone);
    dispatch_release(stopQueue);
    dispatch_release(lifecycle);

    macVNCCaptureSessionReset();
    assert(macVNCCaptureSessionCount() == 0);
}

int main(void)
{
    @autoreleasepool {
        testEmptySessionAnswersFailureOnTheMainThread();
        testBuiltSessionAnswersEveryRequest();
        testRequestsSurviveConcurrentRebuild();
        testExclusionDoesNotSurviveARebuild();
        testStopQueueReadersSurviveAConcurrentStop();
        printf("capture exclusion: all assertions passed (%d answers)\n",
               atomic_load(&gAnswers));
    }
    return 0;
}
