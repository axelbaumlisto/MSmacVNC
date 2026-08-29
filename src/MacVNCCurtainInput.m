#import "MacVNCCurtainInput.h"

#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>          /* IsSecureEventInputEnabled */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>                 /* abort */
#include <unistd.h>                 /* getpid, usleep */

#import "FirstFrameBudget.h"        /* macVNCMonotonicNow */
#import "MacVNCCurtainPolicy.h"
#import "MacVNCCurtainWindow.h"

/* ------------------------------------------------------------------------- */
/* The pure decisions.                                                        */
/* ------------------------------------------------------------------------- */

bool macVNCCurtainInputMaskKeepsKeyboard(uint64_t effectiveMask)
{
    /* ALL of them, not any: a tap that lost kCGEventFlagsChanged would pass
       every Command shortcut straight through to an invisible desktop. An
       unreadable mask is 0, which fails here - the refusal this exists for. */
    return (effectiveMask & MACVNC_CURTAIN_INPUT_KEYBOARD_MASK) ==
           MACVNC_CURTAIN_INPUT_KEYBOARD_MASK;
}

/* The pointer events - and ONLY these - can reach us from an injection path
   with no source to tag: MacVNCInput.m's CGPostMouseEvent. Keyboard and scroll
   injection is built from the tagged source, and the tag was measured to
   survive the round trip through WindowServer, so those types do not need the
   process-id leg and are not given it. */
static bool macVNCCurtainInputTypeIsUntaggablePointer(CGEventType type)
{
    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDown:
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseDown:
    case kCGEventRightMouseUp:
    case kCGEventOtherMouseDown:
    case kCGEventOtherMouseUp:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged:
        return true;
    default:
        return false;
    }
}

bool macVNCCurtainInputEventIsSelfInjected(CGEventType type, CGEventRef event)
{
    if (!event)
        return false;
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) ==
        MACVNC_CURTAIN_INPUT_EVENT_MAGIC)
        return true;
    if (!macVNCCurtainInputTypeIsUntaggablePointer(type))
        return false;
    /* The legacy pointer path (CGPostMouseEvent) builds its event inside
       CoreGraphics and has no source to carry the tag, but the event still
       arrives stamped with the posting process. Measured, not assumed: a
       session tap sees it with pid == getpid() and userData 0. */
    return CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) ==
           (int64_t)getpid();
}

bool macVNCCurtainInputSecureInputSuspected(uint64_t lastKeyboardNanoseconds,
                                            uint64_t lastPointerNanoseconds,
                                            uint64_t nowNanoseconds)
{
    /* Nothing has stopped if nothing ever started. Without this, a local user
       who only ever moves the mouse would lift their own curtain. */
    if (lastKeyboardNanoseconds == 0 || lastPointerNanoseconds == 0)
        return false;
    if (lastPointerNanoseconds <= lastKeyboardNanoseconds)
        return false;
    if (lastPointerNanoseconds - lastKeyboardNanoseconds <
        MACVNC_CURTAIN_INPUT_KEYBOARD_SILENCE_NANOSECONDS)
        return false;
    /* And the pointer must still be arriving NOW. A curtain that has simply
       been idle for an hour is silence, not a withheld keyboard. */
    if (nowNanoseconds < lastPointerNanoseconds)
        return false;
    return (nowNanoseconds - lastPointerNanoseconds) <
           MACVNC_CURTAIN_INPUT_KEYBOARD_SILENCE_NANOSECONDS;
}

MacVNCCurtainInputWatchdogVerdict macVNCCurtainInputWatchdogEvaluate(
    const MacVNCCurtainInputWatchdogState *state, uint64_t nowNanoseconds)
{
    if (!state)
        return MacVNCCurtainInputWatchdogHealthy;
    /* FIRST, because it invalidates everything below it: if the watchdog
       itself did not run, the process was frozen (sleep, SIGSTOP, a debugger)
       and every stamp is now measuring time nobody observed. Darwin's
       CLOCK_MONOTONIC keeps advancing across sleep while the process does not,
       so without this a lid-close would abort() a server on which nothing had
       failed - and abort() is the one action here that is not fail-safe when
       it is wrong. */
    if (state->observationGapNanoseconds >=
        MACVNC_CURTAIN_INPUT_RESUME_GAP_NANOSECONDS)
        return MacVNCCurtainInputWatchdogUnobservedGap;
    /* LATENCY, NOT SILENCE: both clauses are guarded by a non-zero "still
       outstanding" stamp, so a tap that has seen no events at all - the
       feature's normal state, since nobody is typing behind a curtain - is
       healthy however long it lasts. */
    if (state->callbackEntryNanoseconds != 0 &&
        nowNanoseconds >= state->callbackEntryNanoseconds &&
        nowNanoseconds - state->callbackEntryNanoseconds >=
            MACVNC_CURTAIN_INPUT_CALLBACK_STALL_NANOSECONDS)
        return MacVNCCurtainInputWatchdogCallbackStalled;
    if (state->heartbeatSentNanoseconds != 0 &&
        nowNanoseconds >= state->heartbeatSentNanoseconds &&
        nowNanoseconds - state->heartbeatSentNanoseconds >=
            MACVNC_CURTAIN_INPUT_MAIN_STALL_NANOSECONDS)
        return MacVNCCurtainInputWatchdogMainThreadStalled;
    /* AND HERE SILENCE IS THE FAULT. The poll runs on a timer, not on a human:
       nobody has to touch anything for it to fire, so its absence means the
       tap thread's run loop is not running. That thread is where the ONLY
       detector of a silently deaf tap lives - a disabled tap never delivers
       the disable notification, because that notification is an event - so
       without this clause a black screen over a fully live keyboard reads as
       healthy. 0 is "not armed yet", never a fault. */
    if (state->lastPollCompletedNanoseconds != 0 &&
        nowNanoseconds >= state->lastPollCompletedNanoseconds &&
        nowNanoseconds - state->lastPollCompletedNanoseconds >=
            MACVNC_CURTAIN_INPUT_POLL_STALL_NANOSECONDS)
        return MacVNCCurtainInputWatchdogPollStalled;
    return MacVNCCurtainInputWatchdogHealthy;
}

/* ------------------------------------------------------------------------- */
/* The window set is the focus seam. Declared HERE, exactly as the controller  */
/* declares MacVNCCurtain's surface conformance, so the screen half stays      */
/* unaware that an event tap exists.                                          */
/* ------------------------------------------------------------------------- */

@interface MacVNCCurtainWindowSet (MacVNCCurtainInputFocus) <MacVNCCurtainInputFocus>
@end

@implementation MacVNCCurtainWindowSet (MacVNCCurtainInputFocus)
@end

/* The two device-side classes, declared here and implemented at the bottom:
 * the production factory belongs with the rest of this class. */
@interface MacVNCCurtainEventTap : NSObject <MacVNCCurtainInputTap>
@end

@interface MacVNCCurtainInputMonotonicClock : NSObject <MacVNCCurtainClock>
@end

/* ------------------------------------------------------------------------- */
/* The decisions, above the tap seam.                                         */
/* ------------------------------------------------------------------------- */

@implementation MacVNCCurtainInput {
    id<MacVNCCurtainInputTap> _tap;                 /* retained */
    id<MacVNCCurtainInputFocus> _focus;             /* retained, may be nil */
    id<MacVNCCurtainInputObserver> _observer;       /* retained, may be nil */
    id<MacVNCCurtainSecretSource> _secretSource;    /* retained, may be nil */
    id<MacVNCCurtainScheduler> _scheduler;          /* retained */
    id<MacVNCCurtainClock> _clock;                  /* retained */

    /* Owned by the TAP THREAD once armed: written on the main thread before
       the thread exists (arming) and after it is joined (teardown), read and
       written only inside the callback in between. Keys that arrive through
       the curtain WINDOW instead are hopped onto the tap thread rather than
       taking a lock, so this struct never has two owners at once - a lock
       here would be a lock the callback can block on, which is exactly what
       makes WindowServer disable the tap. */
    MacVNCCurtainPolicy _policy;

    BOOL _suppressing;                              /* main thread */
    /* Tap-thread only. */
    uint64_t _lastKeyboardNanoseconds;
    uint64_t _lastPointerNanoseconds;
    BOOL _secureInputReported;
    BOOL _unavailableReported;
    /* Once the keyboard has been handed to the curtain window it is NOT taken
       back while this suppression session lasts. See rule 7 in the header:
       taking focus deactivates whoever holds secure input, so the next poll
       would read "off" and hand it straight back, splitting the local user's
       password across two applications ten times a second. */
    BOOL _focusHandedOver;

    _Atomic uint64_t _callbackEntryNanoseconds;     /* read by the watchdog */
    _Atomic uint64_t _lastPollCompletedNanoseconds; /* read by the watchdog */
    _Atomic bool _tapPathUnavailable;               /* read on the main thread */
}

- (instancetype)initWithTap:(id<MacVNCCurtainInputTap>)tap
                      focus:(id<MacVNCCurtainInputFocus>)focus
                   observer:(id<MacVNCCurtainInputObserver>)observer
               secretSource:(id<MacVNCCurtainSecretSource>)secretSource
                  scheduler:(id<MacVNCCurtainScheduler>)scheduler
                      clock:(id<MacVNCCurtainClock>)clock
{
    if ((self = [super init])) {
        _tap = [tap retain];
        _focus = [focus retain];
        _observer = [observer retain];
        _secretSource = [secretSource retain];
        _scheduler = [scheduler retain];
        _clock = [clock retain];
        macVNCCurtainPolicyReset(&_policy);
        atomic_store(&_callbackEntryNanoseconds, 0);
        atomic_store(&_lastPollCompletedNanoseconds, 0);
        atomic_store(&_tapPathUnavailable, false);
    }
    return self;
}

- (void)dealloc
{
    /* THE TAP GOES FIRST, and it is not enough to assume it is already gone.
       Stopping it is what joins the thread that runs the callback and the
       poll, and that callback reaches the clock, the scheduler and the focus
       seam - so releasing any of them before the join would hand an in-flight
       callback freed objects. The previous order relied on "an owner never
       drops this while it is armed", which nothing enforces. */
    [self endSuppressingInput];
    [_tap stop];
    [_tap release];
    [_focus release];
    [_observer release];
    [_secretSource release];
    [_scheduler release];
    [_clock release];
    macVNCCurtainPolicyReset(&_policy);
    [super dealloc];
}

- (BOOL)suppressing
{
    return _suppressing;
}

- (BOOL)tapPathUnavailable
{
    return atomic_load(&_tapPathUnavailable) ? YES : NO;
}

/* ------------------------------------------------------------------ */
/* Arming: three preconditions, and a way back in before any of them.  */
/* ------------------------------------------------------------------ */

- (BOOL)beginSuppressingInput
{
    if (_suppressing)
        return YES;                 /* idempotent */
    if (!_tap) {
        NSLog(@"macVNC: local input cannot be suppressed - no event tap seam");
        return NO;
    }

    /* PRECONDITION 1. With the prompt suppressed, always: macVNC never raises
       a macOS permission dialog, and a dialog behind a curtain would be a
       dialog nobody can see. */
    if (![_tap processIsTrustedForAccessibility]) {
        NSLog(@"macVNC: local input cannot be suppressed - this app is not "
              @"trusted for Accessibility, so a tap would be deaf to the "
              @"keyboard");
        return NO;
    }

    /* The way back in, armed before anything is created. The controller arms
       its own copy for its own decisions; this one is the one the callback
       feeds, and it is armed on this thread while no tap thread exists. */
    NSData *secret = _secretSource ? [_secretSource copyCurtainSecret] : nil;
    bool armed = macVNCCurtainPolicyArm(&_policy, (const char *)secret.bytes,
                                        secret.length);
    [secret release];
    if (!armed) {
        NSLog(@"macVNC: local input cannot be suppressed - there is no "
              @"password to type to lift the curtain");
        return NO;
    }

    _lastKeyboardNanoseconds = 0;
    _lastPointerNanoseconds = 0;
    _secureInputReported = NO;
    _unavailableReported = NO;
    _focusHandedOver = NO;
    atomic_store(&_callbackEntryNanoseconds, 0);
    /* Baselined BEFORE the tap thread exists, so the watchdog never judges a
       poll that has not had a chance to run - and never treats "armed one
       moment ago" as "the run loop is dead". */
    atomic_store(&_lastPollCompletedNanoseconds,
                 [_clock monotonicNanoseconds] ?: 1);
    atomic_store(&_tapPathUnavailable, false);

    /* PRECONDITION 2. */
    if (![_tap startWithEventMask:MACVNC_CURTAIN_INPUT_EVENT_MASK handler:self]) {
        NSLog(@"macVNC: local input cannot be suppressed - the event tap could "
              @"not be created");
        macVNCCurtainPolicyReset(&_policy);
        return NO;
    }

    /* PRECONDITION 3, and the one that is easy to skip: without Accessibility
       trust the keyboard bits are cleared from the mask while the call still
       succeeds, so "the tap exists" proves nothing about the keyboard. Read
       back what the system kept. */
    uint64_t effective = [_tap effectiveEventMask];
    if (!macVNCCurtainInputMaskKeepsKeyboard(effective)) {
        NSLog(@"macVNC: local input cannot be suppressed - the keyboard was "
              @"cleared from the tap's effective mask (0x%llx); a curtain now "
              @"would be a black screen with a live keyboard",
              (unsigned long long)effective);
        [_tap stop];
        macVNCCurtainPolicyReset(&_policy);
        return NO;
    }

    _suppressing = YES;
    /* Rule 5: while the tap is healthy the curtain window is NOT key. The tap
       is the only path to the policy, and a key window would collect the
       REMOTE party's keystrokes. */
    [_focus setKeyboardSink:self];
    [_focus setAcceptsKeyboardFocus:NO];
    return YES;
}

- (void)endSuppressingInput
{
    if (!_suppressing)
        return;                     /* idempotent */
    _suppressing = NO;
    /* Teardown happens on the tap's own thread inside -stop, which also joins
       it, so the policy below has exactly one owner again - EXCEPT on the one
       path -stop itself documents, where the join times out because a callback
       is stuck. Reaching that costs 2 s, and the watchdog abort()s a callback
       stuck for 500 ms, so a process that gets here is already dying; the
       ownership claim holds for every state this module can be alive in. */
    [_tap stop];
    macVNCCurtainPolicyReset(&_policy);
    atomic_store(&_callbackEntryNanoseconds, 0);
    atomic_store(&_lastPollCompletedNanoseconds, 0);
    atomic_store(&_tapPathUnavailable, false);
    [_focus setAcceptsKeyboardFocus:NO];
    [_focus setKeyboardSink:nil];
}

/* ------------------------------------------------------------------ */
/* The callback. Nothing here may block.                               */
/* ------------------------------------------------------------------ */

/* The hop every report takes. dispatch_after(0) on the main queue in
   production: it copies one block (a malloc, not a wait) and returns. Nothing
   in this file ever waits for the main thread from the tap thread - that is
   the deadlock the watchdog would have to kill the process to break. */
- (void)reportOnMain:(dispatch_block_t)block
{
    [_scheduler afterNanoseconds:0 performBlock:block];
}

- (CGEventRef)handleTapEventOfType:(CGEventType)type event:(CGEventRef)event
{
    uint64_t now = [_clock monotonicNanoseconds];
    /* 0 is the sentinel for "no callback in flight", so a clock that legally
       reads 0 must not look like an idle tap to the watchdog. */
    atomic_store(&_callbackEntryNanoseconds, now ? now : 1);
    CGEventRef result;
    @autoreleasepool {
        result = [self processEventOfType:type event:event atTime:now];
    }
    atomic_store(&_callbackEntryNanoseconds, 0);
    return result;
}

- (CGEventRef)processEventOfType:(CGEventType)type
                           event:(CGEventRef)event
                          atTime:(uint64_t)now
{
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        [self handleTapDisabledByTimeout:(type == kCGEventTapDisabledByTimeout)];
        return NULL;
    }

    /* Our own injection - the remote viewer's keyboard and mouse - passes
       through untouched. CGEventPost delivers to taps at that location, so
       without this the curtain would break the very session that raised it. */
    if (macVNCCurtainInputEventIsSelfInjected(type, event))
        return event;

    if (type == kCGEventKeyDown || type == kCGEventKeyUp ||
        type == kCGEventFlagsChanged) {
        _lastKeyboardNanoseconds = now;
        if (type == kCGEventKeyDown)
            [self feedPolicyFromKeyEvent:event atTime:now];
    } else {
        _lastPointerNanoseconds = now;
    }
    /* Everything local is swallowed. That is the curtain. */
    return NULL;
}

- (void)feedPolicyFromKeyEvent:(CGEventRef)event atTime:(uint64_t)now
{
    /* Allocation-free and layout-aware: shift, caps lock and the active input
       source are already applied, and a dead key yields no units at all. */
    UniChar units[8];
    UniCharCount count = 0;
    CGEventKeyboardGetUnicodeString(event, sizeof(units) / sizeof(units[0]),
                                    &count, units);
    [self feedPolicyUnits:(const uint16_t *)units count:(size_t)count atTime:now];
}

/* Tap thread only. NOTHING here logs what was typed. */
- (void)feedPolicyUnits:(const uint16_t *)units count:(size_t)count atTime:(uint64_t)now
{
    MacVNCCurtainUnlockOutcome outcome =
        macVNCCurtainPolicyFeed(&_policy, units, count, now);
    if (outcome != MacVNCCurtainUnlockGranted)
        return;
    [self reportOnMain:^{
        NSLog(@"macVNC: the local user typed the password; lifting the curtain");
        [_observer noteLocalUnlockAccepted];
    }];
}

- (void)curtainWindowDidReceiveCharacters:(const uint16_t *)units count:(size_t)count
{
    /* Main thread: the curtain window is key, which happens only while the tap
       path is unavailable (rule 5). The characters are carried ONTO THE TAP
       THREAD rather than fed here, so the policy keeps its single owner. */
    if (!_suppressing || !units || count == 0)
        return;
    NSData *carried = [NSData dataWithBytes:units length:count * sizeof(uint16_t)];
    [_tap performOnTapThread:^{
        [self feedPolicyUnits:(const uint16_t *)carried.bytes
                        count:carried.length / sizeof(uint16_t)
                       atTime:[_clock monotonicNanoseconds]];
    }];
}

/* ------------------------------------------------------------------ */
/* Both disable reasons, and the poll.                                 */
/* ------------------------------------------------------------------ */

- (void)handleTapDisabledByTimeout:(BOOL)byTimeout
{
    /* Both reasons get the same treatment: WindowServer disables the tap and
       local input is live again the moment it does, while the black window
       stays composited. Re-enable, then verify it stuck - CGEventTapEnable
       has no return value, so "asked" is not "done". */
    BOOL restored = [_tap reenableTap];
    NSString *reason = byTimeout ? @"a callback timeout" : @"user input";
    [self reportOnMain:^{
        if (restored)
            NSLog(@"macVNC: the curtain's event tap was disabled by %@ and was "
                  @"re-enabled", reason);
        else
            NSLog(@"macVNC: the curtain's event tap was disabled by %@ and "
                  @"could not be re-enabled", reason);
    }];
    if (!restored)
        [self markTapPathUnavailable];
}

- (void)handleTapPoll
{
    uint64_t now = [_clock monotonicNanoseconds];
    /*
     * DELIBERATELY NOT STAMPED INTO THE IN-FLIGHT (CALLBACK) FIELD.
     *
     * That field is judged against MACVNC_CURTAIN_INPUT_CALLBACK_STALL, whose
     * 500 ms is justified by what a CALLBACK does: a handful of field reads
     * and one comparison. This poll is not that - IsSecureEventInputEnabled,
     * CGEventTapIsEnabled, and on the disabled path CGEventTapEnable plus its
     * read-back, all synchronous to WindowServer. Stamping it there would let
     * a briefly slow WindowServer abort() a healthy live server and drop the
     * remote session, which is the one action here that is not fail-safe when
     * it is wrong.
     *
     * And it would buy no detection: a poll that wedges stops advancing the
     * completion stamp below, which is judged by SILENCE against
     * MACVNC_CURTAIN_INPUT_POLL_STALL - a bound that matches what the poll
     * actually does. (CallbackStalled is evaluated first, so the in-flight
     * stamp would in fact make PollStalled unreachable for a wedged poll.)
     */

    /* Secure input, asked on the thread that would have received the keys.
       IsSecureEventInputEnabled() is not thread safe. */
    BOOL secure = [_tap secureInputIsEnabled];
    if (!secure)
        secure = macVNCCurtainInputSecureInputSuspected(_lastKeyboardNanoseconds,
                                                        _lastPointerNanoseconds,
                                                        now)
                     ? YES
                     : NO;
    [self updateSecureInput:secure];

    /* A tap can also be disabled without our callback ever being told - the
       disable notification is itself an event, and an event is what a dead tap
       stops delivering. */
    if (!_unavailableReported && ![_tap tapIsEnabled])
        [self handleTapDisabledByTimeout:YES];

    /* Completed, and stamped as such. This is the one stamp in this module the
       watchdog judges by SILENCE, because a timer needs nobody to fire it. */
    atomic_store(&_lastPollCompletedNanoseconds,
                 [_clock monotonicNanoseconds] ?: 1);
}

- (void)updateSecureInput:(BOOL)active
{
    if (active == _secureInputReported)
        return;                     /* edge-triggered, both ways */
    _secureInputReported = active;
    [self refreshTapPathAvailability];
    /* Computed on the tap thread and captured, so the hop carries a decision
       rather than re-deriving one from state that may have moved on. Note it
       can only ever go NO -> YES within a session: see -handOverFocus. */
    BOOL handOver = [self handOverFocus];
    [self reportOnMain:^{
        /* This block was dispatched from the tap thread and runs later, on
           main - which owns _suppressing. Suppression may already have ended
           in between (the lift that a previous report triggered), and handing
           the keyboard to a curtain window after that would leave the flag set
           on a window set nobody is going to take it back from. */
        if (!_suppressing)
            return;
        if (active)
            NSLog(@"macVNC: secure input is active - the keyboard is being "
                  @"withheld from the tap");
        /* Focus FIRST: while secure input is on, whatever the local user types
           goes to the focused application, which the remote party is watching.
           The report on the next line is what lifts the curtain. */
        [_focus setAcceptsKeyboardFocus:handOver];
        [_observer setSecureInputActive:active];
    }];
}

- (void)markTapPathUnavailable
{
    if (_unavailableReported)
        return;
    _unavailableReported = YES;
    [self refreshTapPathAvailability];
    BOOL handOver = [self handOverFocus];
    [self reportOnMain:^{
        /* Same reason as -updateSecureInput:: a report that lands after
           suppression ended must change nothing. */
        if (!_suppressing)
            return;
        [_focus setAcceptsKeyboardFocus:handOver];
        [_observer noteInputSuppressionUnavailable];
    }];
}

/*
 * Whether the curtain window may hold the keyboard - and a LATCH, not a level.
 *
 * Handing the focus over is an app activation, which deactivates whoever holds
 * secure input; the next poll then reads IsSecureEventInputEnabled() as false
 * and would hand it straight back, ten times a second, with the local user's
 * password split across two applications. So once it is over, it stays over
 * until suppression ends - which is the lift the report itself triggers. This
 * also answers the narrower case: secure input turning off while the tap is
 * ALSO unrecoverably disabled must not take the keyboard away from the only
 * window that can still receive it.
 */
- (BOOL)handOverFocus
{
    if (_secureInputReported || _unavailableReported)
        _focusHandedOver = YES;
    return _focusHandedOver;
}

- (void)refreshTapPathAvailability
{
    atomic_store(&_tapPathUnavailable,
                 (_secureInputReported || _unavailableReported) ? true : false);
}

- (uint64_t)callbackEntryNanoseconds
{
    return atomic_load(&_callbackEntryNanoseconds);
}

- (uint64_t)lastPollCompletedNanoseconds
{
    return atomic_load(&_lastPollCompletedNanoseconds);
}

+ (instancetype)inputWithDefaultSeamsFocus:(id<MacVNCCurtainInputFocus>)focus
                                  observer:(id<MacVNCCurtainInputObserver>)observer
                              secretSource:(id<MacVNCCurtainSecretSource>)secretSource
{
    MacVNCCurtainEventTap *tap = [[MacVNCCurtainEventTap alloc] init];
    MacVNCCurtainMainQueueScheduler *scheduler =
        [[MacVNCCurtainMainQueueScheduler alloc] init];
    MacVNCCurtainInputMonotonicClock *clock =
        [[MacVNCCurtainInputMonotonicClock alloc] init];
    MacVNCCurtainInput *input = [[self alloc] initWithTap:tap
                                                    focus:focus
                                                 observer:observer
                                             secretSource:secretSource
                                                scheduler:scheduler
                                                    clock:clock];
    [tap release];
    [scheduler release];
    [clock release];
    return [input autorelease];
}

@end

/* ------------------------------------------------------------------------- */
/* The device half: a real tap, on its own thread, with a watchdog.           */
/* ------------------------------------------------------------------------- */

/* The clock the controller's production seam also uses. Duplicated rather than
   published from MacVNCCurtainController.m, which keeps that module's private
   seams private; both are three lines around macVNCMonotonicNow(). */
@implementation MacVNCCurtainInputMonotonicClock
- (uint64_t)monotonicNanoseconds { return macVNCMonotonicNow(); }
@end

/*
 * Everything that needs a device: CGEventTapCreate, the tap's own thread and
 * run loop, the poll timer, the teardown order, and the watchdog thread whose
 * only action is abort().
 *
 * The handler IS retained, for as long as any thread here can message it. The
 * older "the join makes a retain unnecessary" argument was false in exactly
 * the place this file already documents: the join is BOUNDED and can time out,
 * and after that a wedged callback, the poll and the watchdog thread all still
 * hold it while the controller is free to release the last other reference.
 * So it is retained on start and released only on the join-SUCCESS branch -
 * deliberately leaked when the join times out, the same trade ScreenCapturer
 * makes for a capturer with work still in flight.
 */
@implementation MacVNCCurtainEventTap {
    id<MacVNCCurtainInputTapHandler> _handler;   /* RETAINED; see above */
    uint64_t _requestedMask;
    CFMachPortRef _tapPort;
    CFRunLoopSourceRef _source;
    /* Atomic: the tap thread publishes it, the main thread reads it to decide
       whether there is a live run loop behind a "yes". */
    _Atomic(CFRunLoopRef) _tapRunLoop;
    CFRunLoopTimerRef _pollTimer;
    dispatch_semaphore_t _started;
    dispatch_semaphore_t _finished;
    dispatch_semaphore_t _watchdogStarted;
    dispatch_semaphore_t _watchdogFinished;
    /* THE ONLY MONOTONE FLAG HERE, and it is monotone on purpose: once a
       teardown fails to join, this tap must never arm again, and NOTHING may
       clear it - least of all the tap thread, which is the one that could not
       be stopped. _startSucceeded cannot carry that meaning, because the tap
       thread writes it too and can win the race. */
    _Atomic bool _refuseForever;
    /* Written on the tap thread, read on the main thread: atomic, because the
       answer it carries is "may a curtain go up over this tap". */
    _Atomic bool _startSucceeded;
    volatile BOOL _stopping;
    volatile BOOL _watchdogRunning;
    _Atomic uint64_t _heartbeatSentNanoseconds;
}

- (BOOL)processIsTrustedForAccessibility
{
    /* kAXTrustedCheckOptionPrompt = NO. The one call in this file that could
       put a dialog on screen if it were written the other way. */
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @NO};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options) ? YES : NO;
}

static CGEventRef curtainTapCallback(CGEventTapProxy proxy, CGEventType type,
                                     CGEventRef event, void *userInfo)
{
    (void)proxy;
    MacVNCCurtainEventTap *tap = (MacVNCCurtainEventTap *)userInfo;
    return [tap deliverEventOfType:type event:event];
}

- (CGEventRef)deliverEventOfType:(CGEventType)type event:(CGEventRef)event
{
    id<MacVNCCurtainInputTapHandler> handler = _handler;
    if (!handler)
        return event;
    return [handler handleTapEventOfType:type event:event];
}

- (BOOL)startSucceeded
{
    return atomic_load(&_startSucceeded) ? YES : NO;
}

static void curtainPollTimerFired(CFRunLoopTimerRef timer, void *info)
{
    (void)timer;
    MacVNCCurtainEventTap *tap = (MacVNCCurtainEventTap *)info;
    [tap deliverPoll];
}

- (void)deliverPoll
{
    @autoreleasepool {
        /* Copied to a local: the ivar is cleared from the main thread in
           -stop, and a torn read here would be a message to half a pointer. */
        id<MacVNCCurtainInputTapHandler> handler = _handler;
        [handler handleTapPoll];
    }
}

- (BOOL)startWithEventMask:(uint64_t)eventMask
                   handler:(id<MacVNCCurtainInputTapHandler>)handler
{
    /* FIRST, before any other state is consulted. A tap whose teardown never
       completed is refused for the rest of the process, and the check has to
       come before the _started short-circuit below or the tap thread gets a
       vote: it can finish CGEventTapCreate LATE, after the failed stop, and
       publish success over the refusal. Then a later client edge would be told
       YES for a tap with no handler, no run loop and - because the watchdog is
       started further down - no detector of any kind. Black screen, fully live
       keyboard, and the escape password typed into whatever the remote party
       is watching, with nothing left to notice. */
    if (atomic_load(&_refuseForever)) {
        NSLog(@"macVNC: refusing to arm the curtain's event tap - an earlier "
              @"tap could not be torn down, so this process will not suppress "
              @"input again");
        return NO;
    }

    if (_started) {
        /* Idempotent for a tap that IS running, and only for that: the answer
           is YES only when there is still a run loop behind it. "Setup once
           reported success" is not the same claim - the thread can have gone
           into teardown since. */
        return ([self startSucceeded] && atomic_load(&_tapRunLoop) != NULL) ? YES : NO;
    }
    _handler = [handler retain];
    _requestedMask = eventMask;
    _stopping = NO;
    atomic_store(&_startSucceeded, false);
    _started = dispatch_semaphore_create(0);
    _finished = dispatch_semaphore_create(0);
    /* The thread retains self for its lifetime, which is what makes the
       teardown-on-its-own-thread rule safe to express as "wait for it". */
    [NSThread detachNewThreadSelector:@selector(tapThreadMain)
                             toTarget:self
                           withObject:nil];
    /* Bounded, and it cannot deadlock: nothing in the tap thread's setup needs
       the main thread. A setup that has not answered in two seconds is a
       failure, and a failure is a curtain that does not go up. */
    if (dispatch_semaphore_wait(_started,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              2ll * NSEC_PER_SEC)) != 0) {
        NSLog(@"macVNC: the curtain's event tap did not start in time");
        [self stop];
        return NO;
    }
    if (![self startSucceeded]) {
        [self stop];
        return NO;
    }
    /* The watchdog is not optional decoration: without it a wedged callback, a
       dead run loop and an unanswered main thread all go unnoticed, which is
       the blind spot this whole round is about. A watchdog that does not start
       is therefore a START FAILURE, not a degraded success. */
    if (![self startWatchdog]) {
        NSLog(@"macVNC: the curtain's watchdog thread did not start; refusing "
              @"to suppress input without it");
        [self stop];
        return NO;
    }
    return YES;
}

- (void)tapThreadMain
{
    @autoreleasepool {
        [[NSThread currentThread] setName:@"net.christianbeier.macVNC.curtain-tap"];
        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        atomic_store(&_tapRunLoop, runLoop);

        /* The SESSION tap: it is where our own CGEventPost injection lands
           too, which is why every injected event carries the tag. */
        _tapPort = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                    kCGEventTapOptionDefault,
                                    (CGEventMask)_requestedMask,
                                    curtainTapCallback, self);
        if (_tapPort) {
            _source = CFMachPortCreateRunLoopSource(NULL, _tapPort, 0);
            if (_source) {
                CFRunLoopAddSource(runLoop, _source, kCFRunLoopCommonModes);
                CGEventTapEnable(_tapPort, true);
                CFRunLoopTimerContext context = {0, self, NULL, NULL, NULL};
                double interval =
                    (double)MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS / 1e9;
                _pollTimer = CFRunLoopTimerCreate(
                    NULL, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0,
                    curtainPollTimerFired, &context);
                if (_pollTimer)
                    CFRunLoopAddTimer(runLoop, _pollTimer,
                                      kCFRunLoopCommonModes);
                /* Only if nobody gave up on us in the meantime. Publishing
                   success after -stop has already decided this tap failed
                   would hand a later caller a "yes" for a tap that is about to
                   tear itself down. */
                if (!_stopping)
                    atomic_store(&_startSucceeded, true);
            }
        }
        dispatch_semaphore_signal(_started);

        while (atomic_load(&_startSucceeded) && !_stopping) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
            }
        }

        /* Rule 3's other half: disable, unhook, invalidate and release ON THIS
           THREAD. Invalidating a run-loop source from another thread races the
           callback that may still be inside it. */
        if (_pollTimer) {
            CFRunLoopTimerInvalidate(_pollTimer);
            CFRelease(_pollTimer);
            _pollTimer = NULL;
        }
        if (_tapPort)
            CGEventTapEnable(_tapPort, false);
        if (_source) {
            CFRunLoopRemoveSource(runLoop, _source, kCFRunLoopCommonModes);
            CFRunLoopSourceInvalidate(_source);
            CFRelease(_source);
            _source = NULL;
        }
        if (_tapPort) {
            CFMachPortInvalidate(_tapPort);
            CFRelease(_tapPort);
            _tapPort = NULL;
        }
        /* Published as gone BEFORE the join is signalled: from here on there
           is no run loop, and -startWithEventMask: must not answer YES for
           one. */
        atomic_store(&_tapRunLoop, NULL);
        dispatch_semaphore_signal(_finished);
    }
}

- (uint64_t)effectiveEventMask
{
    /* What the SYSTEM kept, not what we asked for. Without Accessibility trust
       the keyboard bits are gone from this and CGEventTapCreate still
       succeeded. */
    if (!_tapPort)
        return 0;
    uint32_t capacity = 0;
    if (CGGetEventTapList(0, NULL, &capacity) != kCGErrorSuccess || capacity == 0)
        return 0;
    CGEventTapInformation *taps = calloc(capacity, sizeof(*taps));
    if (!taps)
        return 0;
    uint32_t count = 0;
    uint64_t best = 0;
    unsigned bestOverlap = 0;
    if (CGGetEventTapList(capacity, taps, &count) == kCGErrorSuccess) {
        pid_t me = getpid();
        for (uint32_t i = 0; i < count; ++i) {
            if (taps[i].tappingProcess != me)
                continue;
            /* A DISABLED tap of ours answers nothing, so letting one satisfy
               precondition 3 would be reading the mask of a tap that is not
               watching anything - the leftover of a teardown that did not
               complete, offering its full mask as evidence. */
            if (!taps[i].enabled)
                continue;
            uint64_t mask = (uint64_t)taps[i].eventsOfInterest;
            unsigned overlap = (unsigned)__builtin_popcountll(mask & _requestedMask);
            if (overlap >= bestOverlap) {
                bestOverlap = overlap;
                best = mask;
            }
        }
    }
    free(taps);
    return best;
}

- (BOOL)tapIsEnabled
{
    return _tapPort && CGEventTapIsEnabled(_tapPort);
}

- (BOOL)reenableTap
{
    if (!_tapPort)
        return NO;
    CGEventTapEnable(_tapPort, true);
    /* CGEventTapEnable returns nothing; the read-back is the only evidence. */
    return CGEventTapIsEnabled(_tapPort) ? YES : NO;
}

- (BOOL)secureInputIsEnabled
{
    return IsSecureEventInputEnabled() ? YES : NO;
}

- (BOOL)performOnTapThread:(dispatch_block_t)block
{
    CFRunLoopRef loop = atomic_load(&_tapRunLoop);
    if (!loop || _stopping || !block)
        return NO;
    CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, block);
    CFRunLoopWakeUp(loop);
    return YES;
}

- (void)stop
{
    _stopping = YES;
    /* THE WATCHDOG GOES FIRST, AND THAT ORDER IS LOAD-BEARING: this method can
       block the caller - the MAIN thread - for as long as both bounded waits
       together, against a heartbeat bound of only
       MACVNC_CURTAIN_INPUT_MAIN_STALL_NANOSECONDS. Stopping the watchdog
       before the join, and clearing any outstanding beat with it, is what
       stops an ordinary slow teardown from abort()ing a healthy server. */
    atomic_store(&_heartbeatSentNanoseconds, 0);
    BOOL watchdogJoined = [self stopWatchdog];
    CFRunLoopRef loop = atomic_load(&_tapRunLoop);
    if (loop)
        CFRunLoopWakeUp(loop);
    BOOL joined = NO;
    if (_finished) {
        /* Bounded: a tap thread that has not finished in two seconds is stuck
           inside a callback, and freeing anything under it would be worse than
           the leak of leaving it alone (the same trade ScreenCapturer makes). */
        joined = dispatch_semaphore_wait(_finished,
                                         dispatch_time(DISPATCH_TIME_NOW,
                                                       2ll * NSEC_PER_SEC)) == 0;
    } else {
        joined = YES;               /* nothing was ever started */
    }

    if (joined) {
        [self releaseSemaphores];
        /* BOTH threads, not just the tap one. The watchdog holds _handler too
           (it reads the callback and poll stamps through it every 100 ms), and
           -stopWatchdog can return with that thread still alive: its own wait
           is a dispatch_time deadline, which elapses across system sleep for
           the same reason the monotonic clock does. Releasing here on the tap
           join alone would leave the watchdog messaging a freed object one
           iteration later, with nothing wedged at all. */
        if (watchdogJoined) {
            [_handler release];
            _handler = nil;
        } else {
            NSLog(@"macVNC: the curtain's watchdog thread outlived its join; "
                  @"leaking the tap handler rather than freeing it while that "
                  @"thread can still message it");
        }
        return;
    }

    /* NOT JOINED. Four things follow, and each one is the safe half of a
       trade this file already makes elsewhere:
       - the semaphores are NOT released: the thread still signals them;
       - the handler is NOT released and NOT cleared: a callback still inside
         it holds a raw pointer, and a poll may still message it;
       - _startSucceeded goes to NO;
       - and _refuseForever goes to YES, WITHOUT clearing _started.

       That last one is the point, and it is why the refusal needs a flag of
       its own. _startSucceeded cannot carry this meaning: the TAP THREAD also
       writes it, so a thread still stuck inside CGEventTapCreate can finish
       late - after this line - and publish success over the refusal. A later
       client edge would then be told YES for a tap with no handler, no run
       loop and no watchdog, and the caller would raise a curtain believing
       input is suppressed: black screen, fully live keyboard, no poll, no
       detector, and the local user typing the escape password into an
       application the remote party is watching. _refuseForever is written only
       here and only ever true, so the thread we could not stop gets no vote.
       Refusing for the rest of the run costs a curtain; the alternative costs
       the person standing at the Mac. */
    atomic_store(&_startSucceeded, false);
    atomic_store(&_refuseForever, true);
    NSLog(@"macVNC: the curtain's tap thread did not finish; leaving it alone "
          @"rather than freeing it underneath itself, and refusing to suppress "
          @"input again in this process");
}

- (void)releaseSemaphores
{
    if (_started) {
        dispatch_release(_started);
        _started = NULL;
    }
    if (_finished) {
        dispatch_release(_finished);
        _finished = NULL;
    }
}

/* ------------------------------------------------------------------ */
/* The watchdog: latency, and a main thread that must answer.          */
/* ------------------------------------------------------------------ */

/*
 * Started with the same bounded handshake the tap thread gets, because the
 * watchdog is the one component that has no detector of its own: if
 * detachNewThreadSelector never ran it, _watchdogRunning would stay YES, the
 * abort() net would be silently absent - the P0-2 blind spot again, in a
 * different place - and every later -stopWatchdog would block the main thread
 * for the full timeout waiting for a thread that does not exist. So a watchdog
 * that does not answer is a START FAILURE, and its caller refuses to suppress
 * input at all.
 */
- (BOOL)startWatchdog
{
    atomic_store(&_heartbeatSentNanoseconds, 0);
    _watchdogRunning = YES;
    _watchdogStarted = dispatch_semaphore_create(0);
    _watchdogFinished = dispatch_semaphore_create(0);
    [NSThread detachNewThreadSelector:@selector(watchdogThreadMain)
                             toTarget:self
                           withObject:nil];
    if (dispatch_semaphore_wait(_watchdogStarted,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              2ll * NSEC_PER_SEC)) != 0) {
        /* It may still start later, so nothing here is freed: -stopWatchdog
           owns that decision and makes it the same way. */
        _watchdogRunning = NO;
        return NO;
    }
    dispatch_release(_watchdogStarted);
    _watchdogStarted = NULL;
    return YES;
}

/* YES only when the watchdog thread is known to be GONE - which is what makes
 * it safe to free anything that thread can still reach. */
- (BOOL)stopWatchdog
{
    if (!_watchdogRunning)
        return YES;                 /* never started, or already stopped */
    _watchdogRunning = NO;
    BOOL joined = YES;
    if (_watchdogFinished) {
        /* Released ONLY when the wait actually returned: a watchdog thread that
           has not finished is a thread that will still signal this semaphore,
           and signalling a released dispatch object is a use-after-free.
           -releaseSemaphores makes the same distinction for the tap thread. */
        if (dispatch_semaphore_wait(_watchdogFinished,
                                    dispatch_time(DISPATCH_TIME_NOW,
                                                  2ll * NSEC_PER_SEC)) == 0) {
            dispatch_release(_watchdogFinished);
            _watchdogFinished = NULL;
        } else {
            joined = NO;
            NSLog(@"macVNC: the curtain's watchdog thread did not finish; "
                  @"leaving its semaphore alive rather than signalling a freed "
                  @"object");
        }
    }
    return joined;
}

- (void)watchdogThreadMain
{
    @autoreleasepool {
        [[NSThread currentThread] setName:@"net.christianbeier.macVNC.curtain-watchdog"];
    }
    /* "I exist": the handshake -startWatchdog waits for. Signalled before the
       first sleep, so the answer means the thread is running, not merely that
       it was asked for. */
    if (_watchdogStarted)
        dispatch_semaphore_signal(_watchdogStarted);
    /* The watchdog's own yardstick: how long since IT last looked. Seeded so
       the first iteration measures one sleep, not the whole uptime. */
    uint64_t previousObservation = macVNCMonotonicNow();
    uint64_t graceUntil = 0;
    while (_watchdogRunning) {
        usleep((useconds_t)(MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS / 1000ull));
        id<MacVNCCurtainInputTapHandler> handler = _handler;
        uint64_t now = macVNCMonotonicNow();
        MacVNCCurtainInputWatchdogState state;
        state.callbackEntryNanoseconds = handler ? [handler callbackEntryNanoseconds] : 0;
        state.heartbeatSentNanoseconds = atomic_load(&_heartbeatSentNanoseconds);
        state.lastPollCompletedNanoseconds = handler ? [handler lastPollCompletedNanoseconds] : 0;
        state.observationGapNanoseconds = now > previousObservation ? now - previousObservation : 0;
        previousObservation = now;

        /* After a resume nothing is believed for a while: the run loop and the
           main queue have to be given the chance to catch up before their
           stamps mean anything again. Nothing is killed during that window -
           and if something really is wedged, the very next iteration after it
           says so. */
        if (now < graceUntil) {
            if (atomic_load(&_heartbeatSentNanoseconds) == 0)
                [self sendHeartbeatAt:now];
            continue;
        }

        switch (macVNCCurtainInputWatchdogEvaluate(&state, now)) {
        case MacVNCCurtainInputWatchdogUnobservedGap:
            /* The process was frozen - lid closed, SIGSTOP, a debugger. Every
               stamp is measuring time nobody observed, so re-baseline instead
               of killing a server on which nothing failed. */
            NSLog(@"macVNC: the curtain watchdog did not run for %llu ms "
                  @"(suspension or sleep); re-baselining rather than treating "
                  @"it as a wedge",
                  (unsigned long long)(state.observationGapNanoseconds / 1000000ull));
            atomic_store(&_heartbeatSentNanoseconds, 0);
            graceUntil = now + MACVNC_CURTAIN_INPUT_RESUME_GRACE_NANOSECONDS;
            continue;
        case MacVNCCurtainInputWatchdogCallbackStalled:
            /* The screen cannot fail open by itself: NSWindow teardown is
               main-thread work, and a wedged callback takes the tap with it.
               Process death is the only thing that gives the local user their
               screen back from out here. */
            fprintf(stderr, "macVNC: curtain input callback wedged - aborting so "
                            "the local user gets their screen back\n");
            abort();
        case MacVNCCurtainInputWatchdogPollStalled:
            /* The tap thread's run loop stopped running: nothing is being
               swallowed and nothing is left to notice that. */
            fprintf(stderr, "macVNC: curtain input poll stopped running - the "
                            "tap is no longer suppressing anything; aborting so "
                            "the local user gets their screen back\n");
            abort();
        case MacVNCCurtainInputWatchdogMainThreadStalled:
            fprintf(stderr, "macVNC: main thread has not answered the curtain "
                            "heartbeat - aborting so the local user gets their "
                            "screen back\n");
            abort();
        case MacVNCCurtainInputWatchdogHealthy:
            break;
        }
        if (state.heartbeatSentNanoseconds == 0)
            [self sendHeartbeatAt:now];
    }
    if (_watchdogFinished)
        dispatch_semaphore_signal(_watchdogFinished);
}

- (void)sendHeartbeatAt:(uint64_t)now
{
    atomic_store(&_heartbeatSentNanoseconds, now ? now : 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&_heartbeatSentNanoseconds, 0);
    });
}

- (void)dealloc
{
    [self stop];
    [super dealloc];
}

@end

