#import "MacVNCPermissionsPanel.h"
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

@end

@implementation MacVNCPermissionsPanelController

- (id)init
{
    self = [super init];
    if (!self)
        return nil;

    self.action = MacVNCPermissionPanelActionNone;
    self.openedPermissionKinds = [NSMutableSet set];
    self.window = [[[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 480, 246)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO] autorelease];
    self.window.title = @"macVNC Permissions";
    self.window.releasedWhenClosed = NO;

    NSView *content = self.window.contentView;

    NSTextField *title = [NSTextField labelWithString:@"macVNC needs permissions before starting"];
    title.frame = NSMakeRect(24, 202, 432, 22);
    title.font = [NSFont boldSystemFontOfSize:14];
    [content addSubview:title];

    NSTextField *subtitle = [NSTextField labelWithString:@"Click a missing permission to open System Settings. Return here after granting it."];
    subtitle.frame = NSMakeRect(24, 178, 432, 20);
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [content addSubview:subtitle];

    self.screenButton = [self permissionButtonWithFrame:NSMakeRect(24, 132, 432, 34)
                                                   kind:MacVNCPermissionKindScreenRecording];
    self.accessibilityButton = [self permissionButtonWithFrame:NSMakeRect(24, 90, 432, 34)
                                                          kind:MacVNCPermissionKindAccessibility];
    [content addSubview:self.screenButton];
    [content addSubview:self.accessibilityButton];

    self.hintLabel = [NSTextField labelWithString:@""];
    self.hintLabel.frame = NSMakeRect(24, 58, 432, 20);
    self.hintLabel.textColor = NSColor.secondaryLabelColor;
    self.hintLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [content addSubview:self.hintLabel];

    NSButton *quitButton = [NSButton buttonWithTitle:@"Quit" target:self action:@selector(quitClicked:)];
    quitButton.frame = NSMakeRect(24, 18, 90, 28);
    [content addSubview:quitButton];

    NSButton *preferencesButton = [NSButton buttonWithTitle:@"Preferences" target:self action:@selector(preferencesClicked:)];
    preferencesButton.frame = NSMakeRect(232, 18, 110, 28);
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
    NSArray<NSDictionary<NSString *, id> *> *snapshots = macVNCPermissionSnapshots();
    BOOL allGranted = macVNCPermissionsAllGrantedFromSnapshots(snapshots);
    BOOL restartRequired = NO;
    for (NSDictionary<NSString *, id> *snapshot in snapshots) {
        MacVNCPermissionKind kind = (MacVNCPermissionKind)[snapshot[MacVNCPermissionSnapshotKindKey] integerValue];
        MacVNCPermissionStatus status = (MacVNCPermissionStatus)[snapshot[MacVNCPermissionSnapshotStatusKey] integerValue];
        NSButton *button = [self buttonForPermissionKind:kind];
        if (!button)
            continue;
        BOOL granted = status == MacVNCPermissionStatusGranted;
        NSNumber *kindNumber = @(kind);
        if (granted)
            [self.openedPermissionKinds removeObject:kindNumber];
        BOOL pendingRestart = !granted && [self.openedPermissionKinds containsObject:kindNumber];
        if (pendingRestart)
            restartRequired = YES;
        button.title = [NSString stringWithFormat:@"%@  %@ — %@",
                        granted ? @"✓" : (pendingRestart ? @"↻" : @"⚠"),
                        snapshot[MacVNCPermissionSnapshotNameKey],
                        granted ? @"Granted" : (pendingRestart ? @"Restart required" : macVNCPermissionStatusText(status))];
        button.toolTip = pendingRestart
            ? @"macOS may apply this permission only after restarting macVNC. Click to reopen System Settings."
            : @"Click to open the matching macOS Privacy & Security pane.";
        button.enabled = !granted;
    }
    self.restartRequired = restartRequired;
    if (allGranted) {
        self.startButton.title = @"Start macVNC";
        self.startButton.enabled = YES;
        self.hintLabel.stringValue = @"All permissions granted. You can start macVNC now.";
    } else if (restartRequired) {
        self.startButton.title = @"Restart macVNC";
        self.startButton.enabled = YES;
        self.hintLabel.stringValue = @"macOS may apply Screen Recording only after restart.";
    } else {
        self.startButton.title = @"Start macVNC";
        self.startButton.enabled = NO;
        self.hintLabel.stringValue = @"Server is stopped until both permissions are granted.";
    }
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    (void)timer;
    [self refreshPermissions];
}

- (void)permissionClicked:(NSButton *)sender
{
    /* Only open System Settings. Do not call the CGRequest/AX prompt APIs:
       those trigger macOS's own permission dialog, which we don't want here. */
    [self.openedPermissionKinds addObject:@(sender.tag)];
    macVNCOpenPermissionSettings((MacVNCPermissionKind)sender.tag);
    [self refreshPermissions];
}

- (void)startClicked:(id)sender
{
    (void)sender;
    [self refreshPermissions];
    if (!self.startButton.enabled)
        return;
    self.action = self.restartRequired ? MacVNCPermissionPanelActionRestart
                                       : MacVNCPermissionPanelActionStart;
    [NSApp stopModal];
}

- (void)preferencesClicked:(id)sender
{
    (void)sender;
    self.action = MacVNCPermissionPanelActionPreferences;
    [NSApp stopModal];
}

- (void)quitClicked:(id)sender
{
    (void)sender;
    self.action = MacVNCPermissionPanelActionQuit;
    [NSApp stopModal];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    [self refreshPermissions];
}

- (MacVNCPermissionPanelAction)runModal
{
    [self refreshPermissions];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
    self.refreshTimer = [NSTimer timerWithTimeInterval:1.0
                                                target:self
                                              selector:@selector(refreshTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:self.window];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.window orderOut:nil];
    return self.action;
}

@end
