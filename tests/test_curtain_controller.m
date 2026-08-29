#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCCurtainController.h"
#import "MacVNCCurtainInput.h"

/*
 * "Should the curtain be up" - every transition, with no device, no tap, no
 * window, no capture stream and no real clock.
 *
 * The previous tasks left the dangerous surface manual: the window half could
 * only be exercised by raising a real curtain over a real desktop, and the
 * unlock policy answers a different question. What is tested here is the part
 * that can trap the person standing at the Mac: WHEN black goes up, and every
 * one of the ways it must come back down.
 *
 * The fakes below deliberately model the timing that makes this hard - a raise
 * that answers later (the filter swap really does take milliseconds and may
 * time out), a stream that dies after the raise, a heartbeat that arrives from
 * a curtain that is already over.
 */

/* ---------------------------------------------------------------------- */

@interface FakeCurtainSurface : NSObject <MacVNCCurtainSurface>
/* One shared log across the fakes, so ORDER between the input half and the
   screen half is observed rather than assumed. */
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL answersImmediately;
@property (nonatomic, assign) BOOL answerValue;
@property (nonatomic, retain) NSMutableArray<MacVNCCurtainCompletion> *held;
@property (nonatomic, assign) NSUInteger raiseCount;
@property (nonatomic, assign) NSUInteger liftCount;
/* Runs inside the raise, before it answers: the world moving while the filter
   swap is in flight. */
@property (nonatomic, copy) dispatch_block_t duringRaise;
/* The real curtain establishes the exclusion as part of a successful raise and
   gives it back on a lift; the health fake follows it, so the invariant the
   controller polls is the one a real raise would have produced. */
@property (nonatomic, assign) id health;   /* not owned */
@end

@interface FakeCaptureHealth : NSObject <MacVNCCurtainCaptureHealth>
@property (nonatomic, assign) BOOL live;
@property (nonatomic, assign) BOOL excluding;
@end

@implementation FakeCaptureHealth
- (BOOL)captureIsLive { return _live; }
- (BOOL)captureExcludesOwnApplication { return _excluding; }
@end

@implementation FakeCurtainSurface

- (instancetype)init
{
    if ((self = [super init])) {
        _held = [[NSMutableArray alloc] init];
        _answersImmediately = YES;
        _answerValue = YES;
    }
    return self;
}

- (void)raiseWithCompletion:(MacVNCCurtainCompletion)completion
{
    ++_raiseCount;
    [_log addObject:@"curtain-raise"];
    if (_duringRaise)
        _duringRaise();
    if (!_answersImmediately) {
        if (completion)
            [_held addObject:[[completion copy] autorelease]];
        return;
    }
    if (_answerValue)
        ((FakeCaptureHealth *)_health).excluding = YES;
    if (completion)
        completion(_answerValue);
}

- (void)liftWithCompletion:(MacVNCCurtainCompletion)completion
{
    ++_liftCount;
    [_log addObject:@"curtain-lift"];
    ((FakeCaptureHealth *)_health).excluding = NO;
    if (completion)
        completion(YES);
}

- (void)answerHeldAtIndex:(NSUInteger)index with:(BOOL)success
{
    MacVNCCurtainCompletion completion = [[_held[index] retain] autorelease];
    if (success)
        ((FakeCaptureHealth *)_health).excluding = YES;
    completion(success);
}

- (void)dealloc
{
    [_duringRaise release];
    [_held release];
    [super dealloc];
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeInputSuppression : NSObject <MacVNCCurtainInputSuppression>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL canSuppress;
@property (nonatomic, assign) NSUInteger beginCount;
@property (nonatomic, assign) NSUInteger endCount;
@end

@implementation FakeInputSuppression

- (instancetype)init
{
    if ((self = [super init]))
        _canSuppress = YES;
    return self;
}

- (BOOL)beginSuppressingInput
{
    ++_beginCount;
    [_log addObject:_canSuppress ? @"suppress-begin" : @"suppress-refused"];
    return _canSuppress;
}

- (void)endSuppressingInput
{
    ++_endCount;
    [_log addObject:@"suppress-end"];
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeSecretSource : NSObject <MacVNCCurtainSecretSource>
@property (nonatomic, retain) NSData *secret;
/* How often the password was pulled out of storage: a refusal that was already
   decided must not read it at all. */
@property (nonatomic, assign) NSUInteger reads;
/* EVERY copy ever handed out, kept alive here so a test can read their bytes
   after the callers have finished with them. All of them, not just the last:
   one raise reads the secret twice (arming, then the invariant re-check), and
   a test that looked only at the newest copy would pass with the older one
   left in the clear. */
@property (nonatomic, retain) NSMutableArray<NSMutableData *> *handedOut;
@end

@implementation FakeSecretSource

- (NSData *)copyCurtainSecret
{
    ++_reads;
    if (!_secret)
        return nil;
    /* A FRESH mutable copy per call, exactly like the production source: the
       caller owns the storage outright, which is what makes wiping it legal
       rather than vandalism against whoever else still holds it. */
    NSMutableData *copy = [[NSMutableData alloc] initWithData:_secret];
    if (!_handedOut)
        self.handedOut = [NSMutableArray array];
    [_handedOut addObject:copy];
    return copy;                    /* +1, per the protocol's `copy` naming */
}

- (void)setSecretText:(NSString *)text
{
    self.secret = text ? [text dataUsingEncoding:NSUTF8StringEncoding] : nil;
}

- (void)dealloc
{
    [_secret release];
    [_handedOut release];
    [super dealloc];
}

@end

/* ---------------------------------------------------------------------- */

@interface ManualScheduler : NSObject <MacVNCCurtainScheduler>
@property (nonatomic, retain) NSMutableArray<dispatch_block_t> *pending;
@end

@implementation ManualScheduler

- (instancetype)init
{
    if ((self = [super init]))
        _pending = [[NSMutableArray alloc] init];
    return self;
}

- (void)afterNanoseconds:(uint64_t)nanoseconds performBlock:(dispatch_block_t)block
{
    assert(nanoseconds > 0 && "a heartbeat of zero would spin the main queue");
    if (block)
        [_pending addObject:[[block copy] autorelease]];
}

/** Fires every armed block once; returns how many there were. */
- (NSUInteger)fire
{
    NSArray<dispatch_block_t> *due = [[_pending copy] autorelease];
    [_pending removeAllObjects];
    for (dispatch_block_t block in due)
        block();
    return due.count;
}

- (void)dealloc
{
    [_pending release];
    [super dealloc];
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeClock : NSObject <MacVNCCurtainClock>
@property (nonatomic, assign) uint64_t now;
@end

@implementation FakeClock
- (uint64_t)monotonicNanoseconds { return _now; }
@end

/* ---------------------------------------------------------------------- */

@interface Rig : NSObject
@property (nonatomic, retain) NSMutableArray<NSString *> *log;
@property (nonatomic, retain) FakeCurtainSurface *curtain;
@property (nonatomic, retain) FakeInputSuppression *suppression;
@property (nonatomic, retain) FakeCaptureHealth *health;
@property (nonatomic, retain) FakeSecretSource *secretSource;
@property (nonatomic, retain) ManualScheduler *scheduler;
@property (nonatomic, retain) FakeClock *clock;
@property (nonatomic, retain) MacVNCCurtainController *controller;
@end

@implementation Rig

- (void)dealloc
{
    [_log release];
    [_curtain release];
    [_suppression release];
    [_health release];
    [_secretSource release];
    [_scheduler release];
    [_clock release];
    [_controller release];
    [super dealloc];
}

/* A raised curtain keeps a heartbeat armed, and the block holds the
   controller; leaving one behind would be a retain cycle the leak check finds.
   Terminating first is also the honest end of an app run. */
- (void)finish
{
    [_controller noteApplicationWillTerminate];
    while ([_scheduler fire] > 0)
        ;
    /* A raise the fake never answered still holds the block that captured the
       controller - the real curtain always resolves its pending completion
       (that is what its timeout is for), so this is the fake catching up, not
       an ownership rule the code relies on. */
    [_curtain.held removeAllObjects];
}

@end

/* Everything wired, nothing enabled: no preference, no server, no client. */
static Rig *makeRig(BOOL withSuppression)
{
    Rig *rig = [[[Rig alloc] init] autorelease];
    rig.log = [NSMutableArray array];
    rig.health = [[[FakeCaptureHealth alloc] init] autorelease];
    rig.curtain = [[[FakeCurtainSurface alloc] init] autorelease];
    rig.curtain.log = rig.log;
    rig.curtain.health = rig.health;
    rig.suppression = [[[FakeInputSuppression alloc] init] autorelease];
    rig.suppression.log = rig.log;
    rig.secretSource = [[[FakeSecretSource alloc] init] autorelease];
    [rig.secretSource setSecretText:@"hunter2"];
    rig.scheduler = [[[ManualScheduler alloc] init] autorelease];
    rig.clock = [[[FakeClock alloc] init] autorelease];
    rig.controller = [[[MacVNCCurtainController alloc]
        initWithCurtain:rig.curtain
       inputSuppression:(withSuppression ? rig.suppression : nil)
          captureHealth:rig.health
           secretSource:rig.secretSource
              scheduler:rig.scheduler
                  clock:rig.clock] autorelease];
    return rig;
}

/* Everything a curtain needs EXCEPT the client that raises it. */
static Rig *readyRig(void)
{
    Rig *rig = makeRig(YES);
    rig.health.live = YES;
    [rig.controller setCurtainPreferenceEnabled:YES];
    [rig.controller setServerRunning:YES];
    return rig;
}

static Rig *raisedRig(void)
{
    Rig *rig = readyRig();
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    return rig;
}

/* ---------------------------------------------------------------------- */

static void testNothingRaisesAtLaunch(void)
{
    Rig *rig = makeRig(YES);
    assert(!rig.controller.curtainRaised);

    /* Every condition a curtain needs, arriving in any order, still raises
       nothing: only a client can, and none has connected. A controller that
       raised here would be raising at launch on remembered state, which this
       object deliberately has none of. */
    rig.health.live = YES;
    [rig.controller setCurtainPreferenceEnabled:YES];
    [rig.controller setServerRunning:YES];
    [rig.controller setSecureInputActive:NO];
    [rig.controller setLocalSessionActive:YES];
    assert(rig.curtain.raiseCount == 0);
    assert(!rig.controller.curtainRaised);
    assert(rig.suppression.beginCount == 0);

    [rig finish];
}

static void testFirstClientRaisesAndLastClientLifts(void)
{
    Rig *rig = readyRig();

    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 1);
    /* Input is suppressed BEFORE anything is hidden: a black screen with a
       live keyboard is the worst state this feature can reach. */
    assert([rig.log isEqualToArray:(@[ @"suppress-begin", @"curtain-raise" ])]);

    /* A second viewer is not a first client: nothing happens at all. */
    [rig.controller setAuthenticatedClientCount:2];
    assert(rig.curtain.raiseCount == 1);
    assert(rig.suppression.beginCount == 1);
    assert(rig.controller.curtainRaised);

    /* One of two leaving is not "the last client gone" either. */
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 0);

    [rig.controller setAuthenticatedClientCount:0];
    assert(!rig.controller.curtainRaised);
    /* And the mirror of the raise order: the screen comes back first, input
       after it - the reverse of "suppress, then hide". */
    assert([rig.log isEqualToArray:(@[ @"suppress-begin", @"curtain-raise",
                                       @"curtain-lift", @"suppress-end" ])]);
    assert(rig.suppression.endCount == 1);

    [rig finish];
}

static void testRaiseIsEdgeTriggeredNotLevelTriggered(void)
{
    Rig *rig = raisedRig();

    /* Secure input lifts it (the local user's keystrokes would go to the
       focused app, which the remote party is watching). */
    [rig.controller setSecureInputActive:YES];
    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 1);

    /* Now the condition goes away again while the SAME client is still there.
       A level-triggered design would re-raise here, which is what makes the
       escape hatch a no-op: lift, re-evaluate, re-raise. */
    [rig.controller setSecureInputActive:NO];
    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 1);

    /* Nor does another viewer arriving while the first is still there: 1 -> 2
       is not a first client, and a level-triggered design would raise on the
       strength of "a client is connected and everything is fine again". */
    [rig.controller setAuthenticatedClientCount:2];
    assert(rig.curtain.raiseCount == 1);
    assert(!rig.controller.curtainRaised);
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.curtain.raiseCount == 1);

    /* Nor does any other condition being re-asserted raise it. */
    [rig.controller setCurtainPreferenceEnabled:YES];
    [rig.controller setLocalSessionActive:YES];
    [rig.controller setServerRunning:YES];
    [rig.controller noteSecretMayHaveChanged];
    assert(rig.curtain.raiseCount == 1);
    assert(!rig.controller.curtainRaised);

    /* A NEW connection is a new edge, and that one does raise: only the local
       user's own lift latches. */
    [rig.controller setAuthenticatedClientCount:0];
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 2);

    [rig finish];
}

static void testLocalUnlockLatchesDownForTheWholeRun(void)
{
    Rig *rig = raisedRig();

    [rig.controller noteLocalUnlockAccepted];
    assert(!rig.controller.curtainRaised);
    assert(rig.controller.latchedDownForThisRun);
    assert(rig.suppression.endCount == 1);

    /* Reconnecting in a loop is the attack this latch exists for: whoever
       holds the VNC password could otherwise re-blind the local user by
       dropping and re-opening the connection. */
    for (int i = 0; i < 5; ++i) {
        [rig.controller setAuthenticatedClientCount:0];
        [rig.controller setAuthenticatedClientCount:1];
    }
    assert(rig.curtain.raiseCount == 1);
    assert(!rig.controller.curtainRaised);

    /* Not even a full server restart clears it - only quitting the app does,
       and that is a thing only the person at the machine can do. */
    [rig.controller setServerRunning:NO];
    [rig.controller setServerRunning:YES];
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.curtain.raiseCount == 1);
    assert(rig.controller.latchedDownForThisRun);

    [rig finish];
}

static void testRefusesToRaiseWithoutInputSuppression(void)
{
    /* The tap is a later task; until it exists, raising would produce exactly
       the state fact 4 warns about - black screen, live keyboard, keys landing
       in applications nobody can see. */
    Rig *rig = makeRig(NO);
    rig.health.live = YES;
    [rig.controller setCurtainPreferenceEnabled:YES];
    [rig.controller setServerRunning:YES];
    [rig.controller setAuthenticatedClientCount:1];

    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 0);
    /* And it refuses before reading anything: a curtain that is not going up
       has no business pulling the VNC password out of storage. */
    assert(rig.secretSource.reads == 0);

    [rig finish];
}

static void testRefusesWhenTheServerIsNotRunning(void)
{
    Rig *rig = makeRig(YES);
    rig.health.live = YES;
    [rig.controller setCurtainPreferenceEnabled:YES];

    /* Never told a server is up. A client count arriving without a run behind
       it is stale bookkeeping, and hiding the local screen for it would hide
       it for nobody. */
    [rig.controller setAuthenticatedClientCount:1];
    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 0);

    [rig finish];
}

static void testNothingRaisesAfterTermination(void)
{
    Rig *rig = raisedRig();

    [rig.controller noteApplicationWillTerminate];
    assert(!rig.controller.curtainRaised);

    /* Quitting is the local user's own way out of this feature; a client
       arriving during teardown must not blind them on the way. */
    [rig.controller setAuthenticatedClientCount:0];
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.curtain.raiseCount == 1);
    assert(!rig.controller.curtainRaised);

    [rig finish];
}

static void testRefusesWhenTheTapCannotBeArmed(void)
{
    Rig *rig = readyRig();
    rig.suppression.canSuppress = NO;

    [rig.controller setAuthenticatedClientCount:1];
    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 0);
    /* And nothing is left half-armed: no suppression to end, because none was
       established. */
    assert(rig.suppression.endCount == 0);

    [rig finish];
}

static void testRefusesWithoutAUsableSecret(void)
{
    /* No password stored at all, and a password that is present but empty. */
    for (int useEmptyRatherThanMissing = 0; useEmptyRatherThanMissing < 2;
         ++useEmptyRatherThanMissing) {
        Rig *rig = readyRig();
        [rig.secretSource setSecretText:(useEmptyRatherThanMissing ? @"" : nil)];
        [rig.controller setAuthenticatedClientCount:1];
        /* A curtain with no password to type is a black screen with no way
           out; the policy refuses to arm, and the refusal must reach the
           screen rather than being logged and ignored. */
        assert(!rig.controller.curtainRaised);
        assert(rig.curtain.raiseCount == 0);
        assert(rig.suppression.beginCount == 0);
        [rig finish];
    }
}

static void testRefusesWithoutALiveStream(void)
{
    Rig *rig = readyRig();
    rig.health.live = NO;

    [rig.controller setAuthenticatedClientCount:1];
    /* With no stream the remote party sees nothing, so the curtain would hide
       the screen from the local user for nobody's benefit. */
    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 0);
    assert(rig.suppression.beginCount == 0);
    assert(rig.secretSource.reads == 0);

    [rig finish];
}

static void testStreamFailureDoesNotPoisonTheRun(void)
{
    Rig *rig = raisedRig();

    [rig.controller noteCaptureStreamStopped];
    assert(!rig.controller.curtainRaised);

    /* The failure belonged to THAT curtain. Once the viewer reconnects onto a
       working session, the next first-client edge raises again - remembering a
       dead stream for the rest of the run would silently disable the feature
       after one hiccup. */
    [rig.controller setAuthenticatedClientCount:0];
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 2);

    [rig finish];
}

static void testStreamStopReportedWhileDownDoesNotPoisonTheRun(void)
{
    Rig *rig = readyRig();

    /* The mirror of the case above, and the one that actually happens: with no
       viewer connected the capture stop runs on its own (the keep-warm window
       elapses, or the stream errors between sessions), so the report arrives
       while nothing is raised. If that latched, curtain mode would be dead for
       the rest of the app run - and the refusal is one the local user cannot
       see, because a curtain that never goes up looks exactly like a curtain
       nobody asked for. */
    [rig.controller noteCaptureStreamStopped];
    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 0);

    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 1);

    [rig finish];
}

static void testServerRestartRaisesForTheNextClient(void)
{
    Rig *rig = raisedRig();

    /* A server stop takes every client with it, so the count this object holds
       must go with it too - otherwise the first client of the NEXT run is not
       a 0 -> 1 transition and nothing would ever raise again. */
    [rig.controller setServerRunning:NO];
    assert(!rig.controller.curtainRaised);

    [rig.controller setServerRunning:YES];
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);
    assert(rig.curtain.raiseCount == 2);

    [rig finish];
}

/* Every lift trigger, one at a time. Each runs against its own freshly raised
   curtain, so a trigger cannot pass because another one already lifted. */
static void testEveryLiftTriggerLifts(void)
{
    NSDictionary<NSString *, void (^)(Rig *)> *triggers = @{
        @"last client gone" : ^(Rig *rig) {
            [rig.controller setAuthenticatedClientCount:0];
        },
        @"server stopped" : ^(Rig *rig) {
            [rig.controller setServerRunning:NO];
        },
        @"application terminating" : ^(Rig *rig) {
            [rig.controller noteApplicationWillTerminate];
        },
        @"stream stopped or errored" : ^(Rig *rig) {
            [rig.controller noteCaptureStreamStopped];
        },
        @"secret changed" : ^(Rig *rig) {
            [rig.secretSource setSecretText:@"something else"];
            [rig.controller noteSecretMayHaveChanged];
        },
        @"secret cleared" : ^(Rig *rig) {
            [rig.secretSource setSecretText:nil];
            [rig.controller noteSecretMayHaveChanged];
        },
        @"preference switched off" : ^(Rig *rig) {
            [rig.controller setCurtainPreferenceEnabled:NO];
        },
        @"secure input turned on" : ^(Rig *rig) {
            [rig.controller setSecureInputActive:YES];
        },
        @"screensaver, display sleep or session resign" : ^(Rig *rig) {
            [rig.controller setLocalSessionActive:NO];
        },
        @"input suppression lost" : ^(Rig *rig) {
            [rig.controller noteInputSuppressionUnavailable];
        },
    };

    for (NSString *name in triggers) {
        Rig *rig = raisedRig();
        NSUInteger endsBefore = rig.suppression.endCount;
        triggers[name](rig);
        assert(!rig.controller.curtainRaised);
        assert(rig.curtain.liftCount == 1);
        /* Local input comes back with the screen, whatever the reason: a lift
           that left the tap swallowing keys would be the worst half-state. */
        assert(rig.suppression.endCount == endsBefore + 1);
        [rig finish];
    }
}

static void testSecretChangeIsMeasuredOnTheEffectiveBytes(void)
{
    Rig *rig = readyRig();
    [rig.secretSource setSecretText:@"hunter22"];   /* exactly 8 bytes */
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);

    /* VNC's DES auth keys itself from the first 8 bytes, so a 9th character is
       not a credential change - lifting for it would drop the curtain on an
       edit the server itself cannot see. */
    [rig.secretSource setSecretText:@"hunter22-and-more"];
    [rig.controller noteSecretMayHaveChanged];
    assert(rig.controller.curtainRaised);

    /* A change WITHIN those bytes is the real thing: benignly the owner
       rotating their password, adversarially the remote party changing it to
       lock the local user out. */
    [rig.secretSource setSecretText:@"hunter23"];
    [rig.controller noteSecretMayHaveChanged];
    assert(!rig.controller.curtainRaised);

    [rig finish];
}

static void testStreamDeathAfterTheRaiseLifts(void)
{
    Rig *rig = raisedRig();

    /* Nothing reports this: the stream simply stops being live. Without the
       heartbeat the local user would sit in front of a black screen while the
       remote party sees nothing at all. */
    rig.health.live = NO;
    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
    assert([rig.scheduler fire] == 1);

    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 1);
    assert(rig.suppression.endCount == 1);

    [rig finish];
}

static void testSessionRebuildDropsTheExclusionAndLifts(void)
{
    Rig *rig = raisedRig();

    /* A server stop/start rebuilds the capture session, and a rebuilt stream
       carries the DEFAULT filter again: still live, no longer excluding us. The
       windows would then be IN the stream - the one state the raise/lift
       ordering exists to prevent, and one nothing reports. */
    rig.health.excluding = NO;
    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
    assert([rig.scheduler fire] == 1);

    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 1);

    [rig finish];
}

static void testHeartbeatKeepsBeatingWhileHealthy(void)
{
    Rig *rig = raisedRig();

    for (int i = 0; i < 8; ++i) {
        rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
        /* Exactly ONE beat is ever armed: a chain that forked would multiply
           with every raise over a long-running server. */
        assert([rig.scheduler fire] == 1);
        assert(rig.controller.curtainRaised);
    }
    assert(rig.curtain.liftCount == 0);

    [rig finish];
}

static void testUnobservedTimeLifts(void)
{
    Rig *rig = raisedRig();

    /* The process was stopped, the machine slept, or the main queue was wedged
       for seconds. Everything we can ask still says "fine", because all of it
       is a snapshot of NOW - what we cannot ask about is the gap. */
    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_STALL_NANOSECONDS;
    assert([rig.scheduler fire] == 1);

    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 1);
    assert(rig.suppression.endCount == 1);

    [rig finish];
}

static void testHeartbeatStopsWhenTheCurtainIsDown(void)
{
    Rig *rig = raisedRig();
    [rig.controller setAuthenticatedClientCount:0];
    assert(!rig.controller.curtainRaised);

    /* The beat armed by the curtain that just ended still fires - and must do
       nothing, including not re-arming itself. */
    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
    assert([rig.scheduler fire] == 1);
    assert([rig.scheduler fire] == 0);
    assert(rig.curtain.liftCount == 1);
    assert(!rig.controller.curtainRaised);

    [rig finish];
}

static void testOnlyOneHeartbeatChainSurvivesARelift(void)
{
    Rig *rig = raisedRig();

    /* Lift and raise again: the beat armed by the first curtain is still out
       there, and the second curtain armed its own. */
    [rig.controller setAuthenticatedClientCount:0];
    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.controller.curtainRaised);

    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
    assert([rig.scheduler fire] == 2);
    /* Exactly one of them re-armed. A beat that acted on a curtain it does not
       belong to would fork the chain, and every raise over a long-running
       server would add another one. */
    assert([rig.scheduler fire] == 1);
    assert(rig.controller.curtainRaised);

    [rig finish];
}

static void testASurfaceThatAnswersOneRaiseTwiceArmsOneHeartbeat(void)
{
    Rig *rig = readyRig();
    rig.curtain.answersImmediately = NO;

    [rig.controller setAuthenticatedClientCount:1];
    [rig.curtain answerHeldAtIndex:0 with:YES];
    assert(rig.controller.curtainRaised);

    /* The same raise answered a second time. The generation is unchanged - it
       IS the raise this belongs to - so only "there was a raise in flight" can
       reject it. Without that, a second heartbeat chain is armed and every beat
       from then on is doubled, forever. */
    [rig.curtain answerHeldAtIndex:0 with:YES];

    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
    assert([rig.scheduler fire] == 1);
    rig.clock.now += MACVNC_CURTAIN_HEARTBEAT_NANOSECONDS;
    assert([rig.scheduler fire] == 1);
    assert(rig.controller.curtainRaised);

    [rig finish];
}

static void testConditionsAreRecheckedWhenTheSwapCompletes(void)
{
    Rig *rig = readyRig();
    rig.curtain.answersImmediately = NO;

    [rig.controller setAuthenticatedClientCount:1];
    /* The filter swap is in flight: nothing is up yet, and input is already
       suppressed (that is the order). */
    assert(!rig.controller.curtainRaised);
    assert(rig.suppression.beginCount == 1);

    /* The swap takes real time - up to its own two-second timeout - and the
       world moves during it. Here the stream dies before the answer lands. */
    rig.health.live = NO;
    [rig.curtain answerHeldAtIndex:0 with:YES];

    assert(!rig.controller.curtainRaised);
    assert(rig.curtain.liftCount == 1);
    assert(rig.suppression.endCount == 1);

    [rig finish];
}

static void testClientLeavingDuringTheSwapAbandonsIt(void)
{
    Rig *rig = readyRig();
    rig.curtain.answersImmediately = NO;

    [rig.controller setAuthenticatedClientCount:1];
    assert(rig.curtain.raiseCount == 1);

    /* The viewer disconnects while the swap is still pending. The raise is
       abandoned there and then, rather than being allowed to finish into a
       curtain nobody is watching from. */
    [rig.controller setAuthenticatedClientCount:0];
    assert(rig.curtain.liftCount == 1);
    assert(rig.suppression.endCount == 1);
    assert(!rig.controller.curtainRaised);

    /* And the swap answering late must not raise it behind our back. */
    [rig.curtain answerHeldAtIndex:0 with:YES];
    assert(!rig.controller.curtainRaised);
    assert(rig.suppression.beginCount == 1);
    assert([rig.scheduler fire] == 0);   /* no heartbeat was ever armed */

    [rig finish];
}

/*
 * The cleartext copy does not outlive its use.
 *
 * Every read of the secret allocates a fresh copy of the VNC password, and the
 * curtain re-reads it on EVERY heartbeat while it is up - so releasing without
 * wiping would sprinkle readable passwords through freed heap for the
 * allocator to hand to whoever asks for memory next.
 */
static void testTheSecretCopyIsWipedBeforeItIsReleased(void)
{
    Rig *rig = raisedRig();

    /* Arming the policy is one read and the invariant re-check that follows a
       successful raise is another, so this is not a test about "the last
       copy": every copy the curtain ever asked for has to come back zeroed. */
    NSArray<NSMutableData *> *copies = rig.secretSource.handedOut;
    assert(copies.count >= 2);
    for (NSMutableData *handed in copies) {
        assert(handed.length > 0);  /* a real password, not an empty one */
        const uint8_t *bytes = handed.bytes;
        for (NSUInteger i = 0; i < handed.length; ++i)
            assert(bytes[i] == 0);
    }

    [rig finish];
}

static void testFailedRaiseRestoresInput(void)
{
    Rig *rig = readyRig();
    rig.curtain.answerValue = NO;        /* the filter swap failed or timed out */

    [rig.controller setAuthenticatedClientCount:1];
    assert(!rig.controller.curtainRaised);
    /* Input was suppressed before the swap was asked for, so a failed raise has
       to give it back - otherwise the keyboard stays dead with nothing on
       screen to explain why. */
    assert([rig.log isEqualToArray:(@[ @"suppress-begin", @"curtain-raise",
                                       @"suppress-end" ])]);
    assert([rig.scheduler fire] == 0);

    [rig finish];
}

/* ---------------------------------------------------------------------- */
/* The wiring the production glue performs, minus the device.              */
/*                                                                          */
/* Everything above this line drives a FAKE suppression seam, which cannot   */
/* observe the one property Task 4's header calls a coupling: that THIS      */
/* controller, used as the input module's observer, undoes the keyboard      */
/* focus hand-over that secure input triggers. The real MacVNCCurtainInput   */
/* is used below, above a fake tap, so the composition is exercised rather   */
/* than argued.                                                             */
/* ---------------------------------------------------------------------- */

@interface WiringTap : NSObject <MacVNCCurtainInputTap>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL secureInput;
@property (nonatomic, assign) NSUInteger stopCount;
@end

@implementation WiringTap

- (BOOL)processIsTrustedForAccessibility { return YES; }

- (BOOL)startWithEventMask:(uint64_t)eventMask
                   handler:(id<MacVNCCurtainInputTapHandler>)handler
{
    (void)eventMask; (void)handler;
    [_log addObject:@"tap-start"];
    return YES;
}

- (uint64_t)effectiveEventMask { return MACVNC_CURTAIN_INPUT_EVENT_MASK; }
- (BOOL)tapIsEnabled { return YES; }
- (BOOL)reenableTap { return YES; }
- (BOOL)secureInputIsEnabled { return _secureInput; }

- (BOOL)performOnTapThread:(dispatch_block_t)block
{
    if (block)
        block();
    return YES;
}

- (void)stop
{
    ++_stopCount;
    [_log addObject:@"tap-stop"];
}

@end

@interface WiringFocus : NSObject <MacVNCCurtainInputFocus>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL accepts;
@end

@implementation WiringFocus

- (void)setAcceptsKeyboardFocus:(BOOL)accepts
{
    _accepts = accepts;
    [_log addObject:accepts ? @"focus-to-curtain" : @"focus-not-curtain"];
}

- (void)setKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink { (void)sink; }

@end

/*
 * The same one-way back reference the production glue uses: the controller
 * retains the input, the input retains its observer, so the observer cannot be
 * the controller itself without a cycle - and the construction order forces it
 * anyway (the input must exist before the controller can be built with it).
 */
@interface WiringObserver : NSObject <MacVNCCurtainInputObserver>
@property (nonatomic, assign) MacVNCCurtainController *controller;  /* not owned */
@end

@implementation WiringObserver
- (void)noteLocalUnlockAccepted { [_controller noteLocalUnlockAccepted]; }
- (void)setSecureInputActive:(BOOL)active { [_controller setSecureInputActive:active]; }
- (void)noteInputSuppressionUnavailable { [_controller noteInputSuppressionUnavailable]; }
@end

/* The input module's hop to the main queue is a ZERO-delay schedule, which the
   heartbeat's scheduler refuses on purpose; this one models the hop as what it
   is - work that runs on a later main-queue turn. */
@interface HopScheduler : NSObject <MacVNCCurtainScheduler>
@property (nonatomic, retain) NSMutableArray<dispatch_block_t> *pending;
@end

@implementation HopScheduler

- (instancetype)init
{
    if ((self = [super init]))
        _pending = [[NSMutableArray alloc] init];
    return self;
}

- (void)afterNanoseconds:(uint64_t)nanoseconds performBlock:(dispatch_block_t)block
{
    (void)nanoseconds;
    if (block)
        [_pending addObject:[[block copy] autorelease]];
}

- (NSUInteger)fire
{
    NSArray<dispatch_block_t> *due = [[_pending copy] autorelease];
    [_pending removeAllObjects];
    for (dispatch_block_t block in due)
        block();
    return due.count;
}

- (void)dealloc
{
    [_pending release];
    [super dealloc];
}

@end

/*
 * Secure input, through the REAL input module, with this controller observing.
 *
 * The hand-over of the keyboard focus to the curtain window latches for the
 * rest of the suppression session, and MacVNCCurtainKeyWindow's -keyDown:
 * drops self-injected events - so an observer that did NOT lift would leave
 * the curtain window key for the whole session and the remote viewer's
 * KEYBOARD would die while their mouse kept working. What makes it safe is
 * that the lift is synchronous with the hand-over: by the time the reporting
 * block returns, suppression has ended and the focus is back.
 */
static void testSecureInputHandOverIsUndoneByTheControllersLift(void)
{
    NSMutableArray<NSString *> *log = [NSMutableArray array];
    FakeCaptureHealth *health = [[[FakeCaptureHealth alloc] init] autorelease];
    health.live = YES;
    FakeCurtainSurface *curtain = [[[FakeCurtainSurface alloc] init] autorelease];
    curtain.log = log;
    curtain.health = health;
    FakeSecretSource *secretSource = [[[FakeSecretSource alloc] init] autorelease];
    [secretSource setSecretText:@"hunter2"];
    ManualScheduler *heartbeats = [[[ManualScheduler alloc] init] autorelease];
    HopScheduler *hops = [[[HopScheduler alloc] init] autorelease];
    FakeClock *clock = [[[FakeClock alloc] init] autorelease];
    WiringTap *tap = [[[WiringTap alloc] init] autorelease];
    tap.log = log;
    WiringFocus *focus = [[[WiringFocus alloc] init] autorelease];
    focus.log = log;
    WiringObserver *observer = [[[WiringObserver alloc] init] autorelease];

    MacVNCCurtainInput *input =
        [[[MacVNCCurtainInput alloc] initWithTap:tap
                                           focus:focus
                                        observer:observer
                                    secretSource:secretSource
                                       scheduler:hops
                                           clock:clock] autorelease];
    MacVNCCurtainController *controller =
        [[[MacVNCCurtainController alloc] initWithCurtain:curtain
                                         inputSuppression:input
                                            captureHealth:health
                                             secretSource:secretSource
                                                scheduler:heartbeats
                                                    clock:clock] autorelease];
    observer.controller = controller;

    [controller setCurtainPreferenceEnabled:YES];
    [controller setServerRunning:YES];
    [controller setAuthenticatedClientCount:1];
    assert(controller.curtainRaised);
    assert(input.suppressing);
    /* While the tap is healthy the curtain window must NOT be key, or the
       remote party's keystrokes would land in it. */
    assert(!focus.accepts);
    assert(!input.tapPathUnavailable);

    tap.secureInput = YES;
    [input handleTapPoll];              /* the tap thread's own poll */
    assert(input.tapPathUnavailable);
    /* Nothing has moved on the main thread yet: the report is a hop. */
    assert(controller.curtainRaised);

    assert([hops fire] == 1);           /* the hop lands on main */

    assert(!controller.curtainRaised);
    assert(!input.suppressing);
    /* THE assertion this test exists for: the focus went to the curtain window
       and came straight back, inside the one block, so the window is key for
       zero run-loop iterations and the remote viewer's keyboard never dies. */
    assert(!focus.accepts);
    assert(tap.stopCount == 1);
    assert([log isEqualToArray:(@[ @"tap-start", @"focus-not-curtain",
                                   @"curtain-raise", @"focus-to-curtain",
                                   @"curtain-lift", @"tap-stop",
                                   @"focus-not-curtain" ])]);

    /* And the run ends the way it does in production. */
    [controller noteApplicationWillTerminate];
    while ([heartbeats fire] > 0)
        ;
}

/*
 * WHICH count the wiring feeds this controller.
 *
 * Everything else in this file is behavioural, and this one cannot be: the
 * choice lives in AppDelegate.m, which no test target compiles (it is the
 * glue that owns NSApp, the status item and the server lifecycle). What CAN
 * be pinned is the line itself, the same way tests/test_defaults.m pins the
 * defaults header against its implementation.
 *
 * It is worth pinning because the mistake is invisible: feeding
 * vncConnectedClients instead compiles, runs, passes every other test in this
 * repository, and raises the curtain DURING the up-to-8 s first-frame wait -
 * the local screen black while the remote viewer still holds a placeholder.
 * tests/test_client_counts.m owns the other half, that the two counts really
 * do differ inside that window.
 */
static void testTheWiringFeedsTheReceivingUpdatesCount(void)
{
    NSString *source =
        [NSString stringWithContentsOfFile:@MACVNC_APP_DELEGATE_SOURCE
                                  encoding:NSUTF8StringEncoding
                                     error:NULL];
    if (source.length == 0) {
        fprintf(stderr, "FAIL cannot read AppDelegate.m\n");
        abort();
    }

    /* The body of -refreshCurtainState, which is the one place that answers
       "how many viewers may the curtain hide behind". Bounded at the next
       method so a mention anywhere else in the file cannot satisfy this. */
    NSRange start = [source rangeOfString:@"- (void)refreshCurtainState"];
    if (start.location == NSNotFound) {
        fprintf(stderr, "FAIL -refreshCurtainState is gone from AppDelegate.m\n");
        abort();
    }
    NSRange rest = NSMakeRange(NSMaxRange(start), source.length - NSMaxRange(start));
    NSRange end = [source rangeOfString:@"\n}\n" options:0 range:rest];
    assert(end.location != NSNotFound);
    NSString *body = [source substringWithRange:
        NSMakeRange(rest.location, end.location - rest.location)];

    /* Comments in that body explain the choice and name both counters, so the
       check has to look at CODE. One statement, the one that produces the
       number handed to -setAuthenticatedClientCount:. */
    NSRange assignment =
        [body rangeOfString:@"int clients = vncAuthenticatedClientsReceivingUpdates;"];
    if (assignment.location == NSNotFound) {
        fprintf(stderr, "FAIL the curtain is not fed "
                        "vncAuthenticatedClientsReceivingUpdates\n");
        abort();
    }
    /* And it is not fed the wide count instead - the exact reversion this
       witness exists to catch. */
    NSRange wide = [body rangeOfString:@"int clients = vncConnectedClients;"];
    if (wide.location != NSNotFound) {
        fprintf(stderr, "FAIL the curtain is fed vncConnectedClients, which "
                        "moves before the first frame exists\n");
        abort();
    }
}

/*
 * The clock the production wiring uses, PUBLISHED once rather than copied.
 *
 * There used to be two of these - one private to this module, one private to
 * the event tap - both three lines around macVNCMonotonicNow(), which is the
 * duplication MacVNCCurtainMainQueueScheduler was published to avoid one
 * header over. This drives the surviving one: it must exist, answer non-zero
 * (0 is the "never" sentinel everywhere this clock is read) and never go
 * backwards, because every stall bound in curtain mode is a subtraction of two
 * of its readings.
 */
static void testThePublishedMonotonicClockIsTheOneBothHalvesUse(void)
{
    MacVNCCurtainMonotonicClock *clock =
        [[[MacVNCCurtainMonotonicClock alloc] init] autorelease];
    assert([clock conformsToProtocol:@protocol(MacVNCCurtainClock)]);
    uint64_t first = [clock monotonicNanoseconds];
    assert(first != 0);
    uint64_t second = [clock monotonicNanoseconds];
    assert(second >= first);
}

int main(void)
{
    @autoreleasepool {
        testNothingRaisesAtLaunch();
        testFirstClientRaisesAndLastClientLifts();
        testRaiseIsEdgeTriggeredNotLevelTriggered();
        testLocalUnlockLatchesDownForTheWholeRun();
        testRefusesToRaiseWithoutInputSuppression();
        testRefusesWhenTheServerIsNotRunning();
        testNothingRaisesAfterTermination();
        testRefusesWhenTheTapCannotBeArmed();
        testRefusesWithoutAUsableSecret();
        testRefusesWithoutALiveStream();
        testEveryLiftTriggerLifts();
        testStreamFailureDoesNotPoisonTheRun();
        testStreamStopReportedWhileDownDoesNotPoisonTheRun();
        testServerRestartRaisesForTheNextClient();
        testSecretChangeIsMeasuredOnTheEffectiveBytes();
        testStreamDeathAfterTheRaiseLifts();
        testSessionRebuildDropsTheExclusionAndLifts();
        testHeartbeatKeepsBeatingWhileHealthy();
        testUnobservedTimeLifts();
        testHeartbeatStopsWhenTheCurtainIsDown();
        testOnlyOneHeartbeatChainSurvivesARelift();
        testASurfaceThatAnswersOneRaiseTwiceArmsOneHeartbeat();
        testConditionsAreRecheckedWhenTheSwapCompletes();
        testClientLeavingDuringTheSwapAbandonsIt();
        testFailedRaiseRestoresInput();
        testTheSecretCopyIsWipedBeforeItIsReleased();
        testSecureInputHandOverIsUndoneByTheControllersLift();
        testTheWiringFeedsTheReceivingUpdatesCount();
        testThePublishedMonotonicClockIsTheOneBothHalvesUse();
        printf("curtain controller: all assertions passed\n");
    }
    return 0;
}
