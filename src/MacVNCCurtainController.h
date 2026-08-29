#pragma once

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <string.h>

#import "MacVNCCurtainWindow.h"   /* MacVNCCurtainCompletion, ...Scheduler */

/*
 * The one place that answers "should the curtain be up".
 *
 * The screen half (MacVNCCurtainWindow) knows how to raise and lift; the way
 * back in (MacVNCCurtainPolicy) knows whether what was typed lifts it; the tap
 * (MacVNCCurtainInput) knows how to swallow input. NONE of them decides WHEN. That
 * decision is what this module owns, and it owns it above five injected seams -
 * the curtain, the input suppression, the capture health, the secret and the
 * clock - so every rule below is a unit test with no device, no tap, no window,
 * no capture stream and no real time.
 *
 * The rules, and why each one is what it is:
 *
 * 1. THE RAISE IS EDGE-TRIGGERED, on the transition to a FIRST authenticated
 *    client, and on nothing else. A level-triggered raise ("conditions permit,
 *    so put it up") makes the escape hatch a no-op: the local user types the
 *    password, the curtain lifts, the next re-evaluation sees a client still
 *    connected and raises it straight back. Every other input to this object
 *    can therefore only LIFT. Turning the preference on, or a stream coming
 *    back, never raises anything by itself: the next connection does.
 *
 * 2. A LOCAL LIFT LATCHES DOWN FOR THE REST OF THE APP RUN. Latching only
 *    until the next connection would let whoever holds the VNC password
 *    re-blind the person at the machine by reconnecting in a loop, which is
 *    the same lockout the escape hatch exists to prevent. Nothing clears the
 *    latch; quitting the app does, which is a thing only the LOCAL user can do
 *    (the remote party cannot make the local user stop being latched out of
 *    being blinded).
 *
 * 3. A LIVE STREAM PLUS AN AUTHENTICATED CLIENT IS A CONTINUOUSLY ENFORCED
 *    INVARIANT, not a raise-time precondition. The stream can die AFTER the
 *    raise - it can also be REBUILT after a server stop/start, and a rebuilt
 *    stream carries the default filter again, i.e. it no longer excludes us -
 *    and either way the local user is looking at black while the remote party
 *    sees nothing, or worse, sees the curtain. So the conditions are re-checked
 *    on every event AND on a heartbeat, and the curtain comes down the moment
 *    one of them stops holding.
 *
 * 4. WITHOUT INPUT SUPPRESSION THERE IS NO CURTAIN. A controller with no
 *    suppression seam refuses to raise. A black screen with a live keyboard is
 *    the worst state this feature can reach (keys land in applications nobody
 *    can see), so "the tap is not here yet" and "the tap cannot see keys" get
 *    the same answer: stay down.
 *
 * 5. RAISED STATE NEVER PERSISTS. This object stores nothing; a fresh
 *    controller is DOWN, and since the only raise edge is a client arriving,
 *    nothing can raise at launch.
 *
 * THREADING: every method must be called on the MAIN thread, because a raise
 * ends in ordering NSWindows in. The server core's client-count changes arrive
 * on LibVNCServer client threads and its stop can run on the capture stop
 * queue, so whoever wires those up must hop to the main queue first.
 */

/*
 * The heartbeat that turns rule 3 into something continuous.
 *
 * One second is short enough that a dead stream is a blink rather than a
 * session, and long enough to cost nothing: each beat is a handful of atomic
 * reads and one password comparison.
 */
#define MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS (1ull * 1000ull * 1000ull * 1000ull)

/*
 * A beat that arrives THIS much later than the previous one means time we did
 * not observe: the process was stopped (SIGSTOP, a debugger), the machine
 * slept, or the main queue was wedged for seconds. In all three the world
 * behind the curtain moved without us - the display may have slept and woken,
 * the session may have been switched away and back, WindowServer may have
 * disabled a tap for timing out - and fact 7 of the plan says only the SCREEN
 * cannot fail open by itself. So an unobserved gap lifts, rather than being
 * treated as a beat that merely ran late.
 */
#define MACVNC_CURTAIN_HEARTBEAT_STALL_NANOSECONDS (5ull * 1000ull * 1000ull * 1000ull)

/*
 * The curtain, as this module needs it: raise, lift, nothing else.
 * MacVNCCurtain conforms; a test drives a fake that can answer late, fail, or
 * not answer at all.
 *
 * THE CONTRACT AN IMPLEMENTER MUST KEEP: every completion is invoked EXACTLY
 * ONCE, on the main thread, whatever happens - including when the underlying
 * request fails, times out or is superseded, and including when the surface
 * itself is deallocated mid-transition (which is why -[MacVNCCurtain dealloc]
 * answers its pending completion rather than dropping it). A completion that
 * never arrives leaves this controller with a raise permanently in flight:
 * local input stays suppressed, nothing is on screen, and no heartbeat is
 * armed to notice - the one state it cannot recover from by itself. Bounding
 * that wait belongs to the surface, which owns the timeout, not here, so that
 * the deadline has exactly one owner.
 *
 * A raise may legitimately answer NO SYNCHRONOUSLY - MacVNCCurtain refuses a
 * raise while a lift is still in flight (its restore can take up to
 * MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS), so a viewer reconnecting
 * within about two seconds of a lift gets no curtain. That is a refusal, not
 * an error: this controller undoes the input suppression it had just armed and
 * waits for the next first-client edge.
 */
@protocol MacVNCCurtainSurface <NSObject>
- (void)raiseWithCompletion:(MacVNCCurtainCompletion)completion;
- (void)liftWithCompletion:(MacVNCCurtainCompletion)completion;
@end

/*
 * The tap's seam, defined here so the next task has one shape to fit rather
 * than a shape to invent.
 *
 * -beginSuppressingInput returns NO for every reason the tap must not be
 * trusted (no Accessibility trust, CGEventTapCreate failed, or the keyboard
 * bits were silently cleared from the effective mask), and NO means the
 * curtain does NOT go up. That is the whole contract: this module never asks
 * why, it only refuses to blind someone whose keyboard still works.
 *
 * -endSuppressingInput is idempotent and MUST NOT BLOCK INDEFINITELY - which
 * is a weaker promise than "does not block", and the weaker one is the true
 * one. It is called on every lift, including the ones that happen because
 * something is already wrong, and the production implementation
 * (MacVNCCurtainInput, over MacVNCCurtainEventTap) joins two threads on the
 * CALLER'S thread - which is the main one - with a 2 s deadline each, so the
 * honest bound is about 4 seconds in the worst case and microseconds in every
 * case that is not already a wedge. What makes that acceptable is the ORDER:
 * the curtain's windows are ordered out before this is called, so the local
 * user has their screen back before the wait starts. What it rules out is
 * calling the lift from anything that must stay responsive within that bound.
 */
@protocol MacVNCCurtainInputSuppression <NSObject>
- (BOOL)beginSuppressingInput;
- (void)endSuppressingInput;
@end

/*
 * What the capture side must still be true for a raised curtain to be honest.
 *
 * Both are polled rather than pushed, because the interesting failures are the
 * ones nobody reports: a session rebuilt by a server restart drops the
 * exclusion without any error at all.
 */
@protocol MacVNCCurtainCaptureHealth <NSObject>
/** At least one capture stream exists right now. */
- (BOOL)captureIsLive;
/** The live streams are still excluding THIS application - what the raise
 *  established, still true. NO after a session rebuild. */
- (BOOL)captureExcludesOwnApplication;
@end

/*
 * The secret that lifts the curtain, re-read rather than remembered.
 *
 * Deliberately injected with no default: the only correct secret is the one
 * the RUNNING server authenticates against, and that may have come from
 * defaults, from the environment or from MACVNC_PASSWORD_FILE. Guessing it
 * here would arm the escape hatch with a password that does not open it -
 * which is the lockout this whole feature is built around avoiding.
 *
 * Returns a +1 reference (the `copy` naming is the ownership contract) or nil
 * when there is no password, which is a refusal to raise.
 */
@protocol MacVNCCurtainSecretSource <NSObject>
- (NSData *)copyCurtainSecret;
@end

/*
 * The counterpart of -copyCurtainSecret: release it, and WIPE it first.
 *
 * Every reader of the secret makes a fresh cleartext copy - the controller
 * does it on every heartbeat while the curtain is up - so plain -release would
 * leave a readable password in freed heap for the allocator to hand to
 * somebody else. The wipe happens only when the source handed back storage the
 * caller owns outright (NSMutableData, which the production source returns);
 * an immutable object may be shared with the source itself and is not ours to
 * scribble on, so it is released untouched rather than corrupted.
 *
 * nil is accepted, because "there is no password" is a normal answer here.
 *
 * Inline, next to the protocol whose contract it completes: both readers of a
 * secret (this controller and the event tap) need it, and they are
 * deliberately independent modules - the tap never links the controller - so a
 * shared definition would otherwise have to invent a link edge between them.
 *
 * NS_RELEASES_ARGUMENT states the ownership transfer in the type system rather
 * than in this comment: without it the static analyzer sees a +1 from
 * -copyCurtainSecret going into a function and reports every call site as a
 * leak, which would train the reader to ignore analyzer output on exactly the
 * paths that handle the password.
 */
static inline void macVNCCurtainDiscardSecret(NSData *NS_RELEASES_ARGUMENT secret)
{
    if (!secret)
        return;
    /* The length test is not an optimisation: -mutableBytes may answer NULL
       for an empty NSMutableData, and memset(NULL, 0, 0) is undefined by the
       letter of the standard even though every implementation ignores it. An
       empty secret cannot occur in production (the core refuses to arm without
       a password) which is exactly why it would never be noticed here. */
    if (secret.length > 0 && [secret isKindOfClass:[NSMutableData class]])
        memset([(NSMutableData *)secret mutableBytes], 0, secret.length);
    [secret release];
}

/*
 * A monotonic clock, injected so "the heartbeat arrived five seconds late" is
 * a test rather than a wait. Nanoseconds, same base as macVNCMonotonicNow().
 */
@protocol MacVNCCurtainClock <NSObject>
- (uint64_t)monotonicNanoseconds;
@end

/*
 * The production clock: macVNCMonotonicNow() behind that protocol.
 *
 * Published rather than kept private for the same reason
 * MacVNCCurtainMainQueueScheduler is, one header over: the event tap's own
 * production wiring needs exactly this seam, and two copies of "return
 * macVNCMonotonicNow()" is one too many - the second one is where a future
 * change to what "now" means would silently fail to arrive.
 */
@interface MacVNCCurtainMonotonicClock : NSObject <MacVNCCurtainClock>
@end

@interface MacVNCCurtainController : NSObject

- (instancetype)initWithCurtain:(id<MacVNCCurtainSurface>)curtain
               inputSuppression:(id<MacVNCCurtainInputSuppression>)suppression
                  captureHealth:(id<MacVNCCurtainCaptureHealth>)captureHealth
                   secretSource:(id<MacVNCCurtainSecretSource>)secretSource
                      scheduler:(id<MacVNCCurtainScheduler>)scheduler
                          clock:(id<MacVNCCurtainClock>)clock;

/*
 * Production wiring: the running capture session's health, the main queue and
 * the monotonic clock. Three things stay caller-supplied, each for its own
 * reason.
 *
 * THE CURTAIN, because its window set is ALSO the event tap's focus seam and
 * there must be exactly ONE of it. A factory that built its own would give the
 * tap a window set whose windows nobody ever shows, so the one path the local
 * user has while the tap is unavailable - typing into the curtain window -
 * would lead nowhere.
 *
 * THE SUPPRESSION, because a nil one means "never raise" (rule 4) and because
 * the object that implements it must be constructed with THIS controller as
 * its observer: it reports secure input, and this controller lifting on that
 * report is what makes the tap's focus hand-over safe.
 *
 * THE SECRET, for the reason on MacVNCCurtainSecretSource: only the caller
 * knows whether the running server's password came from defaults, from the
 * environment or from MACVNC_PASSWORD_FILE.
 */
+ (instancetype)controllerWithDefaultSeamsCurtain:(MacVNCCurtain *)curtain
                                 inputSuppression:(id<MacVNCCurtainInputSuppression>)suppression
                                     secretSource:(id<MacVNCCurtainSecretSource>)secretSource;

/* ------------------------------------------------------------------ */
/* Conditions. Any of them turning false lifts; none of them raises.   */
/* ------------------------------------------------------------------ */

- (void)setCurtainPreferenceEnabled:(BOOL)enabled;
- (void)setServerRunning:(BOOL)running;

/*
 * Authenticated, update-receiving clients. THE raise edge: 0 -> non-zero, and
 * only that. A second viewer arriving is not an edge, so a curtain the local
 * user lifted cannot be re-raised by connecting one more time.
 */
- (void)setAuthenticatedClientCount:(NSUInteger)count;

/*
 * Secure Event Input, observed by the tap on its own thread. While it is on,
 * keyboard events are withheld from session taps: local keys are NOT
 * suppressed and the password the local user types goes into whatever app has
 * focus - which the remote party is watching. Hence: lift.
 */
- (void)setSecureInputActive:(BOOL)active;

/*
 * The local session being usable at all: NO on screensaver start, display
 * sleep and session resign (fast user switching), YES on their inverses. One
 * flag rather than three, because the curtain's answer to all three is the
 * same and the difference belongs in the glue that observes them.
 */
- (void)setLocalSessionActive:(BOOL)active;

/* ------------------------------------------------------------------ */
/* Events. Each one can only lift.                                     */
/* ------------------------------------------------------------------ */

/** -[SCStreamDelegate stream:didStopWithError:], or any capture failure. */
- (void)noteCaptureStreamStopped;
/** The stored password may have been changed or cleared: re-read and compare. */
- (void)noteSecretMayHaveChanged;
/** The escape hatch fired: lift, and LATCH DOWN for the rest of this run. */
- (void)noteLocalUnlockAccepted;
/** The tap died and could not be re-established. */
- (void)noteInputSuppressionUnavailable;
/** -[NSApplicationDelegate applicationWillTerminate:]. Nothing raises after. */
- (void)noteApplicationWillTerminate;

/* Whether the curtain is up, as this object believes it. Never persisted, and
 * never true for a controller that has just been created. */
@property (nonatomic, readonly) BOOL curtainRaised;
/* Whether a local lift has latched this run down for good (rule 2). */
@property (nonatomic, readonly) BOOL latchedDownForThisRun;

@end
