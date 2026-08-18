#import "MacVNCPermissions.h"

#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void checkStringContains(NSString *value, NSString *needle)
{
    assert(value != nil);
    assert([value rangeOfString:needle].location != NSNotFound);
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSArray<NSNumber *> *required = macVNCRequiredPermissionKinds();
    assert(required.count == 2);
    assert([required containsObject:@(MacVNCPermissionKindScreenRecording)]);
    assert([required containsObject:@(MacVNCPermissionKindAccessibility)]);

    assert([macVNCPermissionDisplayName(MacVNCPermissionKindScreenRecording) isEqualToString:@"Screen Recording"]);
    assert([macVNCPermissionDisplayName(MacVNCPermissionKindAccessibility) isEqualToString:@"Accessibility"]);
    checkStringContains(macVNCPermissionDescription(MacVNCPermissionKindScreenRecording), @"share");
    checkStringContains(macVNCPermissionDescription(MacVNCPermissionKindAccessibility), @"keyboard");
    checkStringContains(macVNCPermissionSettingsURL(MacVNCPermissionKindScreenRecording), @"Privacy_ScreenCapture");
    checkStringContains(macVNCPermissionSettingsURL(MacVNCPermissionKindAccessibility), @"Privacy_Accessibility");
    assert([macVNCPermissionStatusText(MacVNCPermissionStatusGranted) isEqualToString:@"Granted"]);
    assert([macVNCPermissionStatusText(MacVNCPermissionStatusNotGranted) isEqualToString:@"Not granted"]);

    NSDictionary *grantedScreen = macVNCPermissionSnapshot(MacVNCPermissionKindScreenRecording,
                                                          MacVNCPermissionStatusGranted);
    NSDictionary *grantedAccessibility = macVNCPermissionSnapshot(MacVNCPermissionKindAccessibility,
                                                                 MacVNCPermissionStatusGranted);
    NSDictionary *missingAccessibility = macVNCPermissionSnapshot(MacVNCPermissionKindAccessibility,
                                                                 MacVNCPermissionStatusNotGranted);
    NSArray *allGranted = @[grantedScreen, grantedAccessibility];
    NSArray *oneMissing = @[grantedScreen, missingAccessibility];
    assert(macVNCPermissionsAllGrantedFromSnapshots(allGranted));
    assert(!macVNCPermissionsAllGrantedFromSnapshots(oneMissing));
    NSArray *missing = macVNCMissingPermissionsFromSnapshots(oneMissing);
    assert(missing.count == 1);
    assert([missing[0][MacVNCPermissionSnapshotNameKey] isEqualToString:@"Accessibility"]);

    /* Runtime capture-failure flag forces Screen Recording to NotGranted. */
    macVNCResetScreenCaptureFailure();
    assert(!macVNCScreenCaptureFailureNoted());
    macVNCNoteScreenCaptureFailure();
    assert(macVNCScreenCaptureFailureNoted());
    assert(macVNCCheckPermission(MacVNCPermissionKindScreenRecording) == MacVNCPermissionStatusNotGranted);
    macVNCResetScreenCaptureFailure();
    assert(!macVNCScreenCaptureFailureNoted());

    puts("permissions tests passed");
    [pool drain];
    return 0;
}
