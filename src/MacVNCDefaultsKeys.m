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
    }];
}
