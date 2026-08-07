#import "ScreenCapturer.h"

@interface ScreenCapturer ()

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) dispatch_group_t operationGroup;
@property (nonatomic, assign) BOOL captureRequested;
@property (nonatomic, assign) NSUInteger generation;

// handlers
@property (nonatomic, copy, nonnull) void (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

@end


@implementation ScreenCapturer

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                   frameHandler:(void (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler {
    if (self = [super init]) {
        _displayID = displayID;
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
        _stateQueue = dispatch_queue_create("net.christianbeier.macVNC.capture-state", DISPATCH_QUEUE_SERIAL);
        _operationGroup = dispatch_group_create();
        _captureRequested = NO;
        _generation = 0;
    }
    return self;
}

- (void)startCapture {
    dispatch_async(self.stateQueue, ^{
        if (self.captureRequested)
            return;
        self.captureRequested = YES;
        NSUInteger generation = ++self.generation;
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
                config.minimumFrameInterval = CMTimeMake(1, 20);
                config.pixelFormat = kCVPixelFormatType_32BGRA;

                SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
                [filter release];
                [config release];
                NSError *addOutputError = nil;
                dispatch_queue_attr_t qosAttr = dispatch_queue_attr_make_with_qos_class(
                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
                dispatch_queue_t captureQueue = dispatch_queue_create("libvncserver.examples.mac", qosAttr);
                [stream addStreamOutput:self
                                   type:SCStreamOutputTypeScreen
                     sampleHandlerQueue:captureQueue
                                  error:&addOutputError];
                dispatch_release(captureQueue);
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
        stream = [self.stream retain];
        self.stream = nil;
    });
    if (stream) {
        dispatch_group_enter(self.operationGroup);
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            (void)error;
            dispatch_group_leave(self.operationGroup);
        }];
    }
    /* Covers pending discovery/start/frame tasks and the definitive stream stop. */
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

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen)
        return;
    CFRetain(sampleBuffer);
    dispatch_group_enter(self.operationGroup);
    dispatch_async(self.stateQueue, ^{
        if (self.captureRequested && self.stream == stream)
            self.frameHandler(sampleBuffer);
        CFRelease(sampleBuffer);
        dispatch_group_leave(self.operationGroup);
    });
}

- (void)dealloc {
    [_frameHandler release];
    [_errorHandler release];
    dispatch_release(_operationGroup);
    dispatch_release(_stateQueue);
    [super dealloc];
}

@end
