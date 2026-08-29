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
 * input and decides nothing about when a curtain should be up: what raises and
 * lifts it is MacVNCCurtainController, over the one seam this API is
 * deliberately programmatic and idempotent for.
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
 *    ORDER THEM OUT FIRST and drop them back to the armed alpha, restore the
 *    filter after. (Ordering out is the step that gives the local user their
 *    screen back, so it goes first; dropping the alpha behind it is what makes
 *    the next raise arm from a known state rather than inherit this one's.)
 *    Both orders keep the same invariant - nothing the local user can see is
 *    ever in the stream, and the stream is never excluding an application whose
 *    curtain is not up. The filter is swapped with
 *    `-[SCStream updateContentFilter:completionHandler:]` on the RUNNING
 *    stream; stopping and restarting it would drop frames and re-run the
 *    permission-sensitive start path.
 *
 *    A RAISE THAT COVERS NOTHING IS A FAILED RAISE, AND ONLY A MEASUREMENT CAN
 *    TELL THE DIFFERENCE. Everything above the occluder seam is bookkeeping,
 *    and bookkeeping cannot be wrong about itself: with no screen attached, or
 *    with every window creation refused, `-setCovering:` and `-setVisible:`
 *    are no-ops over an empty set and the state machine still arrives at Up -
 *    a curtain that reports SUCCESS while covering NOTHING, which is exactly
 *    what a live differential measurement found. So the last step of a raise
 *    asks AppKit and the WINDOW SERVER what is actually on the glass
 *    (`-auditCoverageForPhase:`), logs the numbers, and fails the raise
 *    through the same fail-safe path as a failed swap when they do not add up.
 *    The audit runs again at the lift, so the raised interval is bracketed by
 *    two timestamped measurements rather than by one claim.
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

/*
 * PUSH EVERY WINDOW CHANGE TO THE WINDOW SERVER, NOW.
 *
 * `-[NSWindow setAlphaValue:]` records the value on the NSWindow object at
 * once and hands the window-server half of the change to the current
 * (implicit) CoreAnimation transaction, which commits at the END of a main
 * run-loop pass. Everything this module does happens inside ONE pass - arm,
 * swap the filter, cover, measure - so without this call the compositor is
 * still showing the previous alpha when the curtain believes it is up.
 *
 * That is not a deduction, it is the measured behaviour, on this machine, on a
 * borderless non-opaque window at NSScreenSaverWindowLevel (window server
 * alpha read back with CGWindowListCopyWindowInfo):
 *
 *   after -setAlphaValue:0.999          AppKit 0.99900   server 0.00392
 *   after -displayIfNeeded               AppKit 0.99900   server 0.00392
 *   after [CATransaction flush]          AppKit 0.99900   server 0.99900
 *   after a run-loop turn                AppKit 0.99900   server 0.99900
 *   ...and the same inside a main-QUEUE block, which is how a raise resolves.
 *
 * Drawing is NOT the missing step (line two): the pixels were never the
 * problem, the window's compositing alpha was. And a live run produced exactly
 * line one - "alpha=0.99900 ... window server alpha=0.00392" - while every
 * state machine believed the curtain was up, which is the whole reason the
 * occluder set now commits before it returns from any change.
 */
void macVNCCurtainCommitWindowChanges(void);

/*
 * The commit, as an injectable seam.
 *
 * Installing a block replaces the window-server commit; nil restores it. It
 * exists because the RULE worth testing - "the occluder set commits after
 * every change it makes" - is otherwise reachable only through a window
 * server, and a test that needs one is a test that would put a black window on
 * somebody's screen.
 */
typedef void (^MacVNCCurtainWindowCommit)(void);
void macVNCCurtainSetWindowCommit(MacVNCCurtainWindowCommit commit);

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

/*
 * Whether the occluders that are ordered in actually COVER anything: YES is
 * MACVNC_CURTAIN_ALPHA, NO is the armed alpha of note 4. Separate from
 * visibility because the raise needs a window that exists and is on screen
 * while still showing the local user their own desktop - that is the whole
 * reason the exclusion can be armed at all (note 1).
 */
- (void)setOccludersCovering:(BOOL)covering;

/*
 * The focus half: who may hold the local keyboard, and where what is typed
 * into a curtain window goes. The input module owns the decision; this is the
 * delivery.
 */
- (void)setOccludersAcceptKeyboardFocus:(BOOL)accepts;
- (void)setOccludersKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink;

/*
 * MEASUREMENT, not bookkeeping: what AppKit and the window server say about
 * this screen's occluder RIGHT NOW, as one loggable line, and - through
 * `reason` - whether those numbers add up to a covered screen (nil) or not.
 *
 * Asked only while the occluders are supposed to be COVERING, so "it sits at
 * the arming alpha" is a failure here rather than a state. The window server's
 * half is what makes this evidence: AppKit reports back what this process
 * asked for, and the question is whether the compositor agreed.
 *
 * An implementation that models no real window answers a line and a nil
 * reason: nothing to measure is not a failure to cover, and the bookkeeping
 * half of the audit (a screen with no occluder at all) still applies to it.
 */
- (NSString *)occluderReportForScreen:(NSNumber *)identifier
                        failureReason:(NSString **)reason;

/*
 * NOTHING HERE IS @optional, AND THAT IS THE POINT.
 *
 * The four methods above were optional so that a test fake could model windows
 * but not opacity, or windows but not focus. The cost was four
 * -respondsToSelector: branches on the path that RAISES the curtain - four
 * production branches that are always taken in the field, since the single
 * shipped implementation (MacVNCCurtainScreenOccluders) implements all four,
 * and that are exercised in the other direction only by fakes. A fake that
 * needs to ignore one of these implements it and does nothing, which costs a
 * test one line and the raise path nothing at all.
 */
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

/*
 * Says out loud what every occluder IS, and answers whether this curtain is
 * really covering: nil when every ATTACHED screen has an occluder that AppKit
 * and the window server both report as on screen, at the covering alpha, over
 * that screen's whole frame - and otherwise the first reason it does not.
 *
 * One line per screen goes to the log under `phase`, because "the state
 * machine says Up" is not evidence and a single run of the app has to be able
 * to settle what no amount of reading the code can. Nothing secret is logged:
 * geometry, alpha, level and window numbers only.
 *
 * Call it only when the curtain is supposed to be covering; it is the raise's
 * last step and the lift's first.
 */
- (NSString *)auditCoverageForPhase:(NSString *)phase;

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
 * them (note 3 above). MacVNCCurtainController is what raises and lifts it.
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
 * Arm the windows (invisible, note 4), swap the filter, make the windows
 * opaque - and only report success once the windows have been MEASURED to be
 * covering every attached screen (note 3). `completion` runs on the main
 * thread with NO on any failure, including the swap timing out and the
 * measurement disagreeing with the bookkeeping - and after a failure the curtain is DOWN with
 * its windows ordered out again, never half-raised and never having been
 * visible to either party. Raising an already-up curtain succeeds without doing
 * anything; a raise while another transition is in flight fails rather than
 * queueing.
 */
- (void)raiseWithCompletion:(MacVNCCurtainCompletion)completion;

/*
 * Order the windows out and drop them back to the armed alpha, then restore
 * the filter - the reverse of the raise, windows before filter. The windows
 * are gone by the time the filter request is issued, so a failing or
 * timing-out restore still leaves the local user seeing their screen; that is
 * the direction this asymmetry deliberately fails in.
 */
- (void)liftWithCompletion:(MacVNCCurtainCompletion)completion;

@property (nonatomic, readonly) MacVNCCurtainState state;
@property (nonatomic, readonly) MacVNCCurtainWindowSet *windowSet;
@end
