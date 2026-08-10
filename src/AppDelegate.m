#import "AppDelegate.h"
#import "mac.h"
#import "CaptureRate.h"

#import <ServiceManagement/ServiceManagement.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Default TCP port for VNC */
static const int kDefaultPort = 5900;

/* NSUserDefaults keys */
static NSString * const kKeyPort     = @"rfbPort";
static NSString * const kKeyPassword = @"rfbPassword";
static NSString * const kKeyViewOnly = @"viewOnly";
static NSString * const kKeyDisplay  = @"displayNumber";

/* Bundle identifier used for the LaunchAgent plist (must match Info.plist) */
static NSString * const kBundleID = @"net.christianbeier.macVNC";

static NSString *readSecurePasswordFile(NSString *path, NSString **errorMessage)
{
    const char *fileSystemPath = path.fileSystemRepresentation;
    int fd = open(fileSystemPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"Cannot open MACVNC_PASSWORD_FILE %@: %s",
                             path, strerror(errno)];
        return nil;
    }

    struct stat info;
    if (fstat(fd, &info) != 0) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"Cannot inspect MACVNC_PASSWORD_FILE %@: %s",
                             path, strerror(errno)];
        close(fd);
        return nil;
    }
    if (!S_ISREG(info.st_mode)) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ must be a regular file", path];
        close(fd);
        return nil;
    }
    if (info.st_uid != getuid()) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ is not owned by uid %u",
                             path, getuid()];
        close(fd);
        return nil;
    }
    if ((info.st_mode & 0077) != 0) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:
                @"MACVNC_PASSWORD_FILE %@ must not be accessible by group/others", path];
        close(fd);
        return nil;
    }
    if (info.st_size <= 0 || info.st_size > 4096) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ is empty or too large", path];
        close(fd);
        return nil;
    }

    size_t size = (size_t)info.st_size;
    char *bytes = malloc(size);
    size_t received = 0;
    while (received < size) {
        ssize_t count = read(fd, bytes + received, size - received);
        if (count <= 0) break;
        received += (size_t)count;
    }
    close(fd);
    if (received != size) {
        free(bytes);
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"Could not completely read MACVNC_PASSWORD_FILE %@", path];
        return nil;
    }

    NSString *raw = [[[NSString alloc] initWithBytesNoCopy:bytes
                                                     length:size
                                                   encoding:NSUTF8StringEncoding
                                               freeWhenDone:YES] autorelease];
    NSString *password = [raw stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!raw || password.length == 0) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ is not valid non-empty UTF-8", path];
        return nil;
    }
    return password;
}

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
        NSString *configurationError = nil;
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        NSString *portOverride = environment[@"MACVNC_PORT"];
        if (portOverride.integerValue > 0 && portOverride.integerValue <= 65535)
            port = (int)portOverride.integerValue;
        NSString *passwordFile = environment[@"MACVNC_PASSWORD_FILE"];
        if (passwordFile.length > 0) {
            password = readSecurePasswordFile(passwordFile, &configurationError);
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

        if (port <= 0 || port > 65535)
            port = kDefaultPort;

        BOOL ok = configurationError == nil &&
            vncServerStart(port, password.length > 0 ? password.UTF8String : NULL,
                           captureFramesPerSecond);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self updateMenuStatus];
            } else {
                self.statusMenuItem.title = @"Failed to start";
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText     = @"macVNC could not start";
                alert.informativeText = configurationError ?: @"Check System Settings → Privacy & Security → "
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
