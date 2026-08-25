#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenCapturer : NSObject <SCStreamDelegate, SCStreamOutput>

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
        captureFramesPerSecond:(NSInteger)captureFramesPerSecond
                   frameHandler:(nonnull BOOL (^)(CMSampleBufferRef sampleBuffer))frameHandler
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
