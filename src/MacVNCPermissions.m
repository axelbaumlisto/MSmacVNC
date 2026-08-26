#import "MacVNCPermissions.h"

#include <stdatomic.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>

/* The ONE production call site of CGPreflightScreenCaptureAccess(). Overridable
   only from tests; see the header. */
static bool macVNCDefaultScreenRecordingProbe(void)
{
    return CGPreflightScreenCaptureAccess();
}

MacVNCPermissionProbeFn macVNCPermissionScreenRecordingProbe =
    macVNCDefaultScreenRecordingProbe;

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

MacVNCPermissionStatus macVNCCheckPermission(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            /* CGPreflightScreenCaptureAccess() is trustworthy in the context
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
            {
                bool granted = macVNCPermissionScreenRecordingProbe
                                   ? macVNCPermissionScreenRecordingProbe()
                                   : macVNCDefaultScreenRecordingProbe();
                return granted ? MacVNCPermissionStatusGranted
                               : MacVNCPermissionStatusNotGranted;
            }
        case MacVNCPermissionKindAccessibility:
            return AXIsProcessTrusted()
                ? MacVNCPermissionStatusGranted
                : MacVNCPermissionStatusNotGranted;
    }
    return MacVNCPermissionStatusUnknown;
}

/* Deep link to the relevant System Settings pane. Internal: only
   macVNCOpenPermissionSettings needs it, and publishing it invited callers to
   build their own settings flow. */
static NSString *macVNCPermissionSettingsURL(MacVNCPermissionKind kind)
{
    switch (kind) {
        case MacVNCPermissionKindScreenRecording:
            return @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";
        case MacVNCPermissionKindAccessibility:
            return @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    }
    return @"x-apple.systempreferences:com.apple.preference.security";
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
