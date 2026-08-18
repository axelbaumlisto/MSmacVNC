#import "MacVNCPermissions.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>

NSString * const MacVNCPermissionSnapshotKindKey = @"kind";
NSString * const MacVNCPermissionSnapshotNameKey = @"name";
NSString * const MacVNCPermissionSnapshotDescriptionKey = @"description";
NSString * const MacVNCPermissionSnapshotStatusKey = @"status";
NSString * const MacVNCPermissionSnapshotSettingsURLKey = @"settingsURL";

NSArray<NSNumber *> *macVNCRequiredPermissionKinds(void)
{
    return @[@(MacVNCPermissionKindScreenRecording),
             @(MacVNCPermissionKindAccessibility)];
}

NSString *macVNCPermissionDisplayName(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            return @"Screen Recording";
        case MacVNCPermissionKindAccessibility:
            return @"Accessibility";
    }
    return @"Unknown permission";
}

NSString *macVNCPermissionDescription(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            return @"Required to share your display over VNC";
        case MacVNCPermissionKindAccessibility:
            return @"Required for remote keyboard and mouse control";
    }
    return @"Required by macVNC";
}

NSString *macVNCPermissionSettingsURL(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            return @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
        case MacVNCPermissionKindAccessibility:
            return @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    }
    return @"x-apple.systempreferences:com.apple.preference.security?Privacy";
}

NSString *macVNCPermissionStatusText(MacVNCPermissionStatus status)
{
    switch (status) {
        case MacVNCPermissionStatusGranted:
            return @"Granted";
        case MacVNCPermissionStatusNotGranted:
            return @"Not granted";
        case MacVNCPermissionStatusUnknown:
            return @"Unknown";
    }
    return @"Unknown";
}

MacVNCPermissionStatus macVNCCheckPermission(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            return CGPreflightScreenCaptureAccess()
                ? MacVNCPermissionStatusGranted
                : MacVNCPermissionStatusNotGranted;
        case MacVNCPermissionKindAccessibility:
            return AXIsProcessTrusted()
                ? MacVNCPermissionStatusGranted
                : MacVNCPermissionStatusNotGranted;
    }
    return MacVNCPermissionStatusUnknown;
}

NSDictionary<NSString *, id> *macVNCPermissionSnapshot(MacVNCPermissionKind kind,
                                                       MacVNCPermissionStatus status)
{
    return @{
        MacVNCPermissionSnapshotKindKey: @(kind),
        MacVNCPermissionSnapshotNameKey: macVNCPermissionDisplayName(kind),
        MacVNCPermissionSnapshotDescriptionKey: macVNCPermissionDescription(kind),
        MacVNCPermissionSnapshotStatusKey: @(status),
        MacVNCPermissionSnapshotSettingsURLKey: macVNCPermissionSettingsURL(kind),
    };
}

NSArray<NSDictionary<NSString *, id> *> *macVNCPermissionSnapshots(void)
{
    NSMutableArray<NSDictionary<NSString *, id> *> *snapshots = [NSMutableArray array];
    for (NSNumber *kindNumber in macVNCRequiredPermissionKinds()) {
        MacVNCPermissionKind kind = (MacVNCPermissionKind)kindNumber.integerValue;
        [snapshots addObject:macVNCPermissionSnapshot(kind, macVNCCheckPermission(kind))];
    }
    return snapshots;
}

NSArray<NSDictionary<NSString *, id> *> *macVNCMissingPermissionsFromSnapshots(NSArray<NSDictionary<NSString *, id> *> *snapshots)
{
    NSMutableArray<NSDictionary<NSString *, id> *> *missing = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *snapshot in snapshots) {
        MacVNCPermissionStatus status = (MacVNCPermissionStatus)[snapshot[MacVNCPermissionSnapshotStatusKey] integerValue];
        if (status != MacVNCPermissionStatusGranted)
            [missing addObject:snapshot];
    }
    return missing;
}

NSArray<NSDictionary<NSString *, id> *> *macVNCMissingPermissions(void)
{
    return macVNCMissingPermissionsFromSnapshots(macVNCPermissionSnapshots());
}

BOOL macVNCPermissionsAllGrantedFromSnapshots(NSArray<NSDictionary<NSString *, id> *> *snapshots)
{
    return macVNCMissingPermissionsFromSnapshots(snapshots).count == 0;
}

BOOL macVNCPermissionsAllGranted(void)
{
    return macVNCPermissionsAllGrantedFromSnapshots(macVNCPermissionSnapshots());
}

void macVNCRequestPermissionPrompt(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            CGRequestScreenCaptureAccess();
            break;
        case MacVNCPermissionKindAccessibility: {
            NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
            break;
        }
    }
}

static void macVNCOpenURLString(NSString *urlString)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url)
        return;
    [[NSWorkspace sharedWorkspace] openURL:url];
}

void macVNCOpenPermissionSettings(MacVNCPermissionKind kind)
{
    macVNCOpenURLString(macVNCPermissionSettingsURL(kind));
}

void macVNCRequestPermissionAndOpenSettings(MacVNCPermissionKind kind)
{
    macVNCRequestPermissionPrompt(kind);
    macVNCOpenPermissionSettings(kind);
}
