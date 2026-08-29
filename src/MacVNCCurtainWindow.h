#pragma once

#import <Foundation/Foundation.h>
#include <stdint.h>

/*
 * The curtain itself: one black window per physical display, and the capture
 * filter change that keeps those windows OUT of the stream the remote viewer
 * sees.
 *
 * This module owns only the SCREEN half of curtain mode. It suppresses no
 * input, decides nothing about when a curtain should be up, and nothing calls
 * raise/lift yet - the controller that does is a separate task. The API here is
 * deliberately programmatic and idempotent so that controller has one seam.
 *
 * THREADING: every method of MacVNCCurtainWindowSet and MacVNCCurtain must be
 * called on the MAIN thread, because ordering an NSWindow in or out is
 * main-thread-only work. Completion blocks are delivered on the main thread
 * too, including the ones that originate in a ScreenCaptureKit callback.
 *
 * ---------------------------------------------------------------------------
 * Three decisions that are easy to get wrong, and why they are what they are:
 *
 * 1. THE FILTER EXCLUDES OUR APPLICATION, NOT OUR WINDOWS.
 *    `-[SCContentFilter initWithDisplay:excludingApplications:exceptingWindows:]`
 *    (SCStream.h:174-180) names an SCRunningApplication, so it is
 *    order-independent: the exclusion can be installed BEFORE any curtain
 *    window exists. Excluding by window would need the window to be on screen
 *    to be enumerable through SCShareableContent, which forces the order
 *    "show black, then update the filter" - i.e. the remote party watches the
 *    screen go black first. It also survives window recreation, which makes
 *    display hot-plug a pure window-creation problem (step 5) instead of a
 *    filter round trip. The cost is that our Preferences window disappears
 *    from the stream while the curtain is up.
 *
 * 2. THE CURTAIN IS NOT OPAQUE.
 *    An opaque full-screen window makes every window under it report
 *    NSWindowOcclusionState "not visible"; well-behaved applications then stop
 *    drawing, and ScreenCaptureKit cannot capture frames nobody rendered - the
 *    REMOTE viewer would see a frozen desktop while an acceptance test that
 *    only checks "the remote picture is not black" still passes. So the window
 *    is `setOpaque:NO` with an alpha just under 1 over a black backing.
 *
 *    MACVNC_CURTAIN_ALPHA = 0.999 is chosen from a luminance criterion rather
 *    than by eye: what leaks through is (1 - alpha) * L for an underlying
 *    channel value L, so the worst case is pure white, 0.001 * 255 = 0.255 of
 *    one 8-bit level. That quantises to 0 - the darkest representable pixel -
 *    so "looks black" is a measurement (every sampled channel reads 0), not an
 *    impression. Any alpha below ~0.998 leaks a level that a camera and a
 *    dark-adapted eye can both find.
 *
 *    THE CRITERION IS BIT-DEPTH DEPENDENT, and stated here for 8-BIT output.
 *    On a 10-bit panel - which Apple ships - 0.001 * 1023 = 1.02 rounds to
 *    level 1 of 1023 rather than to 0, i.e. ~0.1% of full white in the worst
 *    case (a pure-white area underneath) rather than nothing at all. Reaching
 *    a hard 0 at 10 bits would need alpha > 0.9995. That is deliberately NOT
 *    done here: it is a one-character change with a device-measurable effect,
 *    so it belongs to the on-device luminance check rather than to a guess,
 *    and this note is what keeps the claim honest until that measurement
 *    exists.
 *
 * 3. RAISE AND LIFT ARE ORDERED, AND THE ORDERS ARE MIRRORS.
 *    Raise: swap the filter FIRST, show the windows only after the swap
 *    reports success. Lift: hide the windows FIRST, restore the filter after.
 *    Both orders keep the same invariant - the curtain is never in the stream,
 *    and the stream is never showing our excluded application to nobody.
 *    The filter is swapped with `-[SCStream updateContentFilter:completionHandler:]`
 *    on the RUNNING stream; stopping and restarting the stream would drop
 *    frames and re-run the permission-sensitive start path.
 *
 *    A swap that never reports back is treated as FAILURE: MacVNCCurtain arms
 *    a timeout (MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS) alongside the
 *    request and, whichever arrives first wins, resolves exactly once. On
 *    failure the windows are NOT shown and a best-effort un-exclusion is sent,
 *    so a late success cannot leave the stream permanently excluding us.
 */

/* See note 2 above for the derivation. */
#define MACVNC_CURTAIN_ALPHA 0.999

/* A filter swap on a running stream is milliseconds of work. This is the point
 * at which we stop believing it will ever answer; the local user is looking at
 * an un-curtained screen the whole time, so waiting longer costs nothing but
 * delay, and waiting forever would hang the raise. */
#define MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS (2ull * 1000ull * 1000ull * 1000ull)

typedef void (^MacVNCCurtainCompletion)(BOOL success);

/*
 * Where the keys that reach the curtain WINDOW go.
 *
 * The curtain window is NOT key while the event tap is healthy: the tap is the
 * only path to the unlock policy, and a key window would collect the REMOTE
 * party's keystrokes, which are posted into this session and land in whatever
 * window has focus. The window takes focus only while the tap path is known
 * unavailable - secure input on, or a tap that could not be re-enabled - which
 * is the one case where the local user typing their password would otherwise
 * be typing it into an application the remote party is watching. The input
 * module owns that decision; this header owns only the delivery.
 */
@protocol MacVNCCurtainKeyboardSink <NSObject>
/* One key-down that reached the curtain window, as UTF-16 units exactly as
 * -[NSEvent characters] produces them. Main thread. */
- (void)curtainWindowDidReceiveCharacters:(const uint16_t *)units count:(size_t)count;
@end

/*
 * The screens the curtain covers, as an injectable seam.
 *
 * Identifiers are CGDirectDisplayIDs boxed in NSNumber (NSScreen's
 * "NSScreenNumber" device description). Everything above this protocol is
 * bookkeeping that a test can drive with no display attached, which is the
 * point: the rules "a screen attached while the curtain is up gets a window
 * AND that window is shown", "a detached screen's window is destroyed" and
 * "no screen gets two windows" are the ones worth testing, and none of them
 * needs AppKit.
 */
@protocol MacVNCCurtainOccluders <NSObject>
/** Identifiers of the physically attached screens, right now. */
- (NSArray<NSNumber *> *)attachedScreenIdentifiers;
/** Creates a hidden occluder for one screen. NO if that screen just went away. */
- (BOOL)createOccluderForScreen:(NSNumber *)identifier;
- (void)removeOccluderForScreen:(NSNumber *)identifier;
/** Re-fits an existing occluder after a resolution or arrangement change. */
- (void)updateOccluderGeometryForScreen:(NSNumber *)identifier;
/** Orders every occluder in (with orderFrontRegardless) or out. */
- (void)setOccludersVisible:(BOOL)visible;

@optional
/*
 * The focus half, optional because it arrived with the event tap and the
 * bookkeeping above is testable without it: an occluder set that does not
 * implement these is one that models windows but not focus, which is what the
 * hot-plug and visibility tests need.
 */
- (void)setOccludersAcceptKeyboardFocus:(BOOL)accepts;
- (void)setOccludersKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink;
@end

/*
 * Which screens have an occluder, and whether they are shown. Pure bookkeeping
 * over the seam above - no AppKit, no capture, no timing.
 */
@interface MacVNCCurtainWindowSet : NSObject
- (instancetype)initWithOccluders:(id<MacVNCCurtainOccluders>)occluders;

/*
 * Reconciles the occluder set with the attached screens: creates what is
 * missing, drops what is gone, re-fits what stayed. When the curtain is up it
 * also re-asserts visibility, so a screen attached mid-curtain is covered by
 * the same call that creates its window - that one call IS the exposure
 * window, because application-level exclusion needs no filter round trip.
 */
- (void)synchronizeWithAttachedScreens;

/** Shows or hides every occluder. Idempotent. */
- (void)setVisible:(BOOL)visible;

/*
 * Whether the curtain windows may become key, and who receives what is typed
 * into them. Both default to "no" / nil, which is the state a healthy tap
 * requires; only the input module turns them on, and only while the tap path
 * is unavailable. Kept as bookkeeping here so the rule is testable without
 * AppKit: what a test asserts is that focus is NEVER handed over except in
 * that state.
 */
- (void)setAcceptsKeyboardFocus:(BOOL)accepts;
- (void)setKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink;
@property (nonatomic, readonly) BOOL acceptsKeyboardFocus;

@property (nonatomic, readonly) BOOL visible;
/** Screens currently carrying an occluder, in attachment order. */
@property (nonatomic, readonly) NSArray<NSNumber *> *screenIdentifiers;
@end

/*
 * The capture-side seam: "make the stream stop showing this application".
 * Implemented for real against the running capture session; faked in tests,
 * including the case where it never answers at all.
 */
@protocol MacVNCCurtainCaptureExclusion <NSObject>
- (void)setCaptureExcludesOwnApplication:(BOOL)excluded
                              completion:(MacVNCCurtainCompletion)completion;
@end

/*
 * Deferred work, injectable so the timeout is testable without waiting for it.
 */
@protocol MacVNCCurtainScheduler <NSObject>
- (void)afterNanoseconds:(uint64_t)nanoseconds performBlock:(dispatch_block_t)block;
@end

/*
 * The production scheduler: dispatch_after on the main queue. Published rather
 * than private because the controller that decides when a curtain should be up
 * needs the same seam, and two copies of "dispatch_after on the main queue"
 * is one too many.
 */
@interface MacVNCCurtainMainQueueScheduler : NSObject <MacVNCCurtainScheduler>
@end

typedef NS_ENUM(NSInteger, MacVNCCurtainState) {
    MacVNCCurtainStateDown = 0,
    MacVNCCurtainStateRaising,
    MacVNCCurtainStateUp,
    MacVNCCurtainStateLifting,
};

/*
 * The curtain: the window set, the capture exclusion, and the ordering between
 * them (note 3 above). Nothing raises it yet.
 */
@interface MacVNCCurtain : NSObject
- (instancetype)initWithWindowSet:(MacVNCCurtainWindowSet *)windowSet
                        exclusion:(id<MacVNCCurtainCaptureExclusion>)exclusion
                        scheduler:(id<MacVNCCurtainScheduler>)scheduler
               timeoutNanoseconds:(uint64_t)timeoutNanoseconds;

/*
 * The production wiring: AppKit windows over every NSScreen, the running
 * capture session as the exclusion, the main queue as the scheduler. Creates
 * no window and touches no capture until -raiseWithCompletion: is called.
 */
+ (instancetype)curtainWithDefaultSeams;

/*
 * Swap the filter, then show the windows. `completion` runs on the main thread
 * with NO on any failure, including the swap timing out - and after a failure
 * the curtain is DOWN, never half-raised. Raising an already-up curtain
 * succeeds without doing anything; a raise while another transition is in
 * flight fails rather than queueing.
 */
- (void)raiseWithCompletion:(MacVNCCurtainCompletion)completion;

/*
 * Hide the windows, then restore the filter - the exact reverse. The windows
 * are already down by the time the filter request is issued, so a failing or
 * timing-out restore still leaves the local user seeing their screen; that is
 * the direction this asymmetry deliberately fails in.
 */
- (void)liftWithCompletion:(MacVNCCurtainCompletion)completion;

@property (nonatomic, readonly) MacVNCCurtainState state;
@property (nonatomic, readonly) MacVNCCurtainWindowSet *windowSet;
@end
