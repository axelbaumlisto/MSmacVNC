#import "MacVNCDefaultsKeys.h"
#import "MacVNCListenMode.h"

NSString * const MacVNCKeyPort              = @"rfbPort";
NSString * const MacVNCKeyPassword          = @"rfbPassword";
NSString * const MacVNCKeyViewOnly          = @"viewOnly";
NSString * const MacVNCKeyDisplay           = @"displayNumber";
NSString * const MacVNCKeyListenMode        = @"listenMode";
NSString * const MacVNCKeyListenAddress     = @"listenAddress";
NSString * const MacVNCKeyAllowedClients    = @"allowedClients";
NSString * const MacVNCKeyAllowAllConfirmed = @"allowAllConfirmed";
NSString * const MacVNCKeyAutoAllowedClients = @"autoAllowedClients";

NSString * const MacVNCBundleID = @"net.christianbeier.macVNC";

const int MacVNCDefaultPort = 5900;

NSArray<NSString *> *macVNCAllDefaultsKeys(void)
{
    return @[MacVNCKeyPort, MacVNCKeyPassword, MacVNCKeyViewOnly,
             MacVNCKeyDisplay, MacVNCKeyListenMode, MacVNCKeyListenAddress,
             MacVNCKeyAllowedClients, MacVNCKeyAllowAllConfirmed,
             MacVNCKeyAutoAllowedClients];
}

void macVNCRegisterDefaults(void)
{
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        MacVNCKeyPort:              @(MacVNCDefaultPort),
        MacVNCKeyViewOnly:          @NO,
        MacVNCKeyDisplay:           @(-1),
        MacVNCKeyPassword:          @"",
        MacVNCKeyListenMode:        MacVNCListenModeLocalhost,
        MacVNCKeyListenAddress:     @"",
        MacVNCKeyAllowedClients:    MacVNCLoopbackIPv4,
        MacVNCKeyAllowAllConfirmed: @NO,
        /* Registered so a fresh install is symmetric with a saved one: the
           loopback entry in allowedClients was put there by US, not typed by the
           user, and the "extra allowed clients" field must not present it as if
           it had been. Without this default, that field showed 127.0.0.1 on
           first run and MacVNCPreferences needed a special case to hide it. */
        MacVNCKeyAutoAllowedClients: MacVNCLoopbackIPv4,
    }];
}
