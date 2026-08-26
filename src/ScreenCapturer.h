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

/*
 * NO when a stop timed out with capture work still in flight. Such a capturer
 * must NOT be released: freeing its queues and frame mailbox would be a
 * use-after-free from the callback that is still running. The owner keeps it
 * alive instead - a deliberate leak on an already-degraded shutdown, which is
 * cheaper than a crash and than the unbounded wait it replaced.
 */
- (BOOL)isSafeToDeallocate;

@end

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Dedicated test builds can fail the Nth capturer initialization (zero-based). */
void macVNCFailCaptureInitializationAfter(NSInteger successfulInitializations);
bool macVNCCaptureInitializationFaultWasConsumed(void);
#endif

NS_ASSUME_NONNULL_END
