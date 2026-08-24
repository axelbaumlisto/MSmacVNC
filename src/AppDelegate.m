#import "AppDelegate.h"
#import "mac.h"
#import "CaptureRate.h"
#import "NetworkPolicyResolver.h"
#import "MacVNCPermissions.h"
#import "MacVNCPermissionsPanel.h"
#import "MacVNCPassword.h"
#import "MacVNCPreferences.h"
#import "MacVNCDefaultsKeys.h"
#import "MacVNCListenMode.h"

#import <ServiceManagement/ServiceManagement.h>
#include <string.h>
#include <unistd.h>

/* Local aliases for the shared defaults keys / identifiers. */
#define kDefaultPort         MacVNCDefaultPort
#define kKeyPort             MacVNCKeyPort
#define kKeyPassword         MacVNCKeyPassword
#define kKeyViewOnly         MacVNCKeyViewOnly
#define kKeyDisplay          MacVNCKeyDisplay
#define kKeyListenMode       MacVNCKeyListenMode
#define kKeyListenAddress    MacVNCKeyListenAddress
#define kKeyAllowedClients   MacVNCKeyAllowedClients
#define kKeyAllowAllConfirmed MacVNCKeyAllowAllConfirmed
#define kBundleID            MacVNCBundleID

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
@property (nonatomic, strong) NSTimer       *updateTimer;
@property (nonatomic, assign) BOOL           permissionsPanelVisible;

@end


static AppDelegate *gSharedAppDelegate = nil;

static void macVNCScreenCaptureFailed(void)
{
    [gSharedAppDelegate performSelectorOnMainThread:@selector(handleScreenCaptureFailure)
                                         withObject:nil
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
    [self registerDefaults];
    [self setupStatusBarItem];
    [self startServerIfPermitted];

    /* Poll every 2 s to refresh client-count in the menu. */
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                        target:self
                                                      selector:@selector(updateMenuStatus)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    [self.updateTimer invalidate];
    self.updateTimer = nil;
    vncServerStop();
}

/* -----------------------------------------------------------------------
 * Defaults
 * ----------------------------------------------------------------------- */

- (void)registerDefaults
{
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kKeyPort:     @(kDefaultPort),
        kKeyViewOnly: @NO,
        kKeyDisplay:        @(-1),
        kKeyPassword:       @"",
        kKeyListenMode:        MacVNCListenModeLocalhost,
        kKeyListenAddress:     @"",
        kKeyAllowedClients:    @"127.0.0.1",
        kKeyAllowAllConfirmed: @NO,
    }];
}

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
    NSMenu *menu = [[NSMenu alloc] init];

    /* Title row */
    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:@"macVNC"
                                                       action:nil
                                                keyEquivalent:@""];
    titleItem.enabled = NO;
    titleItem.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"macVNC"
            attributes:@{NSFontAttributeName:
                             [NSFont boldSystemFontOfSize:[NSFont systemFontSize]]}];
    [menu addItem:titleItem];

    /* Status row (port) */
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Starting…"
                                                     action:nil
                                              keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];

    /* Status row (client count) */
    self.clientsMenuItem = [[NSMenuItem alloc] initWithTitle:@"No clients connected"
                                                      action:nil
                                               keyEquivalent:@""];
    self.clientsMenuItem.enabled = NO;
    [menu addItem:self.clientsMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    /* Copy address */
    NSMenuItem *copyItem = [[NSMenuItem alloc] initWithTitle:@"Copy VNC Address"
                                                      action:@selector(copyVNCAddress:)
                                               keyEquivalent:@"c"];
    copyItem.target = self;
    [menu addItem:copyItem];

    /* Preferences */
    NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Preferences…"
                                                       action:@selector(openPreferences:)
                                                keyEquivalent:@","];
    prefsItem.target = self;
    [menu addItem:prefsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    /* Start at Login */
    self.loginItemMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start at Login"
                                                        action:@selector(toggleLoginItem:)
                                                 keyEquivalent:@""];
    self.loginItemMenuItem.target = self;
    self.loginItemMenuItem.state  = [self isLoginItemEnabled]
                                        ? NSControlStateValueOn
                                        : NSControlStateValueOff;
    [menu addItem:self.loginItemMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    /* Quit */
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit macVNC"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

/* -----------------------------------------------------------------------
 * Startup permissions
 * ----------------------------------------------------------------------- */

- (void)relaunchApplication
{
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (bundlePath.length > 0) {
        /* Wait for THIS process to exit, then open exactly one new instance.
           Using a pid wait avoids ending up with two running macVNC processes. */
        pid_t pid = getpid();
        NSString *script = [NSString stringWithFormat:
            @"while kill -0 %d 2>/dev/null; do sleep 0.2; done; /usr/bin/open %@",
            pid, [self shellQuote:bundlePath]];
        NSTask *task = [[[NSTask alloc] init] autorelease];
        task.launchPath = @"/bin/sh";
        task.arguments = @[@"-c", script];
        @try {
            [task launch];
        } @catch (NSException *exception) {
            NSLog(@"Could not relaunch macVNC: %@", exception.reason);
        }
    }
    [NSApp terminate:nil];
}

- (NSString *)shellQuote:(NSString *)path
{
    return [NSString stringWithFormat:@"'%@'",
            [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (void)startServerIfPermitted
{
    if (macVNCPermissionsAllGranted() || macVNCAllowsTestPermissionGateBypass()) {
        [self startServer];
        return;
    }
    [self showPermissionsPanel];
}

- (void)showPermissionsPanel
{
    if (self.permissionsPanelVisible)
        return;
    self.permissionsPanelVisible = YES;
    self.statusMenuItem.title = @"Not running  •  permissions required";

    MacVNCPermissionsPanelController *controller = [[MacVNCPermissionsPanelController alloc] init];
    MacVNCPermissionPanelAction action = [controller runModal];
    [controller release];
    self.permissionsPanelVisible = NO;

    if (action == MacVNCPermissionPanelActionStart) {
        if (macVNCPermissionsAllGranted())
            [self startServer];
        else
            [self showPermissionsPanel];
    } else if (action == MacVNCPermissionPanelActionRestart) {
        [self relaunchApplication];
    } else if (action == MacVNCPermissionPanelActionPreferences) {
        [self openPreferences:nil];
    } else if (action == MacVNCPermissionPanelActionQuit) {
        [NSApp terminate:nil];
    }
}

- (void)handleScreenCaptureFailure
{
    /* ScreenCaptureKit failed at runtime: Screen Recording is not effectively
       granted even if CGPreflight returned a stale YES. Stop the server and show
       the single unified permission popup. */
    macVNCNoteScreenCaptureFailure();
    vncServerStop();
    [self updateMenuStatus];
    [self showPermissionsPanel];
}

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

- (void)startServer
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        int       port     = (int)[defaults integerForKey:kKeyPort];
        NSString *password = macVNCLoadPassword(defaults);
        NSString *configurationError = nil;
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        NSString *portOverride = environment[@"MACVNC_PORT"];
        if (portOverride.integerValue > 0 && portOverride.integerValue <= 65535)
            port = (int)portOverride.integerValue;
        NSString *passwordFile = environment[@"MACVNC_PASSWORD_FILE"];
        if (passwordFile.length > 0) {
            password = macVNCReadSecurePasswordFile(passwordFile, &configurationError);
            if (configurationError)
                NSLog(@"%@", configurationError);
        }

        int captureFramesPerSecond = MACVNC_CAPTURE_FPS_DEFAULT;
        NSString *captureFPSOverride = environment[@"MACVNC_CAPTURE_FPS"];
        if (macVNCParseCaptureFPS(captureFPSOverride.UTF8String,
                                  &captureFramesPerSecond) == MACVNC_CAPTURE_RATE_INVALID) {
            NSString *captureRateError = [NSString stringWithFormat:
                @"Invalid MACVNC_CAPTURE_FPS '%@'; expected an integer from %d to %d",
                captureFPSOverride, MACVNC_CAPTURE_FPS_MIN, MACVNC_CAPTURE_FPS_MAX];
            if (!configurationError)
                configurationError = captureRateError;
            NSLog(@"%@", captureRateError);
        }

        /* Copy these globals before calling vncServerStart(). */
        viewOnly = (rfbBool)[defaults boolForKey:kKeyViewOnly];
        displayNumber = (int)[defaults integerForKey:kKeyDisplay];
        NSString *displayOverride = environment[@"MACVNC_DISPLAY"];
        if (displayOverride.length > 0)
            displayNumber = (int)displayOverride.integerValue;

        MacVNCPolicyInput policyInput = {
            .listenMode = ([defaults stringForKey:kKeyListenMode] ?: MacVNCListenModeLocalhost).UTF8String,
            .listenAddress = ([defaults stringForKey:kKeyListenAddress] ?: @"").UTF8String,
            .allowedClients = ([defaults stringForKey:kKeyAllowedClients] ?: @"").UTF8String,
            .allowAllConfirmed = [defaults boolForKey:kKeyAllowAllConfirmed],
        };
        MacVNCPolicyEnv policyEnv = {
            .listenAddress = environment[@"MACVNC_LISTEN"].length > 0
                ? environment[@"MACVNC_LISTEN"].UTF8String : NULL,
            .allowedClients = environment[@"MACVNC_ALLOWED_CLIENTS"]
                ? environment[@"MACVNC_ALLOWED_CLIENTS"].UTF8String : NULL,
            .hasAllowedClients = environment[@"MACVNC_ALLOWED_CLIENTS"] != nil,
        };
        MacVNCResolvedPolicy resolvedPolicy;
        if (!macVNCResolveNetworkPolicy(&policyInput, &policyEnv, &resolvedPolicy)) {
            configurationError = [NSString stringWithUTF8String:resolvedPolicy.error];
            NSLog(@"Network policy error: %@", configurationError);
        } else {
            snprintf(macVNCListenAddress, sizeof(macVNCListenAddress), "%s", resolvedPolicy.bindAddress);
            snprintf(macVNCAllowedClients, sizeof(macVNCAllowedClients), "%s", resolvedPolicy.allowedClients);
            macVNCClientAccessMode = resolvedPolicy.accessMode;
            if (resolvedPolicy.envOverrideActive)
                NSLog(@"macVNC network policy uses environment override(s)");
        }

        if (port <= 0 || port > 65535)
            port = kDefaultPort;

        BOOL ok = configurationError == nil &&
            vncServerStart(port, password.length > 0 ? password.UTF8String : NULL,
                           captureFramesPerSecond);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self updateMenuStatus];
            } else if (configurationError) {
                self.statusMenuItem.title = @"Failed to start";
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText     = @"macVNC could not start";
                alert.informativeText = configurationError;
                alert.alertStyle      = NSAlertStyleCritical;
                [alert runModal];
            } else {
                /* Non-configuration failure (e.g. capture/permissions). The
                   single permission popup is driven by the capture handler. */
                [self updateMenuStatus];
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

    if (port > 0) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *mode = [defaults stringForKey:kKeyListenMode] ?: MacVNCListenModeLocalhost;
        NSString *bind = macVNCBindHostForMode(mode, [defaults stringForKey:kKeyListenAddress]) ?: @"all interfaces";
        NSString *access = [defaults boolForKey:kKeyAllowAllConfirmed] ? @"allow all" : @"allowlist";
        self.statusMenuItem.title = [NSString stringWithFormat:@"Running  •  %@:%d  •  %@", bind, port, access];
    } else if (!macVNCPermissionsAllGranted()) {
        self.statusMenuItem.title = @"Not running  •  permissions required";
    } else {
        self.statusMenuItem.title = @"Not running";
    }

    int n = vncConnectedClients;
    if (n == 0)
        self.clientsMenuItem.title = @"No clients connected";
    else if (n == 1)
        self.clientsMenuItem.title = @"1 client connected";
    else
        self.clientsMenuItem.title = [NSString stringWithFormat:@"%d clients connected", n];
}

- (void)copyVNCAddress:(id)sender
{
    int port = vncServerGetPort();
    if (port <= 0) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *mode = [defaults stringForKey:kKeyListenMode] ?: MacVNCListenModeLocalhost;
    NSString *hostname = macVNCBindHostForMode(mode, [defaults stringForKey:kKeyListenAddress]);
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

- (BOOL)isLoginItemEnabled
{
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    }
    /* macOS 12.x fallback: check whether our LaunchAgent plist exists. */
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPlistPath]];
}

- (void)setLoginItemEnabled:(BOOL)enabled
{
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        if (enabled)
            [[SMAppService mainAppService] registerAndReturnError:&error];
        else
            [[SMAppService mainAppService] unregisterAndReturnError:&error];
        if (error)
            NSLog(@"SMAppService %@ failed: %@",
                  enabled ? @"register" : @"unregister", error);
        return;
    }

    /* macOS 12.x fallback: write / remove a LaunchAgent plist. */
    if (enabled) {
        NSString *exe = [[[NSBundle mainBundle] bundlePath]
                         stringByAppendingPathComponent:@"Contents/MacOS/macVNC"];
        NSDictionary *plist = @{
            @"Label":            kBundleID,
            @"ProgramArguments": @[exe],
            @"RunAtLoad":        @YES,
            @"KeepAlive":        @NO,
        };
        NSString *path = [self launchAgentPlistPath];
        [[NSFileManager defaultManager]
            createDirectoryAtPath:[path stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
        [plist writeToFile:path atomically:YES];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:[self launchAgentPlistPath]
                                                   error:nil];
    }
}

- (NSString *)launchAgentPlistPath
{
    return [NSHomeDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Library/LaunchAgents/%@.plist", kBundleID]];
}

- (void)toggleLoginItem:(id)sender
{
    BOOL wasEnabled = [self isLoginItemEnabled];
    [self setLoginItemEnabled:!wasEnabled];
    self.loginItemMenuItem.state = (!wasEnabled)
                                    ? NSControlStateValueOn
                                    : NSControlStateValueOff;
}

@end
