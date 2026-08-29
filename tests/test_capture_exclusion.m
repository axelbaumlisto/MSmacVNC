#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#import "MacVNCCaptureSession.h"
#import "ScreenCapturer.h"

#include <unistd.h>

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

/*
 * ---------------------------------------------------------------------------
 * The discovery seam: which SCRunningApplication the exclusion names.
 *
 * THE BUG THIS PINS, found by a live run and by no test: the own application
 * was resolved ONCE, at stream start, out of
 * +[SCShareableContent getShareableContentWithCompletionHandler:] - the
 * ON-SCREEN variant. macVNC is a menu-bar app with no on-screen window of its
 * own, so it is not among that call's `applications`, the cache stayed nil, and
 * every exclusion request refused with "application no" - the curtain could
 * never raise on real hardware while 41 test targets passed.
 *
 * A SECOND live run then falsified the first fix: asking with
 * `onScreenWindowsOnly:NO` did NOT list this process either. The remaining
 * explanation - that `applications` lists the owners of shareable WINDOWS, so a
 * process owning none is in no result at all - is a claim about the platform,
 * and the census below is how one run of the app decides it: the same numbers,
 * taken at stream start and again when the exclusion is requested (by which
 * time the curtain has armed a window), told apart by a pure function that is
 * tested here.
 *
 * These tests drive the seam with a canned application and window list, so they
 * reach no ScreenCaptureKit discovery (which can raise a Screen Recording
 * prompt) and need no display.
 */

@interface FakeRunningApplication : NSObject
@property (nonatomic, assign) pid_t processID;
@end

@implementation FakeRunningApplication
@end

/* Duck-typed against the two things the census asks an SCWindow. */
@interface FakeShareableWindow : NSObject
@property (nonatomic, retain) id owningApplication;
@property (nonatomic, assign, getter=isOnScreen) BOOL onScreen;
@end

@implementation FakeShareableWindow
- (void)dealloc
{
    [_owningApplication release];
    [super dealloc];
}
@end

static _Atomic int gDiscoveries;

/* An application list containing `count` strangers, plus this process when
   `includeSelf`. Strangers only is the on-device state the bug lived in. */
static NSArray *applicationList(BOOL includeSelf)
{
    NSMutableArray *applications = [NSMutableArray array];
    for (int i = 1; i <= 3; ++i) {
        FakeRunningApplication *stranger =
            [[[FakeRunningApplication alloc] init] autorelease];
        /* Deliberately never this process: pid 1..3 are launchd and friends. */
        stranger.processID = (pid_t)i;
        [applications addObject:stranger];
    }
    if (includeSelf) {
        FakeRunningApplication *ours =
            [[[FakeRunningApplication alloc] init] autorelease];
        ours.processID = getpid();
        [applications addObject:ours];
    }
    return applications;
}

/* `count` windows owned by this process, `onScreen` of them on screen, plus one
   stranger's window so "ours" is a filter and not a count of everything. */
static NSArray *windowList(NSUInteger ours, NSUInteger onScreen)
{
    NSMutableArray *windows = [NSMutableArray array];
    FakeRunningApplication *stranger =
        [[[FakeRunningApplication alloc] init] autorelease];
    stranger.processID = 1;
    FakeShareableWindow *theirs = [[[FakeShareableWindow alloc] init] autorelease];
    theirs.owningApplication = stranger;
    theirs.onScreen = YES;
    [windows addObject:theirs];

    for (NSUInteger i = 0; i < ours; ++i) {
        FakeRunningApplication *us =
            [[[FakeRunningApplication alloc] init] autorelease];
        us.processID = getpid();
        FakeShareableWindow *window =
            [[[FakeShareableWindow alloc] init] autorelease];
        window.owningApplication = us;
        window.onScreen = i < onScreen;
        [windows addObject:window];
    }
    return windows;
}

static void installDiscovery(BOOL includeSelf)
{
    macVNCSetOwnApplicationDiscovery(
        ^(void (^completion)(NSArray<SCRunningApplication *> *applications,
                             NSArray<SCWindow *> *windows)) {
            atomic_fetch_add(&gDiscoveries, 1);
            /* Answers on another thread, like ScreenCaptureKit does - with its
               own pool, because that thread has none. */
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
              @autoreleasepool {
                completion(applicationList(includeSelf),
                           windowList(includeSelf ? 1 : 0, includeSelf ? 1 : 0));
              }
            });
        });
}

/*
 * The measurement itself, in the three states that decide the design.
 *
 * This is the test that would have made the second live run unnecessary: the
 * numbers it counts are exactly what the app now prints at stream start and at
 * the exclusion request, and the difference between those two lines is the
 * answer to "does owning a window make ScreenCaptureKit list this process".
 */
static void testCensusSeparatesTheCandidateRules(void)
{
    /* A discovery that failed at all: no numbers, no crash, no exclusion. */
    MacVNCShareableContentCensus none =
        macVNCTakeShareableContentCensus(nil, nil, getpid());
    assert(none.applications == 0 && none.windows == 0);
    assert(none.ownWindows == 0 && none.ownWindowsOnScreen == 0);
    assert(!none.ownApplicationPresent);

    /* State 1 - what the live runs printed: strangers only, and this process
       owns nothing ScreenCaptureKit can see. The exclusion MUST refuse, and
       the cure is to give it a window first. */
    MacVNCShareableContentCensus windowless =
        macVNCTakeShareableContentCensus(applicationList(NO), windowList(0, 0),
                                         getpid());
    assert(windowless.applications == 3);
    assert(windowless.windows == 1);
    assert(windowless.ownWindows == 0);
    assert(!windowless.ownApplicationPresent);
    assert(!macVNCCaptureExclusionMayProceed(true, true,
                                             windowless.ownApplicationPresent, true));

    /* State 2 - the one that would REFUTE the whole design: we own windows,
       ScreenCaptureKit sees them, and still does not list us. Nothing about
       the ORDER of window creation could rescue an exclusion by application
       then; the counts are what say so, and they are counted separately from
       the application list for exactly that reason. */
    MacVNCShareableContentCensus windowedButAbsent =
        macVNCTakeShareableContentCensus(applicationList(NO), windowList(3, 2),
                                         getpid());
    assert(windowedButAbsent.windows == 4);
    assert(windowedButAbsent.ownWindows == 3);
    assert(windowedButAbsent.ownWindowsOnScreen == 2);
    assert(!windowedButAbsent.ownApplicationPresent);

    /* State 3 - the armed curtain window did its job. */
    MacVNCShareableContentCensus present =
        macVNCTakeShareableContentCensus(applicationList(YES), windowList(1, 1),
                                         getpid());
    assert(present.applications == 4);
    assert(present.ownWindows == 1);
    assert(present.ownWindowsOnScreen == 1);
    assert(present.ownApplicationPresent);
    assert(macVNCCaptureExclusionMayProceed(true, true,
                                            present.ownApplicationPresent, true));

    /* Logging one is part of the contract - it is the whole diagnostic - and it
       must survive a failed discovery. */
    macVNCLogShareableContentCensus("self test", 0, none);
    macVNCLogShareableContentCensus("self test", 0, windowedButAbsent);
}

static ScreenCapturer *makeCapturer(void)
{
    /* Never started: nothing here talks to ScreenCaptureKit. */
    return [[ScreenCapturer alloc]
        initWithDisplay:CGMainDisplayID()
        captureFramesPerSecond:30
        frameHandler:^BOOL(CMSampleBufferRef sampleBuffer) { (void)sampleBuffer; return YES; }
        errorHandler:^(NSError *error) { (void)error; }];
}

/* Runs the resolution and returns whether this process was found. */
static BOOL resolveOwnApplication(ScreenCapturer *capturer, id *outApplication)
{
    __block id resolved = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [capturer resolveOwnApplicationWithCompletionHandler:^(SCRunningApplication *application) {
        resolved = [application retain];
        dispatch_semaphore_signal(done);
    }];
    assert(dispatch_semaphore_wait(
               done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    dispatch_release(done);
    if (outApplication)
        *outApplication = [resolved autorelease];
    else
        [resolved release];
    return resolved != nil;
}

static void testDiscoveryWithoutThisProcessFailsClosed(void)
{
    installDiscovery(NO);
    ScreenCapturer *capturer = makeCapturer();

    id resolved = nil;
    assert(!resolveOwnApplication(capturer, &resolved));
    assert(resolved == nil);

    /* Unresolved MUST refuse: naming nobody would swap in a filter that hides
       nothing while reporting success - a curtain the remote party cannot see
       through, which is the one outcome worse than no curtain at all. */
    assert(!macVNCCaptureExclusionMayProceed(true, true, false, true));
    /* ...and refusing is specific to EXCLUDING: giving the stream back needs
       no application, or a failed raise could never be undone. */
    assert(macVNCCaptureExclusionMayProceed(true, true, false, false));

    [capturer release];
}

static void testDiscoveryWithThisProcessResolvesAndCaches(void)
{
    installDiscovery(YES);
    ScreenCapturer *capturer = makeCapturer();

    int before = atomic_load(&gDiscoveries);
    id resolved = nil;
    assert(resolveOwnApplication(capturer, &resolved));
    assert(resolved != nil);
    assert([(FakeRunningApplication *)resolved processID] == getpid());
    assert(atomic_load(&gDiscoveries) == before + 1);

    /* With an application in hand the request goes on to the swap. */
    assert(macVNCCaptureExclusionMayProceed(true, true, true, true));

    /* One round trip per stream, not one per raise: the second resolution is
       answered from the cache. */
    assert(resolveOwnApplication(capturer, NULL));
    assert(atomic_load(&gDiscoveries) == before + 1);

    [capturer release];
}

/*
 * The permission rule, which is why the resolution sits BEHIND the stream check
 * and not in front of it: a shareable-content discovery is what can raise a
 * Screen Recording prompt, and only a running stream proves the permission is
 * already granted. A capturer that never started must therefore refuse without
 * discovering anything - the same refusal, and the same silence, as before.
 */
static void testExclusionWithoutAStreamNeitherDiscoversNorSucceeds(void)
{
    installDiscovery(YES);
    ScreenCapturer *capturer = makeCapturer();

    int before = atomic_load(&gDiscoveries);
    __block BOOL answered = NO;
    __block BOOL reportedSuccess = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [capturer setExcludesOwnApplication:YES completionHandler:^(BOOL success) {
        answered = YES;
        reportedSuccess = success;
        dispatch_semaphore_signal(done);
    }];
    assert(dispatch_semaphore_wait(
               done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    dispatch_release(done);
    assert(answered);
    assert(!reportedSuccess);
    assert(atomic_load(&gDiscoveries) == before);

    [capturer release];
    macVNCSetOwnApplicationDiscovery(nil);
}

int main(void)
{
    @autoreleasepool {
        testCensusSeparatesTheCandidateRules();
        testDiscoveryWithoutThisProcessFailsClosed();
        testDiscoveryWithThisProcessResolvesAndCaches();
        testExclusionWithoutAStreamNeitherDiscoversNorSucceeds();
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
