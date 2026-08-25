#import "AppDelegate.h"
#import "mac.h"
#import "MacVNCPermissions.h"
#import "MacVNCPermissionUI.h"
#import "MacVNCRelauncher.h"
#import "MacVNCStatusText.h"
#import "MacVNCStartFailure.h"
#import "MacVNCPermissionsPanel.h"
#import "MacVNCPreferences.h"
#import "MacVNCDefaultsKeys.h"
#import "MacVNCListenMode.h"
#import "MacVNCLoginItem.h"
#import "MacVNCStartupConfig.h"
#include <string.h>
#include <unistd.h>

static BOOL macVNCAllowsTestPermissionGateBypass(void)
{
    const char *flag = getenv("MACVNC_TEST_SKIP_PERMISSION_GATE");
    if (!flag || strcmp(flag, "1") != 0)
        return NO;
    NSString *bundlePath = NSBundle.mainBundle.bundlePath ?: @"";
    return [bundlePath containsString:@"/build-"] || [bundlePath containsString:@"/build/"];
}


@interface AppDelegate ()

@property (nonatomic, strong) NSStatusItem  *statusItem;
@property (nonatomic, strong) NSMenuItem    *statusMenuItem;
@property (nonatomic, strong) NSMenuItem    *clientsMenuItem;
@property (nonatomic, strong) NSMenuItem    *loginItemMenuItem;
@property (nonatomic, strong) NSMenuItem    *screenPermissionMenuItem;
@property (nonatomic, strong) NSMenuItem    *accessibilityPermissionMenuItem;
@property (nonatomic, strong) NSTimer       *updateTimer;
@property (nonatomic, assign) BOOL           permissionsPanelVisible;
@property (nonatomic, retain) MacVNCPermissionsPanelController *permissionsPanel;
@property (nonatomic, assign) BOOL           relaunchScheduled;

@end


static AppDelegate *gSharedAppDelegate = nil;

/* First delivered frame: Screen Recording is proven to work in this process. */
static void macVNCScreenCaptureWorking_(void)
{
    macVNCNoteScreenCaptureWorking();
    dispatch_async(dispatch_get_main_queue(), ^{
        [gSharedAppDelegate captureBecameWorking];
    });
}

/* The server core asks before touching capture. Answered without prompting:
   CGPreflight never raises a dialog, and this app must never cause one. */
static bool macVNCCaptureAllowed_(void)
{
    return macVNCCheckPermission(MacVNCPermissionKindScreenRecording) ==
           MacVNCPermissionStatusGranted;
}

static void macVNCScreenCaptureFailed(bool likelyPermissionDenial, uint64_t generation)
{
    [gSharedAppDelegate performSelectorOnMainThread:@selector(handleScreenCaptureFailure:)
                                         withObject:@{@"denied": @(likelyPermissionDenial),
                                                      @"generation": @(generation)}
                                      waitUntilDone:NO];
}

@implementation AppDelegate

/* -----------------------------------------------------------------------
 * NSApplicationDelegate
 * ----------------------------------------------------------------------- */

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    gSharedAppDelegate = self;
    macVNCScreenCaptureFailureHandler = macVNCScreenCaptureFailed;
    macVNCScreenCaptureWorkingHandler = macVNCScreenCaptureWorking_;
    macVNCCaptureAllowed = macVNCCaptureAllowed_;
    macVNCRegisterDefaults();
    [self setupStatusBarItem];


    /* Register macVNC in Privacy > Accessibility WITHOUT a system dialog.
       prompt=NO adds the row but shows nothing (the clipshot technique). */
    NSDictionary *axOptions = @{(__bridge id)kAXTrustedCheckOptionPrompt: @NO};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)axOptions);


    [self startServerIfPermitted];

    /* Poll every 2 s to refresh client-count in the menu. */
    /* Common modes, not the default mode only: +scheduledTimer… registers in the
       default mode, which stops running while a menu is being tracked — so the
       rows froze exactly while the user was reading them. */
    self.updateTimer = [NSTimer timerWithTimeInterval:2.0
                                                        target:self
                                                      selector:@selector(updateMenuStatus)
                                                      userInfo:nil
                                                       repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    [self.updateTimer invalidate];
    self.updateTimer = nil;


    vncServerStop();
}

- (void)dealloc
{
    [_updateTimer invalidate];
    [_statusItem release];
    [_statusMenuItem release];
    [_clientsMenuItem release];
    [_loginItemMenuItem release];
    [_permissionsPanel release];
    [_screenPermissionMenuItem release];
    [_accessibilityPermissionMenuItem release];
    [_updateTimer release];
    if (gSharedAppDelegate == self)
        gSharedAppDelegate = nil;
    [super dealloc];
}

/* -----------------------------------------------------------------------
 * Defaults
 * ----------------------------------------------------------------------- */

/* -----------------------------------------------------------------------
 * Status-bar item
 * ----------------------------------------------------------------------- */

- (void)setupStatusBarItem
{
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];

    NSImage *icon = nil;
    if (@available(macOS 11.0, *)) {
        icon = [NSImage imageWithSystemSymbolName:@"desktopcomputer"
                          accessibilityDescription:@"macVNC Server"];
        icon.template = YES;   /* adapts to dark/light menu bar */
    }
    if (icon) {
        self.statusItem.button.image = icon;
    } else {
        self.statusItem.button.title = @"VNC";  /* plain-text fallback */
    }
    self.statusItem.button.toolTip = @"macVNC Server";

    [self buildMenu];
}

- (void)buildMenu
{
    NSMenu *menu = [[[NSMenu alloc] init] autorelease];
    /* We set item.enabled ourselves; with the default YES AppKit would recompute
       enablement from the responder chain and could grey out our rows. */
    menu.autoenablesItems = NO;

    /* Title row */
    NSMenuItem *titleItem = [[[NSMenuItem alloc] initWithTitle:@"macVNC"
                                                        action:nil
                                                 keyEquivalent:@""] autorelease];
    titleItem.enabled = NO;
    titleItem.attributedTitle = [[[NSAttributedString alloc]
        initWithString:@"macVNC"
            attributes:@{NSFontAttributeName:
                             [NSFont boldSystemFontOfSize:[NSFont systemFontSize]]}] autorelease];
    [menu addItem:titleItem];

    /* Status row (port) */
    self.statusMenuItem = [[[NSMenuItem alloc] initWithTitle:@"Starting…"
                                                      action:nil
                                               keyEquivalent:@""] autorelease];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];

    /* Status row (client count) */
    self.clientsMenuItem = [[[NSMenuItem alloc] initWithTitle:@"No clients connected"
                                                       action:nil
                                                keyEquivalent:@""] autorelease];
    self.clientsMenuItem.enabled = NO;
    [menu addItem:self.clientsMenuItem];

    /* Permission rows — the menu-bar equivalent of clipshot's banner.

       An accessory app has no window to host a banner, so the menu is the only
       always-reachable surface. Both rows are driven by the SAME resolver that
       renders the panel, so the two surfaces cannot disagree. They stay hidden
       while everything is granted (clipshot returns null in that case). */
    self.screenPermissionMenuItem =
        [[[NSMenuItem alloc] initWithTitle:@""
                                    action:@selector(openScreenRecordingSettings:)
                             keyEquivalent:@""] autorelease];
    self.screenPermissionMenuItem.target = self;
    [menu addItem:self.screenPermissionMenuItem];

    self.accessibilityPermissionMenuItem =
        [[[NSMenuItem alloc] initWithTitle:@""
                                    action:@selector(openAccessibilitySettings:)
                             keyEquivalent:@""] autorelease];
    self.accessibilityPermissionMenuItem.target = self;
    [menu addItem:self.accessibilityPermissionMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    /* Copy address */
    NSMenuItem *copyItem = [[[NSMenuItem alloc] initWithTitle:@"Copy VNC Address"
                                                       action:@selector(copyVNCAddress:)
                                                keyEquivalent:@"c"] autorelease];
    copyItem.target = self;
    [menu addItem:copyItem];

    /* Preferences */
    /* Permanent recovery affordance: the server can always be (re)started from
       the menu, so no dialog path can leave the app permanently stopped. */
    NSMenuItem *startItem = [[[NSMenuItem alloc] initWithTitle:@"Start Server"
                                                        action:@selector(startServerFromMenu:)
                                                 keyEquivalent:@""] autorelease];
    startItem.target = self;
    [menu addItem:startItem];

    NSMenuItem *permsItem = [[[NSMenuItem alloc] initWithTitle:@"Permissions…"
                                                        action:@selector(showPermissionsPanel)
                                                 keyEquivalent:@""] autorelease];
    permsItem.target = self;
    [menu addItem:permsItem];

    NSMenuItem *prefsItem = [[[NSMenuItem alloc] initWithTitle:@"Preferences…"
                                                        action:@selector(openPreferences:)
                                                 keyEquivalent:@","] autorelease];
    prefsItem.target = self;
    [menu addItem:prefsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    /* Start at Login */
    self.loginItemMenuItem = [[[NSMenuItem alloc] initWithTitle:@"Start at Login"
                                                         action:@selector(toggleLoginItem:)
                                                  keyEquivalent:@""] autorelease];
    self.loginItemMenuItem.target = self;
    self.loginItemMenuItem.state  = [MacVNCLoginItem isEnabled]
                                        ? NSControlStateValueOn
                                        : NSControlStateValueOff;
    [menu addItem:self.loginItemMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    /* Quit */
    NSMenuItem *quitItem = [[[NSMenuItem alloc] initWithTitle:@"Quit macVNC"
                                                       action:@selector(terminate:)
                                                keyEquivalent:@"q"] autorelease];
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

/* -----------------------------------------------------------------------
 * Startup permissions
 * ----------------------------------------------------------------------- */

- (void)relaunchApplication
{
    [self scheduleRelaunchHelper];

    /* Only quit if a successor was actually started. If the spawn failed there
       would be no new process and no old one either — and this is an accessory
       app with no Dock icon, so the user would be left with nothing on screen
       and no way back. Keep running and re-present the gate instead. */
    if (!self.relaunchScheduled) {
        [self showPermissionsPanel];
        return;
    }

    /* Quit on the NEXT runloop turn, so AppKit finishes delivering the action
       that got us here before the process goes away. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

- (void)scheduleRelaunchHelper
{
    if (self.relaunchScheduled)
        return;

    self.relaunchScheduled =
        [MacVNCRelauncher relaunchClosingListeners:^{ vncServerCloseListeners(); }];

    if (!self.relaunchScheduled) {
        /* No successor, and the listeners are already gone: stop the server so
           its state matches reality instead of advertising a dead port. */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            vncServerStop();
        });
    }
}

- (void)startServerIfPermitted
{
    if (macVNCAllowsTestPermissionGateBypass()) {
        [self startServer];
        return;
    }

    /* Both permissions must be readable WITHOUT prompting, and both must be in
       place before the server opens its port.

       Screen Recording is read with CGPreflightScreenCaptureAccess(), which
       never prompts and — measured from a GUI launch — answers YES when granted
       and NO otherwise. Never probe with SCShareableContent/SCStream here: in
       the not-determined state (fresh install, or right after tccutil reset)
       those raise macOS's own "macVNC wants to record this screen" dialog.

       Gating on Accessibility alone was not enough: the server would start with
       Screen Recording still undecided, and the first client to connect would
       reach the capture path and trigger exactly that dialog — on the most
       common fresh-install route, where the user grants Accessibility and has
       not yet added macVNC with "+". */
    /* One snapshot, one decision, and the SAME decision the UI renders: the
       resolver already answers "must the gate be shown?", and having production
       re-derive it by hand is how the gate and the panel drifted apart before.
       shouldShowPanel was previously asserted only in tests — now it is the
       actual control flow. */
    MacVNCPermissionUIInput input = macVNCSamplePermissionUIInput(vncServerGetPort() > 0);
    MacVNCPermissionUIState *ui = macVNCResolvePermissionUI(input);

    if (ui.shouldStartServer)
        [self startServer];
    else if (ui.shouldShowPanel)
        [self showPermissionsPanel];
}

- (void)openScreenRecordingSettings:(id)sender
{
    (void)sender;
    macVNCOpenPermissionSettings(MacVNCPermissionKindScreenRecording);
}

- (void)openAccessibilitySettings:(id)sender
{
    (void)sender;
    macVNCOpenPermissionSettings(MacVNCPermissionKindAccessibility);
}

- (void)startServerFromMenu:(id)sender
{
    if (vncServerGetPort() > 0)
        return; /* already running */
    [self startServerIfPermitted];
}

- (void)captureBecameWorking
{
    /* Proof arrived: Screen Recording really is granted to this process. The
       chip flips to Granted on the next refresh; update the menu right away so
       it cannot keep claiming a permission problem while frames are flowing. */
    [self updateMenuStatus];
}

- (void)showPermissionsPanel
{
    if (self.permissionsPanel) {
        /* Already up — re-front it instead of refusing. An accessory app has no
           Dock icon, so a buried panel would otherwise be unreachable. */
        [self.permissionsPanel bringToFront];
        return;
    }
    self.permissionsPanelVisible = YES;
    /* Let the single renderer own the text: writing a status string by hand here
       claimed "permissions required" even when the server was running, and the
       2 s timer silently corrected it moments later. */
    [self updateMenuStatus];

    MacVNCPermissionsPanelController *controller =
        [[[MacVNCPermissionsPanelController alloc] init] autorelease];
    self.permissionsPanel = controller;
    [controller presentWithCompletion:^(MacVNCPermissionPanelAction action) {
        self.permissionsPanelVisible = NO;
        self.permissionsPanel = nil;

        switch (action) {
            case MacVNCPermissionPanelActionStart:
                /* Both permissions are read without prompting, so this is a
                   straight decision — and it must not call back into
                   -showPermissionsPanel from inside this handler, which used to
                   nest the gate inside itself. */
                [self startServerIfPermitted];
                break;
            case MacVNCPermissionPanelActionRestart:
                [self relaunchApplication];
                break;
            case MacVNCPermissionPanelActionPreferences:
                [self openPreferences:nil];
                /* Re-open on the next run loop turn, never from inside the
                   completion of the panel we are dismissing. */
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showPermissionsPanel];
                });
                break;
            case MacVNCPermissionPanelActionQuit:
                [NSApp terminate:nil];
                break;
            case MacVNCPermissionPanelActionNone:
                break;
        }
    }];
}

- (void)handleScreenCaptureFailure:(NSDictionary *)info
{
    /* Ignore a notification raised by a server run that is no longer current.
       With one capturer per display, several failures can be queued; the first
       one stops the server and opens a modal, and by the time the rest are
       delivered the user may already have started a new run — which must not be
       killed by a stale report. */
    uint64_t reportedGeneration = [info[@"generation"] unsignedLongLongValue];
    if (reportedGeneration != vncServerCurrentGeneration())
        return;

    /* Stop OFF the main thread: vncServerStop() joins client threads and waits
       for in-flight ScreenCaptureKit work, which can be pending behind a system
       permission prompt. Blocking the main thread here would freeze the menu bar
       — including the very buttons the user needs to recover. */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        vncServerStop();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentCaptureFailure:info];
        });
    });
}

- (void)presentCaptureFailure:(NSDictionary *)info
{
    if ([info[@"denied"] boolValue]) {
        /* A real TCC denial at runtime: the permission was revoked while the
           server ran. CGPreflight already reports the truth, so nothing to
           latch — just resurface the gate. */
        [self updateMenuStatus];
        [self showPermissionsPanel];
        return;
    }

    /* Non-permission capture failure (e.g. a display was unplugged or the
       stream stopped). Nothing to record: permission status is read from
       CGPreflight on demand, so a transient failure cannot poison it. */
    [self updateMenuStatus];
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText     = @"Screen capture stopped";
    alert.informativeText = @"macVNC stopped capturing (for example a display was "
                             "disconnected or the capture stream ended). The server "
                             "has been stopped; start it again from the menu.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

- (void)showStartAlert:(NSString *)title body:(NSString *)body style:(NSAlertStyle)style
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText     = title;
    alert.informativeText = body ?: @"";
    alert.alertStyle      = style;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)startServer
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        MacVNCStartupConfig *startup = [MacVNCStartupConfig
            configWithDefaults:defaults
                   environment:NSProcessInfo.processInfo.environment];
        NSString *configurationError = startup.error;

        MacVNCServerConfig serverConfig;
        BOOL ok = [startup fillServerConfig:&serverConfig] &&
                  vncServerStart(&serverConfig);

        dispatch_async(dispatch_get_main_queue(), ^{
            MacVNCStartOutcome outcome;
            outcome.started               = ok;
            outcome.hasConfigurationError = configurationError != nil;
            outcome.permissionsGranted    =
                macVNCResolvePermissionUI(macVNCSamplePermissionUIInput(NO))
                    .shouldShowPermissionRows ? NO : YES;

            switch (macVNCResolveStartAdvice(outcome)) {
            case MacVNCStartAdviceNone:
                [self updateMenuStatus];
                break;
            case MacVNCStartAdviceConfiguration:
                self.statusMenuItem.title = @"Failed to start";
                [self showStartAlert:@"macVNC could not start"
                                body:configurationError
                               style:NSAlertStyleCritical];
                break;
            case MacVNCStartAdvicePortInUse:
                [self updateMenuStatus];
                [self showStartAlert:macVNCStartAdviceTitle(MacVNCStartAdvicePortInUse)
                                body:macVNCStartAdviceBody(MacVNCStartAdvicePortInUse)
                               style:NSAlertStyleWarning];
                break;
            }
        });
    });
}

/* -----------------------------------------------------------------------
 * Menu actions
 * ----------------------------------------------------------------------- */

- (void)updateMenuStatus
{
    int port = vncServerGetPort();

    /* ONE snapshot for the whole render: the status line used to sample TCC
       separately from the permission rows — four reads, two snapshots, one
       frame — which is how a line could contradict the rows beneath it. */
    MacVNCPermissionUIInput input = macVNCSamplePermissionUIInput(port > 0);
    MacVNCPermissionUIState *ui = macVNCResolvePermissionUI(input);

    char activeBind[MACVNC_LISTEN_ADDRESS_MAX] = {0};
    NSString *bind = nil;
    if (port > 0 && vncServerCopyActiveBindAddress(activeBind, sizeof(activeBind)) && activeBind[0])
        bind = [NSString stringWithUTF8String:activeBind];

    MacVNCStatusInput status;
    status.port               = port;
    status.clientCount        = vncConnectedClients;
    status.permissionsMissing = ui.shouldShowPermissionRows;
    status.allowsEveryone     = port > 0 && vncServerActivePolicyAllowsEveryone();

    self.statusMenuItem.title  = macVNCStatusLine(status, bind);
    self.clientsMenuItem.title = macVNCClientsLine(status);

    /* Permission rows from the same snapshot; hidden when both are active,
       exactly like clipshot's banner returning null. */
    self.screenPermissionMenuItem.hidden = !ui.shouldShowPermissionRows;
    self.accessibilityPermissionMenuItem.hidden = !ui.shouldShowPermissionRows;
    self.screenPermissionMenuItem.title = ui.screenChipTitle;
    self.accessibilityPermissionMenuItem.title = ui.accessibilityChipTitle;
}

- (void)copyVNCAddress:(id)sender
{
    int port = vncServerGetPort();
    if (port <= 0) return;

    /* Same rule as the status line: use the address the server is actually
       bound to, so the copied URL matches reality (e.g. under MACVNC_LISTEN). */
    char activeBind[MACVNC_LISTEN_ADDRESS_MAX] = {0};
    NSString *hostname = nil;
    if (vncServerCopyActiveBindAddress(activeBind, sizeof(activeBind)) && activeBind[0])
        hostname = [NSString stringWithUTF8String:activeBind];
    if (hostname.length == 0)
        hostname = [NSHost currentHost].localizedName;
    NSString *address  = [NSString stringWithFormat:@"vnc://%@:%d", hostname, port];

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:address forType:NSPasteboardTypeString];
}

- (void)openPreferences:(id)sender
{
    MacVNCPreferencesController *prefs = [[MacVNCPreferencesController alloc] init];
    [prefs runModal];
    [prefs release];
}

/* -----------------------------------------------------------------------
 * Login-item (autostart) support
 * ----------------------------------------------------------------------- */

- (void)toggleLoginItem:(id)sender
{
    BOOL wasEnabled = [MacVNCLoginItem isEnabled];
    [MacVNCLoginItem setEnabled:!wasEnabled];
    self.loginItemMenuItem.state = (!wasEnabled)
                                    ? NSControlStateValueOn
                                    : NSControlStateValueOff;
}

@end
