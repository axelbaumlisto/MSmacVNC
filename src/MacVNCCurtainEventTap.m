#import "MacVNCCurtainEventTap.h"

#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>          /* IsSecureEventInputEnabled */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>                 /* abort */
#include <unistd.h>                 /* getpid, usleep */

#import "FirstFrameBudget.h"        /* macVNCMonotonicNow */
#import "MacVNCCurtainController.h" /* MacVNCCurtainMonotonicClock */
#import "MacVNCCurtainWindow.h"     /* MacVNCCurtainMainQueueScheduler */

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
 * detachNewThreadSelector never ran it, the abort() net would be silently
 * absent - the P0-2 blind spot again, in a different place - while everything
 * above believed input was being watched. So a watchdog that does not answer
 * is a START FAILURE, and its caller refuses to suppress input at all.
 *
 * A failed handshake costs one bounded join in -stop (see the branch below)
 * and refuses this process any further suppression. That is the price of not
 * having to reason about a thread nobody can account for.
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
        /* IT MAY STILL START LATER, AND THAT IS THE WHOLE PROBLEM. Two things
           follow, and neither is optional.

           _watchdogRunning IS LEFT SET, so -stopWatchdog performs its bounded
           JOIN instead of short-circuiting on "never started" and reporting a
           thread that is not there as gone. It is what makes the difference
           observable: a thread that signalled its handshake just as this wait
           expired is INSIDE the loop, reading _handler every 100 ms, and
           -stop releases _handler on a watchdog reported as joined. Returning
           NO here with _watchdogRunning cleared would hand that thread a freed
           handler one iteration later - the exact use-after-free the tap half
           already refuses to risk. With the flag left set, the join either
           succeeds (the thread really is gone) or times out and everything it
           can reach is deliberately leaked instead.

           _refuseForever IS SET, for the reason it exists on the tap side: a
           thread we could not account for must not be able to satisfy a LATER
           arming's handshake. Without it, a second arming would create fresh
           semaphores over the ivars this one is still reading, and the late
           thread could signal the new arming's start and finish - after which
           the new handler is released while it is still being messaged. One
           process that never suppresses input again costs a curtain; the
           alternative costs the person standing at the Mac. */
        atomic_store(&_refuseForever, true);
        return NO;
    }
    dispatch_release(_watchdogStarted);
    _watchdogStarted = NULL;
    return YES;
}

/* YES only when the watchdog thread is known to be GONE - which is what makes
 * it safe to free anything that thread can still reach.
 *
 * The short-circuit below is therefore only for the two states in which there
 * is provably no thread: one where -startWatchdog was never called, and one
 * where it already returned here. A start whose HANDSHAKE timed out is
 * neither - the thread may be starting as we look - so that path leaves
 * _watchdogRunning set and takes the join, rather than answering "gone" for a
 * thread that is about to read _handler. */
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

/* ------------------------------------------------------------------------- */
/* The production wiring, which is the only reason this file is linked at all. */
/* ------------------------------------------------------------------------- */

/*
 * Declared in MacVNCCurtainInput.h as a category, and implemented HERE rather
 * than beside the decisions: it is the one place that names a device, and
 * keeping it on this side of the seam is what lets every test target compile
 * MacVNCCurtainInput.m without linking a single line of tap, thread or abort().
 */
@implementation MacVNCCurtainInput (MacVNCCurtainDefaultSeams)

+ (instancetype)inputWithDefaultSeamsFocus:(id<MacVNCCurtainInputFocus>)focus
                                  observer:(id<MacVNCCurtainInputObserver>)observer
                              secretSource:(id<MacVNCCurtainSecretSource>)secretSource
{
    MacVNCCurtainEventTap *tap = [[MacVNCCurtainEventTap alloc] init];
    MacVNCCurtainMainQueueScheduler *scheduler =
        [[MacVNCCurtainMainQueueScheduler alloc] init];
    MacVNCCurtainMonotonicClock *clock =
        [[MacVNCCurtainMonotonicClock alloc] init];
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
