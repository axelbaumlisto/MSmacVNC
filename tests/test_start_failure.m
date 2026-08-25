#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCStartFailure.h"

static MacVNCStartOutcome outcome(BOOL started, BOOL configError, BOOL granted)
{
    MacVNCStartOutcome o;
    o.started = started;
    o.hasConfigurationError = configError;
    o.permissionsGranted = granted;
    return o;
}

int main(void)
{
    @autoreleasepool {
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

        /* Only the fixed-text advice carries its own copy. */
        assert(macVNCStartAdviceTitle(MacVNCStartAdvicePortInUse).length > 0);
        assert(macVNCStartAdviceBody(MacVNCStartAdvicePortInUse).length > 0);
        assert(macVNCStartAdviceTitle(MacVNCStartAdviceNone) == nil);
        assert(macVNCStartAdviceBody(MacVNCStartAdviceConfiguration) == nil);

        /* The body must name the actual remedy, or it is just noise. */
        NSString *body = macVNCStartAdviceBody(MacVNCStartAdvicePortInUse);
        assert([body containsString:@"port"]);
        assert([body containsString:@"Preferences"]);

        printf("test_start_failure: all assertions passed\n");
    }
    return 0;
}
