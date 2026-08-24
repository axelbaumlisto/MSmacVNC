#import "MacVNCListenMode.h"
#import "MacVNCListenModeNames.h"

/* Helper: build an NSString literal from a C string macro. */
#define MACVNC_NSSTR2(x) @x
#define MACVNC_NSSTR(x)  MACVNC_NSSTR2(x)

NSString * const MacVNCListenModeLocalhost = MACVNC_NSSTR(MACVNC_LISTEN_MODE_LOCALHOST);
NSString * const MacVNCListenModeAll       = MACVNC_NSSTR(MACVNC_LISTEN_MODE_ALL);
NSString * const MacVNCListenModeCustom    = MACVNC_NSSTR(MACVNC_LISTEN_MODE_CUSTOM);
NSString * const MacVNCListenModeSelected  = MACVNC_NSSTR(MACVNC_LISTEN_MODE_SELECTED);

NSString *macVNCBindHostForMode(NSString *mode, NSString *address)
{
    if ([mode isEqualToString:MacVNCListenModeLocalhost])
        return MACVNC_NSSTR(MACVNC_LOOPBACK_IPV4);
    if ([mode isEqualToString:MacVNCListenModeCustom] ||
        [mode isEqualToString:MacVNCListenModeSelected])
        return address.length > 0 ? address : nil;
    return nil; /* "all" or unknown -> no single host */
}
