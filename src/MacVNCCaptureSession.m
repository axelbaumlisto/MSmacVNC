#import "MacVNCCaptureSession.h"

#include <ScreenCaptureKit/ScreenCaptureKit.h>

#import "MacVNCSweepSchedule.h"
#import "ScreenCapturer.h"
#import "FirstFrameBudget.h"

#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>

/* Capturers for the current run; nil between runs. */
static NSMutableArray<ScreenCapturer *> *gCapturers;

/*
 * Guards gCapturers, and EVERY function here takes it.
 *
 * It used to guard only Build, Reset and SetSelfExcluded, on the argument that
 * the other readers run on client threads which rfbShutdownServer(screen, TRUE)
 * joins before any writer runs. That argument was FALSE and its counter-example
 * ships: mac.m's capture keep-warm timer fires on gCaptureStopQueue - a queue
 * nothing joins - and calls StopAndWait() and Count() after dropping
 * captureControlMutex, so it can overlap the Reset inside vncServerStopLocked,
 * which nils and releases the very list those two were enumerating. The main
 * thread is the other unjoined caller, through the curtain's seams.
 *
 * So the rule has no per-caller reasoning left to keep true: readers snapshot
 * under the lock (the copy retains every stream for the duration of the call)
 * and work on the snapshot; writers swap the pointer under the lock and release
 * the old list outside it.
 *
 * A leaf lock: taken after serverLifecycleMutex, never held while messaging a
 * capturer, and never held across -[ScreenCapturer dealloc], which can wait
 * (bounded) for a sample queue to drain.
 */
static pthread_mutex_t gCapturersMutex = PTHREAD_MUTEX_INITIALIZER;

/*
 * Whether the CURRENT session's streams are excluding this application, and
 * which session that answer belongs to.
 *
 * The exclusion is state on an SCStream, so a rebuilt session silently drops
 * it - "windows up while the stream no longer excludes us" is exactly the
 * state the raise/lift ordering forbids, and nothing reports it. The flag
 * exists so the curtain's controller can ask, and the generation exists so a
 * swap that confirms AFTER a rebuild cannot answer for the session that
 * replaced it.
 */
static bool gSelfExcluded;
static uint64_t gSessionGeneration;

/*
 * Moves the list out of the global under the lock and hands ownership to the
 * caller, which releases it OUTSIDE the lock. Splitting it this way is what
 * keeps the critical section down to a pointer swap: releasing inside would
 * block the main thread's curtain request behind a capturer's bounded drain.
 */
static NSMutableArray<ScreenCapturer *> *detachCapturers(void)
{
    pthread_mutex_lock(&gCapturersMutex);
    NSMutableArray<ScreenCapturer *> *detached = gCapturers;   /* +1 moves out */
    gCapturers = nil;
    gSelfExcluded = false;
    ++gSessionGeneration;
    pthread_mutex_unlock(&gCapturersMutex);
    return detached;
}

static void installCapturers(NSMutableArray<ScreenCapturer *> *capturers)
{
    pthread_mutex_lock(&gCapturersMutex);
    /* Build drops the previous session FIRST; overwriting a live list here
       would leak every stream in it, and "the caller happens to reset first"
       was enforced nowhere. */
    assert(gCapturers == nil);
    gCapturers = [capturers retain];
    gSelfExcluded = false;
    ++gSessionGeneration;
    pthread_mutex_unlock(&gCapturersMutex);
}

/* A snapshot that keeps every stream alive for as long as the caller holds it,
   so a Reset running concurrently cannot free a capturer mid-request. Every
   reader goes through this - see the header's THREADING note for why "the
   client threads are joined before a writer runs" was not an argument that
   covered them all. */
static NSArray<ScreenCapturer *> *copyCapturers(uint64_t *outGeneration)
{
    pthread_mutex_lock(&gCapturersMutex);
    NSArray<ScreenCapturer *> *snapshot = [gCapturers copy];   /* +1 */
    if (outGeneration)
        *outGeneration = gSessionGeneration;
    pthread_mutex_unlock(&gCapturersMutex);
    return snapshot;
}

/* Records the outcome of one exclusion request against the session it was
   issued for. A late answer from a session that has since been rebuilt is
   dropped rather than describing the new one. */
static void noteExclusionOutcome(uint64_t generation, bool excluded, bool success)
{
    pthread_mutex_lock(&gCapturersMutex);
    if (generation == gSessionGeneration)
        gSelfExcluded = (success && excluded);
    pthread_mutex_unlock(&gCapturersMutex);
}

bool macVNCCaptureSessionSelfExcluded(void)
{
    pthread_mutex_lock(&gCapturersMutex);
    bool excluded = gSelfExcluded && gCapturers.count > 0;
    pthread_mutex_unlock(&gCapturersMutex);
    return excluded;
}

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
    /* Unpublish first, under the lock; everything after this point works on a
       list nobody else can reach. */
    NSMutableArray<ScreenCapturer *> *detached = detachCapturers();
    /* A capturer whose work never quiesced is dropped from the set but NOT
       released: freeing its queues would be a use-after-free from the callback
       still running inside it. Leaking one on an already-degraded shutdown is
       cheaper than a crash. See -[ScreenCapturer isSafeToDeallocate]. */
    for (ScreenCapturer *capturer in detached) {
        if (![capturer isSafeToDeallocate]) {
            [capturer retain];  /* ownership moves to the deliberate leak */
            NSLog(@"macVNC: leaking a capturer with stuck capture work");
        }
    }
    [detached release];
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

    installCapturers(built);
    return true;
  }
}

size_t macVNCCaptureSessionCount(void)
{
  @autoreleasepool {
    NSArray<ScreenCapturer *> *capturers = [copyCapturers(NULL) autorelease];
    return capturers.count;
  }
}

void macVNCCaptureSessionStart(void)
{
    /* Client threads come from LibVNCServer pthreads, which have no autorelease
       pool; anything autoreleased below (NSLog formatting, error.description)
       would leak permanently with "autoreleased with no pool in place". */
    @autoreleasepool {
    NSArray<ScreenCapturer *> *capturers = [copyCapturers(NULL) autorelease];
    for (ScreenCapturer *capturer in capturers)
        [capturer startCapture];
    }
}

void macVNCCaptureSessionStopAndWait(void)
{
    /* Client threads come from LibVNCServer pthreads, which have no autorelease
       pool; anything autoreleased below (NSLog formatting, error.description)
       would leak permanently with "autoreleased with no pool in place". */
    @autoreleasepool {
    /* Snapshotted, not read in place: this also runs on the capture STOP QUEUE
       (mac.m's keep-warm timer), which rfbShutdownServer never joins, so it can
       overlap the Reset a server stop performs. */
    NSArray<ScreenCapturer *> *capturers = [copyCapturers(NULL) autorelease];
    for (ScreenCapturer *capturer in capturers)
        [capturer stopCaptureAndWait];
    }
}

/*
 * One exclusion request fanned out over every stream.
 *
 * It exists because the answer is "did they ALL confirm", and because the
 * request must survive its own callers: it is retained by each per-stream
 * completion block and by the group's notify block, and freed when the last of
 * them is destroyed. A ScreenCaptureKit completion that never fires therefore
 * leaks this one small object rather than freeing it under a callback that may
 * still run - the same trade the capturer itself makes for stuck work.
 */
@interface MacVNCCaptureExclusionRequest : NSObject
@end

@implementation MacVNCCaptureExclusionRequest {
    MacVNCCaptureExclusionCompletion _completion;
    void *_context;
    _Atomic bool _anyFailed;
    bool _excluded;
    uint64_t _generation;
}

- (instancetype)initWithCompletion:(MacVNCCaptureExclusionCompletion)completion
                           context:(void *)context
                          excluded:(bool)excluded
                        generation:(uint64_t)generation
{
    if ((self = [super init])) {
        _completion = completion;
        _context = context;
        _excluded = excluded;
        _generation = generation;
        atomic_init(&_anyFailed, false);
    }
    return self;
}

- (void)noteStreamFailed
{
    atomic_store(&_anyFailed, true);
}

/*
 * Called from the group's notify block and from nowhere else, which is what
 * makes "exactly one answer per request" true - dispatch_group_notify fires its
 * block once. There is deliberately no once-only guard here: it would be code
 * no test could reach, and this module owns no timeout that could race the
 * notify. Anyone adding a SECOND way to resolve a request (a deadline here, a
 * cancel path) must add that guard back with a test that fires both.
 */
- (void)reportCompletion
{
    bool success = !atomic_load(&_anyFailed);
    /* Published BEFORE the answer, so a caller that re-checks the invariant
       inside its own completion sees the state its request just established. */
    noteExclusionOutcome(_generation, _excluded, success);
    if (_completion)
        _completion(_context, success);
}

@end

void macVNCCaptureSessionSetSelfExcluded(bool excluded,
                                         MacVNCCaptureExclusionCompletion completion,
                                         void *context)
{
  @autoreleasepool {
    /* Snapshot under the lock, then work on it unlocked: the copy retains every
       stream, so a concurrent Reset can free the LIST without freeing anything
       this request is about to message. */
    uint64_t generation = 0;
    NSArray<ScreenCapturer *> *capturers =
        [copyCapturers(&generation) autorelease];
    if (capturers.count == 0) {
        /* No live stream is a FAILURE for this request, not a vacuous success:
           see the header. Still on the main queue, like every other outcome. */
        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(context, false);
            });
        return;
    }

    MacVNCCaptureExclusionRequest *request =
        [[MacVNCCaptureExclusionRequest alloc] initWithCompletion:completion
                                                          context:context
                                                         excluded:excluded
                                                       generation:generation];
    dispatch_group_t group = dispatch_group_create();
    for (ScreenCapturer *capturer in capturers) {
        dispatch_group_enter(group);
        [capturer setExcludesOwnApplication:(excluded ? YES : NO)
                          completionHandler:^(BOOL streamSucceeded) {
            if (!streamSucceeded)
                [request noteStreamFailed];
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [request reportCompletion];
    });
    dispatch_release(group);
    [request release];   /* the blocks above hold their own references */
  }
}

bool macVNCCaptureSessionWaitForFirstFrames(uint64_t timeoutNanoseconds)
{
  @autoreleasepool {
    /* One budget for the whole set: a per-display timeout would make a
       two-monitor Mac keep the client waiting twice as long. */
    MacVNCFirstFrameBudget budget =
        macVNCFirstFrameBudgetStart(macVNCMonotonicNow(), timeoutNanoseconds);

    NSArray<ScreenCapturer *> *capturers = [copyCapturers(NULL) autorelease];
    for (ScreenCapturer *capturer in capturers) {
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

