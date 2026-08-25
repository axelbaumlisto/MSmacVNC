#import "ScreenCapturer.h"
#import "ReadinessPolicy.h"
#import "FrameMailbox.h"
#include <pthread.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>

/* Identity key for the sample-handler queue (see -dealloc). The address of this
   static is the key; its value is irrelevant. */
static const void * const kMacVNCSampleQueueKey = &kMacVNCSampleQueueKey;

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

@implementation ScreenCapturer

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
                SCDisplay *display = content.displays[displayIndex];

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
       sample callback admitted to the owned serial queue before stop completed. */
    dispatch_group_wait(self.operationGroup, DISPATCH_TIME_FOREVER);
    [stream release];
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
            /* The handler may decline the frame (compositor could not take every
               client's send lock right now). Dropping it would lose those pixels
               until the screen changes again — on a screen that then goes static
               the loss is permanent. So re-submit and retry shortly instead. */
            BOOL composited = self.frameHandler((CMSampleBufferRef)item.frame);
            if (!composited) {
                if (macVNCFrameMailboxSubmit(&_frameMailbox, item.frame,
                                             item.stream, item.generation)) {
                    /* We now own a scheduling reference again; run the next drain
                       after a short delay so the busy client can finish sending. */
                    __block ScreenCapturer *strongSelf = [self retain];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                                   self.frameQueue, ^{
                        [strongSelf drainFrameMailbox];
                        [strongSelf release];
                    });
                }
                /* Submit consumed our reference on success; on failure the mailbox
                   released it. Either way we must not release it again here. */
                if (!macVNCFrameMailboxEndDrainIteration(&_frameMailbox))
                    return;
                return;
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
    MacVNCReadinessBudget budget = macVNCReadinessBudgetStart(
        macVNCReadinessNow(), durationNanoseconds);

    pthread_mutex_lock(&_readinessMutex);
    while (_readinessGeneration == generation && !_firstFrameReady) {
        uint64_t remaining = macVNCReadinessBudgetRemaining(
            &budget, macVNCReadinessNow());
        if (remaining == 0)
            break;
        struct timespec relativeWait = macVNCReadinessRelativeWait(remaining);
        int result = pthread_cond_timedwait_relative_np(
            &_readinessCondition, &_readinessMutex, &relativeWait);
        if (result != 0 && result != ETIMEDOUT)
            break;
    }
    BOOL ready = _readinessGeneration == generation && _firstFrameReady;
    pthread_mutex_unlock(&_readinessMutex);
    return ready;
}

- (BOOL)isCurrentGenerationReady {
    __block NSUInteger generation = 0;
    __block BOOL requested = NO;
    dispatch_sync(self.stateQueue, ^{
        generation = self.generation;
        requested = self.captureRequested;
    });
    if (!requested)
        return NO;

    pthread_mutex_lock(&_readinessMutex);
    BOOL ready = _readinessGeneration == generation && _firstFrameReady;
    pthread_mutex_unlock(&_readinessMutex);
    return ready;
}

- (void)dealloc {
    /* vncServerStop quiesces each capturer first. This final serial drain keeps
       the owned sample queue alive until no callback can still touch state.
       If we are ALREADY executing on that queue (last reference dropped by GCD
       while releasing a completed block), the drain has by definition happened
       and dispatch_sync would deadlock on ourselves — so skip it. */
    if (dispatch_get_specific(kMacVNCSampleQueueKey) == NULL)
        dispatch_sync(_sampleHandlerQueue, ^{});
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
