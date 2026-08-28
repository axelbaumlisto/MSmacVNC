#import "MacVNCStartupConfig.h"

#include "MacVNCImageProfile.h"
#import "MacVNCDefaultsKeys.h"
#import "MacVNCListenMode.h"
#import "MacVNCPassword.h"
#import "CaptureRate.h"
#import "NetworkPolicyResolver.h"

@implementation MacVNCStartupConfig {
    /* Backing storage keeping the produced config's const char* fields alive. */
    NSString *_password;               /* nil = no password (invalid) */
    MacVNCResolvedPolicy _resolvedPolicy;
    int _port;
    int _captureFramesPerSecond;
    MacVNCImageProfile _imageProfile;
    BOOL _viewOnly;
    int _displayNumber;
    BOOL _policyOK;
}

+ (instancetype)configWithDefaults:(NSUserDefaults *)defaults
                       environment:(NSDictionary<NSString *, NSString *> *)environment
{
    return [[[self alloc] initWithDefaults:defaults environment:environment] autorelease];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                     environment:(NSDictionary<NSString *, NSString *> *)environment
{
    if (!(self = [super init]))
        return nil;

    NSString *error = nil;

    int port = (int)[defaults integerForKey:MacVNCKeyPort];
    /* A port outside 1..65535 is a misconfiguration, not a preference: silently
       falling back to 5900 gives the operator a listener they never asked for
       (and possibly believe they did not have). Error instead, matching how
       the capture rate and password paths treat bad input. */
    if (port <= 0 || port > 65535) {
        if (!error)
            error = [NSString stringWithFormat:
                @"Port %d is outside 1-65535; set a valid port in Preferences.", port];
        NSLog(@"macVNC: %@", error);
    }
    /* A non-empty MACVNC_PORT that does not parse to 1..65535 is an error too:
       integerValue==0 used to swallow it into "no override", while the sibling
       MACVNC_CAPTURE_FPS surfaced its parse failures. */
    NSString *portOverride = environment[@"MACVNC_PORT"];
    if (portOverride.length > 0) {
        int overridePort = (int)portOverride.integerValue;
        if (overridePort > 0 && overridePort <= 65535) {
            port = overridePort;
        } else if (!error) {
            error = [NSString stringWithFormat:
                @"Invalid MACVNC_PORT '%@'; expected an integer from 1 to 65535",
                portOverride];
            NSLog(@"macVNC: %@", error);
        }
    }

    NSString *password = macVNCLoadPassword(defaults);
    NSString *passwordFile = environment[@"MACVNC_PASSWORD_FILE"];
    if (passwordFile.length > 0) {
        password = macVNCReadSecurePasswordFile(passwordFile, &error);
        if (error)
            NSLog(@"%@", error);
    }

    /* Capture rate: the stored setting is the normal path, the environment
       variable stays the debugging seam and therefore wins. Both go through the
       same parser so there is exactly one validation rule. An unusable value
       must never prevent the server from starting - it falls back and says so,
       because a mistyped frame rate is not a reason to be unreachable. */
    int captureFramesPerSecond = MACVNC_CAPTURE_FPS_DEFAULT;
    NSString *storedFPS = [defaults objectForKey:MacVNCKeyCaptureFPS]
                              ? [NSString stringWithFormat:@"%ld",
                                     (long)[defaults integerForKey:MacVNCKeyCaptureFPS]]
                              : nil;
    /* A rejected value leaves the variable alone (see macVNCParseCaptureFPS),
       so the fallback is the initialiser above rather than a restatement. */
    if (storedFPS.length > 0 &&
        macVNCParseCaptureFPS(storedFPS.UTF8String, &captureFramesPerSecond) ==
            MACVNC_CAPTURE_RATE_INVALID)
        NSLog(@"macVNC: ignoring stored captureFPS '%@'; using %d FPS",
              storedFPS, captureFramesPerSecond);
    /* The environment is a different SOURCE with a different contract: it is
       typed deliberately by whoever is debugging, so silently ignoring it would
       produce measurements that quietly disagree with the command that asked
       for them. A stored setting falls back; an environment override fails. */
    NSString *captureFPSOverride = environment[@"MACVNC_CAPTURE_FPS"];
    if (captureFPSOverride.length > 0) {
        int fromEnvironment = captureFramesPerSecond;
        if (macVNCParseCaptureFPS(captureFPSOverride.UTF8String,
                                  &fromEnvironment) == MACVNC_CAPTURE_RATE_INVALID) {
            NSString *rateError = [NSString stringWithFormat:
                @"Invalid MACVNC_CAPTURE_FPS '%@'; expected an integer from %d to %d",
                captureFPSOverride, MACVNC_CAPTURE_FPS_MIN, MACVNC_CAPTURE_FPS_MAX];
            if (!error)
                error = rateError;
            NSLog(@"%@", rateError);
        } else {
            captureFramesPerSecond = fromEnvironment;
        }
    }

    /* Image profile: same shape, same reasoning. */
    MacVNCImageProfile imageProfile = macVNCDefaultImageProfile();
    NSString *storedProfile = [defaults stringForKey:MacVNCKeyImageProfile];
    if (storedProfile.length > 0 &&
        !macVNCParseImageProfile(storedProfile.UTF8String, &imageProfile))
        NSLog(@"macVNC: ignoring stored imageProfile '%@'; using '%s'",
              storedProfile, macVNCImageProfileName(imageProfile));
    NSString *profileOverride = environment[@"MACVNC_IMAGE_PROFILE"];
    if (profileOverride.length > 0) {
        MacVNCImageProfile fromEnvironment;
        if (macVNCParseImageProfile(profileOverride.UTF8String, &fromEnvironment)) {
            imageProfile = fromEnvironment;
        } else {
            NSString *profileError = [NSString stringWithFormat:
                @"Invalid MACVNC_IMAGE_PROFILE '%@'; expected 'viewer', "
                @"'lossless', or a level from %d to %d", profileOverride,
                MACVNC_IMAGE_QUALITY_MIN, MACVNC_IMAGE_QUALITY_MAX];
            if (!error)
                error = profileError;
            NSLog(@"%@", profileError);
        }
    }

    _viewOnly = (rfbBool)[defaults boolForKey:MacVNCKeyViewOnly];
    _displayNumber = (int)[defaults integerForKey:MacVNCKeyDisplay];
    NSString *displayOverride = environment[@"MACVNC_DISPLAY"];
    if (displayOverride.length > 0)
        _displayNumber = (int)displayOverride.integerValue;

    MacVNCPolicyInput policyInput = {
        .listenMode = ([defaults stringForKey:MacVNCKeyListenMode] ?: MacVNCListenModeLocalhost).UTF8String,
        .listenAddress = ([defaults stringForKey:MacVNCKeyListenAddress] ?: @"").UTF8String,
        .allowedClients = ([defaults stringForKey:MacVNCKeyAllowedClients] ?: @"").UTF8String,
        .allowAllConfirmed = [defaults boolForKey:MacVNCKeyAllowAllConfirmed],
    };
    MacVNCPolicyEnv policyEnv = {
        .listenAddress = environment[@"MACVNC_LISTEN"].length > 0
            ? environment[@"MACVNC_LISTEN"].UTF8String : NULL,
        .allowedClients = environment[@"MACVNC_ALLOWED_CLIENTS"]
            ? environment[@"MACVNC_ALLOWED_CLIENTS"].UTF8String : NULL,
        .hasAllowedClients = environment[@"MACVNC_ALLOWED_CLIENTS"] != nil,
    };
    _policyOK = macVNCResolveNetworkPolicy(&policyInput, &policyEnv, &_resolvedPolicy);
    if (!_policyOK) {
        NSString *policyError = [NSString stringWithUTF8String:_resolvedPolicy.error];
        if (!error)
            error = policyError;
        NSLog(@"Network policy error: %@", policyError);
    } else if (_resolvedPolicy.envOverrideActive) {
        NSLog(@"macVNC network policy uses environment override(s)");
    }

    _port = port;
    _captureFramesPerSecond = captureFramesPerSecond;
    _imageProfile = imageProfile;

    _password = [(password.length > 0 ? password : nil) copy];

    /* Authentication is mandatory: surface an explicit configuration error for
       an empty/unset password so AppDelegate shows a dialog instead of failing
       silently deep in ScreenInit. */
    if (!error && _password.length == 0)
        error = @"Set a VNC password in Preferences before starting the server.";

    _usedEnvironmentOverride = _policyOK && _resolvedPolicy.envOverrideActive;
    _error = [error copy];
    return self;
}

- (BOOL)fillServerConfig:(MacVNCServerConfig *)config
{
    if (_error || !_policyOK || !config)
        return NO;
    config->port = _port;
    config->password = _password.length > 0 ? _password.UTF8String : NULL;
    config->captureFramesPerSecond = _captureFramesPerSecond;
    config->imageProfile = _imageProfile;
    config->viewOnly = _viewOnly;
    config->displayNumber = _displayNumber;
    config->listenAddress = _resolvedPolicy.bindAddress;
    config->allowedClients = _resolvedPolicy.allowedClients;
    config->clientAccessMode = _resolvedPolicy.accessMode;
    return YES;
}

- (void)dealloc
{
    [_password release];
    [_error release];
    [super dealloc];
}

@end
