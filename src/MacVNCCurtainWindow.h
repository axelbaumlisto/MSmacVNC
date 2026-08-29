#pragma once

#import <Foundation/Foundation.h>
#include <stdbool.h>
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
 * 1. THE FILTER EXCLUDES OUR APPLICATION, NOT OUR WINDOWS - BUT NAMING
 *    OURSELVES STILL NEEDS A WINDOW TO EXIST.
 *    `-[SCContentFilter initWithDisplay:excludingApplications:exceptingWindows:]`
 *    (SCStream.h:174-180) names an SCRunningApplication, and that object can
 *    only be obtained from an SCShareableContent discovery. A live run settled
 *    what the plan assumed away: with an authenticated client, 797 delivered
 *    frames and the `onScreenWindowsOnly:NO` discovery variant, this process
 *    was STILL absent from `applications`, so every raise refused with
 *    "application no". `applications` lists the owners of shareable CONTENT,
 *    and this LSUIElement app owns no window ScreenCaptureKit will count while
 *    its only UI is a status item.
 *
 *    So the exclusion is NOT order-independent after all. The raise now orders
 *    a curtain window in FIRST, in a state neither party can see (note 4), and
 *    only then asks for the exclusion. What survives from the original
 *    argument is the rest of it: naming the APPLICATION still survives window
 *    recreation, so display hot-plug stays a pure window-creation problem
 *    instead of a filter round trip, and the swap still happens before the
 *    curtain becomes opaque, so the remote viewer never sees black. The cost
 *    is unchanged: our Preferences window leaves the stream while the curtain
 *    is up.
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
 *    Raise: ARM the windows (order them in, invisible - note 4), swap the
 *    filter, and only after the swap reports success make them opaque. Lift:
 *    make them transparent and order them out FIRST, restore the filter after.
 *    Both orders keep the same invariant - nothing the local user can see is
 *    ever in the stream, and the stream is never excluding an application whose
 *    curtain is not up. The filter is swapped with
 *    `-[SCStream updateContentFilter:completionHandler:]` on the RUNNING
 *    stream; stopping and restarting it would drop frames and re-run the
 *    permission-sensitive start path.
 *
 *    A swap that never reports back is treated as FAILURE: MacVNCCurtain arms
 *    a timeout (MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS) alongside the
 *    request and, whichever arrives first wins, resolves exactly once. On
 *    failure the windows are ordered out WHILE STILL INVISIBLE and a
 *    best-effort un-exclusion is sent, so neither party ever saw anything and
 *    a late success cannot leave the stream permanently excluding us.
 *
 * 4. THE ARMED STATE IS A WINDOW NEITHER PARTY CAN SEE.
 *    Between "ordered in" and "opaque" the curtain sits at
 *    MACVNC_CURTAIN_ARMING_ALPHA, which exists only so that this process owns a
 *    window ScreenCaptureKit will count (note 1). It must therefore be
 *    non-zero - a window drawn with alpha 0 is a plausible thing for a window
 *    server to skip - and small enough to be invisible to BOTH sides, since
 *    the exclusion is not in place yet and the remote viewer is watching this
 *    same desktop. 1/255 is the largest value that cannot change an 8-bit
 *    channel by more than one level: what composites is (1 - a) * L, so the
 *    worst case is pure white, 255 - 255/255 = 254. One level over one frame
 *    or two, on both sides, and NO black frame for the remote viewer, which is
 *    what the ordering exists to avoid.
 */

/* See note 2 above for the derivation. */
#define MACVNC_CURTAIN_ALPHA 0.999

/* See note 4 above: visible to ScreenCaptureKit, invisible to both humans. */
#define MACVNC_CURTAIN_ARMING_ALPHA (1.0 / 255.0)

/*
 * The alpha one occluder window is drawn at in each state - the ONLY place the
 * two constants above are turned into a window property.
 *
 * A one-line function rather than a literal at the call site because that call
 * site is inside an AppKit NSWindow subclass, which no test can drive without a
 * window server; published here, the mapping is checkable, and "armed" cannot
 * quietly come to mean "opaque" - which would blind the local user (and the
 * remote viewer) BEFORE the exclusion is in place, i.e. exactly the failure the
 * ordering exists to avoid.
 */
double macVNCCurtainOccluderAlpha(bool covering);

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
 * Whether the occluders that are ordered in actually COVER anything: YES is
 * MACVNC_CURTAIN_ALPHA, NO is the armed alpha of note 4. Separate from
 * visibility because the raise needs a window that exists and is on screen
 * while still showing the local user their own desktop - that is the whole
 * reason the exclusion can be armed at all (note 1).
 *
 * Optional for the same reason as the focus pair below: an occluder set that
 * does not implement it models windows but not their opacity, and "ordered in
 * but not covering" is then indistinguishable from "ordered in" - which is
 * exactly what a test of the pre-arming bookkeeping wants.
 */
- (void)setOccludersCovering:(BOOL)covering;

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
 * also re-asserts the covering alpha and then visibility - in that order, so a
 * window created for a newly attached screen is already opaque when it is
 * ordered in rather than showing that screen uncurtained for a frame. That one
 * call IS the exposure window, because application-level exclusion already
 * covers whatever this process creates.
 */
- (void)synchronizeWithAttachedScreens;

/*
 * Orders every occluder in or out. Idempotent, and INDEPENDENT of -setCovering:
 * below: "visible" here means "ordered in", which during the raise deliberately
 * means "on screen and invisible to everyone".
 */
- (void)setVisible:(BOOL)visible;

/*
 * Whether the occluders that are ordered in actually hide the screen. NO is the
 * armed state - a window that exists for ScreenCaptureKit's benefit and for
 * nobody else's. Idempotent, and always false while the curtain is DOWN.
 */
- (void)setCovering:(BOOL)covering;
@property (nonatomic, readonly) BOOL covering;

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
 * Arm the windows (invisible, note 4), swap the filter, and only then make the
 * windows opaque. `completion` runs on the main thread with NO on any failure,
 * including the swap timing out - and after a failure the curtain is DOWN with
 * its windows ordered out again, never half-raised and never having been
 * visible to either party. Raising an already-up curtain succeeds without doing
 * anything; a raise while another transition is in flight fails rather than
 * queueing.
 */
- (void)raiseWithCompletion:(MacVNCCurtainCompletion)completion;

/*
 * Make the windows transparent and order them out, then restore the filter -
 * the exact reverse. The windows are gone by the time the filter request is
 * issued, so a failing or timing-out restore still leaves the local user seeing
 * their screen; that is the direction this asymmetry deliberately fails in.
 */
- (void)liftWithCompletion:(MacVNCCurtainCompletion)completion;

@property (nonatomic, readonly) MacVNCCurtainState state;
@property (nonatomic, readonly) MacVNCCurtainWindowSet *windowSet;
@end
