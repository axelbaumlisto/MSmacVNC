#import "ScreenCapturer.h"
#import "FirstFrameBudget.h"
#import "FrameMailbox.h"
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>

/* Identity key for the sample-handler queue (see -dealloc). The address of this
   static is the key; its value is irrelevant. */
static const void * const kMacVNCSampleQueueKey = &kMacVNCSampleQueueKey;
/* Same purpose for the state queue: the last reference can be dropped by a
   block finishing there, and a dispatch_sync from that thread would deadlock. */
static const void * const kMacVNCStateQueueKey = &kMacVNCStateQueueKey;

@interface ScreenCapturer () {
    pthread_mutex_t _readinessMutex;
    pthread_cond_t _readinessCondition;
    BOOL _firstFrameReady;
    NSUInteger _readinessGeneration;
    MacVNCFrameMailbox _frameMailbox;
    BOOL _frameMailboxInitialized;
}

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) dispatch_queue_t frameQueue;
@property (nonatomic, strong) dispatch_queue_t sampleHandlerQueue;
@property (nonatomic, strong) dispatch_group_t operationGroup;
@property (nonatomic, assign) BOOL captureRequested;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign, readonly) NSInteger captureFramesPerSecond;

// handlers
@property (nonatomic, copy, nonnull) BOOL (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

@end


#if defined(MACVNC_ENABLE_TEST_HOOKS)
static NSInteger captureInitializationsBeforeFailure = -1;
static _Atomic bool captureInitializationFaultConsumed = false;

void
macVNCFailCaptureInitializationAfter(NSInteger successfulInitializations)
{
    captureInitializationsBeforeFailure = successfulInitializations;
    atomic_store(&captureInitializationFaultConsumed, false);
}

bool
macVNCCaptureInitializationFaultWasConsumed(void)
{
    return atomic_load(&captureInitializationFaultConsumed);
}
#endif

static void releaseMailboxFrame(void *frame)
{
    CFRelease(frame);
}

static void beginMailboxActivity(void *context)
{
    dispatch_group_enter((dispatch_group_t)context);
}

static void endMailboxActivity(void *context)
{
    dispatch_group_leave((dispatch_group_t)context);
}

@implementation ScreenCapturer {
    /* Set when a stop timed out with capture work still in flight; read by
       -isSafeToDeallocate from another thread, hence atomic. */
    _Atomic bool _stuckWork;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
        captureFramesPerSecond:(NSInteger)captureFramesPerSecond
                   frameHandler:(BOOL (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler {
    if (self = [super init]) {
        _displayID = displayID;
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
        _stateQueue = dispatch_queue_create("net.christianbeier.macVNC.capture-state", DISPATCH_QUEUE_SERIAL);
        _frameQueue = dispatch_queue_create("net.christianbeier.macVNC.capture-frame", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_attr_t qosAttr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _sampleHandlerQueue = dispatch_queue_create(
            "net.christianbeier.macVNC.capture-sample", qosAttr);
        /* Tag the queue so -dealloc can detect it is already running on it and
           skip the final dispatch_sync (which would self-deadlock). This can
           happen when GCD releases the last block-captured self reference on
           this very queue after stopCaptureAndWait has returned. */
        dispatch_queue_set_specific(_sampleHandlerQueue,
                                    kMacVNCSampleQueueKey,
                                    (void *)kMacVNCSampleQueueKey,
                                    NULL);
        dispatch_queue_set_specific(_stateQueue,
                                    kMacVNCStateQueueKey,
                                    (void *)kMacVNCStateQueueKey,
                                    NULL);
        _operationGroup = dispatch_group_create();
        _captureRequested = NO;
        _generation = 0;
        _captureFramesPerSecond = captureFramesPerSecond;
        pthread_mutex_init(&_readinessMutex, NULL);
        pthread_cond_init(&_readinessCondition, NULL);
        _firstFrameReady = NO;
        _readinessGeneration = 0;
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        if (captureInitializationsBeforeFailure == 0) {
            atomic_store(&captureInitializationFaultConsumed, true);
            [self release];
            return nil;
        }
        if (captureInitializationsBeforeFailure > 0)
            --captureInitializationsBeforeFailure;
#endif
        _frameMailboxInitialized = macVNCFrameMailboxInit(
            &_frameMailbox, releaseMailboxFrame, beginMailboxActivity,
            endMailboxActivity, (void *)_operationGroup);
        if (!_frameMailboxInitialized) {
            [self release];
            return nil;
        }
    }
    return self;
}

/*
 * Everything from "display found" to "stream started", extracted from
 * startCapture so each method states one thing: startCapture is the
 * lifecycle decision (generation, group accounting, discovery), this is the
 * ScreenCaptureKit plumbing (configuration, filter, output wiring, start).
 *
 * Runs on stateQueue; caller has already validated generation and taken one
 * operationGroup reference, which this method leaves ONLY when the stream is
 * started and the start-completion has its own reference pending - every
 * early exit releases the caller's reference.
 */
- (void)beginStreamingWithDisplay:(SCDisplay *)display generation:(NSUInteger)generation
{
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = (int)CGDisplayPixelsWide(self.displayID);
    config.height = (int)CGDisplayPixelsHigh(self.displayID);
    if (@available(macOS 13.0, *))
        config.showsCursor = YES;
    config.minimumFrameInterval = CMTimeMake(1, (int32_t)self.captureFramesPerSecond);
    config.queueDepth = 2;
    config.pixelFormat = kCVPixelFormatType_32BGRA;

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    [filter release];
    [config release];

    NSError *addOutputError = nil;
    [stream addStreamOutput:self
                       type:SCStreamOutputTypeScreen
         sampleHandlerQueue:self.sampleHandlerQueue
                      error:&addOutputError];
    if (addOutputError) {
        [stream release];
        self.errorHandler(addOutputError);
        dispatch_group_leave(self.operationGroup);
        return;
    }

    self.stream = stream;
    dispatch_group_enter(self.operationGroup);
    [stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        dispatch_async(self.stateQueue, ^{
            if (startError && self.captureRequested &&
                self.generation == generation && self.stream == stream)
                self.errorHandler(startError);
            dispatch_group_leave(self.operationGroup);
        });
    }];
    [stream release];
    dispatch_group_leave(self.operationGroup);
}

- (void)startCapture {
    dispatch_async(self.stateQueue, ^{
        if (self.captureRequested)
            return;
        self.captureRequested = YES;
        NSUInteger generation = ++self.generation;
        pthread_mutex_lock(&self->_readinessMutex);
        self->_readinessGeneration = generation;
        self->_firstFrameReady = NO;
        pthread_cond_broadcast(&self->_readinessCondition);
        pthread_mutex_unlock(&self->_readinessMutex);
        dispatch_group_enter(self.operationGroup);

        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
            dispatch_async(self.stateQueue, ^{
                /* A disconnect may have arrived while content discovery was pending. */
                if (!self.captureRequested || self.generation != generation) {
                    dispatch_group_leave(self.operationGroup);
                    return;
                }
                if (error) {
                    self.errorHandler(error);
                    dispatch_group_leave(self.operationGroup);
                    return;
                }

                NSUInteger displayIndex = [content.displays indexOfObjectPassingTest:^BOOL(
                    SCDisplay *_Nonnull display, NSUInteger idx, BOOL *_Nonnull stop) {
                    return display.displayID == self.displayID;
                }];
                if (displayIndex == NSNotFound) {
                    NSError *noDisplayError = [NSError errorWithDomain:@"ScreenCapturerErrorDomain"
                                                                  code:1
                                                              userInfo:@{NSLocalizedDescriptionKey : @"Display not available for capture"}];
                    self.errorHandler(noDisplayError);
                    dispatch_group_leave(self.operationGroup);
                    return;
                }
                [self beginStreamingWithDisplay:content.displays[displayIndex]
                                           generation:generation];
            });
        }];
    });
}

- (void)stopCaptureAndWait {
    __block SCStream *stream = nil;
    dispatch_sync(self.stateQueue, ^{
        self.captureRequested = NO;
        ++self.generation;
        pthread_mutex_lock(&self->_readinessMutex);
        self->_readinessGeneration = self.generation;
        self->_firstFrameReady = NO;
        pthread_cond_broadcast(&self->_readinessCondition);
        pthread_mutex_unlock(&self->_readinessMutex);
        stream = [self.stream retain];
        self.stream = nil;
        /* Keep the group nonzero from invalidation through definitive stream
           stop and the owned callback queue drain. */
        if (stream)
            dispatch_group_enter(self.operationGroup);
    });
    if (stream) {
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            (void)error;
            /* Stop completion prevents new ScreenCaptureKit submissions, but
               does not promise its serial sample queue is drained. This sentinel
               runs after every callback already admitted to the owned queue. */
            dispatch_async(self.sampleHandlerQueue, ^{
                dispatch_group_leave(self.operationGroup);
            });
        }];
    }
    /* Covers discovery/start/mailbox work, definitive stream stop, and every
       sample callback admitted to the owned serial queue before stop completed.

       BOUNDED on purpose: SCShareableContent discovery can stay pending behind a
       system "wants to record this screen" prompt. An unbounded wait here would
       hang whichever thread called stop — including the main thread on the
       permission-failure and quit paths — leaving the menu bar (and the recovery
       affordances in it) permanently unresponsive. */
    if (dispatch_group_wait(self.operationGroup,
                            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        NSLog(@"macVNC: capture stop timed out waiting for in-flight "
              @"ScreenCaptureKit work (display %u); continuing shutdown",
              self.displayID);
        /* Remember it: -dealloc must not free state a live callback still uses,
           and it cannot re-derive this - the group may complete later. */
        atomic_store(&_stuckWork, true);
    }
    [stream release];
}

/*
 * NO when in-flight capture work never finished, so this object must not be
 * deallocated - freeing its queues and mailbox would be a use-after-free from
 * the stuck callback. The owner keeps such a capturer alive on purpose; that
 * leak only happens on an already-degraded shutdown and is far cheaper than
 * either a crash or the unbounded wait it replaced.
 */
- (BOOL)isSafeToDeallocate
{
    return !atomic_load(&_stuckWork);
}


/*
  SCStreamDelegate methods
*/

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(self.stateQueue, ^{
        if (self.captureRequested && self.stream == stream)
            self.errorHandler(error);
    });
}


/*
  SCStreamOutput methods
*/

- (void)drainFrameMailbox {
    for (;;) {
        MacVNCFrameMailboxItem item;
        BOOL haveItem = macVNCFrameMailboxTake(&_frameMailbox, &item);
        NSAssert(haveItem, @"scheduled frame drain must own a pending frame");
        if (!haveItem) {
            macVNCFrameMailboxEndDrainIteration(&_frameMailbox);
            return;
        }

        __block BOOL valid = NO;
        dispatch_sync(self.stateQueue, ^{
            valid = self.captureRequested &&
                    self.generation == item.generation &&
                    self.stream == (SCStream *)item.stream;
        });
        if (valid) {
            /* The handler may decline the frame when the compositor cannot take
               every client's send lock right now. Simply dropping it would lose
               those pixels until the screen changes again — and if the screen
               then goes static, permanently. Retry briefly, bounded, right here.

               Bounded is essential: an unbounded wait would recreate the very
               deadlock the non-blocking lock was introduced to fix (a client
               thread can hold its send lock while waiting on the client
               lifecycle mutex that a stopping capture holds). The mailbox
               coalesces any newer frame meanwhile, so nothing queues up. */
            static const int kMaxComposeAttempts = 12;   /* ~120 ms total */
            static const useconds_t kComposeRetryUs = 10000;
            BOOL composited = self.frameHandler((CMSampleBufferRef)item.frame);
            for (int attempt = 1; !composited && attempt < kMaxComposeAttempts; ++attempt) {
                usleep(kComposeRetryUs);
                composited = self.frameHandler((CMSampleBufferRef)item.frame);
            }
            if (!composited) {
                /* Give up on this frame: a client has been mid-send for >100 ms.
                   Do NOT mark readiness — nothing was drawn for this generation. */
                CFRelease(item.frame);
                if (!macVNCFrameMailboxEndDrainIteration(&_frameMailbox))
                    return;
                continue;
            }
            /* Ready means the generation's frame has finished composition. */
            dispatch_sync(self.stateQueue, ^{
                if (self.captureRequested &&
                    self.generation == item.generation &&
                    self.stream == (SCStream *)item.stream) {
                    pthread_mutex_lock(&self->_readinessMutex);
                    self->_readinessGeneration = item.generation;
                    self->_firstFrameReady = YES;
                    pthread_cond_broadcast(&self->_readinessCondition);
                    pthread_mutex_unlock(&self->_readinessMutex);
                }
            });
        }
        CFRelease(item.frame);
        if (!macVNCFrameMailboxEndDrainIteration(&_frameMailbox))
            return;
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen)
        return;

    /* Cover admission before consulting lifecycle state. If stop invalidates
       concurrently, it cannot observe quiescence while this callback is live. */
    dispatch_group_enter(self.operationGroup);
    __block BOOL accept = NO;
    __block NSUInteger generation = 0;
    dispatch_sync(self.stateQueue, ^{
        accept = self.captureRequested && self.stream == stream;
        generation = self.generation;
    });
    if (!accept) {
        dispatch_group_leave(self.operationGroup);
        return;
    }

    CFRetain(sampleBuffer);
    BOOL scheduleDrain = macVNCFrameMailboxSubmit(&_frameMailbox,
                                                   (void *)sampleBuffer,
                                                   (void *)stream,
                                                   generation);
    if (scheduleDrain) {
        dispatch_async(self.frameQueue, ^{
            [self drainFrameMailbox];
        });
    }
    dispatch_group_leave(self.operationGroup);
}

- (BOOL)waitForFirstFrameWithTimeout:(NSTimeInterval)timeout {
    __block NSUInteger generation = 0;
    __block BOOL requested = NO;
    dispatch_sync(self.stateQueue, ^{
        generation = self.generation;
        requested = self.captureRequested;
    });
    if (!requested)
        return NO;

    uint64_t durationNanoseconds = 0;
    if (isfinite(timeout) && timeout > 0) {
        long double scaled = (long double)timeout * NSEC_PER_SEC;
        durationNanoseconds = scaled >= ldexpl(1.0L, 64)
            ? UINT64_MAX
            : (uint64_t)scaled;
    }
    MacVNCFirstFrameBudget budget = macVNCFirstFrameBudgetStart(
        macVNCMonotonicNow(), durationNanoseconds);

    pthread_mutex_lock(&_readinessMutex);
    while (_readinessGeneration == generation && !_firstFrameReady) {
        uint64_t remaining = macVNCFirstFrameBudgetRemaining(
            &budget, macVNCMonotonicNow());
        if (remaining == 0)
            break;
        struct timespec relativeWait = macVNCRelativeWaitFromNanoseconds(remaining);
        int result = pthread_cond_timedwait_relative_np(
            &_readinessCondition, &_readinessMutex, &relativeWait);
        if (result != 0 && result != ETIMEDOUT)
            break;
    }
    BOOL ready = _readinessGeneration == generation && _firstFrameReady;
    pthread_mutex_unlock(&_readinessMutex);
    return ready;
}


/* Waits, bounded, for every already-admitted sample callback to finish. */
- (BOOL)waitForSampleQueueDrain
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_sampleHandlerQueue, ^{ dispatch_semaphore_signal(done); });
    BOOL drained = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    dispatch_release(done);
    return drained;
}

- (void)dealloc {
    /* Bounded final drain. -isSafeToDeallocate has already told the owner not to
       release a capturer whose work never quiesced, so reaching here means the
       stream was stopped cleanly; this only waits out callbacks already admitted
       to the owned queue. Skipped when we are running ON one of those queues,
       where a sync would deadlock on ourselves. */
    if (dispatch_get_specific(kMacVNCSampleQueueKey) == NULL &&
        dispatch_get_specific(kMacVNCStateQueueKey) == NULL)
        [self waitForSampleQueueDrain];

    if (_frameMailboxInitialized)
        macVNCFrameMailboxDestroy(&_frameMailbox);
    pthread_cond_destroy(&_readinessCondition);
    pthread_mutex_destroy(&_readinessMutex);
    [_stream release];
    [_frameHandler release];
    [_errorHandler release];
    dispatch_release(_operationGroup);
    dispatch_release(_sampleHandlerQueue);
    dispatch_release(_frameQueue);
    dispatch_release(_stateQueue);
    [super dealloc];
}

@end
