#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#include <pthread.h>
#import "FrameMailbox.h"

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCapturer : NSObject <SCStreamDelegate, SCStreamOutput> {
    pthread_mutex_t _readinessMutex;
    pthread_cond_t _readinessCondition;
    BOOL _firstFrameReady;
    NSUInteger _readinessGeneration;
    MacVNCFrameMailbox _frameMailbox;
    BOOL _frameMailboxInitialized;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
        captureFramesPerSecond:(NSInteger)captureFramesPerSecond
                   frameHandler:(nonnull void (^)(CMSampleBufferRef sampleBuffer))frameHandler
                   errorHandler:(nonnull void (^)(NSError *error))errorHandler;

- (void)startCapture;
- (void)stopCapture;
- (void)stopCaptureAndWait;
- (BOOL)waitForFirstFrameWithTimeout:(NSTimeInterval)timeout;
- (BOOL)isCurrentGenerationReady;

@end

NS_ASSUME_NONNULL_END
