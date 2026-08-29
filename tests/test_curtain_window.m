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
/* Screens that report attached but refuse creation - the display that is
   unplugged between being listed and being covered. */
@property (nonatomic, retain) NSMutableSet<NSNumber *> *refuseCreation;
@end

@implementation FakeOccluders

- (instancetype)init
{
    if ((self = [super init])) {
        _attached = [[NSMutableArray alloc] init];
        _created = [[NSMutableArray alloc] init];
        _removed = [[NSMutableArray alloc] init];
        _refitted = [[NSMutableArray alloc] init];
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
    return YES;
}

- (void)removeOccluderForScreen:(NSNumber *)identifier
{
    [_removed addObject:identifier];
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
}

- (void)dealloc
{
    [_attached release];
    [_created release];
    [_removed release];
    [_refitted release];
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
       the same call, because that one window creation is the whole exposure. */
    [set setVisible:YES];
    NSUInteger showsBefore = occluders.showCalls;
    [occluders.attached addObject:@3];
    [set synchronizeWithAttachedScreens];
    assert([occluders.created containsObject:@3]);
    assert(occluders.showCalls == showsBefore + 1);
    assert(set.screenIdentifiers.count == 3);

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
    assert(!set.visible);
    assert(occluders.hideCalls == 1);
    assert(set.screenIdentifiers.count == 3);
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
    /* THE ordering assertion: the exclusion was requested while the windows
       were still hidden. Showing first would blank the remote viewer. */
    assert([exclusion.requests isEqualToArray:@[ @YES ]]);
    assert([exclusion.visibleAtRequest isEqualToArray:@[ @NO ]]);
    assert(set.visible);
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
    assert([exclusion.visibleAtRequest isEqualToArray:(@[ @NO, @NO ])]);
    assert(!set.visible);
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
    assert(!set.visible);
    assert(occluders.showCalls == 0);
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
    /* Nothing has happened yet: no answer, no windows. */
    assert(outcomes == 0);
    assert(curtain.state == MacVNCCurtainStateRaising);
    assert(!set.visible);

    [scheduler fire];
    assert(outcomes == 1 && !raised);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
    assert(occluders.showCalls == 0);

    /* A late success from the swap we gave up on must not raise the curtain
       behind the caller's back. */
    [exclusion answerHeldWith:YES];
    assert(outcomes == 1);
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
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

    [exclusion answerHeldWith:YES];
    assert(curtain.state == MacVNCCurtainStateDown);
    assert(!set.visible);
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

    exclusion.answersImmediately = NO;
    __block int outcomes = 0;
    __block BOOL lifted = YES;
    [curtain liftWithCompletion:^(BOOL success) { lifted = success; ++outcomes; }];
    /* The windows are down BEFORE the filter answers - that asymmetry is the
       point: a restore that never completes still gives the local user their
       screen back. */
    assert(!set.visible);
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
    assert(!set.visible);

    /* The answer that IS being waited for resolves it. */
    [exclusion answerHeldAtIndex:1 with:YES];
    assert(secondOutcomes == 1);
    assert(curtain.state == MacVNCCurtainStateUp);
    assert(set.visible);
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
}

int main(void)
{
    @autoreleasepool {
        testWindowSetBookkeeping();
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
