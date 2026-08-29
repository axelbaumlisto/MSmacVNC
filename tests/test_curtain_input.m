#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <assert.h>
#include <stdio.h>
#include <unistd.h>

#import "MacVNCCurtainInput.h"
#import "MacVNCCurtainWindow.h"

/*
 * The input half of curtain mode, with no tap and no device.
 *
 * This is the module that can trap a human behind their own Mac, so what is
 * tested here is every way it can refuse, and every way it hands control back:
 * the three preconditions (a tap that exists but is DEAF to the keyboard is
 * the one that reads like success), the pass-through that keeps the remote
 * viewer working, both tap-disable reasons, the secure-input transition, the
 * focus rule, and the watchdog's one non-obvious property - that SILENCE is
 * health, because a curtain nobody is typing behind produces no events at all.
 *
 * Real CGEvents are used throughout: they can be built, tagged and re-stamped
 * with a foreign process id without posting anything anywhere, so "is this one
 * of ours" is tested against the same API the callback reads rather than
 * against a mock of it.
 */

/* ---------------------------------------------------------------------- */
/* Fakes.                                                                  */
/* ---------------------------------------------------------------------- */

@interface FakeTap : NSObject <MacVNCCurtainInputTap>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL trusted;
@property (nonatomic, assign) BOOL startSucceeds;
@property (nonatomic, assign) uint64_t effectiveMask;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL reenableSucceeds;
@property (nonatomic, assign) BOOL secureInput;
@property (nonatomic, assign) BOOL hasThread;
@property (nonatomic, assign) NSUInteger startCount;
@property (nonatomic, assign) NSUInteger stopCount;
@property (nonatomic, assign) NSUInteger reenableCount;
@property (nonatomic, assign) NSUInteger performCount;
@property (nonatomic, assign) id<MacVNCCurtainInputTapHandler> handler;  /* not owned */
/* The re-entrant seam: -reenableTap is called from INSIDE a tap callback, so a
   fake that records there observes what the watchdog thread would see while a
   callback is running. Without this the stamp could only be sampled before or
   after, which is exactly the hole this file used to have. */
@property (nonatomic, assign) id<MacVNCCurtainInputTapHandler> observed;  /* not owned */
@property (nonatomic, assign) uint64_t entryStampSeenDuringCallback;
@property (nonatomic, assign) uint64_t pollStampSeenDuringCallback;
@property (nonatomic, assign) BOOL sawCallbackInFlight;
@end

@implementation FakeTap

- (instancetype)init
{
    if ((self = [super init])) {
        _trusted = YES;
        _startSucceeds = YES;
        _enabled = YES;
        _reenableSucceeds = YES;
        _hasThread = YES;
        _effectiveMask = MACVNC_CURTAIN_INPUT_EVENT_MASK;
    }
    return self;
}

- (BOOL)processIsTrustedForAccessibility { return _trusted; }

- (BOOL)startWithEventMask:(uint64_t)eventMask
                   handler:(id<MacVNCCurtainInputTapHandler>)handler
{
    ++_startCount;
    [_log addObject:_startSucceeds ? @"tap-start" : @"tap-start-failed"];
    if (!_startSucceeds)
        return NO;
    _handler = handler;
    assert(eventMask == MACVNC_CURTAIN_INPUT_EVENT_MASK);
    return YES;
}

- (uint64_t)effectiveEventMask { return _effectiveMask; }
- (BOOL)tapIsEnabled { return _enabled; }

- (BOOL)reenableTap
{
    ++_reenableCount;
    [_log addObject:@"tap-reenable"];
    if (_observed) {
        _entryStampSeenDuringCallback = [_observed callbackEntryNanoseconds];
        _pollStampSeenDuringCallback = [_observed lastPollCompletedNanoseconds];
        _sawCallbackInFlight = YES;
    }
    if (_reenableSucceeds)
        _enabled = YES;
    return _reenableSucceeds;
}

- (BOOL)secureInputIsEnabled { return _secureInput; }

- (BOOL)performOnTapThread:(dispatch_block_t)block
{
    ++_performCount;
    if (!_hasThread)
        return NO;
    /* Inline: the real one hops onto the tap thread, and what the test cares
       about is that the work happens THERE rather than on the caller. */
    if (block)
        block();
    return YES;
}

- (void)stop
{
    ++_stopCount;
    [_log addObject:@"tap-stop"];
    _handler = nil;
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeFocus : NSObject <MacVNCCurtainInputFocus>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL accepts;
@property (nonatomic, assign) id sink;                            /* not owned */
@end

@implementation FakeFocus

- (void)setAcceptsKeyboardFocus:(BOOL)accepts
{
    _accepts = accepts;
    [_log addObject:accepts ? @"focus-to-curtain" : @"focus-not-curtain"];
}

- (void)setKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink
{
    _sink = sink;
    [_log addObject:sink ? @"sink-set" : @"sink-cleared"];
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeObserver : NSObject <MacVNCCurtainInputObserver>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) NSUInteger unlockCount;
@property (nonatomic, assign) NSUInteger unavailableCount;
@property (nonatomic, assign) NSUInteger secureInputReports;
@property (nonatomic, assign) BOOL secureInputActive;
@end

@implementation FakeObserver

- (void)noteLocalUnlockAccepted
{
    ++_unlockCount;
    [_log addObject:@"unlock-accepted"];
}

- (void)setSecureInputActive:(BOOL)active
{
    ++_secureInputReports;
    _secureInputActive = active;
    [_log addObject:active ? @"secure-input-on" : @"secure-input-off"];
}

- (void)noteInputSuppressionUnavailable
{
    ++_unavailableCount;
    [_log addObject:@"suppression-unavailable"];
}

@end

/* ---------------------------------------------------------------------- */

@interface FakeSecretSource : NSObject <MacVNCCurtainSecretSource>
@property (nonatomic, retain) NSData *secret;
@end

@implementation FakeSecretSource
- (NSData *)copyCurtainSecret { return [_secret retain]; }
- (void)dealloc { [_secret release]; [super dealloc]; }
@end

/* Deferred work, run by hand. Unlike the controller's heartbeat, every hop
   this module makes is an IMMEDIATE main-queue hop (zero delay), because it is
   a report, not a schedule: a delayed report would be a curtain that stays up
   after the tap died. */
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
    assert(nanoseconds == 0 && "reports hop immediately; nothing here is scheduled");
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

- (void)dealloc { [_pending release]; [super dealloc]; }

@end

@interface FakeClock : NSObject <MacVNCCurtainClock>
@property (nonatomic, assign) uint64_t now;
@end

@implementation FakeClock
- (uint64_t)monotonicNanoseconds { return _now; }
@end

/* An occluder set that records the focus calls and nothing else - enough to
   check that MacVNCCurtainWindowSet passes the rule down to real windows. */
@interface RecordingOccluders : NSObject <MacVNCCurtainOccluders>
@property (nonatomic, assign) NSMutableArray<NSString *> *log;   /* not owned */
@property (nonatomic, assign) BOOL accepts;
@property (nonatomic, assign) id sink;                            /* not owned */
@end

@implementation RecordingOccluders
- (NSArray<NSNumber *> *)attachedScreenIdentifiers { return @[ @1 ]; }
- (BOOL)createOccluderForScreen:(NSNumber *)identifier { (void)identifier; return YES; }
- (void)removeOccluderForScreen:(NSNumber *)identifier { (void)identifier; }
- (void)updateOccluderGeometryForScreen:(NSNumber *)identifier { (void)identifier; }
- (void)setOccludersVisible:(BOOL)visible { (void)visible; }
- (void)setOccludersAcceptKeyboardFocus:(BOOL)accepts
{
    _accepts = accepts;
    [_log addObject:accepts ? @"occluders-key" : @"occluders-not-key"];
}
- (void)setOccludersKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink { _sink = sink; }
@end

/* ---------------------------------------------------------------------- */
/* The rig.                                                                */
/* ---------------------------------------------------------------------- */

@interface Rig : NSObject
@property (nonatomic, retain) NSMutableArray<NSString *> *log;
@property (nonatomic, retain) FakeTap *tap;
@property (nonatomic, retain) FakeFocus *focus;
@property (nonatomic, retain) FakeObserver *observer;
@property (nonatomic, retain) FakeSecretSource *secretSource;
@property (nonatomic, retain) ManualScheduler *scheduler;
@property (nonatomic, retain) FakeClock *clock;
@property (nonatomic, retain) MacVNCCurtainInput *input;
@end

@implementation Rig
- (void)dealloc
{
    /* THE INPUT GOES FIRST, for the same reason its own -dealloc stops the tap
       before releasing anything the callback touches: dropping it last would
       have it message fakes - and the shared log they write to - after they
       were freed. This ordering is the rig's half of that rule, and it caught
       a real crash when -dealloc started tearing the tap down. */
    [_input release];
    [_tap release];
    [_focus release];
    [_observer release];
    [_secretSource release];
    [_scheduler release];
    [_clock release];
    [_log release];
    [super dealloc];
}
@end

static Rig *makeRig(void)
{
    Rig *rig = [[[Rig alloc] init] autorelease];
    rig.log = [NSMutableArray array];
    rig.tap = [[[FakeTap alloc] init] autorelease];
    rig.tap.log = rig.log;
    rig.focus = [[[FakeFocus alloc] init] autorelease];
    rig.focus.log = rig.log;
    rig.observer = [[[FakeObserver alloc] init] autorelease];
    rig.observer.log = rig.log;
    rig.secretSource = [[[FakeSecretSource alloc] init] autorelease];
    rig.secretSource.secret = [@"hunter2" dataUsingEncoding:NSUTF8StringEncoding];
    rig.scheduler = [[[ManualScheduler alloc] init] autorelease];
    rig.clock = [[[FakeClock alloc] init] autorelease];
    /* Not zero: the policy's throttle is a deadline against this clock, and a
       clock frozen at 0 would make every deadline already passed. */
    rig.clock.now = 1000ull * 1000ull * 1000ull;
    rig.input = [[[MacVNCCurtainInput alloc] initWithTap:rig.tap
                                                   focus:rig.focus
                                                observer:rig.observer
                                            secretSource:rig.secretSource
                                               scheduler:rig.scheduler
                                                   clock:rig.clock] autorelease];
    return rig;
}

static Rig *armedRig(void)
{
    Rig *rig = makeRig();
    assert([rig.input beginSuppressingInput]);
    [rig.log removeAllObjects];
    return rig;
}

/* ---------------------------------------------------------------------- */
/* Event builders. Nothing is ever posted.                                 */
/* ---------------------------------------------------------------------- */

/* A keystroke from the person standing at the Mac: no tag, and a process id
   that is not ours. */
static CGEventRef localKeyEvent(UniChar character)
{
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)0, true);
    assert(event);
    CGEventKeyboardSetUnicodeString(event, 1, &character);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 1);
    return event;
}

static CGEventRef localMouseEvent(void)
{
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                               CGPointMake(10, 10),
                                               kCGMouseButtonLeft);
    assert(event);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 1);
    return event;
}

/* What MacVNCInput.m injects on the remote viewer's behalf: built from a
   source carrying the shared tag. */
static CGEventRef taggedRemoteEvent(void)
{
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    assert(source);
    CGEventSourceSetUserData(source, MACVNC_CURTAIN_INPUT_EVENT_MAGIC);
    CGEventRef event = CGEventCreateKeyboardEvent(source, (CGKeyCode)0, true);
    CFRelease(source);
    assert(event);
    /* A foreign pid, so the tag is what is doing the work here and not the
       process check below it. */
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 1);
    return event;
}

/* The one path that cannot be tagged: CGPostMouseEvent builds its own event
   and it reaches the tap carrying only our process id. */
static CGEventRef untaggableOwnMouseEvent(void)
{
    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                               CGPointMake(1, 1),
                                               kCGMouseButtonLeft);
    assert(event);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0);
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, (int64_t)getpid());
    return event;
}

static void typeLocally(Rig *rig, const char *text)
{
    for (const char *c = text; *c; ++c) {
        CGEventRef event = localKeyEvent((UniChar)*c);
        CGEventRef passed = [rig.input handleTapEventOfType:kCGEventKeyDown
                                                      event:event];
        assert(passed == NULL && "local keystrokes are swallowed");
        CFRelease(event);
        rig.clock.now += 1000ull * 1000ull;      /* 1 ms per keystroke */
    }
}

/* ---------------------------------------------------------------------- */
/* Preconditions - the refusals.                                           */
/* ---------------------------------------------------------------------- */

static void testRefusesWithoutAccessibilityTrust(void)
{
    Rig *rig = makeRig();
    rig.tap.trusted = NO;

    assert(![rig.input beginSuppressingInput]);
    assert(!rig.input.suppressing);
    /* Not even created: a tap made without trust is the deaf one below. */
    assert(rig.tap.startCount == 0);
    /* And nothing was handed the keyboard focus on the way out. */
    assert([rig.log count] == 0);
}

static void testRefusesWhenTheTapCannotBeCreated(void)
{
    Rig *rig = makeRig();
    rig.tap.startSucceeds = NO;

    assert(![rig.input beginSuppressingInput]);
    assert(!rig.input.suppressing);
    assert(rig.tap.startCount == 1);
}

/*
 * THE precondition. Without Accessibility trust the keyboard bits are silently
 * cleared from the mask while CGEventTapCreate still returns non-NULL - so a
 * module that trusts "the tap was created" produces a black screen, a dead
 * mouse, a fully live keyboard typing into invisible applications, and an
 * escape hatch that never sees a key.
 */
static void testRefusesWhenTheKeyboardWasClearedFromTheEffectiveMask(void)
{
    Rig *rig = makeRig();
    rig.tap.effectiveMask = MACVNC_CURTAIN_INPUT_POINTER_MASK;   /* deaf */

    assert(![rig.input beginSuppressingInput]);
    assert(!rig.input.suppressing);
    /* The tap it did create is torn down again: a live pointer-only tap with
       nothing on screen would swallow the local user's mouse for nothing. */
    assert(rig.tap.stopCount == 1);
    assert([rig.log isEqualToArray:(@[ @"tap-start", @"tap-stop" ])]);
}

static void testAnUnreadableMaskIsARefusal(void)
{
    Rig *rig = makeRig();
    rig.tap.effectiveMask = 0;      /* CGGetEventTapList could not answer */
    assert(![rig.input beginSuppressingInput]);
}

static void testTheMaskRuleWantsEveryKeyboardBit(void)
{
    assert(macVNCCurtainInputMaskKeepsKeyboard(MACVNC_CURTAIN_INPUT_EVENT_MASK));
    assert(macVNCCurtainInputMaskKeepsKeyboard(MACVNC_CURTAIN_INPUT_KEYBOARD_MASK));
    assert(!macVNCCurtainInputMaskKeepsKeyboard(0));
    assert(!macVNCCurtainInputMaskKeepsKeyboard(MACVNC_CURTAIN_INPUT_POINTER_MASK));
    /* Key events but no modifier changes: every Command shortcut would reach
       a desktop nobody can see. */
    assert(!macVNCCurtainInputMaskKeepsKeyboard(
        MACVNC_CURTAIN_INPUT_EVENT_MASK & ~(1ULL << kCGEventFlagsChanged)));
}

static void testRefusesWithoutAPasswordToTypeBack(void)
{
    Rig *rig = makeRig();
    rig.secretSource.secret = nil;

    assert(![rig.input beginSuppressingInput]);
    /* The refusal comes BEFORE the tap exists: a curtain with no way out must
       not even briefly swallow the local user's keyboard. */
    assert(rig.tap.startCount == 0);
}

static void testArmingKeepsTheCurtainWindowAwayFromTheKeyboard(void)
{
    Rig *rig = makeRig();
    assert([rig.input beginSuppressingInput]);
    assert(rig.input.suppressing);
    assert(!rig.input.tapPathUnavailable);
    /* Rule 5: the tap is healthy, so the window is NOT key - it would collect
       the REMOTE party's keystrokes if it were. */
    assert(!rig.focus.accepts);
    assert([rig.log isEqualToArray:(@[ @"tap-start", @"sink-set",
                                       @"focus-not-curtain" ])]);
    /* Idempotent. */
    assert([rig.input beginSuppressingInput]);
    assert(rig.tap.startCount == 1);
}

/* ---------------------------------------------------------------------- */
/* The pass-through.                                                       */
/* ---------------------------------------------------------------------- */

static void testOurOwnTaggedInjectionPassesThroughUnmodified(void)
{
    Rig *rig = armedRig();
    CGEventRef event = taggedRemoteEvent();
    CGEventRef passed = [rig.input handleTapEventOfType:kCGEventKeyDown event:event];
    /* The SAME event, not a copy and not a swallow: this is the remote
       viewer's own keyboard arriving at our own tap. */
    assert(passed == event);
    CFRelease(event);
}

static void testTheUntaggableInjectionPathIsRecognisedByProcessId(void)
{
    Rig *rig = armedRig();
    CGEventRef event = untaggableOwnMouseEvent();
    assert([rig.input handleTapEventOfType:kCGEventMouseMoved event:event] == event);
    CFRelease(event);
}

static void testLocalInputIsSwallowed(void)
{
    Rig *rig = armedRig();
    CGEventRef key = localKeyEvent('a');
    assert([rig.input handleTapEventOfType:kCGEventKeyDown event:key] == NULL);
    CFRelease(key);
    CGEventRef mouse = localMouseEvent();
    assert([rig.input handleTapEventOfType:kCGEventMouseMoved event:mouse] == NULL);
    CFRelease(mouse);
}

static void testTheSelfInjectionRuleItself(void)
{
    CGEventRef tagged = taggedRemoteEvent();
    assert(macVNCCurtainInputEventIsSelfInjected(kCGEventKeyDown, tagged));
    CFRelease(tagged);

    CGEventRef ours = untaggableOwnMouseEvent();
    assert(macVNCCurtainInputEventIsSelfInjected(kCGEventMouseMoved, ours));
    CFRelease(ours);

    CGEventRef theirs = localKeyEvent('x');
    assert(!macVNCCurtainInputEventIsSelfInjected(kCGEventKeyDown, theirs));
    CFRelease(theirs);

    assert(!macVNCCurtainInputEventIsSelfInjected(kCGEventKeyDown, NULL));
}

/*
 * The process-id leg exists for ONE path - CGPostMouseEvent, which is a
 * pointer path - and is granted to pointer events only. Keyboard injection is
 * tagged at the source, and the tag was measured to survive CGEventPost
 * through WindowServer, so a KEY event carrying our pid but no tag is not
 * something this server posts.
 */
static void testTheProcessIdLegIsPointerOnly(void)
{
    /* Same event contents, same pid, no tag: pointer passes, key does not. */
    CGEventRef pointer = untaggableOwnMouseEvent();
    assert(macVNCCurtainInputEventIsSelfInjected(kCGEventMouseMoved, pointer));
    assert(macVNCCurtainInputEventIsSelfInjected(kCGEventLeftMouseDragged, pointer));
    CFRelease(pointer);

    CGEventRef key = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)0, true);
    CGEventSetIntegerValueField(key, kCGEventSourceUserData, 0);
    CGEventSetIntegerValueField(key, kCGEventSourceUnixProcessID, (int64_t)getpid());
    assert(!macVNCCurtainInputEventIsSelfInjected(kCGEventKeyDown, key));
    /* Scroll is built from the tagged source too, so it does not get the leg. */
    assert(!macVNCCurtainInputEventIsSelfInjected(kCGEventScrollWheel, key));
    CFRelease(key);
}

/* ---------------------------------------------------------------------- */
/* The way back in.                                                        */
/* ---------------------------------------------------------------------- */

static void testTypingThePasswordLocallyUnlocks(void)
{
    Rig *rig = armedRig();
    typeLocally(rig, "hunter2\r");
    /* Reported on the MAIN thread, not from the callback. */
    assert(rig.observer.unlockCount == 0);
    assert([rig.scheduler fire] == 1);
    assert(rig.observer.unlockCount == 1);
}

static void testAWrongPasswordDoesNotUnlock(void)
{
    Rig *rig = armedRig();
    typeLocally(rig, "hunter3\r");
    [rig.scheduler fire];
    assert(rig.observer.unlockCount == 0);
}

static void testTheRemotePartyCannotTypeTheCurtainOpen(void)
{
    Rig *rig = armedRig();
    /* The same characters, but injected by us on the remote viewer's behalf.
       They pass through to the desktop and must never reach the policy - the
       escape hatch belongs to the person standing at the Mac. */
    for (const char *c = "hunter2\r"; *c; ++c) {
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
        CGEventSourceSetUserData(source, MACVNC_CURTAIN_INPUT_EVENT_MAGIC);
        CGEventRef event = CGEventCreateKeyboardEvent(source, (CGKeyCode)0, true);
        CFRelease(source);
        UniChar character = (UniChar)*c;
        CGEventKeyboardSetUnicodeString(event, 1, &character);
        assert([rig.input handleTapEventOfType:kCGEventKeyDown event:event] == event);
        CFRelease(event);
    }
    [rig.scheduler fire];
    assert(rig.observer.unlockCount == 0);
}

static void testKeysThatReachTheWindowFeedTheSamePolicy(void)
{
    Rig *rig = armedRig();
    /* Put the rig in the ONLY state where this can happen: the tap path is
       unavailable, so the window holds the keyboard and the characters arrive
       through it instead. They are carried onto the tap's thread. */
    rig.tap.secureInput = YES;
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.input.tapPathUnavailable);
    assert(rig.focus.accepts);

    const char *text = "hunter2\r";
    for (const char *c = text; *c; ++c) {
        uint16_t unit = (uint16_t)*c;
        [rig.input curtainWindowDidReceiveCharacters:&unit count:1];
        rig.clock.now += 1000ull * 1000ull;
    }
    [rig.scheduler fire];
    assert(rig.observer.unlockCount == 1);
}

/*
 * THE FOCUS HAND-OVER LATCHES - a design decision, not a patch. Taking the
 * keyboard means ACTIVATING this application, which deactivates whoever held
 * secure input, so IsSecureEventInputEnabled() - a session-wide query - reads
 * false on the very next poll. Handing the focus back on that reading would
 * flap at 10 Hz with the local user's password split across two applications,
 * which is the exact disclosure the secure-input rule exists to prevent. So
 * within one suppression session the focus only ever goes NO -> YES;
 * endSuppressingInput gives it back, and the report that triggered the
 * hand-over is already lifting the curtain.
 */
static void testTheFocusHandOverDoesNotFlapBackWhenSecureInputClears(void)
{
    Rig *rig = armedRig();

    rig.tap.secureInput = YES;
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.focus.accepts);

    /* Exactly what activating our app causes: the owner is deactivated, and
       the session-wide query now says nothing is wrong. */
    rig.tap.secureInput = NO;
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.secureInputReports == 2);   /* still reported honestly */
    assert(!rig.observer.secureInputActive);
    assert(rig.focus.accepts && "the keyboard must not flap back mid-password");

    /* The same latch answers the other route: secure input clearing while the
       tap is ALSO unrecoverably disabled must not take the keyboard away from
       the only window that can still receive it. */
    rig.tap.reenableSucceeds = NO;
    rig.tap.enabled = NO;
    [rig.input handleTapEventOfType:kCGEventTapDisabledByTimeout event:NULL];
    [rig.scheduler fire];
    assert(rig.focus.accepts);

    /* And only the teardown gives it back. */
    [rig.input endSuppressingInput];
    assert(!rig.focus.accepts);
}

/*
 * A report is dispatched from the tap thread and runs later, on main. By the
 * time it lands, suppression may already have ended - the lift that an earlier
 * report triggered is exactly how that happens - and a report that still acted
 * would hand the keyboard to a curtain window nobody is going to take it back
 * from, leaving the flag set on the window set for the next curtain to
 * inherit.
 */
static void testAReportThatLandsAfterTeardownChangesNothing(void)
{
    Rig *rig = armedRig();

    /* Both routes to a report, armed but not yet delivered. */
    rig.tap.secureInput = YES;
    [rig.input handleTapPoll];
    rig.tap.reenableSucceeds = NO;
    rig.tap.enabled = NO;
    [rig.input handleTapEventOfType:kCGEventTapDisabledByTimeout event:NULL];

    /* Suppression ends first - the focus goes back and the sink is cleared. */
    [rig.input endSuppressingInput];
    assert(!rig.focus.accepts);
    assert(rig.focus.sink == nil);

    /* Now the reports land. */
    [rig.scheduler fire];
    assert(!rig.focus.accepts && "a late report must not re-take the keyboard");
    assert(rig.observer.secureInputReports == 0);
    assert(rig.observer.unavailableCount == 0);
}

static void testWindowKeysAfterTeardownAreDroppedAtTheDoor(void)
{
    Rig *rig = armedRig();
    uint16_t unit = 'h';
    [rig.input curtainWindowDidReceiveCharacters:&unit count:1];
    assert(rig.tap.performCount == 1);      /* armed: carried to the tap thread */

    [rig.input endSuppressingInput];
    /* A window that is still up for a moment after the lift must not hand work
       to a tap thread that has been joined and a policy that has been reset. */
    [rig.input curtainWindowDidReceiveCharacters:&unit count:1];
    assert(rig.tap.performCount == 1);
}

static void testWindowKeysAreDroppedWhenThereIsNoTapThreadToOwnThePolicy(void)
{
    Rig *rig = armedRig();
    rig.tap.hasThread = NO;
    uint16_t unit = 'h';
    [rig.input curtainWindowDidReceiveCharacters:&unit count:1];
    /* Nothing crashed and nothing was fed: the policy has exactly one owner,
       and if that owner is gone the characters are dropped rather than raced
       in from the main thread. */
    assert([rig.scheduler fire] == 0);
}

/* ---------------------------------------------------------------------- */
/* Both disable reasons.                                                   */
/* ---------------------------------------------------------------------- */

static void testBothDisableReasonsAreReEnabled(void)
{
    Rig *rig = armedRig();

    rig.tap.enabled = NO;
    assert([rig.input handleTapEventOfType:kCGEventTapDisabledByTimeout
                                     event:NULL] == NULL);
    assert(rig.tap.reenableCount == 1);
    assert(rig.tap.enabled);

    rig.tap.enabled = NO;
    [rig.input handleTapEventOfType:kCGEventTapDisabledByUserInput event:NULL];
    assert(rig.tap.reenableCount == 2);
    assert(rig.tap.enabled);

    [rig.scheduler fire];
    /* Re-enabled means still available: nothing was reported, nothing changed
       hands. */
    assert(rig.observer.unavailableCount == 0);
    assert(!rig.input.tapPathUnavailable);
    assert(!rig.focus.accepts);
}

static void testADisableThatDoesNotStickHandsControlBack(void)
{
    Rig *rig = armedRig();
    rig.tap.reenableSucceeds = NO;
    rig.tap.enabled = NO;

    [rig.input handleTapEventOfType:kCGEventTapDisabledByUserInput event:NULL];
    assert(rig.input.tapPathUnavailable);
    /* Nothing is reported FROM the callback: the controller is main-thread
       only, and a callback that called into it would be a callback that can
       block on the main queue. */
    assert(rig.observer.unavailableCount == 0);
    [rig.scheduler fire];
    assert(rig.observer.unavailableCount == 1);
    /* Rule 5's other half: NOW the window may take the keyboard, because the
       tap is no longer a path to the policy - and the focus is handed over
       BEFORE the controller is told, so no keystroke lands in a watched app in
       between. */
    assert(rig.focus.accepts);
    NSUInteger focusIndex = [rig.log indexOfObject:@"focus-to-curtain"];
    NSUInteger reportIndex = [rig.log indexOfObject:@"suppression-unavailable"];
    assert(focusIndex < reportIndex);

    /* A second disable reports nothing new: the controller is already lifting. */
    [rig.input handleTapEventOfType:kCGEventTapDisabledByTimeout event:NULL];
    [rig.scheduler fire];
    assert(rig.observer.unavailableCount == 1);
}

static void testASilentDisableIsCaughtByThePoll(void)
{
    Rig *rig = armedRig();
    /* No callback ever arrives to say so - a dead tap delivers nothing, and
       the disable notification is itself an event. */
    rig.tap.enabled = NO;
    rig.tap.reenableSucceeds = NO;

    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.unavailableCount == 1);
    assert(rig.focus.accepts);
}

/* ---------------------------------------------------------------------- */
/* Secure input.                                                           */
/* ---------------------------------------------------------------------- */

static void testSecureInputHandsFocusOverAndIsReportedOnce(void)
{
    Rig *rig = armedRig();

    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.secureInputReports == 0);   /* nothing happened */

    rig.tap.secureInput = YES;
    [rig.input handleTapPoll];
    assert(rig.input.tapPathUnavailable);
    assert([rig.scheduler fire] == 1);
    assert(rig.observer.secureInputReports == 1);
    assert(rig.observer.secureInputActive);
    assert(rig.focus.accepts);
    NSUInteger focusIndex = [rig.log indexOfObject:@"focus-to-curtain"];
    NSUInteger reportIndex = [rig.log indexOfObject:@"secure-input-on"];
    assert(focusIndex < reportIndex);

    /* Edge-triggered: polling again while it is still on says nothing. */
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.secureInputReports == 1);

    /* And it is reported when it goes away again - the REPORT is level-honest
       in both directions, so the controller sees the truth. The FOCUS is not:
       see testTheFocusHandOverDoesNotFlapBackWhenSecureInputClears for why it
       latches instead of following this edge back down. */
    rig.tap.secureInput = NO;
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.secureInputReports == 2);
    assert(!rig.observer.secureInputActive);
    assert(!rig.input.tapPathUnavailable);
}

static void testKeyboardSilenceUnderPointerTrafficCorroboratesSecureInput(void)
{
    const uint64_t second = 1000ull * 1000ull * 1000ull;
    /* Nothing has stopped if nothing ever started: a local user who only ever
       moves the mouse must not lift their own curtain. */
    assert(!macVNCCurtainInputSecureInputSuspected(0, 10 * second, 10 * second));
    /* Keys were flowing, then stopped, while the pointer kept going. */
    assert(macVNCCurtainInputSecureInputSuspected(second, 10 * second,
                                                  10 * second + second));
    /* Keys stopped and so did the pointer: that is an idle desk, not a
       withheld keyboard. */
    assert(!macVNCCurtainInputSecureInputSuspected(second, 2 * second,
                                                   60 * second));
    /* A key came in more recently than the pointer: the keyboard is arriving. */
    assert(!macVNCCurtainInputSecureInputSuspected(10 * second, 9 * second,
                                                   10 * second));
    /* Within the silence bound it is not yet a signal. */
    assert(!macVNCCurtainInputSecureInputSuspected(10 * second, 11 * second,
                                                   11 * second));
}

static void testTheTrafficSignalReachesTheObserver(void)
{
    Rig *rig = armedRig();
    const uint64_t second = 1000ull * 1000ull * 1000ull;

    CGEventRef key = localKeyEvent('a');
    [rig.input handleTapEventOfType:kCGEventKeyDown event:key];
    CFRelease(key);

    rig.clock.now += 6 * second;          /* keys stop */
    CGEventRef mouse = localMouseEvent(); /* the pointer keeps going */
    [rig.input handleTapEventOfType:kCGEventMouseMoved event:mouse];
    CFRelease(mouse);

    assert(!rig.tap.secureInput);          /* the API says nothing is wrong */
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.secureInputActive);
}

/* ---------------------------------------------------------------------- */
/* The watchdog.                                                           */
/* ---------------------------------------------------------------------- */

static void testWatchdogTreatsEventSilenceAsHealth(void)
{
    /* The feature's NORMAL state: a curtain is up, nobody is typing, no
       callback has run for an hour. A watchdog that measured EVENT silence
       would kill the process here - which is why events are judged by latency.
       The poll is fresh, because a timer does not need a human. */
    const uint64_t hour = 3600ull * 1000000000ull;
    MacVNCCurtainInputWatchdogState state = {
        .lastPollCompletedNanoseconds = hour,
    };
    assert(macVNCCurtainInputWatchdogEvaluate(&state, hour) ==
           MacVNCCurtainInputWatchdogHealthy);
}

static void testWatchdogCatchesACallbackInFlightTooLong(void)
{
    MacVNCCurtainInputWatchdogState state = {
        .callbackEntryNanoseconds = 1000,
        .lastPollCompletedNanoseconds = 1,   /* a live poll: not what is tested */
    };
    assert(macVNCCurtainInputWatchdogEvaluate(
               &state, 1000 + MACVNC_CURTAIN_INPUT_CALLBACK_STALL_NANOSECONDS) ==
           MacVNCCurtainInputWatchdogCallbackStalled);
    /* A callback that is merely running is not a wedge. */
    assert(macVNCCurtainInputWatchdogEvaluate(&state, 1000 + 1000) ==
           MacVNCCurtainInputWatchdogHealthy);
}

static void testWatchdogCatchesAMainThreadThatNeverAnswers(void)
{
    MacVNCCurtainInputWatchdogState state = {
        .heartbeatSentNanoseconds = 1000,
        .lastPollCompletedNanoseconds = 1000 + MACVNC_CURTAIN_INPUT_MAIN_STALL_NANOSECONDS,
    };
    assert(macVNCCurtainInputWatchdogEvaluate(
               &state, 1000 + MACVNC_CURTAIN_INPUT_MAIN_STALL_NANOSECONDS) ==
           MacVNCCurtainInputWatchdogMainThreadStalled);
    assert(macVNCCurtainInputWatchdogEvaluate(&state, 1000 + 1000) ==
           MacVNCCurtainInputWatchdogHealthy);
    /* An acknowledged heartbeat is a zero: no beat is outstanding, so however
       long ago it was, nothing is wrong. */
    MacVNCCurtainInputWatchdogState acknowledged = {
        .lastPollCompletedNanoseconds = ~0ull,
    };
    assert(macVNCCurtainInputWatchdogEvaluate(&acknowledged, ~0ull) ==
           MacVNCCurtainInputWatchdogHealthy);
}

/*
 * The poll is the exception to "latency, not silence", and it is the exception
 * that closes the blind spot: it is TIMER-driven, so nobody has to touch
 * anything for it to run. If it stops, the tap thread's run loop has stopped
 * servicing everything - the tap swallows nothing, and the only detector of a
 * silently deaf tap has died with it. Without this clause that state reads as
 * healthy: black screen, fully live keyboard, no report, no hatch.
 */
static void testWatchdogTreatsPollSilenceAsAFault(void)
{
    MacVNCCurtainInputWatchdogState state = {
        .lastPollCompletedNanoseconds = 1000,
    };
    assert(macVNCCurtainInputWatchdogEvaluate(
               &state, 1000 + MACVNC_CURTAIN_INPUT_POLL_STALL_NANOSECONDS) ==
           MacVNCCurtainInputWatchdogPollStalled);
    /* One or two missed ticks are scheduling, not death. */
    assert(macVNCCurtainInputWatchdogEvaluate(
               &state, 1000 + MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS * 3) ==
           MacVNCCurtainInputWatchdogHealthy);
    /* And a poll that has never run yet is not judged at all: arming stamps a
       baseline, but a zero must never abort a process. */
    MacVNCCurtainInputWatchdogState unarmed = {0, 0, 0, 0};
    assert(macVNCCurtainInputWatchdogEvaluate(&unarmed, ~0ull) ==
           MacVNCCurtainInputWatchdogHealthy);
}

/*
 * abort() is the one action here that is not fail-safe when it is wrong, and
 * the ordinary case that would make it wrong is a lid closing: Darwin's
 * CLOCK_MONOTONIC keeps advancing while the process is frozen, so on wake
 * every stamp looks ancient on a machine where nothing failed.
 */
static void testUnobservedTimeIsNotAWedge(void)
{
    const uint64_t minute = 60ull * 1000000000ull;
    /* Everything looks terrible - a callback in flight since before the sleep,
       a heartbeat never answered, a poll that has not run - and none of it is
       a fault, because the watchdog itself did not run either. */
    MacVNCCurtainInputWatchdogState afterSleep = {
        .callbackEntryNanoseconds = 1000,
        .heartbeatSentNanoseconds = 1000,
        .lastPollCompletedNanoseconds = 1000,
        .observationGapNanoseconds = minute,
    };
    assert(macVNCCurtainInputWatchdogEvaluate(&afterSleep, minute) ==
           MacVNCCurtainInputWatchdogUnobservedGap);

    /* The same stamps with the watchdog running normally ARE a fault: the gap
       is what distinguishes a frozen process from a wedged one. */
    MacVNCCurtainInputWatchdogState observed = afterSleep;
    observed.observationGapNanoseconds = MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS;
    assert(macVNCCurtainInputWatchdogEvaluate(&observed, minute) ==
           MacVNCCurtainInputWatchdogCallbackStalled);
}

/*
 * The watchdog's only real input, observed WHERE IT MATTERS: from inside a
 * callback that is running. Reading the stamp before or after the callback can
 * only ever see zero, so a test that did that would stay green with the stamp
 * deleted - and the watchdog would be permanently blind to the wedge it exists
 * to catch, which is the mechanism that rescues someone trapped behind their
 * own Mac. -reenableTap is called from within the callback, so the fake reads
 * the stamp through the same accessor the watchdog thread uses.
 */
static void testTheCallbackStampIsVisibleToTheWatchdogWhileItRuns(void)
{
    Rig *rig = armedRig();
    assert([rig.input callbackEntryNanoseconds] == 0);   /* nothing in flight */

    rig.tap.observed = rig.input;
    /* A clock that legitimately reads ZERO must still not look like an idle
       tap while a callback is running: that is what the sentinel is for. */
    rig.clock.now = 0;
    [rig.input handleTapEventOfType:kCGEventTapDisabledByTimeout event:NULL];

    assert(rig.tap.sawCallbackInFlight);
    assert(rig.tap.entryStampSeenDuringCallback != 0);
    /* Cleared on the way out, so silence really is silence afterwards. */
    assert([rig.input callbackEntryNanoseconds] == 0);

    /* The same stamp, with a clock that is not zero. */
    rig.clock.now = 12345;
    rig.tap.entryStampSeenDuringCallback = 0;
    [rig.input handleTapEventOfType:kCGEventTapDisabledByUserInput event:NULL];
    assert(rig.tap.entryStampSeenDuringCallback == 12345);
    assert([rig.input callbackEntryNanoseconds] == 0);
}

/*
 * The poll is watched by its COMPLETION stamp and by nothing else.
 *
 * It is deliberately NOT stamped into the in-flight field the callback uses:
 * that field is judged at 500 ms, a bound justified by what a callback does
 * (a few field reads and one comparison), while the poll makes synchronous
 * cross-process calls to WindowServer. Stamping it there would let a briefly
 * slow WindowServer abort() a healthy, live server - the one action here that
 * is not fail-safe when it is wrong - and it would add no detection, because a
 * poll that wedges stops advancing the completion stamp and PollStalled
 * already catches that at a bound that matches what the poll actually does.
 */
static void testThePollIsJudgedByItsCompletionStampNotByTheCallbackBound(void)
{
    Rig *rig = armedRig();
    /* Armed, but no poll has completed yet: the baseline is non-zero so the
       watchdog never reads "armed a moment ago" as "the run loop is dead". */
    uint64_t baseline = [rig.input lastPollCompletedNanoseconds];
    assert(baseline != 0);

    rig.tap.observed = rig.input;
    rig.tap.enabled = NO;            /* makes the poll call -reenableTap */
    rig.clock.now += 1000;
    [rig.input handleTapPoll];

    /* Observed from INSIDE the running poll: no callback-stall timer is armed
       against it, so WindowServer taking its time here cannot trip the 500 ms
       abort. */
    assert(rig.tap.sawCallbackInFlight);
    assert(rig.tap.entryStampSeenDuringCallback == 0);
    /* ...and the completion stamp had not yet moved while it ran. */
    assert(rig.tap.pollStampSeenDuringCallback == baseline);

    /* Only on return is the completion recorded - the stamp whose SILENCE is
       the fault. */
    assert([rig.input callbackEntryNanoseconds] == 0);
    assert([rig.input lastPollCompletedNanoseconds] == rig.clock.now);
}

/* ---------------------------------------------------------------------- */
/* Teardown, and the window set as the focus seam.                         */
/* ---------------------------------------------------------------------- */

static void testEndingSuppressionStopsTheTapAndTakesFocusBack(void)
{
    Rig *rig = armedRig();
    rig.tap.secureInput = YES;
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.focus.accepts);

    [rig.input endSuppressingInput];
    assert(!rig.input.suppressing);
    assert(rig.tap.stopCount == 1);
    assert(!rig.focus.accepts);
    assert(rig.focus.sink == nil);
    assert(!rig.input.tapPathUnavailable);

    /* Idempotent: it is called on every lift, including the ones that happen
       because something is already wrong. */
    [rig.input endSuppressingInput];
    assert(rig.tap.stopCount == 1);
}

static void testARearmedTapStartsFromACleanSlate(void)
{
    Rig *rig = armedRig();
    rig.tap.reenableSucceeds = NO;
    rig.tap.enabled = NO;
    [rig.input handleTapEventOfType:kCGEventTapDisabledByTimeout event:NULL];
    [rig.scheduler fire];
    assert(rig.input.tapPathUnavailable);

    [rig.input endSuppressingInput];
    rig.tap.reenableSucceeds = YES;
    rig.tap.enabled = YES;
    assert([rig.input beginSuppressingInput]);
    /* The previous curtain's failure must not be remembered: this one has its
       own tap, and reporting "unavailable" again from a stale flag would lift
       a curtain that is fine. */
    assert(!rig.input.tapPathUnavailable);
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(rig.observer.unavailableCount == 1);
}

/*
 * An owner that lets go while suppression is still armed must not leave a tap
 * thread running against a half-freed object. The tap is what the callback and
 * the poll run on, so stopping it - which joins that thread - has to happen
 * before anything the callback touches is released. Nothing enforces "a
 * caller never drops this while armed", so -dealloc does it rather than
 * assuming it.
 */
static void testDeallocStopsTheTapBeforeAnythingElseGoes(void)
{
    FakeTap *tap = nil;
    @autoreleasepool {
        Rig *rig = makeRig();
        assert([rig.input beginSuppressingInput]);
        tap = [rig.tap retain];      /* outlives the rig, so it can be asked */
        assert(tap.handler != nil);
    }   /* every owner of the input is gone here */

    /* The thread was joined and the handler let go, from -dealloc itself. */
    assert(tap.stopCount >= 1);
    assert(tap.handler == nil);
    [tap release];
}

static void testTheWindowSetIsTheFocusSeam(void)
{
    NSMutableArray<NSString *> *log = [NSMutableArray array];
    RecordingOccluders *occluders = [[[RecordingOccluders alloc] init] autorelease];
    occluders.log = log;
    MacVNCCurtainWindowSet *windowSet =
        [[[MacVNCCurtainWindowSet alloc] initWithOccluders:occluders] autorelease];

    Rig *rig = makeRig();
    rig.input = [[[MacVNCCurtainInput alloc]
        initWithTap:rig.tap
              focus:(id<MacVNCCurtainInputFocus>)windowSet
           observer:rig.observer
       secretSource:rig.secretSource
          scheduler:rig.scheduler
              clock:rig.clock] autorelease];

    assert([rig.input beginSuppressingInput]);
    /* Armed and healthy: the windows must NOT be able to take the keyboard. */
    assert(!windowSet.acceptsKeyboardFocus);
    assert(!occluders.accepts);
    assert(occluders.sink == rig.input);

    rig.tap.secureInput = YES;
    [rig.input handleTapPoll];
    [rig.scheduler fire];
    assert(windowSet.acceptsKeyboardFocus);
    assert(occluders.accepts);

    [rig.input endSuppressingInput];
    assert(!windowSet.acceptsKeyboardFocus);
    assert(occluders.sink == nil);
    assert([log isEqualToArray:(@[ @"occluders-not-key", @"occluders-key",
                                   @"occluders-not-key" ])]);
}

/* ---------------------------------------------------------------------- */

int main(void)
{
    @autoreleasepool {
        testRefusesWithoutAccessibilityTrust();
        testRefusesWhenTheTapCannotBeCreated();
        testRefusesWhenTheKeyboardWasClearedFromTheEffectiveMask();
        testAnUnreadableMaskIsARefusal();
        testTheMaskRuleWantsEveryKeyboardBit();
        testRefusesWithoutAPasswordToTypeBack();
        testArmingKeepsTheCurtainWindowAwayFromTheKeyboard();
        testOurOwnTaggedInjectionPassesThroughUnmodified();
        testTheUntaggableInjectionPathIsRecognisedByProcessId();
        testLocalInputIsSwallowed();
        testTheSelfInjectionRuleItself();
        testTheProcessIdLegIsPointerOnly();
        testTypingThePasswordLocallyUnlocks();
        testAWrongPasswordDoesNotUnlock();
        testTheRemotePartyCannotTypeTheCurtainOpen();
        testKeysThatReachTheWindowFeedTheSamePolicy();
        testTheFocusHandOverDoesNotFlapBackWhenSecureInputClears();
        testAReportThatLandsAfterTeardownChangesNothing();
        testWindowKeysAfterTeardownAreDroppedAtTheDoor();
        testWindowKeysAreDroppedWhenThereIsNoTapThreadToOwnThePolicy();
        testBothDisableReasonsAreReEnabled();
        testADisableThatDoesNotStickHandsControlBack();
        testASilentDisableIsCaughtByThePoll();
        testSecureInputHandsFocusOverAndIsReportedOnce();
        testKeyboardSilenceUnderPointerTrafficCorroboratesSecureInput();
        testTheTrafficSignalReachesTheObserver();
        testWatchdogTreatsEventSilenceAsHealth();
        testWatchdogTreatsPollSilenceAsAFault();
        testUnobservedTimeIsNotAWedge();
        testWatchdogCatchesACallbackInFlightTooLong();
        testWatchdogCatchesAMainThreadThatNeverAnswers();
        testTheCallbackStampIsVisibleToTheWatchdogWhileItRuns();
        testThePollIsJudgedByItsCompletionStampNotByTheCallbackBound();
        testEndingSuppressionStopsTheTapAndTakesFocusBack();
        testDeallocStopsTheTapBeforeAnythingElseGoes();
        testARearmedTapStartsFromACleanSlate();
        testTheWindowSetIsTheFocusSeam();
        printf("curtain input: all assertions passed\n");
    }
    return 0;
}
