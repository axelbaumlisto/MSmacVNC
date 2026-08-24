#import "MacVNCStartupConfig.h"
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
    NSString *portOverride = environment[@"MACVNC_PORT"];
    if (portOverride.integerValue > 0 && portOverride.integerValue <= 65535)
        port = (int)portOverride.integerValue;

    NSString *password = macVNCLoadPassword(defaults);
    NSString *passwordFile = environment[@"MACVNC_PASSWORD_FILE"];
    if (passwordFile.length > 0) {
        password = macVNCReadSecurePasswordFile(passwordFile, &error);
        if (error)
            NSLog(@"%@", error);
    }

    int captureFramesPerSecond = MACVNC_CAPTURE_FPS_DEFAULT;
    NSString *captureFPSOverride = environment[@"MACVNC_CAPTURE_FPS"];
    if (macVNCParseCaptureFPS(captureFPSOverride.UTF8String,
                              &captureFramesPerSecond) == MACVNC_CAPTURE_RATE_INVALID) {
        NSString *captureRateError = [NSString stringWithFormat:
            @"Invalid MACVNC_CAPTURE_FPS '%@'; expected an integer from %d to %d",
            captureFPSOverride, MACVNC_CAPTURE_FPS_MIN, MACVNC_CAPTURE_FPS_MAX];
        if (!error)
            error = captureRateError;
        NSLog(@"%@", captureRateError);
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

    if (port <= 0 || port > 65535)
        port = MacVNCDefaultPort;
    _port = port;
    _captureFramesPerSecond = captureFramesPerSecond;

    _password = [(password.length > 0 ? password : nil) copy];
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
