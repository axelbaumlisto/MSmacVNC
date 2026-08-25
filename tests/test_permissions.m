#import "MacVNCPermissions.h"
#import <CoreGraphics/CoreGraphics.h>

#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    /* The two names the panel and the menu rows display. */
    assert([macVNCPermissionDisplayName(MacVNCPermissionKindScreenRecording)
               isEqualToString:@"Screen Recording"]);
    assert([macVNCPermissionDisplayName(MacVNCPermissionKindAccessibility)
               isEqualToString:@"Accessibility"]);

    /* Screen Recording has exactly ONE reader: CGPreflightScreenCaptureAccess().
       A second source of truth (a runtime "capture failed" latch) used to let
       the gate and the UI disagree, so it was removed rather than kept in sync. */
    assert(macVNCCheckPermission(MacVNCPermissionKindScreenRecording) ==
           (CGPreflightScreenCaptureAccess() ? MacVNCPermissionStatusGranted
                                             : MacVNCPermissionStatusNotGranted));

    puts("permissions tests passed");
    [pool drain];
    return 0;
}
