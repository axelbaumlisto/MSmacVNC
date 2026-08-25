#import "MacVNCPermissionsPanel.h"
#import "MacVNCPermissionUI.h"
#import "mac.h"
#import "MacVNCPermissions.h"

@interface MacVNCPermissionsPanelController ()

@property (nonatomic, retain) NSWindow *window;
@property (nonatomic, retain) NSButton *screenButton;
@property (nonatomic, retain) NSButton *accessibilityButton;
@property (nonatomic, retain) NSTextField *hintLabel;
@property (nonatomic, retain) NSButton *startButton;
@property (nonatomic, retain) NSTimer *refreshTimer;
@property (nonatomic, retain) NSMutableSet<NSNumber *> *openedPermissionKinds;
@property (nonatomic, assign) BOOL restartRequired;
@property (nonatomic, assign) MacVNCPermissionPanelAction action;
@property (nonatomic, copy)   void (^completion)(MacVNCPermissionPanelAction);

@end

@implementation MacVNCPermissionsPanelController

- (id)init
{
    self = [super init];
    if (!self)
        return nil;

    /* Named layout metrics instead of scattered NSMakeRect literals: the hint
       label's height was hard-coded, so when the "+" instructions grew the text
       was silently truncated — and nothing failed. Sizes are derived here, in
       one place, from the content that has to fit. */
    const CGFloat kMargin      = 24;
    const CGFloat kWidth       = 480;
    const CGFloat kInnerWidth  = kWidth - 2 * kMargin;
    const CGFloat kChipHeight  = 34;
    const CGFloat kHintHeight  = 112;   /* fits the longest instruction text */
    const CGFloat kButtonRow   = 28;
    const CGFloat kHeight      = 336;

    self.action = MacVNCPermissionPanelActionNone;
    self.openedPermissionKinds = [NSMutableSet set];
    self.window = [[[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kWidth, kHeight)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO] autorelease];
    self.window.title = @"macVNC Permissions";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = (id<NSWindowDelegate>)self;

    NSView *content = self.window.contentView;

    NSTextField *title = [NSTextField labelWithString:@"macVNC needs permissions before starting"];
    title.frame = NSMakeRect(kMargin, kHeight - 44, kInnerWidth, 22);
    title.font = [NSFont boldSystemFontOfSize:14];
    [content addSubview:title];

    NSTextField *subtitle = [NSTextField labelWithString:@"Click a permission to open System Settings, then press Run macVNC to apply it."];
    subtitle.frame = NSMakeRect(kMargin, kHeight - 68, kInnerWidth, 20);
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [content addSubview:subtitle];

    self.screenButton = [self permissionButtonWithFrame:NSMakeRect(kMargin, kHeight - 114, kInnerWidth, kChipHeight)
                                                   kind:MacVNCPermissionKindScreenRecording];
    self.accessibilityButton = [self permissionButtonWithFrame:NSMakeRect(kMargin, kHeight - 156, kInnerWidth, kChipHeight)
                                                          kind:MacVNCPermissionKindAccessibility];
    [content addSubview:self.screenButton];
    [content addSubview:self.accessibilityButton];

    /* Wrapping, multi-line: this label carries the step-by-step "+" instructions,
       which are the ONLY way to grant Screen Recording in this app. In a 20pt
       single-line label they were silently truncated — i.e. unreadable exactly
       where they matter most. */
    self.hintLabel = [NSTextField wrappingLabelWithString:@""];
    self.hintLabel.frame = NSMakeRect(kMargin, kMargin + kButtonRow + 12, kInnerWidth, kHintHeight);
    self.hintLabel.selectable = YES;
    self.hintLabel.textColor = NSColor.secondaryLabelColor;
    self.hintLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [content addSubview:self.hintLabel];

    NSButton *quitButton = [NSButton buttonWithTitle:@"Quit" target:self action:@selector(quitClicked:)];
    quitButton.frame = NSMakeRect(kMargin, 18, 90, kButtonRow);
    [content addSubview:quitButton];

    NSButton *preferencesButton = [NSButton buttonWithTitle:@"Preferences" target:self action:@selector(preferencesClicked:)];
    preferencesButton.frame = NSMakeRect(232, 18, 110, kButtonRow);
    [content addSubview:preferencesButton];

    self.startButton = [NSButton buttonWithTitle:@"Start macVNC" target:self action:@selector(startClicked:)];
    self.startButton.frame = NSMakeRect(350, 18, 106, 28);
    self.startButton.keyEquivalent = @"\r";
    [content addSubview:self.startButton];

    [self refreshPermissions];
    return self;
}

- (void)dealloc
{
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    self.window = nil;
    self.screenButton = nil;
    self.accessibilityButton = nil;
    self.hintLabel = nil;
    self.startButton = nil;
    self.openedPermissionKinds = nil;
    self.completion = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (NSButton *)permissionButtonWithFrame:(NSRect)frame kind:(MacVNCPermissionKind)kind
{
    NSButton *button = [NSButton buttonWithTitle:@"" target:self action:@selector(permissionClicked:)];
    button.frame = frame;
    button.tag = kind;
    button.bezelStyle = NSBezelStyleRounded;
    button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    button.toolTip = @"Click to open the matching macOS Privacy & Security pane.";
    return button;
}

- (NSButton *)buttonForPermissionKind:(MacVNCPermissionKind)kind
{
    if (kind == MacVNCPermissionKindScreenRecording)
        return self.screenButton;
    if (kind == MacVNCPermissionKindAccessibility)
        return self.accessibilityButton;
    return nil;
}

- (void)refreshPermissions
{
    /* ONE snapshot per render, rendered by the pure resolver in
       MacVNCPermissionUI. Sampling TCC separately for the chips and for the hint
       is exactly what let them contradict each other, and logic living here
       could not be tested at all. */
    /* Read the server state, never assert it: the panel can be open while the
       server is (re)started from the menu. */
    MacVNCPermissionUIInput input = macVNCSamplePermissionUIInput(vncServerGetPort() > 0);

    MacVNCPermissionUIState *ui = macVNCResolvePermissionUI(input);

    self.screenButton.title = ui.screenChipTitle;
    self.screenButton.enabled = !input.screenActive;
    self.accessibilityButton.title = ui.accessibilityChipTitle;
    self.accessibilityButton.enabled = !input.accessibilityActive;

    NSString *chipTip =
        @"Click to open the matching macOS pane. Already enabled there? "
         "Press Run macVNC — macOS applies it only to a freshly started macVNC.";
    self.screenButton.toolTip = chipTip;
    self.accessibilityButton.toolTip = chipTip;

    self.restartRequired     = ui.buttonRelaunches;
    self.startButton.title   = ui.buttonTitle;
    self.startButton.enabled = ui.buttonEnabled;
    self.hintLabel.stringValue = ui.hint;
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    (void)timer;
    /* Poll only APIs that never prompt. Probing screen capture here would raise
       macOS's own permission dialog whenever Screen Recording is in the
       not-determined state — seen appearing behind this very panel. */
    [self refreshPermissions];
}

- (void)permissionClicked:(NSButton *)sender
{
    /* Our panel is the UI — never raise macOS's own permission dialog here.
       Clicking a chip takes the user straight to the matching Settings pane and
       our chip then reflects the result.

       The "if it is not listed, click +" guidance belongs to the STATE, not to
       this handler: anything assigned to hintLabel here is overwritten by
       -refreshPermissions on the next line and by the 1 s refresh timer. */
    MacVNCPermissionKind kind = (MacVNCPermissionKind)sender.tag;
    [self.openedPermissionKinds addObject:@(kind)];
    macVNCOpenPermissionSettings(kind);
    [self refreshPermissions];
}

- (void)startClicked:(id)sender
{
    (void)sender;
    [self refreshPermissions];

    /* "Run macVNC" means: make it work now.

       If capture is already proven to work in THIS process, just start. If it is
       not, relaunching is the only way to find out honestly — macOS applies a
       freshly granted Screen Recording permission to a new process, and no API
       can tell us in advance whether it did. The relaunch runs via /usr/bin/open
       so TCC attributes capture to macVNC itself. */
    [self finishWithAction:self.restartRequired ? MacVNCPermissionPanelActionRestart
                                                : MacVNCPermissionPanelActionStart];
}

- (void)preferencesClicked:(id)sender
{
    (void)sender;
    [self finishWithAction:MacVNCPermissionPanelActionPreferences];
}

- (void)quitClicked:(id)sender
{
    (void)sender;
    [self finishWithAction:MacVNCPermissionPanelActionQuit];
}

- (void)presentWithCompletion:(void (^)(MacVNCPermissionPanelAction))completion
{
    self.completion = completion;
    [self retain];            /* released in -finishWithAction: */

    [self refreshPermissions];

    /* NSRunLoopCommonModes only: the old code also added the timer to
       NSModalPanelRunLoopMode, which is already part of the common set. */
    self.refreshTimer = [NSTimer timerWithTimeInterval:1.0
                                                target:self
                                              selector:@selector(refreshTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    /* An accessory app (LSUIElement) is not in the activation cycle, so its
       window would otherwise open behind whatever the user is looking at. */
    [NSApp activateIgnoringOtherApps:YES];
}

/* User closed the window: finish with no action, otherwise the completion would
   never run, the controller would stay retained forever, the refresh timer would
   keep polling TCC, and permissionsPanelVisible would stay YES — which makes
   every recovery affordance a no-op. */
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    (void)sender;
    [self finishWithAction:MacVNCPermissionPanelActionNone];
    return NO;   /* -finishWithAction: orders it out */
}

- (void)bringToFront
{
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)finishWithAction:(MacVNCPermissionPanelAction)action
{
    if (!self.completion)
        return;                       /* already finished */

    self.action = action;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.window orderOut:nil];

    void (^done)(MacVNCPermissionPanelAction) = [[self.completion copy] autorelease];
    self.completion = nil;
    done(action);

    /* Release on the next runloop turn, never synchronously: this runs inside a
       button's own action, and AppKit still touches the control (and therefore
       its target) after the action returns — a synchronous release here is the
       classic use-after-free. */
    [self performSelector:@selector(release) withObject:nil afterDelay:0.0];
}

@end
