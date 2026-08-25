#import "MacVNCStartFailure.h"

MacVNCStartAdvice macVNCResolveStartAdvice(MacVNCStartOutcome outcome)
{
    if (outcome.started)
        return MacVNCStartAdviceNone;

    /* A bad configuration is reported even when permissions are missing: the
       user must fix it regardless, and its message is specific. */
    if (outcome.hasConfigurationError)
        return MacVNCStartAdviceConfiguration;

    /* Without permissions the permission flow already owns the conversation;
       a port-collision alert on top of it would be both wrong and stacked over
       the panel the user needs to act on. */
    if (!outcome.permissionsGranted)
        return MacVNCStartAdviceNone;

    return MacVNCStartAdvicePortInUse;
}

NSString *macVNCStartAdviceTitle(MacVNCStartAdvice advice)
{
    if (advice == MacVNCStartAdvicePortInUse)
        return @"macVNC could not start the server";
    return nil;
}

NSString *macVNCStartAdviceBody(MacVNCStartAdvice advice)
{
    if (advice == MacVNCStartAdvicePortInUse)
        return @"The VNC server failed to start. The most likely cause is that "
                "the port is already in use — for example macOS Screen Sharing "
                "on port 5900, or another macVNC instance. Choose a different "
                "port in Preferences and start the server again.";
    return nil;
}
