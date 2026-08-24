#import "MacVNCListenMode.h"

NSString * const MacVNCListenModeLocalhost = @"localhost";
NSString * const MacVNCListenModeAll       = @"all";
NSString * const MacVNCListenModeCustom    = @"custom";
NSString * const MacVNCListenModeSelected  = @"selected";

NSString *macVNCBindHostForMode(NSString *mode, NSString *address)
{
    if ([mode isEqualToString:MacVNCListenModeLocalhost])
        return @"127.0.0.1";
    if ([mode isEqualToString:MacVNCListenModeCustom] ||
        [mode isEqualToString:MacVNCListenModeSelected])
        return address.length > 0 ? address : nil;
    return nil; /* "all" or unknown -> no single host */
}
