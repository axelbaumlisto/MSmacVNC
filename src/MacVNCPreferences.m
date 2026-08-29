#import "MacVNCPreferences.h"

#include "CaptureRate.h"
#include "MacVNCEncryptionPolicy.h"
#include "MacVNCImageProfile.h"
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
static const CGFloat kFormHeight  = 402;
static const CGFloat kColLabelX   = 0;
static const CGFloat kColCtrlX    = 160;
static const CGFloat kRowHeight   = 22;
static const CGFloat kRowPort     = 372;
static const CGFloat kRowListen   = 336;
static const CGFloat kRowCustom   = 306;
static const CGFloat kRowAllowed  = 276;
static const CGFloat kRowManual   = 242;
static const CGFloat kRowScroll   = 208;
static const CGFloat kRowHint     = 184;
/* Performance rows sit below the network block: they are the settings people
   revisit, and they must not push the allowlist off the top of the sheet. */
static const CGFloat kRowFrameRate = 158;
static const CGFloat kRowQuality   = 132;
static const CGFloat kRowEncrypt   = 106;
/* Curtain mode sits at the bottom, alone, with room for the help text that has
   to say what it does, what it does NOT do (it hides the screen; it does not
   lock the Mac), WHEN it starts doing it (the next connection, not this one)
   and what has not been verified (the blackout on a second display). A
   one-line tooltip could not carry that, and every one of those sentences is
   there because leaving it out would leave a false impression. */
static const CGFloat kRowCurtain     = 80;
static const CGFloat kRowCurtainHelp = 0;
static const CGFloat kCurtainHelpHeight = 76;

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
/*
 * What the window is opened WITH.
 *
 * The builder had grown to eight parameters, which is the same problem this
 * file already solved once for its outputs: at that count a call site says
 * nothing about which value goes where, and adding a setting means editing a
 * signature, a declaration block and an assignment block in three places.
 */
typedef struct {
    int port;
    __unsafe_unretained NSString *password;
    __unsafe_unretained NSString *listenMode;
    __unsafe_unretained NSString *listenAddress;
    __unsafe_unretained NSString *manualAllowed;
    __unsafe_unretained NSArray<NSDictionary *> *networkRows;
    int captureFPS;
    __unsafe_unretained NSString *imageProfileName;
    __unsafe_unretained NSString *encryptionName;
    BOOL curtainEnabled;
} MacVNCPreferencesValues;

@interface MacVNCPreferencesForm : NSObject
@property (nonatomic, retain) NSView *view;
@property (nonatomic, retain) NSTextField *portField;
@property (nonatomic, retain) NSSecureTextField *pwdField;
@property (nonatomic, retain) NSPopUpButton *listenPopup;
@property (nonatomic, retain) NSTextField *customField;
@property (nonatomic, retain) NSTextView *allowedText;
@property (nonatomic, retain) NSPopUpButton *frameRatePopup;
@property (nonatomic, retain) NSPopUpButton *imageQualityPopup;
@property (nonatomic, retain) NSPopUpButton *encryptionPopup;
@property (nonatomic, retain) NSButton *curtainCheckbox;
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
    [_frameRatePopup release];
    [_imageQualityPopup release];
    [_encryptionPopup release];
    [_curtainCheckbox release];
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
- (MacVNCPreferencesForm *)buildFormWithValues:(MacVNCPreferencesValues)values
{
    const int port = values.port;
    NSString *pwd = values.password;
    NSString *currentMode = values.listenMode;
    NSString *currentAddress = values.listenAddress;
    NSString *manualAllowed = values.manualAllowed;
    NSArray<NSDictionary *> *networkRows = values.networkRows;

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

    /* Performance: one universal frame rate (there is one capture stream per
       display shared by every viewer, so it cannot be per-connection) and one
       image-quality ladder whose entries are measured, not a marketing scale.
       Level 5 delivers MORE frames than level 7 - fewer bytes means less
       encode and less transfer - so the items are labelled by what they
       trade. */
    NSTextField *rateLabel = [NSTextField labelWithString:@"Frame rate:"];
    rateLabel.frame = NSMakeRect(kColLabelX, kRowFrameRate + 2, 150, kRowHeight);
    rateLabel.toolTip = @"How often each display is captured. Higher is smoother "
                        "and costs CPU; it is shared by every connected viewer.";
    NSPopUpButton *ratePopup = [[[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(kColCtrlX, kRowFrameRate, 360, 26) pullsDown:NO] autorelease];
    for (size_t i = 0; i < macVNCCaptureRateLadderCount(); ++i) {
        [ratePopup addItemWithTitle:@(macVNCCaptureRateLadderTitle(i))];
        ratePopup.lastItem.tag = macVNCCaptureRateLadderValue(i);
    }
    /* A rate set outside this list (by hand, or by a future default) must not
       silently become one of these - show it rather than lie about it. */
    if (![ratePopup selectItemWithTag:values.captureFPS]) {
        [ratePopup addItemWithTitle:[NSString stringWithFormat:@"Custom - %d fps",
                                                              values.captureFPS]];
        ratePopup.lastItem.tag = values.captureFPS;
        [ratePopup selectItemWithTag:values.captureFPS];
    }

    NSTextField *qualityLabel = [NSTextField labelWithString:@"Image quality:"];
    qualityLabel.frame = NSMakeRect(kColLabelX, kRowQuality + 2, 150, kRowHeight);
    qualityLabel.toolTip = @"Higher quality sends more data. Measured on this Mac: "
                           "level 0 uses about a third of the bandwidth of lossless.";
    NSPopUpButton *qualityPopup = [[[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(kColCtrlX, kRowQuality, 360, 26) pullsDown:NO] autorelease];
    /* Tags are indices into the ladder that MacVNCImageProfile owns, so the
       popup and the stored NAME cannot drift apart - this list used to exist
       here AND in the save path. */
    NSInteger selectedQuality = -1;
    for (size_t i = 0; i < macVNCImageProfileLadderCount(); ++i) {
        [qualityPopup addItemWithTitle:@(macVNCImageProfileLadderTitle(i))];
        qualityPopup.lastItem.tag = (NSInteger)i;
        if (!strcmp(macVNCImageProfileLadderName(i), values.imageProfileName.UTF8String))
            selectedQuality = (NSInteger)i;
    }
    if (selectedQuality < 0) {
        /* Stored value is not on the ladder (hand-edited, or a level we stopped
           offering): fall back to the default rather than preselecting whatever
           happens to be first. */
        MacVNCImageProfile fallback = macVNCDefaultImageProfile();
        for (size_t i = 0; i < macVNCImageProfileLadderCount(); ++i)
            if (!strcmp(macVNCImageProfileLadderName(i),
                        macVNCImageProfileName(fallback)))
                selectedQuality = (NSInteger)i;
    }
    [qualityPopup selectItemWithTag:selectedQuality];

    /* Encryption is a SERVER policy, not a per-viewer preference: the client
       picks the security type, and it always picks the unencrypted one, so
       refusing is the only reliable lever. */
    NSTextField *encryptLabel = [NSTextField labelWithString:@"Encryption:"];
    encryptLabel.frame = NSMakeRect(kColLabelX, kRowEncrypt + 2, 150, kRowHeight);
    encryptLabel.toolTip = @"macVNC always offers TLS, but the viewer chooses, and "
                            "most viewers choose the unencrypted path. Requiring "
                            "encryption refuses viewers that will not use TLS.";
    NSPopUpButton *encryptPopup = [[[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(kColCtrlX, kRowEncrypt, 360, 26) pullsDown:NO] autorelease];
    NSInteger selectedEncryption = 0;
    for (size_t i = 0; i < macVNCEncryptionLadderCount(); ++i) {
        [encryptPopup addItemWithTitle:@(macVNCEncryptionLadderTitle(i))];
        encryptPopup.lastItem.tag = (NSInteger)i;
        if (!strcmp(macVNCEncryptionLadderName(i), values.encryptionName.UTF8String))
            selectedEncryption = (NSInteger)i;
    }
    [encryptPopup selectItemWithTag:selectedEncryption];

    /* Curtain mode. The help text below the checkbox is not decoration: this
       is the only setting whose whole point is that the person at the Mac
       stops seeing their own screen, so the words have to say exactly what is
       true - the screen is hidden, local input is swallowed, the VNC password
       typed HERE lifts it, and the Mac is NOT locked. Claiming a lock would be
       the one lie that could get someone to walk away from an unlocked
       machine. */
    NSButton *curtainCheckbox =
        [NSButton checkboxWithTitle:@"Hide this Mac\u2019s screen while a viewer is connected"
                             target:nil
                             action:NULL];
    curtainCheckbox.frame = NSMakeRect(kColLabelX, kRowCurtain, kFormWidth, kRowHeight);
    curtainCheckbox.state = values.curtainEnabled ? NSControlStateValueOn
                                                  : NSControlStateValueOff;
    curtainCheckbox.toolTip = @"Off by default: the curtain goes up when a viewer "
                               "connects, so anyone holding the VNC password can "
                               "hide the screen from the person at this Mac.";
    /* EDGE-TRIGGERED, AND THE WORDS HAVE TO SAY SO. The controller raises only
       on the transition to a FIRST authenticated client (rule 1), so ticking
       this box while somebody is already connected hides nothing until the
       next connection - "while a viewer is connected" promised a level rule
       the code deliberately does not implement, because a level rule would
       re-raise the curtain the instant the local user typed it away. And the
       local lift latches for the rest of the APP RUN, not "the session": that
       is what stops whoever holds the password from re-blinding the local user
       by reconnecting in a loop.

       THE LAST SENTENCE IS THERE BECAUSE A LIVE RUN EARNED IT. On a
       multi-display desk the raise's own audit reported every screen covered
       while part of the desktop was still visible on a second display, and
       that has not been explained or re-measured since. Until it is, this is
       the one thing about the feature we may not overstate. */
    NSTextField *curtainHelp = [NSTextField wrappingLabelWithString:
        @"From the next viewer connection onward, this Mac\u2019s screen is hidden "
        @"and local keyboard and pointer input are blocked; turning this on while "
        @"a viewer is already connected changes nothing until they reconnect. "
        @"Typing the VNC password on this Mac lifts it until macVNC is restarted. "
        @"The Mac itself stays unlocked, and Accessibility permission is required "
        @"or the curtain refuses to go up. NOT VERIFIED ON MULTI-DISPLAY SETUPS: "
        @"a live run showed the curtain reporting every screen covered while part "
        @"of the desktop was still visible on a second display."];
    curtainHelp.frame = NSMakeRect(kColLabelX, kRowCurtainHelp, kFormWidth, kCurtainHelpHeight);
    curtainHelp.textColor = NSColor.secondaryLabelColor;
    curtainHelp.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];

    [form addSubview:curtainCheckbox]; [form addSubview:curtainHelp];

    [form addSubview:rateLabel]; [form addSubview:ratePopup];
    [form addSubview:qualityLabel]; [form addSubview:qualityPopup];
    [form addSubview:encryptLabel]; [form addSubview:encryptPopup];

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
    result.frameRatePopup = ratePopup;
    result.imageQualityPopup = qualityPopup;
    result.encryptionPopup = encryptPopup;
    result.curtainCheckbox = curtainCheckbox;
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
                                     BOOL allowAllConfirmed,
                                     int captureFPS,
                                     NSString *imageProfileName,
                                     NSString *encryptionName,
                                     BOOL curtainEnabled)
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

    /* Validated here as well as at startup: a popup should never be able to
       store a value the server would have to reject on the next launch. */
    if (captureFPS >= MACVNC_CAPTURE_FPS_MIN && captureFPS <= MACVNC_CAPTURE_FPS_MAX)
        [defaults setInteger:captureFPS forKey:MacVNCKeyCaptureFPS];
    MacVNCImageProfile parsedProfile;
    if (macVNCParseImageProfile(imageProfileName.UTF8String, &parsedProfile))
        [defaults setObject:imageProfileName forKey:MacVNCKeyImageProfile];
    MacVNCEncryptionPolicy parsedEncryption;
    if (macVNCParseEncryptionPolicy(encryptionName.UTF8String, &parsedEncryption))
        [defaults setObject:encryptionName forKey:MacVNCKeyEncryption];

    /* Unlike every other setting here, this one takes effect WITHOUT a restart:
       AppDelegate observes the defaults change, so switching it off while the
       curtain is up brings the screen back rather than waiting for the next
       launch. That direction is the one that must not be deferred. */
    [defaults setBool:curtainEnabled forKey:MacVNCKeyCurtain];

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
    int captureFPS = (int)[defaults integerForKey:MacVNCKeyCaptureFPS];
    if (captureFPS < MACVNC_CAPTURE_FPS_MIN || captureFPS > MACVNC_CAPTURE_FPS_MAX)
        captureFPS = MACVNC_CAPTURE_FPS_DEFAULT;
    NSString *imageProfileName = [defaults stringForKey:MacVNCKeyImageProfile]
                                 ?: @(MACVNC_IMAGE_PROFILE_DEFAULT_NAME);
    NSString *encryptionName = [defaults stringForKey:MacVNCKeyEncryption]
                               ?: @(MACVNC_ENCRYPTION_DEFAULT_NAME);
    BOOL curtainEnabled = [defaults boolForKey:MacVNCKeyCurtain];
    NSArray<NSDictionary *> *networkRows = macVNCActiveNetworkRows();
    NSString *manualAllowed = macVNCManualAllowedText(
        currentAllowed, [defaults stringForKey:MacVNCKeyAutoAllowedClients]);

    MacVNCPreferencesValues values = {
        .port = port,
        .password = pwd,
        .listenMode = currentMode,
        .listenAddress = currentAddress,
        .manualAllowed = manualAllowed,
        .networkRows = networkRows,
        .captureFPS = captureFPS,
        .imageProfileName = imageProfileName,
        .encryptionName = encryptionName,
        .curtainEnabled = curtainEnabled,
    };
    MacVNCPreferencesForm *form = [self buildFormWithValues:values];

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText     = @"macVNC Preferences";
    alert.informativeText = @"Changes take effect after restarting macVNC. IPv4 only in this version.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.accessoryView = form.view;

    if ([alert runModal] != NSAlertFirstButtonReturn)
        return;

    int newPort = form.portField.intValue;

    /* Popup tags are ladder indices, so nothing has to re-derive a value from
       the visible titles - and the ladder has exactly one definition. */
    int newCaptureFPS = (int)form.frameRatePopup.selectedItem.tag;
    const char *ladderName =
        macVNCImageProfileLadderName((size_t)form.imageQualityPopup.selectedItem.tag);
    NSString *newImageProfile = ladderName ? @(ladderName)
                                           : @(MACVNC_IMAGE_PROFILE_DEFAULT_NAME);
    const char *encryptionLadderName =
        macVNCEncryptionLadderName((size_t)form.encryptionPopup.selectedItem.tag);
    NSString *newEncryption = encryptionLadderName
                                  ? @(encryptionLadderName)
                                  : @(MACVNC_ENCRYPTION_DEFAULT_NAME);

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
                             newMode, newAddress, plan, newAllowAll,
                             newCaptureFPS, newImageProfile, newEncryption,
                             form.curtainCheckbox.state == NSControlStateValueOn);
}

@end
