#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * How this process's own SCRunningApplication is discovered - the object the
 * curtain's filter must name, and the seam TWO live runs have now corrected.
 *
 * RUN 1 falsified "the start-time answer is good enough": the resolution was
 * done once, at stream start, and the nil it produced was cached forever.
 *
 * RUN 2 falsified the fix that followed it. The theory was that
 * `+[SCShareableContent getShareableContentWithCompletionHandler:]`
 * (SCShareableContent.h:146) is the ON-SCREEN variant and that asking with
 * `onScreenWindowsOnly:NO`
 * (`+getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:`,
 * SCShareableContent.h:162) would list us. It does NOT. On a real two-display
 * Mac, with that variant, an authenticated client and 797 delivered frames,
 * the log still read "application no" for every display.
 *
 * THE RULE UNDER TEST NOW: `applications` lists the owners of shareable
 * CONTENT, and content means WINDOWS - so a process that owns no window
 * ScreenCaptureKit can see appears in no discovery result, whichever variant
 * is used. macVNC is an LSUIElement app whose only UI is a status item, so at
 * the moment the curtain asks it owns nothing that qualifies. If that is the
 * rule, the exclusion CANNOT be armed before a curtain window exists, and the
 * raise must order an invisible window in FIRST (see MacVNCCurtainWindow.h).
 *
 * That is a claim about the platform, so it is MEASURED rather than assumed:
 * the discovery is censused (MacVNCShareableContentCensus below) and logged -
 * ONCE PER PROCESS at stream start, when this process owns no curtain window,
 * and again at every moment the exclusion is requested, when it does. One run
 * prints both lines and settles it. The stream-start line is once per process
 * on purpose: captures start on every first-client edge for every user, and a
 * census that answered the same question on every connection would be a
 * diagnostic experiment shipped as a permanent log.
 *
 * The block is handed a completion it must call EXACTLY ONCE, on any thread,
 * with the applications AND the windows of a discovery result, or nil/nil for
 * "discovery failed". The windows are there for the census only: no decision
 * is taken from them. Installing nil restores the ScreenCaptureKit default.
 *
 * Tests install one because no test may reach ScreenCaptureKit itself: its
 * discovery can raise a Screen Recording prompt, and a test that prompts is a
 * test nobody can run unattended.
 */
typedef void (^MacVNCOwnApplicationDiscovery)(
    void (^completion)(NSArray<SCRunningApplication *> *_Nullable applications,
                       NSArray<SCWindow *> *_Nullable windows));

/* Installs (or, with nil, removes) the discovery seam above. */
void macVNCSetOwnApplicationDiscovery(MacVNCOwnApplicationDiscovery _Nullable discovery);

/*
 * What one shareable-content discovery said about THIS process.
 *
 * These are exactly the numbers that separate the candidate rules, counted by a
 * pure function so the log line and the tests agree by construction:
 *
 *   own application PRESENT                 -> exclusion by application works;
 *   own application ABSENT, own windows 0   -> we own nothing ScreenCaptureKit
 *                                              can see, so a window has to
 *                                              exist BEFORE the request;
 *   own application ABSENT, own windows > 0 -> the rule above is wrong and no
 *                                              ordering can rescue it; the
 *                                              exclusion would have to name
 *                                              windows instead.
 *
 * `ownWindowsOnScreen` separates "SCK knows our window" from "SCK counts it as
 * on screen", which is what a window at NSScreenSaverWindowLevel, or one with a
 * near-zero alpha, could plausibly fail.
 */
typedef struct {
    unsigned long applications;
    unsigned long windows;
    unsigned long ownWindows;
    unsigned long ownWindowsOnScreen;
    bool ownApplicationPresent;
} MacVNCShareableContentCensus;

/*
 * Counts the above out of one discovery result. Pure, nil-tolerant, and
 * published because it IS the measurement: `tests/test_capture_exclusion.m`
 * feeds it each of the three states without reaching ScreenCaptureKit.
 */
MacVNCShareableContentCensus macVNCTakeShareableContentCensus(
    NSArray<SCRunningApplication *> *_Nullable applications,
    NSArray<SCWindow *> *_Nullable windows,
    pid_t ownProcessID);

/*
 * Prints one census as a single line, plus - when the third state above holds -
 * the verdict that application-level exclusion is impossible on this system.
 * `phase` says WHEN the discovery happened ("stream start", "exclusion
 * request"), because the measurement is the DIFFERENCE between the two.
 */
void macVNCLogShareableContentCensus(const char *phase,
                                     unsigned int displayID,
                                     MacVNCShareableContentCensus census);

/*
 * May one exclusion request go on to swap the filter?
 *
 * The whole precondition set of -setExcludesOwnApplication:, as one pure
 * decision: there must be a running stream and its display, and EXCLUDING also
 * needs this process's own SCRunningApplication - naming nobody would swap in a
 * filter that hides nothing while reporting success, i.e. a curtain the remote
 * viewer cannot see through. Anything missing fails CLOSED.
 *
 * Published because that decision, not the swap, is where the device failure
 * lived: `tests/test_capture_exclusion.m` feeds it a discovery result with and
 * without this process.
 */
bool macVNCCaptureExclusionMayProceed(bool haveStream,
                                      bool haveDisplay,
                                      bool haveOwnApplication,
                                      bool excluded);

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
 * The exclusion names an SCRunningApplication, never a window - but naming
 * ourselves REQUIRES a discovery in which we appear, and a live run showed we
 * do not appear while this process owns no window (see the seam comment at the
 * top of this header). So the CALLER must already own an on-screen window when
 * it asks for `excluded:YES`; MacVNCCurtain orders a fully invisible one in
 * first for exactly this reason. The SCDisplay was captured when the stream
 * started, and the application is taken from the same discovery when it happens
 * to be there - otherwise it is resolved HERE, at the moment it is needed (see
 * -resolveOwnApplicationWithCompletionHandler:), because for a windowless
 * menu-bar app the start-time answer is nil and caching nil forever is how the
 * curtain came to be unraisable on real hardware.
 *
 * That resolution costs one SCShareableContent round trip on the first raise of
 * a stream, and only then. It is never attempted without a RUNNING stream: only
 * a running stream proves Screen Recording is already granted, and a discovery
 * made without it could raise a permission prompt.
 *
 * `completionHandler` runs with NO when there is no running stream, when the
 * cached SCDisplay is missing, when this process cannot be found in the
 * discovery result, or when the swap itself fails; the caller must treat that
 * as "do not raise the curtain". It carries
 * no timeout - the caller owns the deadline. It is NULLABLE on purpose: the
 * un-exclusion sent after a failed raise is fire-and-forget, and this file is
 * inside NS_ASSUME_NONNULL_BEGIN, so leaving it implicit would have made the
 * implementation's NULL check a contradiction of its own header.
 */
- (void)setExcludesOwnApplication:(BOOL)excluded
                completionHandler:(nullable void (^)(BOOL success))completionHandler;

/*
 * Resolves - and then caches - this process's own SCRunningApplication.
 *
 * `handler` runs on this capturer's state queue with nil when this process is
 * not in the discovery result; nil means the caller must fail closed, never
 * guess. A resolved application is cached, so repeated raises of one stream do
 * one round trip in total.
 *
 * Safe to call from any thread. Published because it is the seam the on-device
 * failure lived in, and the only one a test can drive without a display; the
 * exclusion path calls it for itself.
 */
- (void)resolveOwnApplicationWithCompletionHandler:
    (nullable void (^)(SCRunningApplication *_Nullable application))handler;

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
