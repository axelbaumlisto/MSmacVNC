#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCCurtainWindow.h"

/*
 * The curtain's screen half, tested with NO display, NO capture stream and no
 * window server: the rules that matter are ORDERING (filter before windows on
 * the way up, windows before filter on the way down), what happens when the
 * filter swap never answers, and the per-screen bookkeeping across hot-plug.
 * All three are decided above the AppKit seam, which is why the seam exists.
 */

/* ---------------------------------------------------------------------- */

@interface FakeOccluders : NSObject <MacVNCCurtainOccluders>
@property (nonatomic, retain) NSMutableArray<NSNumber *> *attached;
@property (nonatomic, retain) NSMutableArray<NSNumber *> *created;
@property (nonatomic, retain) NSMutableArray<NSNumber *> *removed;
@property (nonatomic, retain) NSMutableArray<NSNumber *> *refitted;
@property (nonatomic, assign) NSUInteger showCalls;
@property (nonatomic, assign) NSUInteger hideCalls;
/* @YES / @NO per -setOccludersCovering:, in order. "Ordered in" and "actually
   hides the screen" are two different things now: the raise puts an INVISIBLE
   window on screen so ScreenCaptureKit will list this process at all, and only
   the swap's success turns it opaque. */
@property (nonatomic, retain) NSMutableArray<NSNumber *> *coveringCalls;
/* Every occluder event in one ordered list ("create:1", "cover:1", "show",
   "hide", ...), because the rules under test are about ORDER between two
   different calls, which two counters cannot express. */
@property (nonatomic, retain) NSMutableArray<NSString *> *log;
/* Screens that report attached but refuse creation - the display that is
   unplugged between being listed and being covered. */
@property (nonatomic, retain) NSMutableSet<NSNumber *> *refuseCreation;
- (BOOL)everCovered;
- (NSUInteger)lastIndexOfEvent:(NSString *)event;
@end

@implementation FakeOccluders

- (instancetype)init
{
    if ((self = [super init])) {
        _attached = [[NSMutableArray alloc] init];
        _created = [[NSMutableArray alloc] init];
        _removed = [[NSMutableArray alloc] init];
        _refitted = [[NSMutableArray alloc] init];
        _coveringCalls = [[NSMutableArray alloc] init];
        _log = [[NSMutableArray alloc] init];
        _refuseCreation = [[NSMutableSet alloc] init];
    }
    return self;
}

- (NSArray<NSNumber *> *)attachedScreenIdentifiers { return _attached; }

- (BOOL)createOccluderForScreen:(NSNumber *)identifier
{
    if ([_refuseCreation containsObject:identifier])
        return NO;
    [_created addObject:identifier];
    [_log addObject:[NSString stringWithFormat:@"create:%@", identifier]];
    return YES;
}

- (void)removeOccluderForScreen:(NSNumber *)identifier
{
    [_removed addObject:identifier];
    [_log addObject:[NSString stringWithFormat:@"remove:%@", identifier]];
}

- (void)updateOccluderGeometryForScreen:(NSNumber *)identifier
{
    [_refitted addObject:identifier];
}

- (void)setOccludersVisible:(BOOL)visible
{
    if (visible)
        ++_showCalls;
    else
        ++_hideCalls;
    [_log addObject:visible ? @"show" : @"hide"];
}

- (void)setOccludersCovering:(BOOL)covering
{
    [_coveringCalls addObject:@(covering)];
    [_log addObject:covering ? @"cover:1" : @"cover:0"];
}

- (BOOL)everCovered
{
    return [_coveringCalls containsObject:@YES];
}

- (NSUInteger)lastIndexOfEvent:(NSString *)event
{
    NSUInteger found = NSNotFound;
    for (NSUInteger i = 0; i < _log.count; ++i) {
        if ([_log[i] isEqualToString:event])
            found = i;
    }
    return found;
}

- (void)dealloc
{
    [_attached release];
    [_created release];
    [_removed release];
    [_refitted release];
    [_coveringCalls release];
    [_log release];
    [_refuseCreation release];
    [super dealloc];
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeExclusion : NSObject <MacVNCCurtainCaptureExclusion>
/* @YES / @NO per request, in order. */
@property (nonatomic, retain) NSMutableArray<NSNumber *> *requests;
/* Whether the curtain windows were visible at the moment each request was
   made: this is how the ORDER of "swap the filter" against "show the windows"
   is observed rather than assumed. */
@property (nonatomic, retain) NSMutableArray<NSNumber *> *visibleAtRequest;
/* ...and whether they were COVERING then. The two together are the whole rule:
   the windows must already be on screen when the exclusion is asked for (or
   ScreenCaptureKit does not list this process and the swap can only refuse),
   and they must not yet hide anything (or the local user is blinded before the
   stream stopped carrying them). */
@property (nonatomic, retain) NSMutableArray<NSNumber *> *coveringAtRequest;
@property (nonatomic, assign) MacVNCCurtainWindowSet *windowSet;   /* not owned */
/* NO: hold the completion instead of answering, so a test can answer late or
   never. */
@property (nonatomic, assign) BOOL answersImmediately;
@property (nonatomic, assign) BOOL answerValue;
/* Held completions in request order, so a test can answer an OLD one - the
   real stream can answer a swap the curtain has already given up on. */
@property (nonatomic, retain) NSMutableArray<MacVNCCurtainCompletion> *held;
@end

@implementation FakeExclusion

- (instancetype)init
{
    if ((self = [super init])) {
        _requests = [[NSMutableArray alloc] init];
        _visibleAtRequest = [[NSMutableArray alloc] init];
        _coveringAtRequest = [[NSMutableArray alloc] init];
        _held = [[NSMutableArray alloc] init];
        _answersImmediately = YES;
        _answerValue = YES;
    }
    return self;
}

- (void)setCaptureExcludesOwnApplication:(BOOL)excluded
                              completion:(MacVNCCurtainCompletion)completion
{
    [_requests addObject:@(excluded)];
    [_visibleAtRequest addObject:@(_windowSet.visible)];
    [_coveringAtRequest addObject:@(_windowSet.covering)];
    if (_answersImmediately) {
        if (completion)
            completion(_answerValue);
        return;
    }
    if (completion)
        [_held addObject:[[completion copy] autorelease]];
}

- (void)answerHeldAtIndex:(NSUInteger)index with:(BOOL)success
{
    MacVNCCurtainCompletion completion = [[_held[index] retain] autorelease];
    completion(success);
}

- (void)answerHeldWith:(BOOL)success
{
    [self answerHeldAtIndex:0 with:success];
}

- (void)dealloc
{
    [_requests release];
    [_visibleAtRequest release];
    [_coveringAtRequest release];
    [_held release];
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
    assert(nanoseconds > 0 && "a timeout of zero would fire before any answer");
    if (block)
        [_pending addObject:[[block copy] autorelease]];
}

/* Every armed deadline expires. */
- (void)fire
{
    NSArray<dispatch_block_t> *due = [[_pending copy] autorelease];
    [_pending removeAllObjects];
    for (dispatch_block_t block in due)
        block();
}

- (void)dealloc
{
    [_pending release];
    [super dealloc];
}

@end

/* ---------------------------------------------------------------------- */

static MacVNCCurtain *makeCurtain(FakeOccluders *occluders,
                                  FakeExclusion *exclusion,
                                  ManualScheduler *scheduler,
                                  MacVNCCurtainWindowSet **outWindowSet)
{
    MacVNCCurtainWindowSet *windowSet =
        [[[MacVNCCurtainWindowSet alloc] initWithOccluders:occluders] autorelease];
    exclusion.windowSet = windowSet;
    if (outWindowSet)
        *outWindowSet = windowSet;
    return [[[MacVNCCurtain alloc]
        initWithWindowSet:windowSet
                exclusion:exclusion
                scheduler:scheduler
       timeoutNanoseconds:MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS]
        autorelease];
}

static void testWindowSetBookkeeping(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObjectsFromArray:@[ @1, @2 ]];
    MacVNCCurtainWindowSet *set =
        [[[MacVNCCurtainWindowSet alloc] initWithOccluders:occluders] autorelease];

    /* One window per attached screen, and nothing shown by merely existing:
       creating the set must not put anything on the local screen. */
    [set synchronizeWithAttachedScreens];
    assert(set.screenIdentifiers.count == 2);
    assert(occluders.created.count == 2);
    assert(occluders.showCalls == 0);
    assert(!set.visible);

    /* Re-synchronising an unchanged desk creates nothing new (a second window
       per screen would stack alpha and stop looking black) and re-fits what is
       already there. */
    [set synchronizeWithAttachedScreens];
    assert(occluders.created.count == 2);
    assert(occluders.refitted.count == 2);

    /* Hot-plug WHILE the curtain is up: the new screen is covered and shown by
       the same call, because that one window creation is the whole exposure -
       and the opacity is re-asserted BEFORE the window is ordered in, or that
       screen shows its own desktop for a frame. */
    [set setCovering:YES];
    [set setVisible:YES];
    assert(set.covering);
    NSUInteger showsBefore = occluders.showCalls;
    [occluders.attached addObject:@3];
    [set synchronizeWithAttachedScreens];
    assert([occluders.created containsObject:@3]);
    assert(occluders.showCalls == showsBefore + 1);
    assert(set.screenIdentifiers.count == 3);
    assert([occluders lastIndexOfEvent:@"create:3"] <
           [occluders lastIndexOfEvent:@"cover:1"]);
    assert([occluders lastIndexOfEvent:@"cover:1"] <
           [occluders lastIndexOfEvent:@"show"]);

    /* Detach: the window goes away and is not counted as covered any more. */
    [occluders.attached removeObject:@2];
    [set synchronizeWithAttachedScreens];
    assert([occluders.removed isEqualToArray:@[ @2 ]]);
    assert(![set.screenIdentifiers containsObject:@2]);

    /* A screen that vanishes between being listed and being covered is NOT
       recorded as covered - otherwise the set would believe a display has a
       curtain it never got, and never retry. */
    [occluders.refuseCreation addObject:@4];
    [occluders.attached addObject:@4];
    [set synchronizeWithAttachedScreens];
    assert(![set.screenIdentifiers containsObject:@4]);
    [occluders.refuseCreation removeAllObjects];
    [set synchronizeWithAttachedScreens];
    assert([set.screenIdentifiers containsObject:@4]);

    /* Hiding is a set-wide operation and does not forget the screens. */
    [set setVisible:NO];
    [set setCovering:NO];
    assert(!set.visible);
    assert(!set.covering);
    assert(occluders.hideCalls == 1);
    assert(set.screenIdentifiers.count == 3);

    /* A set that is not covering does not re-assert opacity on every
       synchronise. */
    NSUInteger coveringCallsBefore = occluders.coveringCalls.count;
    [set synchronizeWithAttachedScreens];
    assert(occluders.coveringCalls.count == coveringCallsBefore);
}

/*
 * Hot-plug DURING the arming window - the state that only exists because the
 * exclusion cannot be armed before a window is on screen.
 *
 * A display attached while the swap is still in flight gets an occluder, and
 * that occluder must be ARMED like the others: opacity follows the covering
 * flag, never "is anything ordered in". Deriving it from visibility would black
 * out the new display while the stream is still carrying this application -
 * blinding the local user on a raise that may yet be refused.
 */
static void testHotPlugWhileArmedStaysArmed(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    MacVNCCurtainWindowSet *set =
        [[[MacVNCCurtainWindowSet alloc] initWithOccluders:occluders] autorelease];

    [set synchronizeWithAttachedScreens];
    [set setCovering:NO];
    [set setVisible:YES];        /* armed: on screen, hiding nothing */
    assert(set.visible && !set.covering);

    [occluders.attached addObject:@2];
    [set synchronizeWithAttachedScreens];
    assert([occluders.created containsObject:@2]);
    assert(set.visible && !set.covering);
    assert(!occluders.everCovered);

    /* And the alpha the real AppKit occluder would use in each state, which is
       otherwise reachable only with a window server. */
    assert(macVNCCurtainOccluderAlpha(false) == MACVNC_CURTAIN_ARMING_ALPHA);
    assert(macVNCCurtainOccluderAlpha(true) == MACVNC_CURTAIN_ALPHA);
    assert(macVNCCurtainOccluderAlpha(false) * 255.0 <= 1.0);
    assert(macVNCCurtainOccluderAlpha(false) < macVNCCurtainOccluderAlpha(true));
}

/*
 * THE REGRESSION THIS FILE EXISTS FOR NOW.
 *
 * The previous order - swap the filter, then show the windows - is impossible
 * on the platform, and a live run proved it: ScreenCaptureKit lists an
 * application only while it owns a window, this app is an LSUIElement whose
 * only UI is a status item, and so every raise refused with "application no"
 * however the discovery was phrased. The windows must be on screen BEFORE the
 * exclusion is requested.
 *
 * What makes that safe is that they go up ARMED: ordered in, but transparent
 * enough (MACVNC_CURTAIN_ARMING_ALPHA) that neither the local user nor the
 * remote viewer - who is still being shown this same desktop, since the
 * exclusion is not in place yet - can see anything. Opacity comes last.
 *
 * Written against the old code, the `visibleAtRequest` assertion below fails.
 */
static void testRaiseArmsWindowsBeforeRequestingExclusion(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    exclusion.answersImmediately = NO;   /* hold the swap open mid-raise */
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    __block int outcomes = 0;
    [curtain raiseWithCompletion:^(BOOL success) { assert(success); ++outcomes; }];

    /* Mid-raise: the window exists and is on screen - that is what makes this
       process discoverable at all - and it hides nothing. */
    assert(curtain.state == MacVNCCurtainStateRaising);
    assert(outcomes == 0);
    assert(occluders.created.count == 1);
    assert(set.visible);
    assert(!set.covering);
    assert(!occluders.everCovered);
    assert([exclusion.requests isEqualToArray:@[ @YES ]]);
    assert([exclusion.visibleAtRequest isEqualToArray:@[ @YES ]]);
    assert([exclusion.coveringAtRequest isEqualToArray:@[ @NO ]]);
    /* Ordered in before the request, and the request before any opacity. */
    assert([occluders lastIndexOfEvent:@"show"] != NSNotFound);
    assert([occluders lastIndexOfEvent:@"cover:1"] == NSNotFound);

    /* The swap confirms: only now does the screen actually go black. */
    [exclusion answerHeldWith:YES];
    assert(outcomes == 1);
    assert(curtain.state == MacVNCCurtainStateUp);
    assert(set.visible && set.covering);
    assert(occluders.everCovered);
    assert([occluders lastIndexOfEvent:@"cover:1"] >
           [occluders lastIndexOfEvent:@"create:1"]);
}

static void testRaiseSwapsFilterBeforeShowingWindows(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    __block int outcomes = 0;
    __block BOOL raised = NO;
    [curtain raiseWithCompletion:^(BOOL success) { raised = success; ++outcomes; }];

    assert(outcomes == 1 && raised);
    assert(curtain.state == MacVNCCurtainStateUp);
    /* THE ordering assertion: the exclusion was requested with the windows on
       screen but COVERING NOTHING. On screen, because otherwise this process is
       in no discovery result and the swap can only refuse; covering nothing,
       because the stream still carries them at that instant. */
    assert([exclusion.requests isEqualToArray:@[ @YES ]]);
    assert([exclusion.visibleAtRequest isEqualToArray:@[ @YES ]]);
    assert([exclusion.coveringAtRequest isEqualToArray:@[ @NO ]]);
    assert(set.visible);
    assert(set.covering);
    assert(occluders.created.count == 1);

    /* Raising an up curtain changes nothing and asks the stream nothing. */
    [curtain raiseWithCompletion:^(BOOL success) { assert(success); ++outcomes; }];
    assert(outcomes == 2);
    assert(exclusion.requests.count == 1);

    /* Lift is the exact reverse: the windows are already out when the filter is
       asked to carry us again. */
    __block BOOL lifted = NO;
    [curtain liftWithCompletion:^(BOOL success) { lifted = success; ++outcomes; }];
    assert(outcomes == 3 && lifted);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert([exclusion.requests isEqualToArray:(@[ @YES, @NO ])]);
    /* The restore is asked for with the windows already out and already
       transparent - the exact reverse. */
    assert([exclusion.visibleAtRequest isEqualToArray:(@[ @YES, @NO ])]);
    assert([exclusion.coveringAtRequest isEqualToArray:(@[ @NO, @NO ])]);
    assert(!set.visible);
    assert(!set.covering);
    assert(occluders.hideCalls >= 1);

    /* Lifting a down curtain is a no-op, not a second filter swap. */
    [curtain liftWithCompletion:^(BOOL success) { assert(success); ++outcomes; }];
    assert(outcomes == 4);
    assert(exclusion.requests.count == 2);
}

static void testFailedSwapDoesNotRaise(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    exclusion.answerValue = NO;
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    __block int outcomes = 0;
    [curtain raiseWithCompletion:^(BOOL success) { assert(!success); ++outcomes; }];
    assert(outcomes == 1);
    assert(curtain.state == MacVNCCurtainStateDown);
    /* The armed window was ordered in (it had to be) and is ordered out again,
       having NEVER covered anything: a refused raise is invisible to the local
       user and to the remote viewer alike. */
    assert(!set.visible);
    assert(!set.covering);
    assert(!occluders.everCovered);
    assert(occluders.hideCalls >= 1);
    /* And the exclusion is taken back, so a stream does not keep hiding an
       application whose curtain never went up. */
    assert([exclusion.requests isEqualToArray:(@[ @YES, @NO ])]);
}

static void testSwapTimeoutIsAFailure(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    exclusion.answersImmediately = NO;   /* the handler never fires */
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    __block int outcomes = 0;
    __block BOOL raised = YES;
    [curtain raiseWithCompletion:^(BOOL success) { raised = success; ++outcomes; }];
    /* No answer yet, and nothing that either party can see: the window is on
       screen only so the discovery can find this process. */
    assert(outcomes == 0);
    assert(curtain.state == MacVNCCurtainStateRaising);
    assert(set.visible);
    assert(!set.covering);

    [scheduler fire];
    assert(outcomes == 1 && !raised);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
    assert(!set.covering);
    assert(!occluders.everCovered);

    /* A late success from the swap we gave up on must not raise the curtain
       behind the caller's back. */
    [exclusion answerHeldWith:YES];
    assert(outcomes == 1);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
    assert(!set.covering);
    assert(!occluders.everCovered);
}

static void testTimeoutAfterSuccessIsIgnored(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    __block int outcomes = 0;
    [curtain raiseWithCompletion:^(BOOL success) { assert(success); ++outcomes; }];
    assert(curtain.state == MacVNCCurtainStateUp);

    /* The deadline of a transition that already resolved must not tear the
       curtain down under a caller that was told it was up. */
    [scheduler fire];
    assert(outcomes == 1);
    assert(curtain.state == MacVNCCurtainStateUp);
    assert(set.visible);
    assert(set.covering);
}

static void testLiftDuringRaiseAbandonsIt(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    exclusion.answersImmediately = NO;
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    __block BOOL raiseOutcome = YES;
    __block int raiseCalls = 0;
    [curtain raiseWithCompletion:^(BOOL success) { raiseOutcome = success; ++raiseCalls; }];
    assert(curtain.state == MacVNCCurtainStateRaising);

    /* A raise in flight refuses a second raise rather than queueing one. */
    __block int refusals = 0;
    [curtain raiseWithCompletion:^(BOOL success) { assert(!success); ++refusals; }];
    assert(refusals == 1);
    assert(exclusion.requests.count == 1);

    /* Lifting mid-raise is the escape hatch's shape: the pending raise is told
       it failed, and the swap it was waiting for can no longer show anything. */
    exclusion.answersImmediately = YES;
    __block int liftCalls = 0;
    [curtain liftWithCompletion:^(BOOL success) { assert(success); ++liftCalls; }];
    assert(raiseCalls == 1 && !raiseOutcome);
    assert(liftCalls == 1);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
    assert(!set.covering);
    /* The abandoned raise had armed its windows; they never covered anything. */
    assert(!occluders.everCovered);

    [exclusion answerHeldWith:YES];
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
    assert(!occluders.everCovered);
}

static void testLiftKeepsWindowsDownWhenRestoreTimesOut(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    [curtain raiseWithCompletion:nil];
    assert(set.visible);
    assert(set.covering);

    exclusion.answersImmediately = NO;
    __block int outcomes = 0;
    __block BOOL lifted = YES;
    [curtain liftWithCompletion:^(BOOL success) { lifted = success; ++outcomes; }];
    /* The windows are down BEFORE the filter answers - that asymmetry is the
       point: a restore that never completes still gives the local user their
       screen back. Transparent too, so the next raise arms from a known
       state instead of inheriting this one's opacity. */
    assert(!set.visible);
    assert(!set.covering);
    assert(outcomes == 0);

    [scheduler fire];
    assert(outcomes == 1 && !lifted);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);

    /* The restore we gave up on can still answer later, while a whole new
       raise/lift cycle is in flight. Being in the same state is not enough to
       accept it: it would report the new lift finished before the stream has
       actually taken us back. */
    [curtain raiseWithCompletion:nil];
    [exclusion answerHeldAtIndex:1 with:YES];     /* the new raise's swap */
    assert(curtain.state == MacVNCCurtainStateUp);

    __block int secondLiftOutcomes = 0;
    [curtain liftWithCompletion:^(BOOL success) { assert(success); ++secondLiftOutcomes; }];
    assert(curtain.state == MacVNCCurtainStateLifting);

    [exclusion answerHeldAtIndex:0 with:YES];     /* the abandoned restore */
    assert(secondLiftOutcomes == 0);
    assert(curtain.state == MacVNCCurtainStateLifting);

    [exclusion answerHeldAtIndex:2 with:YES];     /* the one being waited for */
    assert(secondLiftOutcomes == 1);
    assert(curtain.state == MacVNCCurtainStateDown);
}

static void testStaleAnswerCannotResolveTheNextTransition(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    exclusion.answersImmediately = NO;
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    /* First raise times out and is abandoned - but ScreenCaptureKit still owns
       its completion block and may call it whenever it likes. */
    __block int firstOutcomes = 0;
    [curtain raiseWithCompletion:^(BOOL success) { assert(!success); ++firstOutcomes; }];
    [scheduler fire];
    assert(firstOutcomes == 1);
    assert(curtain.state == MacVNCCurtainStateDown);

    /* A second raise is in flight when the FIRST swap finally answers. Being in
       the same state is not enough to accept that answer: it belongs to a
       transition that was already resolved, and honouring it would raise the
       curtain on the strength of a swap nobody is waiting for. */
    __block int secondOutcomes = 0;
    [curtain raiseWithCompletion:^(BOOL success) { assert(success); ++secondOutcomes; }];
    assert(curtain.state == MacVNCCurtainStateRaising);

    [exclusion answerHeldAtIndex:0 with:YES];
    assert(secondOutcomes == 0);
    assert(curtain.state == MacVNCCurtainStateRaising);
    /* Armed, because the second raise armed it - but nothing is hidden on the
       strength of an answer nobody is waiting for. */
    assert(set.visible);
    assert(!set.covering);
    assert(!occluders.everCovered);

    /* The answer that IS being waited for resolves it. */
    [exclusion answerHeldAtIndex:1 with:YES];
    assert(secondOutcomes == 1);
    assert(curtain.state == MacVNCCurtainStateUp);
    assert(set.visible);
    assert(set.covering);
}

static void testScreenParameterChangeCoversNewDisplay(void)
{
    FakeOccluders *occluders = [[[FakeOccluders alloc] init] autorelease];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[[FakeExclusion alloc] init] autorelease];
    ManualScheduler *scheduler = [[[ManualScheduler alloc] init] autorelease];
    MacVNCCurtainWindowSet *set = nil;
    MacVNCCurtain *curtain = makeCurtain(occluders, exclusion, scheduler, &set);

    /* DOWN: the notification fires on every resolution change and every display
       sleep, and a curtain nobody raised must answer it with nothing at all -
       not even a hidden window per screen. "Touches no window until raised" is
       a promise in the header, so it is an assertion here. */
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSApplicationDidChangeScreenParametersNotification
                      object:nil];
    assert(occluders.created.count == 0);
    assert(occluders.showCalls == 0);
    assert(set.screenIdentifiers.count == 0);

    [curtain raiseWithCompletion:nil];
    assert(curtain.state == MacVNCCurtainStateUp);
    NSUInteger showsBefore = occluders.showCalls;

    [occluders.attached addObject:@7];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSApplicationDidChangeScreenParametersNotification
                      object:nil];

    assert([occluders.created containsObject:@7]);
    assert(occluders.showCalls == showsBefore + 1);
    assert([set.screenIdentifiers containsObject:@7]);

    /* And once it is down again it goes quiet again: a display attached after
       the lift is covered by the next RAISE, which synchronises before it
       shows, not by a window allocated behind the user's back. */
    [curtain liftWithCompletion:nil];
    assert(curtain.state == MacVNCCurtainStateDown);
    NSUInteger createdAfterLift = occluders.created.count;
    [occluders.attached addObject:@8];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSApplicationDidChangeScreenParametersNotification
                      object:nil];
    assert(occluders.created.count == createdAfterLift);
    assert(![set.screenIdentifiers containsObject:@8]);

    [curtain raiseWithCompletion:nil];
    assert([set.screenIdentifiers containsObject:@8]);
}

static void testDroppedCurtainAnswersAndUndoesItself(void)
{
    /* Part 1: an owner that lets go mid-transition still hears an answer.

       The fakes have to DROP the blocks they are holding for this to be
       reachable: a pending completion and a pending timeout each retain the
       curtain, so as long as either can still fire, the curtain is alive to
       resolve itself. Dropping them is what "this answer is never coming"
       looks like from the inside - and a raise that is neither answered nor
       failed leaves its caller believing a curtain may still be going up. */
    FakeOccluders *occluders = [[FakeOccluders alloc] init];
    [occluders.attached addObject:@1];
    FakeExclusion *exclusion = [[FakeExclusion alloc] init];
    exclusion.answersImmediately = NO;
    ManualScheduler *scheduler = [[ManualScheduler alloc] init];
    MacVNCCurtainWindowSet *windowSet =
        [[MacVNCCurtainWindowSet alloc] initWithOccluders:occluders];
    exclusion.windowSet = windowSet;

    __block int outcomes = 0;
    __block BOOL raised = YES;
    @autoreleasepool {
        MacVNCCurtain *curtain = [[MacVNCCurtain alloc]
            initWithWindowSet:windowSet
                    exclusion:exclusion
                    scheduler:scheduler
           timeoutNanoseconds:MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS];
        [curtain raiseWithCompletion:^(BOOL success) { raised = success; ++outcomes; }];
        assert(outcomes == 0);
        [curtain release];
        /* Both fakes hold a block that captured the curtain, so the release
           above is not the last one: dropping them is what makes this
           reachable at all. (They are autoreleased copies, hence the pool.) */
        [scheduler.pending removeAllObjects];
        [exclusion.held removeAllObjects];
    }
    assert(outcomes == 1 && !raised);
    /* Dropped mid-raise: the armed windows never covered anything, so nobody
       is left in front of a black screen that nothing can lift. */
    assert(!occluders.everCovered);
    [windowSet release];
    [scheduler release];
    [exclusion release];
    [occluders release];

    /* Part 2: a curtain deallocated while it is UP takes itself down on BOTH
       sides. Hiding the windows is not enough - the stream would keep
       excluding this application forever, with nothing left that could ever
       ask for it back. */
    FakeOccluders *upOccluders = [[FakeOccluders alloc] init];
    [upOccluders.attached addObject:@1];
    FakeExclusion *upExclusion = [[FakeExclusion alloc] init];
    ManualScheduler *upScheduler = [[ManualScheduler alloc] init];
    MacVNCCurtainWindowSet *upWindowSet =
        [[MacVNCCurtainWindowSet alloc] initWithOccluders:upOccluders];
    upExclusion.windowSet = upWindowSet;

    @autoreleasepool {
        MacVNCCurtain *up = [[MacVNCCurtain alloc]
            initWithWindowSet:upWindowSet
                    exclusion:upExclusion
                    scheduler:upScheduler
           timeoutNanoseconds:MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS];
        [up raiseWithCompletion:nil];
        assert(upWindowSet.visible);
        assert([upExclusion.requests isEqualToArray:@[ @YES ]]);
        [up release];
        [upScheduler.pending removeAllObjects];   /* the resolved timeout */
    }
    assert(!upWindowSet.visible);
    assert(!upWindowSet.covering);
    assert([upExclusion.requests isEqualToArray:(@[ @YES, @NO ])]);
    [upWindowSet release];
    [upScheduler release];
    [upExclusion release];
    [upOccluders release];
}

static void testAlphaLeaksNoVisibleLevel(void)
{
    /* The "looks black" criterion, stated as arithmetic rather than as an
       impression: what a fully white pixel underneath composites to must
       quantise to level 0 in 8 bits. An opaque curtain would satisfy this too,
       but it freezes the remote picture - hence "just under 1", not 1. */
    double leaked = (1.0 - MACVNC_CURTAIN_ALPHA) * 255.0;
    assert(leaked < 0.5);
    assert(MACVNC_CURTAIN_ALPHA < 1.0);

    /* The ARMED alpha has the mirrored criterion, and it is two-sided.
       Non-zero, because the armed window exists for one reason only - to make
       ScreenCaptureKit list this process - and a window drawn at alpha 0 is
       exactly the kind of thing a window server may decline to composite. And
       at most one 8-bit level of dimming over pure white, because at that
       moment the exclusion is NOT yet in place: whatever this window costs, it
       costs the remote viewer too. */
    assert(MACVNC_CURTAIN_ARMING_ALPHA > 0.0);
    assert(MACVNC_CURTAIN_ARMING_ALPHA * 255.0 <= 1.0);
    assert(MACVNC_CURTAIN_ARMING_ALPHA < MACVNC_CURTAIN_ALPHA);
}

int main(void)
{
    @autoreleasepool {
        testWindowSetBookkeeping();
        testHotPlugWhileArmedStaysArmed();
        testRaiseArmsWindowsBeforeRequestingExclusion();
        testRaiseSwapsFilterBeforeShowingWindows();
        testFailedSwapDoesNotRaise();
        testSwapTimeoutIsAFailure();
        testTimeoutAfterSuccessIsIgnored();
        testLiftDuringRaiseAbandonsIt();
        testLiftKeepsWindowsDownWhenRestoreTimesOut();
        testStaleAnswerCannotResolveTheNextTransition();
        testScreenParameterChangeCoversNewDisplay();
        testDroppedCurtainAnswersAndUndoesItself();
        testAlphaLeaksNoVisibleLevel();
        printf("curtain window: all assertions passed\n");
    }
    return 0;
}
