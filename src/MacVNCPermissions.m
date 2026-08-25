#import "MacVNCPermissions.h"

#include <stdatomic.h>
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

static _Atomic BOOL gScreenCaptureWorking = NO;

void macVNCNoteScreenCaptureWorking(void)
{
    atomic_store(&gScreenCaptureWorking, YES);
}

BOOL macVNCScreenCaptureWorking(void)
{
    return atomic_load(&gScreenCaptureWorking);
}

MacVNCPermissionStatus macVNCCheckPermission(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            /* A frame that actually arrived is proof; otherwise ask TCC.

               CGPreflightScreenCaptureAccess() is trustworthy in the context
               that matters — a GUI-launched app — and it never prompts, verified
               in the not-determined state. Earlier readings that claimed it
               "always answers NO" were taken from shell-launched runs, where TCC
               attributes the request to the terminal, not to macVNC. Measured
               from a GUI launch: granted -> YES, revoked -> NO, and NO while
               undecided. Trusting it is what lets the chip tell the truth right
               after a relaunch, instead of waiting for a client to connect. */
            /* ONE reader. A second source of truth (a "capture is working" flag)
               used to let the gate and the UI disagree: the panel could show
               "both permissions are active" while the gate refused to start,
               and Run macVNC did nothing forever. */
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

static void macVNCOpenURLString(NSString *urlString)
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url)
        return;
    [[NSWorkspace sharedWorkspace] openURL:url];
}

void macVNCOpenPermissionSettings(MacVNCPermissionKind kind)
{
    /* Plain open, deliberately.

       Do NOT drive System Settings with AppleScript to force a fresh pane:
       controlling another app needs the Apple Events TCC permission, so the
       first attempt raises macOS's own authorization dialog — exactly what this
       app must never do. Verified: kTCCServiceAppleEvents is a separate service
       in the TCC database. */
    macVNCOpenURLString(macVNCPermissionSettingsURL(kind));
}

BOOL macVNCRunningFromApplicationsFolder(void)
{
    /* The "+" flow tells the user to pick macVNC from Applications. If the
       running copy lives somewhere else (Downloads, a mounted .dmg, a build
       directory), they would grant the permission to a different bundle and
       nothing would change for this one. */
    NSString *path = NSBundle.mainBundle.bundlePath;
    if (path.length == 0)
        return NO;
    NSArray<NSString *> *appDirs =
        NSSearchPathForDirectoriesInDomains(NSApplicationDirectory,
                                            NSLocalDomainMask | NSUserDomainMask, YES);
    for (NSString *dir in appDirs) {
        if ([path hasPrefix:[dir stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}
