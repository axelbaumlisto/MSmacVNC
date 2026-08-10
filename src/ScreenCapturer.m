#import "ScreenCapturer.h"
#import "CaptureQueueDrain.h"
#include <errno.h>
#include <math.h>
#include <time.h>

@interface ScreenCapturer ()

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
@property (nonatomic, copy, nonnull) void (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

@end


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
                   frameHandler:(void (^)(CMSampleBufferRef))frameHandler
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
        _operationGroup = dispatch_group_create();
        _captureRequested = NO;
        _generation = 0;
        _captureFramesPerSecond = captureFramesPerSecond;
        pthread_mutex_init(&_readinessMutex, NULL);
        pthread_cond_init(&_readinessCondition, NULL);
        _firstFrameReady = NO;
        _readinessGeneration = 0;
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

- (void)stopCapture {
    [self stopCaptureAndWait];
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
               does not promise its sample-handler queue is drained. The serial
               barrier closes admission for callbacks queued before completion;
               only then may the stop sentinel leave the group. */
            macVNCEndOperationAfterSerialQueueDrain(self.sampleHandlerQueue,
                                                     self.operationGroup);
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
            self.frameHandler((CMSampleBufferRef)item.frame);
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

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    long nanoseconds = (long)((timeout - floor(timeout)) * NSEC_PER_SEC);
    deadline.tv_sec += (time_t)floor(timeout) + (deadline.tv_nsec + nanoseconds) / NSEC_PER_SEC;
    deadline.tv_nsec = (deadline.tv_nsec + nanoseconds) % NSEC_PER_SEC;

    pthread_mutex_lock(&_readinessMutex);
    while (_readinessGeneration == generation && !_firstFrameReady) {
        int result = pthread_cond_timedwait(&_readinessCondition, &_readinessMutex, &deadline);
        if (result == ETIMEDOUT)
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
       the owned sample queue alive until no callback can still touch state. */
    dispatch_sync(_sampleHandlerQueue, ^{});
    if (_frameMailboxInitialized)
        macVNCFrameMailboxDestroy(&_frameMailbox);
    pthread_cond_destroy(&_readinessCondition);
    pthread_mutex_destroy(&_readinessMutex);
    [_frameHandler release];
    [_errorHandler release];
    dispatch_release(_operationGroup);
    dispatch_release(_sampleHandlerQueue);
    dispatch_release(_frameQueue);
    dispatch_release(_stateQueue);
    [super dealloc];
}

@end
