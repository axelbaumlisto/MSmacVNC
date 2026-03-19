#import "AppDelegate.h"
#import "mac.h"

#import <ServiceManagement/ServiceManagement.h>

/* Default TCP port for VNC */
static const int kDefaultPort = 5900;

/* NSUserDefaults keys */
static NSString * const kKeyPort     = @"rfbPort";
static NSString * const kKeyPassword = @"rfbPassword";
static NSString * const kKeyViewOnly = @"viewOnly";
static NSString * const kKeyDisplay  = @"displayNumber";

/* Bundle identifier used for the LaunchAgent plist (must match Info.plist) */
static NSString * const kBundleID = @"net.christianbeier.macVNC";


@interface AppDelegate ()

@property (nonatomic, strong) NSStatusItem  *statusItem;
@property (nonatomic, strong) NSMenuItem    *statusMenuItem;
@property (nonatomic, strong) NSMenuItem    *clientsMenuItem;
@property (nonatomic, strong) NSMenuItem    *loginItemMenuItem;
@property (nonatomic, strong) NSTimer       *updateTimer;

@end


@implementation AppDelegate

/* -----------------------------------------------------------------------
 * NSApplicationDelegate
 * ----------------------------------------------------------------------- */

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [self registerDefaults];
    [self setupStatusBarItem];
    [self startServer];

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
        kKeyDisplay:  @(-1),
        kKeyPassword: @"",
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
 * Server lifecycle
 * ----------------------------------------------------------------------- */

- (void)startServer
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        int       port     = (int)[defaults integerForKey:kKeyPort];
        NSString *password = [defaults stringForKey:kKeyPassword];

        /* Copy these globals before calling vncServerStart(). */
        viewOnly      = (rfbBool)[defaults boolForKey:kKeyViewOnly];
        displayNumber = (int)[defaults integerForKey:kKeyDisplay];

        if (port <= 0 || port > 65535)
            port = kDefaultPort;

        BOOL ok = vncServerStart(port,
                                 password.length > 0 ? password.UTF8String : NULL);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self updateMenuStatus];
            } else {
                self.statusMenuItem.title = @"Failed to start";
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText     = @"macVNC could not start";
                alert.informativeText = @"Check System Settings → Privacy & Security → "
                                        @"Accessibility and Screen Recording, then relaunch.";
                alert.alertStyle      = NSAlertStyleCritical;
                [alert runModal];
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
        self.statusMenuItem.title = [NSString stringWithFormat:@"Running  •  port %d", port];
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

    NSString *hostname = [NSHost currentHost].localizedName;
    NSString *address  = [NSString stringWithFormat:@"vnc://%@:%d", hostname, port];

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:address forType:NSPasteboardTypeString];
}

- (void)openPreferences:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int       port = (int)[defaults integerForKey:kKeyPort] ?: kDefaultPort;
    NSString *pwd  = [defaults stringForKey:kKeyPassword] ?: @"";

    /* Build a simple form inside an NSAlert. */
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"macVNC Preferences";
    alert.informativeText = @"Changes take effect after restarting macVNC.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 66)];

    NSTextField *portLabel = [NSTextField labelWithString:@"Port:"];
    portLabel.frame = NSMakeRect(0, 42, 80, 22);

    NSTextField *portField = [NSTextField textFieldWithString:
                              [NSString stringWithFormat:@"%d", port]];
    portField.frame = NSMakeRect(88, 42, 172, 22);

    NSTextField *pwdLabel = [NSTextField labelWithString:@"Password:"];
    pwdLabel.frame = NSMakeRect(0, 12, 80, 22);

    NSSecureTextField *pwdField = [[NSSecureTextField alloc]
                                   initWithFrame:NSMakeRect(88, 12, 172, 22)];
    pwdField.placeholderString = @"(no password)";
    pwdField.stringValue = pwd;

    [form addSubview:portLabel];
    [form addSubview:portField];
    [form addSubview:pwdLabel];
    [form addSubview:pwdField];
    alert.accessoryView = form;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        int newPort = portField.intValue;
        if (newPort > 0 && newPort <= 65535)
            [defaults setInteger:newPort forKey:kKeyPort];
        [defaults setObject:pwdField.stringValue forKey:kKeyPassword];
        [defaults synchronize];
    }
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
