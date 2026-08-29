#import "MacVNCCurtainController.h"

#import "FirstFrameBudget.h"
#import "MacVNCCaptureSession.h"
#import "MacVNCCurtainPolicy.h"

#include <assert.h>
#include <string.h>

/* The one refusal reason that is not worth a log line (see
   -raiseOnFirstClientEdge). Named rather than repeated, so the test for "is
   this THAT reason" cannot drift from the string the reason is built with. */
static NSString * const MacVNCCurtainReasonPreferenceOff =
    @"curtain mode is switched off";

/* ------------------------------------------------------------------------- */
/* The production seams.                                                      */
/* ------------------------------------------------------------------------- */

/* MacVNCCurtain already publishes exactly the two methods the surface seam
   needs. Declaring the conformance HERE, rather than in MacVNCCurtainWindow.h,
   keeps the screen half unaware that a controller exists: it is still a module
   anyone can raise and lift by hand. */
@interface MacVNCCurtain (MacVNCCurtainSurface) <MacVNCCurtainSurface>
@end

@implementation MacVNCCurtain (MacVNCCurtainSurface)
@end

@interface MacVNCCurtainSessionHealth : NSObject <MacVNCCurtainCaptureHealth>
@end

@implementation MacVNCCurtainSessionHealth

- (BOOL)captureIsLive
{
    /* SAY WHAT THIS MEANS: "a capturer OBJECT exists", not "a stream is
       delivering frames". macVNCCaptureSessionStopAndWait() stops every
       capturer but does NOT detach the list, so a session that has been
       stopped - the keep-warm stop between viewers, for instance - still
       counts here. It is the cheap half of the invariant; the half that
       notices a stream which stopped or errored is -noteCaptureStreamStopped,
       reported by the delegate, and the half that notices a session rebuilt
       underneath us is -captureExcludesOwnApplication. Reading this alone as
       "the remote viewer is seeing something" would be wrong. */
    return macVNCCaptureSessionCount() > 0;
}

- (BOOL)captureExcludesOwnApplication
{
    return macVNCCaptureSessionSelfExcluded() ? YES : NO;
}

@end

@interface MacVNCCurtainMonotonicClock : NSObject <MacVNCCurtainClock>
@end

@implementation MacVNCCurtainMonotonicClock

- (uint64_t)monotonicNanoseconds
{
    return macVNCMonotonicNow();
}

@end

/* ------------------------------------------------------------------------- */
/* The controller.                                                            */
/* ------------------------------------------------------------------------- */

@implementation MacVNCCurtainController {
    id<MacVNCCurtainSurface> _curtain;                    /* retained */
    id<MacVNCCurtainInputSuppression> _suppression;       /* retained, may be nil */
    id<MacVNCCurtainCaptureHealth> _captureHealth;        /* retained */
    id<MacVNCCurtainSecretSource> _secretSource;          /* retained, may be nil */
    id<MacVNCCurtainScheduler> _scheduler;                /* retained */
    id<MacVNCCurtainClock> _clock;                        /* retained */

    /* Armed at the raise, reset at every lift. This controller never FEEDS the
       policy - the tap does, on its own thread, with its own copy - it uses it
       for the two decisions that belong to "should the curtain be up": arming
       refuses a secret nobody can type, and macVNCCurtainPolicySecretChanged
       answers "is the way back in still the same one". */
    MacVNCCurtainPolicy _policy;

    BOOL _preferenceEnabled;
    BOOL _serverRunning;
    NSUInteger _authenticatedClients;
    BOOL _secureInputActive;
    BOOL _localSessionActive;
    /* Set by a reported stream stop. Scoped to ONE curtain: it is cleared when
       a curtain that was up comes down, and again at every raise edge - a stop
       reported while nothing is raised (the keep-warm capture stop, a stream
       that errored between viewers) must not latch the feature off for the
       rest of the run, and the raise re-asks the live truth one line later
       anyway. What it is for is the window in between: a stream that died
       under THIS curtain must not be forgiven just because the session still
       reports a stream object. */
    BOOL _captureStreamFailed;
    BOOL _latchedDown;
    BOOL _terminating;

    BOOL _raised;
    BOOL _raiseInFlight;
    BOOL _suppressingInput;
    /* Bumped by every raise and every lift. A raise completion or a heartbeat
       carrying an older generation belongs to a transition that is over, and
       is ignored - the same monotonic-token discipline MacVNCCurtain uses, for
       the same reason: the answers arrive from things we do not control. */
    NSUInteger _transitionGeneration;
    uint64_t _lastHeartbeatNanoseconds;
}

- (instancetype)initWithCurtain:(id<MacVNCCurtainSurface>)curtain
               inputSuppression:(id<MacVNCCurtainInputSuppression>)suppression
                  captureHealth:(id<MacVNCCurtainCaptureHealth>)captureHealth
                   secretSource:(id<MacVNCCurtainSecretSource>)secretSource
                      scheduler:(id<MacVNCCurtainScheduler>)scheduler
                          clock:(id<MacVNCCurtainClock>)clock
{
    if ((self = [super init])) {
        _curtain = [curtain retain];
        _suppression = [suppression retain];
        _captureHealth = [captureHealth retain];
        _secretSource = [secretSource retain];
        _scheduler = [scheduler retain];
        _clock = [clock retain];
        macVNCCurtainPolicyReset(&_policy);
        /* A session nobody told us about yet is assumed usable; every other
           condition starts in its refusing state, so nothing can raise before
           it is told the server is up and a client authenticated. */
        _localSessionActive = YES;
    }
    return self;
}

+ (instancetype)controllerWithDefaultSeamsCurtain:(MacVNCCurtain *)curtain
                                 inputSuppression:(id<MacVNCCurtainInputSuppression>)suppression
                                     secretSource:(id<MacVNCCurtainSecretSource>)secretSource
{
    MacVNCCurtainSessionHealth *health =
        [[MacVNCCurtainSessionHealth alloc] init];
    MacVNCCurtainMainQueueScheduler *scheduler =
        [[MacVNCCurtainMainQueueScheduler alloc] init];
    MacVNCCurtainMonotonicClock *clock =
        [[MacVNCCurtainMonotonicClock alloc] init];
    MacVNCCurtainController *controller =
        [[self alloc] initWithCurtain:curtain
                     inputSuppression:suppression
                        captureHealth:health
                         secretSource:secretSource
                            scheduler:scheduler
                                clock:clock];
    [health release];
    [scheduler release];
    [clock release];
    return [controller autorelease];
}

- (void)dealloc
{
    /* A raised curtain cannot reach here: while it is up there is always a
       scheduled heartbeat block, and copying that block retained this object,
       so the last release cannot land mid-curtain. That is deliberate - it is
       the bug -[MacVNCCurtain dealloc] had, where an owner dropped
       mid-transition never heard an answer. */
    [_clock release];
    [_scheduler release];
    [_secretSource release];
    [_captureHealth release];
    [_suppression release];
    [_curtain release];
    macVNCCurtainPolicyReset(&_policy);
    [super dealloc];
}

- (BOOL)curtainRaised
{
    return _raised;
}

- (BOOL)latchedDownForThisRun
{
    return _latchedDown;
}

/* ------------------------------------------------------------------ */
/* The decision.                                                       */
/* ------------------------------------------------------------------ */

/*
 * Everything that must hold for a curtain to be up, expressed as the REASON it
 * may not be and nil when it may. Read on the raise edge AND on every
 * re-evaluation: a raise-time-only check would leave the local user black
 * behind a condition that stopped holding a second later.
 *
 * One list, two callers, and the reason is carried rather than dropped: a
 * refusal nobody can see is the field failure that costs the most to work out,
 * and "the curtain stopped going up and nothing was logged" is the report
 * nobody can act on.
 */
- (NSString *)reasonCurtainMayNotBeUp
{
    if (_latchedDown)
        return @"the local user already lifted it this run";
    if (_terminating)
        return @"the application is terminating";
    if (!_preferenceEnabled)
        return MacVNCCurtainReasonPreferenceOff;
    if (!_serverRunning)
        return @"the server is not running";
    if (_authenticatedClients == 0)
        return @"no authenticated client is connected";
    if (_secureInputActive)
        return @"secure input is active";
    if (!_localSessionActive)
        return @"the local session is not active (screensaver, display sleep or fast user switching)";
    if (_captureStreamFailed)
        return @"the capture stream reported that it stopped";
    return nil;
}

/*
 * The half of the invariant that only the capture side knows. Kept apart from
 * -conditionsPermitCurtain because a raise needs a LIVE stream while the
 * exclusion is only established by the raise itself: asking for it before
 * would refuse every first raise.
 */
- (BOOL)captureInvariantHolds
{
    return [_captureHealth captureIsLive] &&
           [_captureHealth captureExcludesOwnApplication];
}

/* True when the way back in is not the one this curtain was raised with -
 * including "there is no way back in at all", which is what an unarmed policy,
 * a cleared password and a missing secret source all report. */
- (BOOL)secretHasChanged
{
    NSData *secret = _secretSource ? [_secretSource copyCurtainSecret] : nil;
    bool changed = macVNCCurtainPolicySecretChanged(&_policy,
                                                    (const char *)secret.bytes,
                                                    secret.length);
    macVNCCurtainDiscardSecret(secret);
    return changed ? YES : NO;
}

/* ------------------------------------------------------------------ */
/* Raising - the ONE edge.                                             */
/* ------------------------------------------------------------------ */

- (void)raiseOnFirstClientEdge
{
    assert([NSThread isMainThread]);
    if (_raised || _raiseInFlight)
        return;
    /* A stop reported while nothing was raised belonged to no curtain. Clearing
       it HERE, one line before the live truth is asked for again, is what stops
       a keep-warm capture stop between viewers from disabling the feature for
       the rest of the run - silently, since this is a refusal the local user
       cannot see. */
    _captureStreamFailed = NO;

    NSString *blocked = [self reasonCurtainMayNotBeUp];
    if (blocked) {
        /* Every refusal is logged EXCEPT the one that means "nobody asked for
           this feature": with curtain mode off - the shipped default - that
           line would be one log entry per client connection on every server
           running, forever, describing a decision nobody is debugging. The
           other reasons are exactly the ones somebody has to diagnose. */
        if (![blocked isEqualToString:MacVNCCurtainReasonPreferenceOff])
            NSLog(@"macVNC: curtain stays down - %@", blocked);
        return;
    }

    /* Rule 4: no suppression, no curtain. A black screen with a live keyboard
       is worse than no curtain at all, so an absent tap and a tap that cannot
       see keys get the same answer. */
    if (!_suppression) {
        NSLog(@"macVNC: curtain stays down - no input suppression is wired up");
        return;
    }

    if (![_captureHealth captureIsLive]) {
        NSLog(@"macVNC: curtain stays down - no live capture stream to hide from");
        return;
    }

    /* The way back in is armed BEFORE anything is hidden: a policy that
       refuses to arm (empty or missing password) is a curtain with no exit.
       Read LAST of the cheap checks, so a refusal that was already decided
       never pulls the password out of storage at all. */
    NSData *secret = _secretSource ? [_secretSource copyCurtainSecret] : nil;
    bool armed = macVNCCurtainPolicyArm(&_policy, (const char *)secret.bytes,
                                        secret.length);
    macVNCCurtainDiscardSecret(secret);
    if (!armed) {
        NSLog(@"macVNC: curtain stays down - no VNC password to type to lift it");
        return;
    }

    if (![_suppression beginSuppressingInput]) {
        NSLog(@"macVNC: curtain stays down - local input cannot be suppressed");
        macVNCCurtainPolicyReset(&_policy);
        return;
    }
    _suppressingInput = YES;

    _raiseInFlight = YES;
    NSUInteger generation = ++_transitionGeneration;
    /* Copying this block retains `self` (MRC block semantics), so the answer
       can never arrive at a deallocated controller: the transition itself
       keeps this object alive for exactly as long as it is pending. */
    [_curtain raiseWithCompletion:^(BOOL success) {
        [self finishRaiseWithGeneration:generation success:success];
    }];
}

- (void)finishRaiseWithGeneration:(NSUInteger)generation success:(BOOL)success
{
    /* Entered from the curtain's completion, which is a hop out of a
       ScreenCaptureKit callback: this is exactly where a threading mistake
       would originate, so it is checked here rather than assumed. */
    assert([NSThread isMainThread]);
    if (generation != _transitionGeneration)
        return;                    /* a lift already abandoned this raise */
    /* A surface that answers the SAME raise twice - same generation, two
       completions - would otherwise arm a second heartbeat chain, and two
       chains mean two beats per interval forever. The generation guard cannot
       see that; only "there was a raise in flight" can. */
    if (!_raiseInFlight)
        return;
    _raiseInFlight = NO;
    if (!success) {
        NSLog(@"macVNC: curtain was not raised - the capture filter swap failed");
        [self releaseCurtainResources];
        return;
    }

    _raised = YES;
    _lastHeartbeatNanoseconds = [_clock monotonicNanoseconds];
    [self scheduleHeartbeat];
    /* The swap took real time (up to its own timeout), during which the client
       may have gone, the stream may have died and the password may have
       changed. Rule 3 is enforced from the first moment the curtain is up. */
    [self enforceInvariant];
}

/* ------------------------------------------------------------------ */
/* Lifting - every trigger ends here.                                  */
/* ------------------------------------------------------------------ */

- (void)releaseCurtainResources
{
    if (_suppressingInput) {
        [_suppression endSuppressingInput];
        _suppressingInput = NO;
    }
    macVNCCurtainPolicyReset(&_policy);
    _captureStreamFailed = NO;     /* belonged to the curtain that just ended */
}

- (void)liftBecause:(NSString *)reason
{
    if (!_raised && !_raiseInFlight)
        return;

    _raised = NO;
    _raiseInFlight = NO;
    /* Supersedes the raise completion and the heartbeat chain in one move. */
    ++_transitionGeneration;
    NSLog(@"macVNC: lifting the curtain - %@", reason);
    /* The curtain hides its windows synchronously and only then asks the
       stream to carry us again, so by the time this returns the local user has
       their screen back. Input is restored AFTER that, mirroring the raise
       order (suppress, then hide) exactly. */
    [_curtain liftWithCompletion:nil];
    [self releaseCurtainResources];
}

/*
 * Re-evaluates everything a raised curtain depends on. Called from every
 * condition change and from the heartbeat - and it can only ever LIFT. Raising
 * from here would be the level-triggered version this design exists to avoid
 * (rule 1).
 */
- (void)enforceInvariant
{
    if (!_raised && !_raiseInFlight)
        return;
    NSString *blocked = [self reasonCurtainMayNotBeUp];
    if (blocked) {
        [self liftBecause:blocked];
        return;
    }
    if ([self secretHasChanged]) {
        [self liftBecause:@"the VNC password changed or was cleared"];
        return;
    }
    /* Only meaningful once the raise established the exclusion; while it is in
       flight the stream is not excluding us yet, by construction. */
    if (_raised && ![self captureInvariantHolds]) {
        [self liftBecause:@"the capture stream is gone or no longer hides this app"];
        return;
    }
}

/* ------------------------------------------------------------------ */
/* The heartbeat.                                                      */
/* ------------------------------------------------------------------ */

- (void)scheduleHeartbeat
{
    /* NOT a fresh generation: the chain belongs to the raise that started it,
       so a lift retires it by bumping past it, and exactly one beat is ever
       armed at a time. */
    NSUInteger generation = _transitionGeneration;
    [_scheduler afterNanoseconds:MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS
                    performBlock:^{
        [self heartbeatWithGeneration:generation];
    }];
}

- (void)heartbeatWithGeneration:(NSUInteger)generation
{
    /* Entered from the scheduler (dispatch_after in production), the other
       foreign callback into this object. */
    assert([NSThread isMainThread]);
    if (generation != _transitionGeneration || !_raised)
        return;                    /* a beat from a curtain that is over */

    uint64_t now = [_clock monotonicNanoseconds];
    uint64_t elapsed = now >= _lastHeartbeatNanoseconds
                           ? now - _lastHeartbeatNanoseconds
                           : 0;
    _lastHeartbeatNanoseconds = now;
    if (elapsed >= MACVNC_CURTAIN_HEARTBEAT_STALL_NANOSECONDS) {
        [self liftBecause:@"time passed unobserved (sleep, suspension or a "
                          @"stalled main thread)"];
        return;
    }

    [self enforceInvariant];
    if (_raised)
        [self scheduleHeartbeat];
}

/* ------------------------------------------------------------------ */
/* Conditions.                                                         */
/* ------------------------------------------------------------------ */

- (void)setCurtainPreferenceEnabled:(BOOL)enabled
{
    assert([NSThread isMainThread]);
    _preferenceEnabled = enabled;
    [self enforceInvariant];
}

- (void)setServerRunning:(BOOL)running
{
    assert([NSThread isMainThread]);
    _serverRunning = running;
    if (!running)
        _authenticatedClients = 0; /* a stopped server has no clients */
    [self enforceInvariant];
}

- (void)setAuthenticatedClientCount:(NSUInteger)count
{
    assert([NSThread isMainThread]);
    NSUInteger previous = _authenticatedClients;
    _authenticatedClients = count;
    /* THE edge, and the only one. A second viewer arriving (1 -> 2) is not a
       first client, so it cannot re-raise a curtain that came down. */
    if (previous == 0 && count > 0) {
        [self raiseOnFirstClientEdge];
        return;
    }
    [self enforceInvariant];
}

- (void)setSecureInputActive:(BOOL)active
{
    assert([NSThread isMainThread]);
    _secureInputActive = active;
    [self enforceInvariant];
}

- (void)setLocalSessionActive:(BOOL)active
{
    assert([NSThread isMainThread]);
    _localSessionActive = active;
    [self enforceInvariant];
}

/* ------------------------------------------------------------------ */
/* Events.                                                             */
/* ------------------------------------------------------------------ */

- (void)noteCaptureStreamStopped
{
    assert([NSThread isMainThread]);
    _captureStreamFailed = YES;
    [self enforceInvariant];
}

- (void)noteSecretMayHaveChanged
{
    assert([NSThread isMainThread]);
    [self enforceInvariant];
}

- (void)noteLocalUnlockAccepted
{
    assert([NSThread isMainThread]);
    /* Rule 2. Set BEFORE the lift, so nothing in the lift path can decide the
       curtain may go back up, and never cleared again. */
    _latchedDown = YES;
    [self liftBecause:@"the local user typed the password"];
}

- (void)noteInputSuppressionUnavailable
{
    assert([NSThread isMainThread]);
    [self liftBecause:@"local input suppression is no longer available"];
}

- (void)noteApplicationWillTerminate
{
    assert([NSThread isMainThread]);
    _terminating = YES;
    [self liftBecause:@"the application is terminating"];
}

@end
