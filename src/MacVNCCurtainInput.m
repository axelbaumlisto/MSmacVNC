#import "MacVNCCurtainInput.h"

#include <stdatomic.h>
#include <unistd.h>                 /* getpid */

#import "MacVNCCurtainPolicy.h"
#import "MacVNCCurtainWindow.h"

/*
 * NOTHING IN THIS FILE TOUCHES A DEVICE. The tap, its thread, its run loop,
 * its poll timer, the watchdog and the abort() live in MacVNCCurtainEventTap.m
 * behind the MacVNCCurtainInputTap protocol, and so does the production
 * factory that names them - which is why the three curtain test targets can
 * compile this file and link no tap at all.
 */

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
/* The window set is the focus seam; the conformance is declared in this       */
/* module's HEADER (the wiring has to pass the curtain's own window set in),    */
/* which leaves nothing but an empty implementation here.                      */
/* ------------------------------------------------------------------------- */

@implementation MacVNCCurtainWindowSet (MacVNCCurtainInputFocus)
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
    macVNCCurtainDiscardSecret(secret);
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
        /* WindowServer told us why, so the log says why. */
        [self handleTapDisabledBecause:(type == kCGEventTapDisabledByTimeout
                                            ? @"a callback timeout"
                                            : @"user input")];
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

/*
 * `reason` is a phrase for the log and NOTHING else: every reason gets the
 * same treatment, so the parameter cannot change what happens - only what is
 * said about it. It is a STRING rather than the BOOL it used to be because
 * there are three reasons and only two of them are ones WindowServer told us:
 * the poll finds a tap disabled without any notification at all (the
 * notification is itself an event, and an event is what a dead tap stops
 * delivering), and the old signature made that path claim "a callback
 * timeout", which is a log line stating a cause nobody measured.
 */
- (void)handleTapDisabledBecause:(NSString *)reason
{
    /* Every reason gets the same treatment: WindowServer disables the tap and
       local input is live again the moment it does, while the black window
       stays composited. Re-enable, then verify it stuck - CGEventTapEnable
       has no return value, so "asked" is not "done". */
    BOOL restored = [_tap reenableTap];
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
        [self handleTapDisabledBecause:@"a check that found it disabled"];

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

@end
