#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

#import "MacVNCCurtainController.h"   /* MacVNCCurtainInputSuppression, ...Clock,
                                       * ...SecretSource, ...Scheduler */

/*
 * The input half of curtain mode: the event tap that swallows what the person
 * standing at the Mac types and clicks, and the ONE path back in - the same
 * keystrokes, fed to MacVNCCurtainPolicy.
 *
 * This is the module that can trap a human behind their own Mac, so every
 * decision here is biased toward the local user getting control back, and
 * every decision that can be made without a device IS made without one: the
 * tap itself is a seam (MacVNCCurtainInputTap), and the four judgements that
 * matter - "may this curtain go up at all", "is this event one of ours", "is
 * the keyboard being withheld from us", "is something wedged" - are pure
 * functions below, tested with real CGEvents and no tap at all.
 *
 * ---------------------------------------------------------------------------
 * The rules, and the failure each one exists to prevent:
 *
 * 1. THREE PRECONDITIONS, NOT ONE. -beginSuppressingInput answers NO unless
 *    (a) this process is trusted for Accessibility - checked with the prompt
 *    SUPPRESSED, because macVNC never raises a macOS permission dialog - AND
 *    (b) CGEventTapCreate returned non-NULL AND (c) the keyboard bits SURVIVED
 *    in the effective mask. (c) is not a belt-and-braces re-check of (a):
 *    without Accessibility trust the keyboard bits are silently cleared from
 *    the mask and the call still returns non-NULL as long as pointer bits
 *    survive (CGEvent.h:272-279). Believing "the tap was created" would give
 *    the worst state this feature can produce - a black screen, a dead mouse,
 *    a fully live keyboard typing into applications nobody can see, and an
 *    escape hatch that never sees a key. TCC resets when the app is re-signed
 *    or updated, so this is a field condition, not a lab one, and the mask is
 *    READ BACK (CGGetEventTapList) rather than assumed.
 *
 * 2. OUR OWN INJECTION IS TAGGED, AND PASSES THROUGH UNMODIFIED. CGEventPost
 *    passes events through taps at that location, so the remote viewer's own
 *    keyboard and mouse arrive at this tap (CGEvent.h:347-352). They are
 *    recognised by MACVNC_CURTAIN_INPUT_EVENT_MAGIC, set on the server's
 *    private CGEventSource with CGEventSourceSetUserData, and - for the one
 *    legacy POINTER path that has no source to tag - by the posting process
 *    id. See macVNCCurtainInputEventIsSelfInjected.
 *
 *    THE TAG SURVIVES THE ROUND TRIP, MEASURED RATHER THAN ASSUMED. An
 *    in-process read-back proves nothing: what matters is what a real tap sees
 *    after CGEventPost has been through WindowServer. Measured on macOS 15
 *    with an active session tap that swallowed its own probes: a keyboard
 *    event (keyDown and keyUp) and a mouse event, all built from a source
 *    tagged with this constant, arrived at the tap carrying
 *    kCGEventSourceUserData == 0x6D6163564E43 exactly - unshifted, unmasked -
 *    and kCGEventSourceUnixProcessID == our pid. Because the tag is intact for
 *    KEYBOARD events, the process-id leg is deliberately narrowed to POINTER
 *    events, which is the only place it is load-bearing; that keeps the
 *    pass-through surface as small as the injection side actually needs.
 *
 * 3. THE TAP RUNS ON ITS OWN THREAD, with its own run loop, never the main
 *    one: a wedged main thread would take the callback and the AppKit path
 *    down together, and NSWindow teardown is main-thread only, so the screen
 *    could not be given back. Teardown happens on that same thread
 *    (CGEventTapEnable(false), invalidate the source, release), because
 *    invalidating a run-loop source from another thread is a use-after-free.
 *
 * 4. THE CALLBACK CANNOT BLOCK. It takes no lock that anything else can hold,
 *    does no I/O, never sleeps and NEVER LOGS A KEYSTROKE. It reads a few
 *    fields, translates with CGEventKeyboardGetUnicodeString (allocation-free)
 *    and feeds MacVNCCurtainPolicy, which is callback-safe by construction. A
 *    callback that blocks for ~1 s makes WindowServer disable the tap, which
 *    restores local input while the black window stays composited - input
 *    fails open by itself, the SCREEN does not. Hence rule 6.
 *
 * 5. FOCUS POLICY, STATED ONCE. The curtain window is NOT key while the tap is
 *    healthy: the tap is the only path to the unlock policy, and a key window
 *    would receive the REMOTE party's keystrokes (their events are posted into
 *    this session and land in the focused window). The window becomes key ONLY
 *    while the tap path is known unavailable - secure input on, or the tap
 *    disabled and not re-enablable - and its keyDown: ignores self-injected
 *    events by the same tag as rule 2.
 *
 * 6. THE WATCHDOG MEASURES LATENCY, NOT SILENCE - WITH ONE EXCEPTION, AND THE
 *    EXCEPTION IS WHERE THE BLIND SPOT WAS. An idle user produces no EVENTS at
 *    all, so "no callbacks for N seconds" would fire in the feature's NORMAL
 *    state; hence a callback is judged only by how long it has been IN FLIGHT,
 *    and a main-thread heartbeat only by how long it has gone unacknowledged.
 *    THE POLL IS DIFFERENT: it is TIMER-driven at a known interval, so nobody
 *    has to do anything for it to run, and its SILENCE IS A FAULT. That
 *    matters because the poll is the only detector of a tap that went deaf
 *    without saying so - a disabled tap never delivers the disable
 *    notification, which is itself an event - and it runs on the same run loop
 *    as the callback, so a wedged or starved tap thread kills the detector and
 *    the thing it detects together. Without the poll clause the watchdog would
 *    answer "healthy" for a black screen with a fully live keyboard.
 *
 *    UNOBSERVED TIME IS NOT A WEDGE. abort() is the one action here that is
 *    not fail-safe when it is wrong, and Darwin's CLOCK_MONOTONIC keeps
 *    advancing while the machine sleeps while this process is frozen - so on
 *    wake every stamp looks ancient on a machine where nothing failed. The
 *    watchdog therefore measures ITS OWN observation gap first: a gap far
 *    larger than its sleep means the process was frozen (lid closed, SIGSTOP,
 *    a debugger), which is reported as its own verdict and answered by
 *    re-baselining rather than by killing a healthy server.
 *
 *    Its action, when something really is wedged, is abort(), because process
 *    death is the only thing that restores the SCREEN from outside a wedged
 *    main thread.
 *
 * 7. SECURE EVENT INPUT IS POLLED ON THE TAP'S OWN THREAD.
 *    IsSecureEventInputEnabled() is documented as not thread safe
 *    (CarbonEventsCore.h:3055-3056) and the lifecycle queue is the wrong
 *    caller; polling it where the keyboard events would arrive is what keeps
 *    the check-then-act window small. THE HONEST BOUND IS NOT "one poll
 *    interval": it is one poll interval, PLUS the main-queue hop the report
 *    takes, PLUS the controller's lift and the windows going out - so on a
 *    busy main thread it is bounded only by the heartbeat's own abort. For
 *    that whole window the local user's keystrokes go where they were already
 *    going. What this module can shorten is the first term; the rest is the
 *    price of every decision being made on the main thread. While it is on, keyboard
 *    events are withheld from session taps: local keys are NOT suppressed, and
 *    the owner typing the unlock password types it into the focused app -
 *    WHICH THE REMOTE PARTY IS WATCHING. So the answer is: hand focus to the
 *    curtain window (rule 5) and report it, which lifts.
 *
 *    THE HAND-OVER LATCHES FOR THE REST OF THE SUPPRESSION SESSION, and that
 *    is a design decision rather than an oversight. Taking the focus is itself
 *    an app ACTIVATION, which deactivates whoever held secure input, so the
 *    very next poll would read IsSecureEventInputEnabled() as false and hand
 *    the focus straight back - a 10 Hz flap with the local user's password
 *    split across two applications, which is precisely the disclosure this
 *    rule exists to stop. Once the tap path has been known unavailable, the
 *    curtain window keeps the keyboard until suppression ends; suppression
 *    ends on the lift the report triggers, which is milliseconds away.
 *
 *    AND THAT LAST CLAUSE IS A COUPLING, NOT A CONVENIENCE - WHOEVER WIRES THE
 *    OBSERVER OWNS IT. With the observer this module is designed for
 *    (MacVNCCurtainController), the hand-over is in practice INERT: the
 *    controller lifts on -setSecureInputActive:YES and on
 *    -noteInputSuppressionUnavailable, and it does so SYNCHRONOUSLY inside the
 *    very main-queue block that just handed the focus over, so the curtain
 *    window is key for zero run-loop iterations and no flap is possible.
 *    -curtainWindowDidReceiveCharacters: is, in that wiring, unreachable.
 *
 *    Under an observer that does NOT lift on those reports, the latch is what
 *    keeps this application active and the curtain window key for the whole
 *    session - and MacVNCCurtainKeyWindow's -keyDown: DROPS self-injected
 *    events (rule 5, so the remote party cannot type the curtain open). The
 *    consequence is specific and easy to miss: THE REMOTE VIEWER'S KEYBOARD
 *    WOULD DIE WHILE THEIR MOUSE KEPT WORKING, because pointer events never go
 *    through a key window. So an observer that wants to keep the curtain up
 *    across secure input must also give the focus back, and this module offers
 *    no way to do that except ending suppression. Task 5 wires that observer.
 */

/*
 * The tag on every event this application injects.
 *
 * Set on the server's private CGEventSource in MacVNCInput.m, read back here.
 * A #define rather than a function so the injection side needs no link
 * dependency on the curtain: MacVNCInput.m is compiled into targets that have
 * no tap at all.
 */
#define MACVNC_CURTAIN_INPUT_EVENT_MAGIC 0x6D6163564E43LL   /* "macVNC" */

/* The events this tap asks for. The keyboard bits are the ones that get
 * silently cleared without Accessibility trust, which is what makes them worth
 * naming separately (rule 1). Modifier changes count as keyboard: a curtain
 * that swallows letters but passes Command through is not a curtain. */
#define MACVNC_CURTAIN_INPUT_KEYBOARD_MASK                                     \
    ((1ULL << kCGEventKeyDown) | (1ULL << kCGEventKeyUp) |                     \
     (1ULL << kCGEventFlagsChanged))
#define MACVNC_CURTAIN_INPUT_POINTER_MASK                                      \
    ((1ULL << kCGEventLeftMouseDown) | (1ULL << kCGEventLeftMouseUp) |         \
     (1ULL << kCGEventRightMouseDown) | (1ULL << kCGEventRightMouseUp) |       \
     (1ULL << kCGEventOtherMouseDown) | (1ULL << kCGEventOtherMouseUp) |       \
     (1ULL << kCGEventMouseMoved) | (1ULL << kCGEventLeftMouseDragged) |       \
     (1ULL << kCGEventRightMouseDragged) | (1ULL << kCGEventOtherMouseDragged) | \
     (1ULL << kCGEventScrollWheel))
#define MACVNC_CURTAIN_INPUT_EVENT_MASK                                        \
    (MACVNC_CURTAIN_INPUT_KEYBOARD_MASK | MACVNC_CURTAIN_INPUT_POINTER_MASK)

/* How often the tap thread looks at secure input, at the tap's enabled state
 * and at the traffic it has been seeing. Short, because it bounds the window
 * in which secure input is on and we still believe we are suppressing keys. */
#define MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS (100ull * 1000ull * 1000ull)

/* A callback still in flight after this long is a wedge, not slow work: the
 * whole callback is a handful of field reads and one comparison, and
 * WindowServer itself gives up at about a second. */
#define MACVNC_CURTAIN_INPUT_CALLBACK_STALL_NANOSECONDS (500ull * 1000ull * 1000ull)

/* A main-thread heartbeat unacknowledged for this long means the thread that
 * owns every NSWindow cannot answer, so the curtain cannot be taken down by
 * anything short of process death. Same figure as the controller's own stall
 * bound, for the same reason. */
#define MACVNC_CURTAIN_INPUT_MAIN_STALL_NANOSECONDS (5ull * 1000ull * 1000ull * 1000ull)

/* The poll is timer-driven every MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS, so
 * twenty missed polls is not an idle user - it is a run loop that is not
 * running, i.e. the detector for a silently deaf tap has died with the thread
 * it was watching. Long enough that ordinary scheduling jitter never reaches
 * it, short enough that a black screen with a live keyboard is measured in
 * seconds. */
#define MACVNC_CURTAIN_INPUT_POLL_STALL_NANOSECONDS (2ull * 1000ull * 1000ull * 1000ull)

/* The watchdog sleeps in MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS-sized steps; an
 * observation gap this much larger than that means the PROCESS did not run,
 * not that something in it is stuck. Everything measured across such a gap is
 * unobserved time, so it is re-baselined rather than judged. */
#define MACVNC_CURTAIN_INPUT_RESUME_GAP_NANOSECONDS (2ull * 1000ull * 1000ull * 1000ull)

/* How long after a resume the watchdog judges nothing at all, so the run loop
 * and the main queue get a chance to catch up before their stamps are believed
 * again. */
#define MACVNC_CURTAIN_INPUT_RESUME_GRACE_NANOSECONDS (2ull * 1000ull * 1000ull * 1000ull)

/* How long the pointer may keep moving with the keyboard silent before we
 * believe the keyboard is being withheld from us. Deliberately generous: this
 * is a corroborating signal for secure input, and firing it wrongly lifts a
 * curtain that did not need lifting - which is the direction this feature is
 * allowed to fail in. */
#define MACVNC_CURTAIN_INPUT_KEYBOARD_SILENCE_NANOSECONDS (5ull * 1000ull * 1000ull * 1000ull)

/* ------------------------------------------------------------------------- */
/* The four pure decisions. No tap, no thread, no device.                     */
/* ------------------------------------------------------------------------- */

/*
 * Whether the mask the system actually kept still lets us see the keyboard.
 *
 * `effectiveMask` is CGEventTapInformation.eventsOfInterest for our own tap. 0
 * means "could not be read", which is a refusal: an unverifiable mask is
 * exactly the state rule 1 exists to catch. ALL keyboard bits must be present,
 * not any - a tap that sees key-downs but not flag changes would let the local
 * user drive an invisible desktop with Command shortcuts.
 */
bool macVNCCurtainInputMaskKeepsKeyboard(uint64_t effectiveMask);

/*
 * Whether this event is one WE injected on behalf of the remote viewer.
 *
 * Two legs, because the injection side has two kinds of path:
 *   - the SOURCE TAG, for ALL event types: every event built from the server's
 *     private CGEventSource carries MACVNC_CURTAIN_INPUT_EVENT_MAGIC in
 *     kCGEventSourceUserData, and it is still there when a real tap reads it
 *     back (see rule 2 for the measurement). This is the primary leg.
 *   - the POSTING PROCESS, for POINTER EVENTS ONLY: CGPostMouseEvent
 *     (MacVNCInput.m's pointer path, used because it takes a button MASK plus
 *     a position, so drags and double clicks need no synthesis) builds its
 *     event internally and has no source to tag. Measured on macOS 15: such an
 *     event DOES reach our own session tap and DOES carry our pid in
 *     kCGEventSourceUnixProcessID, with userData 0. Without this leg the
 *     remote viewer's mouse would die the moment the curtain went up while
 *     their keyboard kept working.
 *
 * The pid leg is restricted to the event types that need it. Keyboard and
 * scroll injection is tagged at the source, so a KEY event carrying our pid
 * but no tag is not something this server posts, and is treated as local -
 * which keeps the pass-through surface as narrow as the injection side is.
 *
 * Both legs fail in the safe direction: an event wrongly believed to be ours
 * is PASSED THROUGH, i.e. the local user keeps control. Hardware events carry
 * the HID system's pid, not ours.
 */
bool macVNCCurtainInputEventIsSelfInjected(CGEventType type, CGEventRef event);

/*
 * The corroborating signal for secure input (rule 7): the keyboard went quiet
 * while the pointer kept moving.
 *
 * Requires that keyboard traffic was seen at all under this curtain
 * (`lastKeyboardNanoseconds` != 0): with no keys ever observed there is
 * nothing to have stopped, and a local user who only ever moves the mouse
 * would otherwise lift their own curtain for no reason. Timestamps are
 * monotonic nanoseconds; 0 means "never".
 */
bool macVNCCurtainInputSecureInputSuspected(uint64_t lastKeyboardNanoseconds,
                                            uint64_t lastPointerNanoseconds,
                                            uint64_t nowNanoseconds);

typedef enum {
    MacVNCCurtainInputWatchdogHealthy = 0,
    /* A tap callback has been in flight past the stall bound. */
    MacVNCCurtainInputWatchdogCallbackStalled,
    /* A heartbeat the main thread was asked to acknowledge never came back. */
    MacVNCCurtainInputWatchdogMainThreadStalled,
    /* The timer-driven poll stopped running: the tap thread's run loop is not
     * servicing anything, so the only detector of a silently deaf tap is gone
     * and so is the tap's ability to swallow anything. */
    MacVNCCurtainInputWatchdogPollStalled,
    /* NOT a fault: the watchdog itself did not run for far longer than it
     * sleeps, so the process was frozen. Every other stamp is now measuring
     * unobserved time and must be re-baselined, NOT acted on - this is the
     * verdict that stops a lid-close from killing a healthy server. Checked
     * FIRST, because it invalidates the other three. */
    MacVNCCurtainInputWatchdogUnobservedGap,
} MacVNCCurtainInputWatchdogVerdict;

typedef struct {
    /* When the callback currently in flight was entered; 0 when none is. THIS
     * IS NOT "when the last callback happened": silence is health here. */
    uint64_t callbackEntryNanoseconds;
    /* When the outstanding main-thread heartbeat was sent; 0 when the last one
     * has already been acknowledged. */
    uint64_t heartbeatSentNanoseconds;
    /* When the timer-driven poll last COMPLETED. Unlike the two above, this one
     * is judged by silence, because nobody has to type for a timer to fire. 0
     * means "not armed yet" and is not judged at all. */
    uint64_t lastPollCompletedNanoseconds;
    /* How long since the watchdog's own previous observation. Its own sleep is
     * the yardstick: much more than that means the process was not running. */
    uint64_t observationGapNanoseconds;
} MacVNCCurtainInputWatchdogState;

/*
 * The watchdog's whole decision, as a pure function so the difference between
 * LATENCY and SILENCE is a test rather than a claim: a state with no callback
 * in flight and no outstanding heartbeat is HEALTHY no matter how long ago
 * anything last happened - while a poll that stopped arriving is a FAULT,
 * because the poll runs on a timer rather than on a human.
 */
MacVNCCurtainInputWatchdogVerdict macVNCCurtainInputWatchdogEvaluate(
    const MacVNCCurtainInputWatchdogState *state, uint64_t nowNanoseconds);

/* ------------------------------------------------------------------------- */
/* The seams.                                                                 */
/* ------------------------------------------------------------------------- */

/*
 * What this module tells the controller. The three selectors are exactly the
 * ones MacVNCCurtainController already publishes, so the wiring task declares
 * the conformance and needs no adapter - and this module never imports the
 * controller CLASS, which is what keeps its test free of the whole capture
 * stack.
 *
 * ALL THREE ARRIVE ON THE MAIN THREAD: the controller asserts it, and the tap
 * thread is where they originate, so every one of them is hopped.
 */
@protocol MacVNCCurtainInputObserver <NSObject>
- (void)noteLocalUnlockAccepted;
- (void)setSecureInputActive:(BOOL)active;
- (void)noteInputSuppressionUnavailable;
@end

/*
 * Rule 5's other half: who may hold the local keyboard focus. Implemented by
 * MacVNCCurtainWindowSet; called on the MAIN thread only.
 */
@protocol MacVNCCurtainInputFocus <NSObject>
- (void)setAcceptsKeyboardFocus:(BOOL)accepts;
/* Where the keys that reach the WINDOW go. Set while suppression is armed and
 * cleared when it ends, so a window left behind cannot feed a policy that is
 * no longer armed. */
- (void)setKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink;
@end

/* Called BY the tap seam, ON the tap's own thread (except where noted). */
@protocol MacVNCCurtainInputTapHandler <NSObject>
/* One event. Returns the event to pass it on, or NULL to swallow it. */
- (CGEventRef)handleTapEventOfType:(CGEventType)type event:(CGEventRef)event;
/* Every MACVNC_CURTAIN_INPUT_POLL_NANOSECONDS while the tap is armed. */
- (void)handleTapPoll;
/* For the watchdog, which runs on a THIRD thread: 0 when no callback is in
 * flight. Must be readable without taking anything the callback holds. */
- (uint64_t)callbackEntryNanoseconds;
/* Also for the watchdog: when -handleTapPoll last returned. 0 until the first
 * one completes. */
- (uint64_t)lastPollCompletedNanoseconds;
@end

/*
 * The tap itself, as the one thing a test cannot have: a real CGEventTap on a
 * real thread, seeing real keys.
 *
 * Everything above this protocol - the preconditions, the pass-through, the
 * disable-reason handling, the secure-input transition, the focus policy - is
 * decided in MacVNCCurtainInput and tested against a fake that can refuse
 * trust, return a deaf mask, disable itself with either reason, refuse to be
 * re-enabled, and claim secure input.
 */
@protocol MacVNCCurtainInputTap <NSObject>
/* AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt = NO. Never
 * prompts: this project's hardest rule is that no code path may raise a macOS
 * permission dialog. */
- (BOOL)processIsTrustedForAccessibility;
/* Creates the tap, starts ITS OWN thread and run loop, enables it, and
 * delivers everything to `handler` from that thread. NO when CGEventTapCreate
 * returned NULL or the thread could not be started. */
- (BOOL)startWithEventMask:(uint64_t)eventMask
                   handler:(id<MacVNCCurtainInputTapHandler>)handler;
/* CGEventTapInformation.eventsOfInterest for our own tap, read back from the
 * system; 0 when it cannot be determined. */
- (uint64_t)effectiveEventMask;
- (BOOL)tapIsEnabled;
/* CGEventTapEnable(tap, true) plus a READ-BACK: NO when it did not stick. */
- (BOOL)reenableTap;
/* IsSecureEventInputEnabled(), called from the tap thread only. */
- (BOOL)secureInputIsEnabled;
/* Runs `block` on the tap thread, so the unlock policy stays owned by exactly
 * one thread even when keys arrive through the curtain WINDOW instead of the
 * tap. NO when there is no tap thread to run it on. */
- (BOOL)performOnTapThread:(dispatch_block_t)block;
/* Tears the tap down ON ITS OWN THREAD and joins it. Idempotent. */
- (void)stop;
@end

/* ------------------------------------------------------------------------- */

/*
 * The decisions, above the seam. Conforms to the suppression protocol the
 * controller already refuses to raise without.
 *
 * Nothing constructs this in production yet - the preference and the wiring
 * are the next task - so with no curtain ever raised, behaviour is exactly
 * what it was: no tap is created, and the only trace of this module in a
 * running server is the tag on the event source (MacVNCInput.m), which nothing
 * but a tap can read.
 */
/*
 * WHAT IS TESTED HERE, AND WHAT IS ONLY ARGUED.
 *
 * Everything above the tap seam - the three preconditions, the pass-through,
 * both disable reasons, the secure-input transition and its corroboration, the
 * focus latch, the watchdog's verdicts, the poll's completion stamp - is
 * exercised by tests/test_curtain_input.m against a fake tap, with real
 * CGEvents and no device.
 *
 * NONE of the following is reachable by that suite, because all of it lives
 * inside MacVNCCurtainEventTap's own state machine and its three threads. It
 * is argued from source and reviewed, NOT tested; a device test or a fault
 * injection seam would be needed to cover it, and neither exists yet:
 *
 *   - the monotone refusal latch (_refuseForever): a tap whose teardown never
 *     joined must never arm again, and the tap thread must not be able to
 *     clear that by finishing late;
 *   - publishing setup success only while nobody has given up on it, and
 *     answering "already started" only while a run loop is still live;
 *   - the handler being retained for both the tap and the WATCHDOG thread, and
 *     released only when BOTH joins succeed (leaked otherwise);
 *   - the semaphore lifetimes on every timeout branch;
 *   - the watchdog's own start handshake, and the rule that a watchdog which
 *     does not start is a start FAILURE rather than a degraded success;
 *   - the resume grace window, and abort() itself, which by construction
 *     cannot be observed by a test that must survive it.
 */
@interface MacVNCCurtainInput : NSObject <MacVNCCurtainInputSuppression,
                                          MacVNCCurtainInputTapHandler,
                                          MacVNCCurtainKeyboardSink>

- (instancetype)initWithTap:(id<MacVNCCurtainInputTap>)tap
                      focus:(id<MacVNCCurtainInputFocus>)focus
                   observer:(id<MacVNCCurtainInputObserver>)observer
               secretSource:(id<MacVNCCurtainSecretSource>)secretSource
                  scheduler:(id<MacVNCCurtainScheduler>)scheduler
                      clock:(id<MacVNCCurtainClock>)clock;

/* Production wiring: the real tap on its own thread, the main queue for the
 * hops, the monotonic clock. */
+ (instancetype)inputWithDefaultSeamsFocus:(id<MacVNCCurtainInputFocus>)focus
                                  observer:(id<MacVNCCurtainInputObserver>)observer
                              secretSource:(id<MacVNCCurtainSecretSource>)secretSource;

/* -curtainWindowDidReceiveCharacters:count: (MacVNCCurtainKeyboardSink) is the
 * other way in: keys that reached the curtain WINDOW instead of the tap, which
 * is possible only while the tap path is unavailable (rule 5). They are fed to
 * the same policy, carried onto the tap's own thread, so the policy is never
 * touched by two threads at once. */

/* Whether the tap is armed right now. */
@property (nonatomic, readonly) BOOL suppressing;
/* Whether the tap path is currently believed unavailable - the state in which,
 * and only in which, the curtain window may take the keyboard focus. */
@property (nonatomic, readonly) BOOL tapPathUnavailable;

@end
