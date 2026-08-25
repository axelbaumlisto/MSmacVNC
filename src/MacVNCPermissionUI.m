#import "MacVNCPermissionUI.h"

@implementation MacVNCPermissionUIState

- (void)dealloc
{
    [_screenChipTitle release];
    [_accessibilityChipTitle release];
    [_hint release];
    [_buttonTitle release];
    [super dealloc];
}

@end

/* "Active"/"Not active yet" rather than "Granted"/"Not granted": the status
   describes THIS process, not the checkbox in System Settings. Saying "Not
   granted" made the panel look like it was demanding a permission the user had
   just given. */
static NSString *macVNCChipTitle(NSString *name, BOOL active)
{
    return [NSString stringWithFormat:@"%@  %@ — %@",
            active ? @"✓" : @"⚠", name, active ? @"Active" : @"Not active yet"];
}

MacVNCPermissionUIInput macVNCSamplePermissionUIInput(BOOL serverRunning)
{
    MacVNCPermissionUIInput input;
    input.screenActive =
        macVNCCheckPermission(MacVNCPermissionKindScreenRecording) == MacVNCPermissionStatusGranted;
    input.accessibilityActive =
        macVNCCheckPermission(MacVNCPermissionKindAccessibility) == MacVNCPermissionStatusGranted;
    input.serverRunning        = serverRunning;
    input.inApplicationsFolder = macVNCRunningFromApplicationsFolder();
    return input;
}

MacVNCPermissionUIState *macVNCResolvePermissionUI(MacVNCPermissionUIInput input)
{
    MacVNCPermissionUIState *state = [[[MacVNCPermissionUIState alloc] init] autorelease];

    state.screenChipTitle =
        macVNCChipTitle(macVNCPermissionDisplayName(MacVNCPermissionKindScreenRecording),
                        input.screenActive);
    state.accessibilityChipTitle =
        macVNCChipTitle(macVNCPermissionDisplayName(MacVNCPermissionKindAccessibility),
                        input.accessibilityActive);

    BOOL bothActive = input.screenActive && input.accessibilityActive;

    /* One button, always enabled: no state may be a dead end. */
    state.buttonTitle      = @"Run macVNC";
    state.buttonEnabled    = YES;
    state.buttonRelaunches = !bothActive;

    /* Never show the gate over a running server. */
    state.shouldShowPanel = !input.serverRunning && !bothActive;
    state.shouldShowPermissionRows = !bothActive;
    state.shouldStartServer = bothActive && !input.serverRunning;

    /* macVNC never triggers macOS's own permission dialog, so nothing will ever
       add its row to the Screen Recording list automatically — the user has to
       add it with "+". That makes these steps the only way in, and they must be
       spelled out rather than hinted at. */
    NSString *screenSteps =
        input.inApplicationsFolder
            ? @"Screen Recording: click the chip above, then in System Settings press + , "
               "pick macVNC in Applications and switch it on."
            : @"Screen Recording: move macVNC to your Applications folder first \u2014 the "
               "permission is tied to the copy you add, and adding it from anywhere "
               "else grants it to the wrong one. Then click the chip above and add it "
               "with + .";
    NSString *accessibilitySteps =
        @"Accessibility: click the chip above and switch macVNC on — it is already "
         "listed there.";
    NSString *applyTail =
        @" Then press Run macVNC: macOS grants these permissions only to a freshly "
         "started macVNC, so the app has to restart to pick them up.";

    if (bothActive)
        state.hint = @"Both permissions are active. Press Run macVNC to start the server.";
    else if (!input.screenActive && !input.accessibilityActive)
        state.hint = [NSString stringWithFormat:@"%@ %@%@",
                      screenSteps, accessibilitySteps, applyTail];
    else if (!input.screenActive)
        state.hint = [screenSteps stringByAppendingString:applyTail];
    else
        state.hint = [accessibilitySteps stringByAppendingString:applyTail];

    return state;
}
