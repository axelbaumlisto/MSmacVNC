#import "MacVNCPermissions.h"
#import <CoreGraphics/CoreGraphics.h>

#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bool testProbe(void);

static bool testProbeImpl = false;
static bool testProbe(void) { return testProbeImpl; }

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    /* The two names the panel and the menu rows display. */
    assert([macVNCPermissionDisplayName(MacVNCPermissionKindScreenRecording)
               isEqualToString:@"Screen Recording"]);
    assert([macVNCPermissionDisplayName(MacVNCPermissionKindAccessibility)
               isEqualToString:@"Accessibility"]);

    /* Screen Recording has exactly ONE reader: CGPreflightScreenCaptureAccess().
       The OLD assertion compared the production reader against that very API on
       the live host - a tautology that stayed green whichever way the mapping
       was gutted, as long as the gutting matched the machine. Now the mapping
       is pinned deterministically through the test probe: both branches, plus
       no-latch (re-ask every call) and never-Unknown. Production stays at one
       call site; the probe defaults to it and is reset after use. */
    macVNCPermissionScreenRecordingProbe = testProbe;
    bool *answer = &testProbeImpl;

    *answer = false;
    assert(macVNCCheckPermission(MacVNCPermissionKindScreenRecording) ==
           MacVNCPermissionStatusNotGranted);
    *answer = true;
    assert(macVNCCheckPermission(MacVNCPermissionKindScreenRecording) ==
           MacVNCPermissionStatusGranted);
    /* Re-read every time, never cached: revocation mid-run must be seen. */
    *answer = false;
    assert(macVNCCheckPermission(MacVNCPermissionKindScreenRecording) ==
           MacVNCPermissionStatusNotGranted);
    /* Never Unknown for this kind: "unknown" would park the panel forever. */
    assert(macVNCCheckPermission(MacVNCPermissionKindScreenRecording) !=
           MacVNCPermissionStatusUnknown);

    macVNCPermissionScreenRecordingProbe = NULL;
    /* NULL falls back to the real probe, which answers Granted or NotGranted -
       never crashes, never Unknown. */
    MacVNCPermissionStatus fallback =
        macVNCCheckPermission(MacVNCPermissionKindScreenRecording);
    assert(fallback == MacVNCPermissionStatusGranted ||
           fallback == MacVNCPermissionStatusNotGranted);

    puts("permissions tests passed");
    [pool drain];
    return 0;
}
