#import "MacVNCPreferences.h"
#import "MacVNCDefaultsKeys.h"
#import "MacVNCPassword.h"
#import "MacVNCNetworkRows.h"
#import "MacVNCListenMode.h"
#import "NetworkPolicyResolver.h"

/* Listen-popup item tags (implicit contract shared by build + save paths). */
static const NSInteger kListenTagLocalhost = 1;
static const NSInteger kListenTagCustom    = 2;
static const NSInteger kListenTagRowBase   = 1000; /* + interface row index */

/* Preferences form layout grid (points). Rows are laid out top-down; columns
   give a label column and a control column so the magic NSMakeRect numbers read
   as intent, not arbitrary constants. */
static const CGFloat kFormWidth   = 520;
static const CGFloat kFormHeight  = 236;
static const CGFloat kColLabelX   = 0;
static const CGFloat kColCtrlX    = 160;
static const CGFloat kRowHeight   = 22;
static const CGFloat kRowPort     = 206;
static const CGFloat kRowListen   = 170;
static const CGFloat kRowCustom   = 140;
static const CGFloat kRowAllowed  = 110;
static const CGFloat kRowManual   = 76;
static const CGFloat kRowScroll   = 42;
static const CGFloat kRowHint     = 18;

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

/* Extra manual allowlist lines = stored allowlist minus preset CIDRs and the
   safe localhost default. Pure model helper, kept out of the view builder. */
static NSString *macVNCManualAllowedText(NSString *currentAllowed,
                                         NSArray<NSDictionary *> *networkRows)
{
    NSMutableArray<NSString *> *presetCIDRs = [NSMutableArray array];
    for (NSDictionary *row in networkRows) {
        if ([row[MacVNCRowKeyAllowPresetVisible] boolValue])
            [presetCIDRs addObject:row[MacVNCRowKeyAllowCIDR]];
    }
    NSMutableArray<NSString *> *manualLines = [NSMutableArray array];
    for (NSString *trimmed in macVNCTrimmedNonEmptyLines(currentAllowed)) {
        BOOL isSafeLocalhostDefault = [trimmed isEqualToString:MacVNCLoopbackIPv4] ||
                                      [trimmed isEqualToString:[MacVNCLoopbackIPv4 stringByAppendingString:@"/32"]];
        if (![presetCIDRs containsObject:trimmed] && !isSafeLocalhostDefault)
            [manualLines addObject:trimmed];
    }
    return [manualLines componentsJoinedByString:@"\n"];
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
    if (tag == kListenTagCustom) {
        addressLabel.stringValue = @"Custom address:";
        addressField.enabled = YES;
        addressField.editable = YES;
        addressField.alphaValue = 1.0;
        allowedSummary.stringValue = @"Advanced: enter allowed client IP/CIDR below.";
    } else if (tag >= kListenTagRowBase) {
        NSDictionary *row = [popup.selectedItem.representedObject isKindOfClass:NSDictionary.class]
            ? popup.selectedItem.representedObject : nil;
        addressLabel.stringValue = @"Selected address:";
        addressField.stringValue = row[MacVNCRowKeyAddress] ?: @"";
        addressField.enabled = NO;
        addressField.editable = NO;
        addressField.alphaValue = 0.65;
        allowedSummary.stringValue = row[MacVNCRowKeyAllowSummary] ?: @"Auto: matching client network.";
        allowedSummary.toolTip = row[MacVNCRowKeyAllowTitle] ?: allowedSummary.toolTip;
    } else {
        addressLabel.stringValue = @"Custom address:";
        addressField.stringValue = @"";
        addressField.enabled = NO;
        addressField.editable = NO;
        addressField.alphaValue = 0.35;
        allowedSummary.stringValue = @"This Mac only — 127.0.0.1";
    }
}

/* Builds the Preferences form view, populated from the given values, and
 * returns the save-time controls the caller reads back after the modal. */
- (NSView *)buildFormForPort:(int)port
                    password:(NSString *)pwd
                 currentMode:(NSString *)currentMode
              currentAddress:(NSString *)currentAddress
               manualAllowed:(NSString *)manualAllowed
                 networkRows:(NSArray<NSDictionary *> *)networkRows
                   portField:(NSTextField **)outPortField
                    pwdField:(NSSecureTextField **)outPwdField
                 listenPopup:(NSPopUpButton **)outListenPopup
                 customField:(NSTextField **)outCustomField
                 allowedText:(NSTextView **)outAllowedText
{
    NSView *form = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, kFormWidth, kFormHeight)] autorelease];

    NSTextField *portLabel = [NSTextField labelWithString:@"Port:"];
    portLabel.frame = NSMakeRect(kColLabelX, kRowPort, 120, kRowHeight);
    NSTextField *portField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%d", port]];
    portField.frame = NSMakeRect(130, kRowPort, 120, kRowHeight);

    NSTextField *pwdLabel = [NSTextField labelWithString:@"Password:"];
    pwdLabel.frame = NSMakeRect(270, kRowPort, 90, kRowHeight);
    NSSecureTextField *pwdField = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(360, kRowPort, 160, kRowHeight)] autorelease];
    pwdField.placeholderString = @"(required)";
    pwdField.stringValue = pwd;

    NSTextField *listenLabel = [NSTextField labelWithString:@"Accept connections on:"];
    listenLabel.frame = NSMakeRect(kColLabelX, kRowListen + 2, 150, kRowHeight);
    listenLabel.toolTip = @"Where the VNC server listens. Localhost means this Mac only; a network interface allows devices that can reach that interface.";
    NSPopUpButton *listenPopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(kColCtrlX, kRowListen, 360, 26) pullsDown:NO] autorelease];
    listenPopup.toolTip = @"Choose the local address/interface that accepts incoming VNC connections. This is not the allowlist; it only chooses where to listen.";
    [listenPopup addItemWithTitle:@"Localhost only (127.0.0.1)"];
    listenPopup.lastItem.tag = kListenTagLocalhost;
    [listenPopup addItemWithTitle:@"Custom IPv4 address (advanced)"];
    listenPopup.lastItem.tag = kListenTagCustom;
    for (NSUInteger i = 0; i < networkRows.count; ++i) {
        NSDictionary *row = networkRows[i];
        [listenPopup addItemWithTitle:[NSString stringWithFormat:@"%@", row[MacVNCRowKeyListenTitle]]];
        listenPopup.lastItem.tag = kListenTagRowBase + (NSInteger)i;
        listenPopup.lastItem.representedObject = row;
    }

    if ([currentMode isEqualToString:MacVNCListenModeCustom])
        [listenPopup selectItemWithTag:kListenTagCustom];
    else if ([currentMode isEqualToString:MacVNCListenModeSelected]) {
        BOOL selected = NO;
        for (NSUInteger i = 0; i < networkRows.count; ++i) {
            if ([networkRows[i][MacVNCRowKeyAddress] isEqualToString:currentAddress]) {
                [listenPopup selectItemWithTag:kListenTagRowBase + (NSInteger)i];
                selected = YES;
                break;
            }
        }
        if (!selected)
            [listenPopup selectItemWithTag:kListenTagLocalhost];
    } else {
        [listenPopup selectItemWithTag:kListenTagLocalhost];
    }

    NSTextField *customLabel = [NSTextField labelWithString:@"Custom address:"];
    customLabel.frame = NSMakeRect(kColLabelX, kRowCustom, 150, kRowHeight);
    customLabel.tag = kCustomAddressLabelTag;
    customLabel.toolTip = @"Editable only when 'Custom IPv4 address' is selected above.";
    NSTextField *customField = [NSTextField textFieldWithString:currentAddress];
    customField.frame = NSMakeRect(kColCtrlX, kRowCustom, 190, kRowHeight);
    customField.tag = kCustomAddressFieldTag;
    customField.toolTip = @"Local IPv4 address to bind, for example 192.168.100.87 or 100.70.214.41.";
    listenPopup.target = self;
    listenPopup.action = @selector(listenPopupChanged:);

    NSTextField *netLabel = [NSTextField labelWithString:@"Allowed clients:"];
    netLabel.frame = NSMakeRect(kColLabelX, kRowAllowed, 150, kRowHeight);
    netLabel.toolTip = @"Calculated automatically from the selected listen interface.";
    NSTextField *allowedSummary = [NSTextField labelWithString:@""];
    allowedSummary.frame = NSMakeRect(kColCtrlX, kRowAllowed, 360, kRowHeight);
    allowedSummary.tag = kAllowedSummaryTag;
    allowedSummary.textColor = NSColor.secondaryLabelColor;
    allowedSummary.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    allowedSummary.toolTip = @"No checkbox needed: localhost allows localhost, a Tailscale interface allows Tailscale clients, and a LAN interface allows that LAN.";

    NSTextField *manualLabel = [NSTextField labelWithString:@"Extra allowed clients (advanced):"];
    manualLabel.frame = NSMakeRect(kColLabelX, kRowManual, 210, kRowHeight);
    manualLabel.toolTip = @"Optional extra client IPs/subnets, one per line. Leave empty for the automatic safe policy.";
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(210, kRowScroll, 310, 56)] autorelease];
    NSTextView *allowedText = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 310, 56)] autorelease];
    allowedText.string = manualAllowed;
    allowedText.toolTip = @"Format: one IPv4 or CIDR per line. Examples: 100.101.102.103/32 or 192.168.100.0/24.";
    NSTextField *manualHint = [NSTextField labelWithString:@"Format: one IPv4/CIDR per line, e.g. 100.x.y.z/32 or 192.168.100.0/24"];
    manualHint.frame = NSMakeRect(210, kRowHint, 310, 18);
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

    *outPortField = portField;
    *outPwdField = pwdField;
    *outListenPopup = listenPopup;
    *outCustomField = customField;
    *outAllowedText = allowedText;
    return form;
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
    NSString *manualAllowed = macVNCManualAllowedText(currentAllowed, networkRows);

    NSTextField *portField = nil;
    NSSecureTextField *pwdField = nil;
    NSPopUpButton *listenPopup = nil;
    NSTextField *customField = nil;
    NSTextView *allowedText = nil;
    NSView *form = [self buildFormForPort:port password:pwd
                              currentMode:currentMode currentAddress:currentAddress
                            manualAllowed:manualAllowed networkRows:networkRows
                                portField:&portField pwdField:&pwdField
                              listenPopup:&listenPopup customField:&customField
                              allowedText:&allowedText];

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText     = @"macVNC Preferences";
    alert.informativeText = @"Changes take effect after restarting macVNC. IPv4 only in this version.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.accessoryView = form;

    if ([alert runModal] != NSAlertFirstButtonReturn)
        return;

    int newPort = portField.intValue;

    /* Decode the popup selection into (mode, address). */
    NSString *newMode = MacVNCListenModeLocalhost;
    NSString *newAddress = @"";
    NSInteger tag = listenPopup.selectedItem.tag;
    if (tag == kListenTagCustom) {
        newMode = MacVNCListenModeCustom;
        newAddress = customField.stringValue;
    } else if (tag >= kListenTagRowBase) {
        NSUInteger rowIndex = (NSUInteger)(tag - kListenTagRowBase);
        if (rowIndex < networkRows.count) {
            newMode = MacVNCListenModeSelected;
            newAddress = networkRows[rowIndex][MacVNCRowKeyAddress];
        }
    }

    /* Assemble the combined allowlist: the auto CIDR for the chosen interface
       plus any manual advanced lines, de-duplicated in order. */
    NSMutableOrderedSet<NSString *> *allowedSet = [NSMutableOrderedSet orderedSet];
    if ([newMode isEqualToString:MacVNCListenModeLocalhost]) {
        [allowedSet addObject:MacVNCLoopbackIPv4];
    } else if ([newMode isEqualToString:MacVNCListenModeSelected] && tag >= kListenTagRowBase) {
        NSUInteger rowIndex = (NSUInteger)(tag - kListenTagRowBase);
        if (rowIndex < networkRows.count)
            [allowedSet addObject:networkRows[rowIndex][MacVNCRowKeyAllowCIDR]];
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
        /* User explicitly confirmed allow-all: record it so the resolved policy
           uses ALLOW_ALL_CONFIRMED and the status label reflects reality. */
        newAllowAll = YES;
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
