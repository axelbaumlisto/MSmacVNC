#import "MacVNCListenMode.h"

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

    assert([macVNCBindHostForMode(MacVNCListenModeLocalhost, nil) isEqualToString:@"127.0.0.1"]);
    assert([macVNCBindHostForMode(MacVNCListenModeLocalhost, @"1.2.3.4") isEqualToString:@"127.0.0.1"]);
    assert([macVNCBindHostForMode(MacVNCListenModeCustom, @"1.2.3.4") isEqualToString:@"1.2.3.4"]);
    assert([macVNCBindHostForMode(MacVNCListenModeSelected, @"100.101.102.103") isEqualToString:@"100.101.102.103"]);
    assert(macVNCBindHostForMode(MacVNCListenModeCustom, @"") == nil);
    assert(macVNCBindHostForMode(MacVNCListenModeSelected, nil) == nil);
    assert(macVNCBindHostForMode(MacVNCListenModeAll, @"1.2.3.4") == nil);
    assert(macVNCBindHostForMode(@"bogus", @"1.2.3.4") == nil);

    puts("listen mode tests passed");
    [pool drain];
    return 0;
}
