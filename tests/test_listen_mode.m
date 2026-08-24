#import "MacVNCListenMode.h"
#import "MacVNCListenModeNames.h"

#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    assert([MacVNCListenModeLocalhost isEqualToString:@"localhost"]);
    assert([MacVNCListenModeAll isEqualToString:@"all"]);
    assert([MacVNCListenModeCustom isEqualToString:@"custom"]);
    assert([MacVNCListenModeSelected isEqualToString:@"selected"]);

    /* Cross-language single source of truth: ObjC constants must equal the
       shared C macros used by NetworkPolicyResolver. */
    assert([MacVNCListenModeLocalhost isEqualToString:@MACVNC_LISTEN_MODE_LOCALHOST]);
    assert([MacVNCListenModeAll isEqualToString:@MACVNC_LISTEN_MODE_ALL]);
    assert([MacVNCListenModeCustom isEqualToString:@MACVNC_LISTEN_MODE_CUSTOM]);
    assert([MacVNCListenModeSelected isEqualToString:@MACVNC_LISTEN_MODE_SELECTED]);
    assert([macVNCBindHostForMode(MacVNCListenModeLocalhost, nil) isEqualToString:@MACVNC_LOOPBACK_IPV4]);

    assert([macVNCBindHostForMode(MacVNCListenModeLocalhost, nil) isEqualToString:@"127.0.0.1"]);
    assert([macVNCBindHostForMode(MacVNCListenModeLocalhost, @"1.2.3.4") isEqualToString:@"127.0.0.1"]);
    assert([macVNCBindHostForMode(MacVNCListenModeCustom, @"1.2.3.4") isEqualToString:@"1.2.3.4"]);
    assert([macVNCBindHostForMode(MacVNCListenModeSelected, @"100.70.214.41") isEqualToString:@"100.70.214.41"]);
    assert(macVNCBindHostForMode(MacVNCListenModeCustom, @"") == nil);
    assert(macVNCBindHostForMode(MacVNCListenModeSelected, nil) == nil);
    assert(macVNCBindHostForMode(MacVNCListenModeAll, @"1.2.3.4") == nil);
    assert(macVNCBindHostForMode(@"bogus", @"1.2.3.4") == nil);

    puts("listen mode tests passed");
    [pool drain];
    return 0;
}
