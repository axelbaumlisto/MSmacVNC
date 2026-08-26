#import "MacVNCPreferences.h"
#import "MacVNCDefaultsKeys.h"
#import "MacVNCPassword.h"
#import "MacVNCNetworkRows.h"
#import "MacVNCListenMode.h"
#import "MacVNCAllowlistPlan.h"
#import "NetworkAccess.h"
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

/* Extra manual allowlist lines = stored allowlist minus ONLY the entries a
 * previous save added automatically (recorded in autoAllowedClients).
 *
 * Deliberately does NOT subtract every visible interface preset: a user may
 * legitimately type a CIDR by hand that happens to equal some other interface's
 * preset (e.g. a Tailscale subnet-router range that also matches the local LAN).
 * Subtracting those would silently delete the user's own entry on an unrelated
 * save — which, for a remote-access tool, can lock the operator out. */
static NSString *macVNCManualAllowedText(NSString *currentAllowed,
                                         NSString *previouslyAutoAdded)
{
    NSArray<NSString *> *autoAdded = macVNCTrimmedNonEmptyLines(previouslyAutoAdded ?: @"");
    NSMutableArray<NSString *> *manualLines = [NSMutableArray array];
    for (NSString *trimmed in macVNCTrimmedNonEmptyLines(currentAllowed)) {
        /* Anything WE added is recorded in autoAllowedClients - including on a
           fresh install, which now registers the loopback entry as a default.
           There used to be an extra "but 127.0.0.1 is also fine" case here; it
           existed only because that default was missing, and it silently hid a
           loopback entry the user had typed deliberately. */
        if (![autoAdded containsObject:trimmed])
            [manualLines addObject:trimmed];
    }
    return [manualLines componentsJoinedByString:@"\n"];
}

/*
 * The controls the caller reads back after the modal closes.
 *
 * Replaces five out-parameters: at that count the call site said nothing about
 * which value went where, and adding a sixth field meant touching the
 * signature, the declaration block and the assignment block in three places.
 */
@interface MacVNCPreferencesForm : NSObject
@property (nonatomic, retain) NSView *view;
@property (nonatomic, retain) NSTextField *portField;
@property (nonatomic, retain) NSSecureTextField *pwdField;
@property (nonatomic, retain) NSPopUpButton *listenPopup;
@property (nonatomic, retain) NSTextField *customField;
@property (nonatomic, retain) NSTextView *allowedText;
@end

@implementation MacVNCPreferencesForm
- (void)dealloc
{
    [_view release];
    [_portField release];
    [_pwdField release];
    [_listenPopup release];
    [_customField release];
    [_allowedText release];
    [super dealloc];
}
@end

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

/* Builds the Preferences form, populated from the given values, and returns it
 * together with the controls the caller reads back after the modal. */
- (MacVNCPreferencesForm *)buildFormForPort:(int)port
                                   password:(NSString *)pwd
                                currentMode:(NSString *)currentMode
                             currentAddress:(NSString *)currentAddress
                              manualAllowed:(NSString *)manualAllowed
                                networkRows:(NSArray<NSDictionary *> *)networkRows
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
    pwdField.toolTip = @"The VNC protocol uses only the first 8 characters (DES). "
                        "Longer passwords add no security, and changing only the part "
                        "after character 8 does not change the credential.";
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

    MacVNCPreferencesForm *result =
        [[[MacVNCPreferencesForm alloc] init] autorelease];
    result.view = form;
    result.portField = portField;
    result.pwdField = pwdField;
    result.listenPopup = listenPopup;
    result.customField = customField;
    result.allowedText = allowedText;
    return result;
}

/*
 * Decodes the listen popup's selected tag into what gets saved: the mode, the
 * bind address, and the allowlist preset that interface implies.
 *
 * The three were derived in two separate passes over the same tag, each
 * re-deriving the row index; they are one decision and belong together.
 *
 * `autoCIDR` stays nil when the interface implies no usable client network. A
 * point-to-point link's "CIDR" is the host's OWN /32, which as an allowlist
 * matches nobody and would lock every client out, so the user must name the
 * peer range explicitly.
 */
static void macVNCDecodeListenSelection(NSInteger tag,
                                        NSString *customAddress,
                                        NSArray<NSDictionary *> *networkRows,
                                        NSString **outMode,
                                        NSString **outAddress,
                                        NSString **outAutoCIDR)
{
    *outMode = MacVNCListenModeLocalhost;
    *outAddress = @"";
    *outAutoCIDR = nil;

    if (tag == kListenTagCustom) {
        *outMode = MacVNCListenModeCustom;
        *outAddress = customAddress;
        return;
    }
    if (tag < kListenTagRowBase)
        return;                     /* localhost */

    NSUInteger rowIndex = (NSUInteger)(tag - kListenTagRowBase);
    if (rowIndex >= networkRows.count)
        return;                     /* stale selection: fall back to localhost */

    NSDictionary *row = networkRows[rowIndex];
    *outMode = MacVNCListenModeSelected;
    *outAddress = row[MacVNCRowKeyAddress];
    if ([row[MacVNCRowKeyAllowPresetVisible] boolValue])
        *outAutoCIDR = row[MacVNCRowKeyAllowCIDR];
}

/* One construction site for the dialog's alerts: four near-identical NSAlert
   allocations differed only in text and buttons. Returns YES when the user chose
   the first (affirmative) button. */
static BOOL macVNCConfirm(NSString *title, NSString *body,
                          NSString *affirmative, NSString *_Nullable cancel)
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = title;
    alert.informativeText = body;
    [alert addButtonWithTitle:affirmative];
    if (cancel)
        [alert addButtonWithTitle:cancel];
    return [alert runModal] == NSAlertFirstButtonReturn;
}

static void macVNCTell(NSString *title, NSString *body)
{
    macVNCConfirm(title, body, @"OK", nil);
}

/* Writes the accepted settings. Everything above this point may still bail out;
   nothing is written until every check has passed, so a cancelled dialog cannot
   leave half a policy behind. */
static void macVNCPersistPreferences(NSUserDefaults *defaults,
                                     int port,
                                     NSString *password,
                                     NSString *mode,
                                     NSString *address,
                                     MacVNCAllowlistPlan *plan,
                                     BOOL allowAllConfirmed)
{
    /* Plaintext in defaults, by explicit request; also clears any older
       Keychain copy. */
    macVNCStorePassword(defaults, password);

    if (port > 0 && port <= 65535)
        [defaults setInteger:port forKey:MacVNCKeyPort];
    [defaults setObject:mode forKey:MacVNCKeyListenMode];
    [defaults setObject:address forKey:MacVNCKeyListenAddress];
    [defaults setObject:plan.combined forKey:MacVNCKeyAllowedClients];
    /* Remember which entries were added automatically, so the next save can
       tell them apart from user-typed ones and drop only the stale ones. */
    [defaults setObject:[plan.autoAdded componentsJoinedByString:@"\n"]
                 forKey:MacVNCKeyAutoAllowedClients];
    [defaults setBool:allowAllConfirmed forKey:MacVNCKeyAllowAllConfirmed];
    [defaults synchronize];
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
    NSString *manualAllowed = macVNCManualAllowedText(
        currentAllowed, [defaults stringForKey:MacVNCKeyAutoAllowedClients]);

    MacVNCPreferencesForm *form =
        [self buildFormForPort:port password:pwd
                   currentMode:currentMode currentAddress:currentAddress
                 manualAllowed:manualAllowed networkRows:networkRows];

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText     = @"macVNC Preferences";
    alert.informativeText = @"Changes take effect after restarting macVNC. IPv4 only in this version.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.accessoryView = form.view;

    if ([alert runModal] != NSAlertFirstButtonReturn)
        return;

    int newPort = form.portField.intValue;

    NSString *newMode = nil, *newAddress = nil, *autoCIDR = nil;
    macVNCDecodeListenSelection(form.listenPopup.selectedItem.tag,
                                form.customField.stringValue,
                                networkRows, &newMode, &newAddress, &autoCIDR);

    MacVNCAllowlistPlan *plan =
        macVNCPlanAllowlist(newMode, autoCIDR, form.allowedText.string);

    if (plan.verdict == MacVNCAllowlistVerdictAdmitsNobody) {
        macVNCTell(@"No clients would be allowed",
                   @"The selected interface does not imply a client network (for "
                   @"example a point-to-point VPN link), and no extra allowed "
                   @"clients were entered. Add the peer IP or subnet under "
                   @"\u201cExtra allowed clients\u201d.");
        return;
    }

    BOOL newAllowAll = NO;
    if (plan.verdict == MacVNCAllowlistVerdictAdmitsEveryone) {
        if (!macVNCConfirm(@"Allow all clients?",
                           @"This allowlist contains an entry that matches every "
                           @"IPv4 client that can reach macVNC (a /0 prefix). This "
                           @"is unsafe outside a trusted VPN.",
                           @"Continue", @"Cancel"))
            return;
        /* Recorded so the resolved policy uses ALLOW_ALL_CONFIRMED and the
           status label reflects reality. */
        newAllowAll = YES;
    }

    NSString *combinedAllowed = plan.combined;

    MacVNCPolicyInput input = {
        .listenMode = newMode.UTF8String,
        .listenAddress = newAddress.UTF8String,
        .allowedClients = combinedAllowed.UTF8String,
        .allowAllConfirmed = newAllowAll,
    };
    MacVNCResolvedPolicy resolved;
    if (!macVNCResolveNetworkPolicy(&input, NULL, &resolved)) {
        macVNCTell(@"Invalid network policy",
                   [NSString stringWithUTF8String:resolved.error]);
        return;
    }

    /* The RFB DES auth only uses the first 8 characters. Tell the user rather
       than silently truncating their "long" password's security to 8 bytes. */
    NSString *trimmedPwd = [form.pwdField.stringValue stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    /* DES truncates BYTES, not characters: an 8-character password can still be
       cut mid-way if it contains non-ASCII (é = 2 bytes, emoji = 4). Measure the
       UTF-8 byte length so the warning is accurate for any input. */
    NSUInteger passwordBytes = [trimmedPwd lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (passwordBytes > MACVNC_VNC_PASSWORD_EFFECTIVE_MAX) {
        NSString *body = [NSString stringWithFormat:
            @"The VNC protocol derives its key from the first %d BYTES (DES). "
            @"Your password is %lu bytes, so the rest is ignored \u2014 and changing only "
            @"the part after byte %d would NOT change the credential.\n\n"
            @"Note: non-ASCII characters take more than one byte (é = 2, emoji = 4).\n\n"
            @"Save anyway, or go back and choose a different first %d bytes?",
            MACVNC_VNC_PASSWORD_EFFECTIVE_MAX, (unsigned long)passwordBytes,
            MACVNC_VNC_PASSWORD_EFFECTIVE_MAX, MACVNC_VNC_PASSWORD_EFFECTIVE_MAX];
        if (!macVNCConfirm(@"Only the first 8 bytes of the password are used",
                           body, @"Save anyway", @"Cancel"))
            return;
    }

    macVNCPersistPreferences(defaults, newPort, form.pwdField.stringValue,
                             newMode, newAddress, plan, newAllowAll);
}

@end
