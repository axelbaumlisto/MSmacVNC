#import "MacVNCPreferences.h"
#import "MacVNCDefaultsKeys.h"
#import "MacVNCPassword.h"
#import "MacVNCNetworkRows.h"
#import "MacVNCListenMode.h"
#import "NetworkPolicyResolver.h"

static const NSInteger kCustomAddressLabelTag = 9101;
static const NSInteger kCustomAddressFieldTag = 9102;
static const NSInteger kAllowedSummaryTag = 9103;

/* Split newline-separated text into trimmed, non-empty lines. */
static NSArray<NSString *> *macVNCTrimmedNonEmptyLines(NSString *text)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0)
            [lines addObject:trimmed];
    }
    return lines;
}

@implementation MacVNCPreferencesController

- (void)listenPopupChanged:(NSPopUpButton *)popup
{
    NSTextField *addressLabel = nil;
    NSTextField *addressField = nil;
    NSTextField *allowedSummary = nil;
    for (NSView *subview in popup.superview.subviews) {
        if (subview.tag == kCustomAddressLabelTag)
            addressLabel = (NSTextField *)subview;
        else if (subview.tag == kCustomAddressFieldTag)
            addressField = (NSTextField *)subview;
        else if (subview.tag == kAllowedSummaryTag)
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

- (void)runModal
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int       port = (int)[defaults integerForKey:MacVNCKeyPort] ?: MacVNCDefaultPort;
    NSString *pwd  = macVNCLoadPassword(defaults);
    NSString *currentMode = [defaults stringForKey:MacVNCKeyListenMode] ?: MacVNCListenModeLocalhost;
    NSString *currentAddress = [defaults stringForKey:MacVNCKeyListenAddress] ?: @"";
    NSString *currentAllowed = [defaults stringForKey:MacVNCKeyAllowedClients] ?: @"";
    NSArray<NSDictionary *> *networkRows = macVNCActiveNetworkRows();
    NSMutableArray<NSString *> *presetCIDRs = [NSMutableArray array];
    for (NSDictionary *row in networkRows) {
        if ([row[@"allowPresetVisible"] boolValue])
            [presetCIDRs addObject:row[@"allowCIDR"]];
    }
    NSMutableArray<NSString *> *manualLines = [NSMutableArray array];
    for (NSString *trimmed in macVNCTrimmedNonEmptyLines(currentAllowed)) {
        BOOL isSafeLocalhostDefault = [trimmed isEqualToString:@"127.0.0.1"] || [trimmed isEqualToString:@"127.0.0.1/32"];
        if (![presetCIDRs containsObject:trimmed] && !isSafeLocalhostDefault)
            [manualLines addObject:trimmed];
    }
    NSString *manualAllowed = [manualLines componentsJoinedByString:@"\n"];

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText     = @"macVNC Preferences";
    alert.informativeText = @"Changes take effect after restarting macVNC. IPv4 only in this version.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView *form = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 236)] autorelease];

    NSTextField *portLabel = [NSTextField labelWithString:@"Port:"];
    portLabel.frame = NSMakeRect(0, 206, 120, 22);
    NSTextField *portField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%d", port]];
    portField.frame = NSMakeRect(130, 206, 120, 22);

    NSTextField *pwdLabel = [NSTextField labelWithString:@"Password:"];
    pwdLabel.frame = NSMakeRect(270, 206, 90, 22);
    NSSecureTextField *pwdField = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(360, 206, 160, 22)] autorelease];
    pwdField.placeholderString = @"(required)";
    pwdField.stringValue = pwd;

    NSTextField *listenLabel = [NSTextField labelWithString:@"Accept connections on:"];
    listenLabel.frame = NSMakeRect(0, 172, 150, 22);
    listenLabel.toolTip = @"Where the VNC server listens. Localhost means this Mac only; a network interface allows devices that can reach that interface.";
    NSPopUpButton *listenPopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(160, 170, 360, 26) pullsDown:NO] autorelease];
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

    if ([currentMode isEqualToString:MacVNCListenModeCustom])
        [listenPopup selectItemWithTag:2];
    else if ([currentMode isEqualToString:MacVNCListenModeSelected]) {
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
    customLabel.tag = kCustomAddressLabelTag;
    customLabel.toolTip = @"Editable only when 'Custom IPv4 address' is selected above.";
    NSTextField *customField = [NSTextField textFieldWithString:currentAddress];
    customField.frame = NSMakeRect(160, 140, 190, 22);
    customField.tag = kCustomAddressFieldTag;
    customField.toolTip = @"Local IPv4 address to bind, for example 192.168.100.87 or 100.70.214.41.";
    listenPopup.target = self;
    listenPopup.action = @selector(listenPopupChanged:);

    NSTextField *netLabel = [NSTextField labelWithString:@"Allowed clients:"];
    netLabel.frame = NSMakeRect(0, 110, 150, 22);
    netLabel.toolTip = @"Calculated automatically from the selected listen interface.";
    NSTextField *allowedSummary = [NSTextField labelWithString:@""];
    allowedSummary.frame = NSMakeRect(160, 110, 360, 22);
    allowedSummary.tag = kAllowedSummaryTag;
    allowedSummary.textColor = NSColor.secondaryLabelColor;
    allowedSummary.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    allowedSummary.toolTip = @"No checkbox needed: localhost allows localhost, a Tailscale interface allows Tailscale clients, and a LAN interface allows that LAN.";

    NSTextField *manualLabel = [NSTextField labelWithString:@"Extra allowed clients (advanced):"];
    manualLabel.frame = NSMakeRect(0, 76, 210, 22);
    manualLabel.toolTip = @"Optional extra client IPs/subnets, one per line. Leave empty for the automatic safe policy.";
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(210, 42, 310, 56)] autorelease];
    NSTextView *allowedText = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 310, 56)] autorelease];
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
    [self listenPopupChanged:listenPopup];
    alert.accessoryView = form;

    if ([alert runModal] != NSAlertFirstButtonReturn)
        return;

    int newPort = portField.intValue;
    NSString *newMode = MacVNCListenModeLocalhost;
    NSString *newAddress = @"";
    NSInteger tag = listenPopup.selectedItem.tag;
    if (tag == 1) {
        newMode = MacVNCListenModeLocalhost;
    } else if (tag == 2) {
        newMode = MacVNCListenModeCustom;
        newAddress = customField.stringValue;
    } else if (tag >= 1000) {
        NSUInteger rowIndex = (NSUInteger)(tag - 1000);
        if (rowIndex < networkRows.count) {
            newMode = MacVNCListenModeSelected;
            newAddress = networkRows[rowIndex][@"address"];
        }
    }

    NSMutableOrderedSet<NSString *> *allowedSet = [NSMutableOrderedSet orderedSet];
    if ([newMode isEqualToString:MacVNCListenModeLocalhost]) {
        [allowedSet addObject:@"127.0.0.1"];
    } else if ([newMode isEqualToString:MacVNCListenModeSelected] && tag >= 1000) {
        NSUInteger rowIndex = (NSUInteger)(tag - 1000);
        if (rowIndex < networkRows.count)
            [allowedSet addObject:networkRows[rowIndex][@"allowCIDR"]];
    }
    for (NSString *trimmed in macVNCTrimmedNonEmptyLines(allowedText.string))
        [allowedSet addObject:trimmed];
    NSMutableString *combinedAllowed = [NSMutableString string];
    for (NSString *entry in allowedSet)
        [combinedAllowed appendFormat:@"%@\n", entry];
    BOOL newAllowAll = NO;

    if ([combinedAllowed containsString:@"0.0.0.0/0"]) {
        NSAlert *warning = [[[NSAlert alloc] init] autorelease];
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
        NSAlert *errorAlert = [[[NSAlert alloc] init] autorelease];
        errorAlert.messageText = @"Invalid network policy";
        errorAlert.informativeText = [NSString stringWithUTF8String:resolved.error];
        [errorAlert addButtonWithTitle:@"OK"];
        [errorAlert runModal];
        return;
    }

    /* Store password in plaintext defaults (by request), trimmed, and remove
       any previously stored Keychain copy. */
    macVNCStorePassword(defaults, pwdField.stringValue);

    if (newPort > 0 && newPort <= 65535)
        [defaults setInteger:newPort forKey:MacVNCKeyPort];
    [defaults setObject:newMode forKey:MacVNCKeyListenMode];
    [defaults setObject:newAddress forKey:MacVNCKeyListenAddress];
    [defaults setObject:combinedAllowed forKey:MacVNCKeyAllowedClients];
    [defaults setBool:newAllowAll forKey:MacVNCKeyAllowAllConfirmed];
    [defaults synchronize];
}

@end
