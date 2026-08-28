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
 * Rebuild this stream's content filter so it excludes (or stops excluding)
 * THIS application's own windows, and swap it onto the RUNNING stream with
 * -[SCStream updateContentFilter:completionHandler:]. The stream is never
 * stopped: a stop/start would drop frames and re-run the start path.
 *
 * The exclusion names an SCRunningApplication, never a window, so it needs no
 * window to exist and no SCShareableContent round trip here - both the
 * SCDisplay and our own SCRunningApplication were captured when the stream
 * started, out of the discovery call that path already makes.
 *
 * `completionHandler` runs with NO when there is no running stream, when the
 * cached SCDisplay or SCRunningApplication is missing, or when the swap itself
 * fails; the caller must treat that as "do not raise the curtain". It carries
 * no timeout - the caller owns the deadline. It is NULLABLE on purpose: the
 * un-exclusion sent after a failed raise is fire-and-forget, and this file is
 * inside NS_ASSUME_NONNULL_BEGIN, so leaving it implicit would have made the
 * implementation's NULL check a contradiction of its own header.
 */
- (void)setExcludesOwnApplication:(BOOL)excluded
                completionHandler:(nullable void (^)(BOOL success))completionHandler;

/*
 * NO when a stop timed out with capture work still in flight. Such a capturer
 * must NOT be released: freeing its queues and frame mailbox would be a
 * use-after-free from the callback that is still running. The owner keeps it
 * alive instead - a deliberate leak on an already-degraded shutdown, which is
 * cheaper than a crash and than the unbounded wait it replaced.
 */
- (BOOL)isSafeToDeallocate;

/* True when this stream produced its first frame inside `timeout`. Declared
 * here because MacVNCCaptureSession calls it: without the declaration the
 * compiler warned and inferred an `id` return for a BOOL method. */
- (BOOL)waitForFirstFrameWithTimeout:(NSTimeInterval)timeout;

@end

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Dedicated test builds can fail the Nth capturer initialization (zero-based). */
void macVNCFailCaptureInitializationAfter(NSInteger successfulInitializations);
bool macVNCCaptureInitializationFaultWasConsumed(void);
#endif

NS_ASSUME_NONNULL_END
