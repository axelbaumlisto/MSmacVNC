#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#include <pthread.h>
#include <stdbool.h>
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
- (void)stopCaptureAndWait;
- (BOOL)waitForFirstFrameWithTimeout:(NSTimeInterval)timeout;
- (BOOL)isCurrentGenerationReady;

@end

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Dedicated test builds can fail the Nth capturer initialization (zero-based). */
void macVNCFailCaptureInitializationAfter(NSInteger successfulInitializations);
bool macVNCCaptureInitializationFaultWasConsumed(void);
#endif

NS_ASSUME_NONNULL_END
