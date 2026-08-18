#import "AppDelegate.h"
#import "mac.h"
#import "CaptureRate.h"
#import "NetworkAccess.h"
#import "NetworkCIDR.h"
#import "NetworkInventory.h"
#import "NetworkPolicyResolver.h"

#import <ServiceManagement/ServiceManagement.h>
#import <Security/Security.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
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
static NSString * const kKeyViewOnly       = @"viewOnly";
static NSString * const kKeyDisplay        = @"displayNumber";
static NSString * const kKeyListenMode     = @"listenMode";
static NSString * const kKeyListenAddress  = @"listenAddress";
static NSString * const kKeyAllowedClients = @"allowedClients";
static NSString * const kKeyAllowAllConfirmed = @"allowAllConfirmed";
static NSString * const kKeychainService = @"net.christianbeier.macVNC";
static NSString * const kKeychainPasswordAccount = @"rfbPassword";

/* Bundle identifier used for the LaunchAgent plist (must match Info.plist) */
static NSString * const kBundleID = @"net.christianbeier.macVNC";

static const NSInteger kPreferencesCustomAddressLabelTag = 9101;
static const NSInteger kPreferencesCustomAddressFieldTag = 9102;
static const NSInteger kPreferencesAllowedSummaryTag = 9103;

static NSData *macVNCUTF8Data(NSString *string)
{
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

static NSMutableDictionary *macVNCKeychainQuery(void)
{
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainPasswordAccount,
    } mutableCopy];
}

static NSString *macVNCReadKeychainPassword(void)
{
    NSMutableDictionary *query = macVNCKeychainQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    [query release];
    if (status != errSecSuccess || !result)
        return nil;

    NSData *data = [(NSData *)result autorelease];
    NSString *password = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return password.length > 0 ? password : nil;
}

static BOOL macVNCDeleteKeychainPassword(void)
{
    NSMutableDictionary *query = macVNCKeychainQuery();
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    [query release];
    return status == errSecSuccess || status == errSecItemNotFound;
}

static BOOL macVNCSaveKeychainPassword(NSString *password, NSString **errorMessage)
{
    if (password.length == 0) {
        if (!macVNCDeleteKeychainPassword()) {
            if (errorMessage)
                *errorMessage = @"Could not delete password from Keychain";
            return NO;
        }
        return YES;
    }

    NSData *data = macVNCUTF8Data(password);
    NSMutableDictionary *query = macVNCKeychainQuery();
    NSDictionary *update = @{(__bridge id)kSecValueData: data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)update);
    if (status == errSecItemNotFound) {
        query[(__bridge id)kSecValueData] = data;
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    [query release];

    if (status != errSecSuccess) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"Could not save password to Keychain (OSStatus %d)", (int)status];
        return NO;
    }
    return YES;
}

static NSString *macVNCLoadPassword(NSUserDefaults *defaults)
{
    NSString *password = macVNCReadKeychainPassword();
    NSString *legacy = [defaults objectForKey:kKeyPassword];
    if (password.length == 0 && legacy.length > 0) {
        NSString *error = nil;
        if (macVNCSaveKeychainPassword(legacy, &error)) {
            [defaults removeObjectForKey:kKeyPassword];
            [defaults synchronize];
            password = legacy;
        } else {
            NSLog(@"%@", error ?: @"Could not migrate password to Keychain");
        }
    } else if (legacy.length > 0) {
        [defaults removeObjectForKey:kKeyPassword];
        [defaults synchronize];
    }
    return password ?: @"";
}

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
        kKeyDisplay:        @(-1),
        kKeyPassword:       @"",
        kKeyListenMode:        @"localhost",
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

        MacVNCPolicyInput policyInput = {
            .listenMode = ([defaults stringForKey:kKeyListenMode] ?: @"localhost").UTF8String,
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
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *mode = [defaults stringForKey:kKeyListenMode] ?: @"localhost";
        NSString *bind = @"all interfaces";
        if ([mode isEqualToString:@"localhost"])
            bind = @"127.0.0.1";
        else if ([mode isEqualToString:@"custom"] || [mode isEqualToString:@"selected"])
            bind = [defaults stringForKey:kKeyListenAddress] ?: @"";
        NSString *access = [defaults boolForKey:kKeyAllowAllConfirmed] ? @"allow all" : @"allowlist";
        self.statusMenuItem.title = [NSString stringWithFormat:@"Running  •  %@:%d  •  %@", bind, port, access];
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

- (NSArray<NSDictionary *> *)activeNetworkRows
{
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0)
        return rows;

    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_name || !item->ifa_addr || !item->ifa_netmask)
            continue;
        if (item->ifa_addr->sa_family != AF_INET)
            continue;
        if ((item->ifa_flags & IFF_UP) == 0 || (item->ifa_flags & IFF_RUNNING) == 0)
            continue;

        char address[INET_ADDRSTRLEN] = {0};
        char netmask[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *addr = (struct sockaddr_in *)item->ifa_addr;
        struct sockaddr_in *mask = (struct sockaddr_in *)item->ifa_netmask;
        if (!inet_ntop(AF_INET, &addr->sin_addr, address, sizeof(address)) ||
            !inet_ntop(AF_INET, &mask->sin_addr, netmask, sizeof(netmask)))
            continue;

        MacVNCNetworkInterfaceRow row;
        MacVNCNetworkInterfaceSnapshot snapshot = {
            .name = item->ifa_name,
            .active = true,
            .address = address,
            .netmask = netmask,
        };
        if (!macVNCBuildNetworkInterfaceRow(&snapshot, &row) || !row.selectable)
            continue;

        NSString *name = [NSString stringWithUTF8String:row.name];
        NSString *displayName = [NSString stringWithUTF8String:row.displayName];
        NSString *ip = [NSString stringWithUTF8String:row.address];
        NSString *cidr = [NSString stringWithUTF8String:row.cidr];
        NSString *allowCIDR = [NSString stringWithUTF8String:row.suggestedAllowCIDR];
        NSString *listenTitle = [NSString stringWithFormat:@"%@ — %@", displayName, ip];
        NSString *allowTitle = row.cgnatLike
            ? [NSString stringWithFormat:@"Tailscale tailnet / CGNAT range — %@ (broad; use Tailscale ACLs)", allowCIDR]
            : [NSString stringWithFormat:@"Same network as %@ — %@", displayName, allowCIDR];
        NSString *allowSummary = row.cgnatLike
            ? [NSString stringWithFormat:@"Auto: Tailscale clients — %@", allowCIDR]
            : [NSString stringWithFormat:@"Auto: same network — %@", allowCIDR];
        [rows addObject:@{
            @"name": name,
            @"displayName": displayName,
            @"address": ip,
            @"cidr": cidr,
            @"allowCIDR": allowCIDR,
            @"listenTitle": listenTitle,
            @"allowTitle": allowTitle,
            @"allowSummary": allowSummary,
            @"allowPresetVisible": @(row.allowPresetVisible),
            @"cgnatLike": @(row.cgnatLike),
        }];
    }
    freeifaddrs(interfaces);
    return rows;
}

- (void)preferencesListenPopupChanged:(NSPopUpButton *)popup
{
    NSTextField *addressLabel = nil;
    NSTextField *addressField = nil;
    NSTextField *allowedSummary = nil;
    for (NSView *subview in popup.superview.subviews) {
        if (subview.tag == kPreferencesCustomAddressLabelTag)
            addressLabel = (NSTextField *)subview;
        else if (subview.tag == kPreferencesCustomAddressFieldTag)
            addressField = (NSTextField *)subview;
        else if (subview.tag == kPreferencesAllowedSummaryTag)
            allowedSummary = (NSTextField *)subview;
    }
    if (!addressLabel || !addressField)
        return;

    NSInteger tag = popup.selectedItem.tag;
    if (tag == 2) {
        addressLabel.stringValue = @"Custom address:";
        addressField.enabled = YES;
        addressField.editable = YES;
        addressField.alphaValue = 1.0;
        allowedSummary.stringValue = @"Advanced: enter allowed client IP/CIDR below.";
    } else if (tag >= 1000) {
        NSDictionary *row = [popup.selectedItem.representedObject isKindOfClass:NSDictionary.class]
            ? popup.selectedItem.representedObject : nil;
        addressLabel.stringValue = @"Selected address:";
        addressField.stringValue = row[@"address"] ?: @"";
        addressField.enabled = NO;
        addressField.editable = NO;
        addressField.alphaValue = 0.65;
        allowedSummary.stringValue = row[@"allowSummary"] ?: @"Auto: matching client network.";
        allowedSummary.toolTip = row[@"allowTitle"] ?: allowedSummary.toolTip;
    } else {
        addressLabel.stringValue = @"Custom address:";
        addressField.stringValue = @"";
        addressField.enabled = NO;
        addressField.editable = NO;
        addressField.alphaValue = 0.35;
        allowedSummary.stringValue = @"This Mac only — 127.0.0.1";
    }
}

- (void)copyVNCAddress:(id)sender
{
    int port = vncServerGetPort();
    if (port <= 0) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *mode = [defaults stringForKey:kKeyListenMode] ?: @"localhost";
    NSString *hostname = nil;
    if ([mode isEqualToString:@"localhost"])
        hostname = @"127.0.0.1";
    else if ([mode isEqualToString:@"custom"] || [mode isEqualToString:@"selected"])
        hostname = [defaults stringForKey:kKeyListenAddress];
    if (hostname.length == 0)
        hostname = [NSHost currentHost].localizedName;
    NSString *address  = [NSString stringWithFormat:@"vnc://%@:%d", hostname, port];

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:address forType:NSPasteboardTypeString];
}

- (void)openPreferences:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int       port = (int)[defaults integerForKey:kKeyPort] ?: kDefaultPort;
    NSString *pwd  = macVNCLoadPassword(defaults);
    NSString *currentMode = [defaults stringForKey:kKeyListenMode] ?: @"localhost";
    NSString *currentAddress = [defaults stringForKey:kKeyListenAddress] ?: @"";
    NSString *currentAllowed = [defaults stringForKey:kKeyAllowedClients] ?: @"";
    NSArray<NSDictionary *> *networkRows = [self activeNetworkRows];
    NSMutableArray<NSString *> *presetCIDRs = [NSMutableArray array];
    for (NSDictionary *row in networkRows) {
        if ([row[@"allowPresetVisible"] boolValue])
            [presetCIDRs addObject:row[@"allowCIDR"]];
    }
    NSMutableArray<NSString *> *manualLines = [NSMutableArray array];
    for (NSString *line in [currentAllowed componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL isSafeLocalhostDefault = [trimmed isEqualToString:@"127.0.0.1"] || [trimmed isEqualToString:@"127.0.0.1/32"];
        if (trimmed.length > 0 && ![presetCIDRs containsObject:trimmed] && !isSafeLocalhostDefault)
            [manualLines addObject:trimmed];
    }
    NSString *manualAllowed = [manualLines componentsJoinedByString:@"\n"];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"macVNC Preferences";
    alert.informativeText = @"Changes take effect after restarting macVNC. IPv4 only in this version.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 236)];

    NSTextField *portLabel = [NSTextField labelWithString:@"Port:"];
    portLabel.frame = NSMakeRect(0, 206, 120, 22);
    NSTextField *portField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%d", port]];
    portField.frame = NSMakeRect(130, 206, 120, 22);

    NSTextField *pwdLabel = [NSTextField labelWithString:@"Password:"];
    pwdLabel.frame = NSMakeRect(270, 206, 90, 22);
    NSSecureTextField *pwdField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(360, 206, 160, 22)];
    pwdField.placeholderString = @"(required)";
    pwdField.stringValue = pwd;

    NSTextField *listenLabel = [NSTextField labelWithString:@"Accept connections on:"];
    listenLabel.frame = NSMakeRect(0, 172, 150, 22);
    listenLabel.toolTip = @"Where the VNC server listens. Localhost means this Mac only; a network interface allows devices that can reach that interface.";
    NSPopUpButton *listenPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(160, 170, 360, 26) pullsDown:NO];
    listenPopup.toolTip = @"Choose the local address/interface that accepts incoming VNC connections. This is not the allowlist; it only chooses where to listen.";
    [listenPopup addItemWithTitle:@"Localhost only (127.0.0.1)"];
    listenPopup.lastItem.tag = 1;
    [listenPopup addItemWithTitle:@"Custom IPv4 address (advanced)"];
    listenPopup.lastItem.tag = 2;
    for (NSUInteger i = 0; i < networkRows.count; ++i) {
        NSDictionary *row = networkRows[i];
        [listenPopup addItemWithTitle:[NSString stringWithFormat:@"%@", row[@"listenTitle"]]];
        listenPopup.lastItem.tag = 1000 + (NSInteger)i;
        listenPopup.lastItem.representedObject = row;
    }

    if ([currentMode isEqualToString:@"custom"])
        [listenPopup selectItemWithTag:2];
    else if ([currentMode isEqualToString:@"selected"]) {
        BOOL selected = NO;
        for (NSUInteger i = 0; i < networkRows.count; ++i) {
            if ([networkRows[i][@"address"] isEqualToString:currentAddress]) {
                [listenPopup selectItemWithTag:1000 + (NSInteger)i];
                selected = YES;
                break;
            }
        }
        if (!selected)
            [listenPopup selectItemWithTag:1];
    } else {
        [listenPopup selectItemWithTag:1];
    }

    NSTextField *customLabel = [NSTextField labelWithString:@"Custom address:"];
    customLabel.frame = NSMakeRect(0, 140, 150, 22);
    customLabel.tag = kPreferencesCustomAddressLabelTag;
    customLabel.toolTip = @"Editable only when 'Custom IPv4 address' is selected above.";
    NSTextField *customField = [NSTextField textFieldWithString:currentAddress];
    customField.frame = NSMakeRect(160, 140, 190, 22);
    customField.tag = kPreferencesCustomAddressFieldTag;
    customField.toolTip = @"Local IPv4 address to bind, for example 192.168.100.87 or 100.70.214.41.";
    listenPopup.target = self;
    listenPopup.action = @selector(preferencesListenPopupChanged:);

    NSTextField *netLabel = [NSTextField labelWithString:@"Allowed clients:"];
    netLabel.frame = NSMakeRect(0, 110, 150, 22);
    netLabel.toolTip = @"Calculated automatically from the selected listen interface.";
    NSTextField *allowedSummary = [NSTextField labelWithString:@""];
    allowedSummary.frame = NSMakeRect(160, 110, 360, 22);
    allowedSummary.tag = kPreferencesAllowedSummaryTag;
    allowedSummary.textColor = NSColor.secondaryLabelColor;
    allowedSummary.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    allowedSummary.toolTip = @"No checkbox needed: localhost allows localhost, a Tailscale interface allows Tailscale clients, and a LAN interface allows that LAN.";

    NSTextField *manualLabel = [NSTextField labelWithString:@"Extra allowed clients (advanced):"];
    manualLabel.frame = NSMakeRect(0, 76, 210, 22);
    manualLabel.toolTip = @"Optional extra client IPs/subnets, one per line. Leave empty for the automatic safe policy.";
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(210, 42, 310, 56)];
    NSTextView *allowedText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 310, 56)];
    allowedText.string = manualAllowed;
    allowedText.toolTip = @"Format: one IPv4 or CIDR per line. Examples: 100.101.102.103/32 or 192.168.100.0/24.";
    NSTextField *manualHint = [NSTextField labelWithString:@"Format: one IPv4/CIDR per line, e.g. 100.x.y.z/32 or 192.168.100.0/24"];
    manualHint.frame = NSMakeRect(210, 18, 310, 18);
    manualHint.textColor = NSColor.secondaryLabelColor;
    manualHint.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    scroll.documentView = allowedText;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    [form addSubview:portLabel]; [form addSubview:portField];
    [form addSubview:pwdLabel]; [form addSubview:pwdField];
    [form addSubview:listenLabel]; [form addSubview:listenPopup];
    [form addSubview:customLabel]; [form addSubview:customField];
    [form addSubview:netLabel]; [form addSubview:allowedSummary];
    [form addSubview:manualLabel]; [form addSubview:scroll]; [form addSubview:manualHint];
    [self preferencesListenPopupChanged:listenPopup];
    alert.accessoryView = form;

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        int newPort = portField.intValue;
        NSString *newMode = @"localhost";
        NSString *newAddress = @"";
        NSInteger tag = listenPopup.selectedItem.tag;
        if (tag == 1) {
            newMode = @"localhost";
        } else if (tag == 2) {
            newMode = @"custom";
            newAddress = customField.stringValue;
        } else if (tag >= 1000) {
            NSUInteger rowIndex = (NSUInteger)(tag - 1000);
            if (rowIndex < networkRows.count) {
                newMode = @"selected";
                newAddress = networkRows[rowIndex][@"address"];
            }
        }

        NSMutableOrderedSet<NSString *> *allowedSet = [NSMutableOrderedSet orderedSet];
        if ([newMode isEqualToString:@"localhost"]) {
            [allowedSet addObject:@"127.0.0.1"];
        } else if ([newMode isEqualToString:@"selected"] && tag >= 1000) {
            NSUInteger rowIndex = (NSUInteger)(tag - 1000);
            if (rowIndex < networkRows.count)
                [allowedSet addObject:networkRows[rowIndex][@"allowCIDR"]];
        }
        for (NSString *line in [allowedText.string componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length > 0)
                [allowedSet addObject:trimmed];
        }
        NSMutableString *combinedAllowed = [NSMutableString string];
        for (NSString *entry in allowedSet)
            [combinedAllowed appendFormat:@"%@\n", entry];
        BOOL newAllowAll = NO;

        if ([combinedAllowed containsString:@"0.0.0.0/0"]) {
            NSAlert *warning = [[NSAlert alloc] init];
            warning.messageText = @"Allow all clients?";
            warning.informativeText = @"0.0.0.0/0 allows every IPv4 client that can reach macVNC. This is unsafe outside a trusted VPN.";
            [warning addButtonWithTitle:@"Continue"];
            [warning addButtonWithTitle:@"Cancel"];
            if ([warning runModal] != NSAlertFirstButtonReturn)
                return;
        }

        MacVNCPolicyInput input = {
            .listenMode = newMode.UTF8String,
            .listenAddress = newAddress.UTF8String,
            .allowedClients = combinedAllowed.UTF8String,
            .allowAllConfirmed = newAllowAll,
        };
        MacVNCResolvedPolicy resolved;
        if (!macVNCResolveNetworkPolicy(&input, NULL, &resolved)) {
            NSAlert *errorAlert = [[NSAlert alloc] init];
            errorAlert.messageText = @"Invalid network policy";
            errorAlert.informativeText = [NSString stringWithUTF8String:resolved.error];
            [errorAlert addButtonWithTitle:@"OK"];
            [errorAlert runModal];
            return;
        }

        NSString *passwordError = nil;
        if (!macVNCSaveKeychainPassword(pwdField.stringValue, &passwordError)) {
            NSAlert *errorAlert = [[NSAlert alloc] init];
            errorAlert.messageText = @"Could not save password";
            errorAlert.informativeText = passwordError ?: @"macVNC could not save the VNC password to Keychain.";
            [errorAlert addButtonWithTitle:@"OK"];
            [errorAlert runModal];
            return;
        }

        if (newPort > 0 && newPort <= 65535)
            [defaults setInteger:newPort forKey:kKeyPort];
        [defaults removeObjectForKey:kKeyPassword];
        [defaults setObject:newMode forKey:kKeyListenMode];
        [defaults setObject:newAddress forKey:kKeyListenAddress];
        [defaults setObject:combinedAllowed forKey:kKeyAllowedClients];
        [defaults setBool:newAllowAll forKey:kKeyAllowAllConfirmed];
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
