#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCStartFailure.h"

static MacVNCStartOutcome outcome(BOOL started, BOOL configError, BOOL granted)
{
    MacVNCStartOutcome o;
    o.started = started;
    o.alreadyRunning = NO;
    o.hasConfigurationError = configError;
    o.permissionsGranted = granted;
    return o;
}

static MacVNCStartOutcome alreadyRunning(BOOL granted)
{
    MacVNCStartOutcome o = outcome(NO, NO, granted);
    o.alreadyRunning = YES;
    return o;
}

static void testCaptureFailureLatch(void)
{
    uint64_t last = 0;
    /* Fresh generation: act, and remember it. */
    assert(macVNCShouldActOnCaptureFailure(7, 7, &last) == true);
    assert(last == 7);
    /* Same generation again (multi-display failure storm, stop still queued):
       must NOT act a second time - each act stacks a modal alert. */
    assert(macVNCShouldActOnCaptureFailure(7, 7, &last) == false);
    assert(last == 7);
    /* A genuinely new run: act again. */
    assert(macVNCShouldActOnCaptureFailure(8, 8, &last) == true);
    assert(last == 8);
    /* Stale notification from a dead run: never act. */
    assert(macVNCShouldActOnCaptureFailure(3, 8, &last) == false);
    assert(last == 8);
    /* NULL latch: only the staleness rule applies. */
    assert(macVNCShouldActOnCaptureFailure(8, 8, NULL) == true);
    assert(macVNCShouldActOnCaptureFailure(7, 8, NULL) == false);
}

int main(void)
{
    @autoreleasepool {
        testCaptureFailureLatch();
        /* Success says nothing. */
        assert(macVNCResolveStartAdvice(outcome(YES, NO,  YES)) == MacVNCStartAdviceNone);
        assert(macVNCResolveStartAdvice(outcome(YES, YES, NO))  == MacVNCStartAdviceNone);

        /* A bad configuration is reported whatever the permission state: the
           user must fix it either way and the message is specific. */
        assert(macVNCResolveStartAdvice(outcome(NO, YES, YES)) == MacVNCStartAdviceConfiguration);
        assert(macVNCResolveStartAdvice(outcome(NO, YES, NO))  == MacVNCStartAdviceConfiguration);

        /* Permissions granted and no config error: the listener is the problem.
           Staying silent here is the bug this replaced - the menu would read
           "Not running" with no reason given. */
        assert(macVNCResolveStartAdvice(outcome(NO, NO, YES)) == MacVNCStartAdvicePortInUse);

        /* Permissions missing: the permission flow owns the conversation. A
           port alert here would be wrong AND would stack over the panel the
           user has to act on. */
        assert(macVNCResolveStartAdvice(outcome(NO, NO, NO)) == MacVNCStartAdviceNone);

        /* Already running is NOT a failure: telling the user to change the port
           while the server is serving on the current one is worse than silence.
           Reached by pressing "Start Server" twice. */
        assert(macVNCResolveStartAdvice(alreadyRunning(YES)) == MacVNCStartAdviceNone);
        assert(macVNCResolveStartAdvice(alreadyRunning(NO))  == MacVNCStartAdviceNone);

        /* Only the fixed-text advice carries its own copy. */
        assert(macVNCStartAdviceTitle(MacVNCStartAdvicePortInUse).length > 0);
        assert(macVNCStartAdviceBody(MacVNCStartAdvicePortInUse).length > 0);
        assert(macVNCStartAdviceTitle(MacVNCStartAdviceNone) == nil);
        assert(macVNCStartAdviceBody(MacVNCStartAdviceConfiguration) == nil);

        /* The body must name the actual remedy, or it is just noise. */
        NSString *body = macVNCStartAdviceBody(MacVNCStartAdvicePortInUse);
        assert([body containsString:@"port"]);
        assert([body containsString:@"Preferences"]);

    
        /* What a capture failure costs.

           Every failure used to stop the server and raise a modal whose only
           recovery - "start it again from the menu" - lives in a menu bar the
           remote user cannot reach. Once the display-wake assertion stopped
           leaking, the screens could idle-sleep again, ScreenCaptureKit
           reported failure, and macVNC killed its own listener with nobody
           watching. These rows exist so that cannot come back. */
        assert(macVNCResolveCaptureFailure(true, true, 1) ==
               MacVNCCaptureFailurePermission);
        /* A revoked permission is the user's to fix, whether or not anyone is
           connected and whatever the desk looks like. */
        assert(macVNCResolveCaptureFailure(true, false, 0) ==
               MacVNCCaptureFailurePermission);

        /* Nobody watching: never trade the listener for nothing. This is the
           common case, because a capturer outlives the stream it stopped. */
        assert(macVNCResolveCaptureFailure(false, true, 0) ==
               MacVNCCaptureFailureKeepServing);
        assert(macVNCResolveCaptureFailure(false, false, 0) ==
               MacVNCCaptureFailureKeepServing);

        /* Watching, and something is still attached - a panel asleep, a mode
           change, one monitor of several unplugged. Keep serving. */
        assert(macVNCResolveCaptureFailure(false, true, 1) ==
               MacVNCCaptureFailureKeepServing);
        assert(macVNCResolveCaptureFailure(false, true, 5) ==
               MacVNCCaptureFailureKeepServing);

        /* Watching, and nothing left attached: there is no picture to serve. */
        assert(macVNCResolveCaptureFailure(false, false, 1) ==
               MacVNCCaptureFailureStopServer);

    printf("test_start_failure: all assertions passed\n");
    }
    return 0;
}
