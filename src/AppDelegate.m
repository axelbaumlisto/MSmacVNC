/* memset_s, so the wipe of the stack copy of the password below cannot be
   optimised away as a dead store. Must precede every include: <string.h>
   declares it only when this is already defined. */
#define __STDC_WANT_LIB_EXT1__ 1

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
#import "MacVNCCurtainController.h"
#import "MacVNCCurtainInput.h"
#import "MacVNCCurtainWindow.h"
#include <string.h>
#include <unistd.h>

/* -----------------------------------------------------------------------
 * Curtain mode: the glue that finally constructs it.
 *
 * Every decision about WHEN the curtain may be up lives in
 * MacVNCCurtainController, every decision about the screen in
 * MacVNCCurtainWindow and every decision about local input in
 * MacVNCCurtainInput. What is left here is the part only this file can do:
 * saying which secret, which clients, which session events - and doing so
 * WITHOUT changing anything while the preference is off, which is the shipped
 * default. With it off, the objects below exist and answer questions; no tap
 * is created, no window is allocated, no capture filter is touched, and the
 * server behaves exactly as it did before this file grew this section.
 * ----------------------------------------------------------------------- */

/*
 * The secret the escape hatch is armed with.
 *
 * It is deliberately the password the RUNNING server authenticates against,
 * read back from the core, and not the one in NSUserDefaults: the two differ
 * whenever the password came from MACVNC_PASSWORD_FILE, and whenever it was
 * changed in Preferences without a restart. Arming the curtain
 * with a password the server does not accept would mean the curtain the remote
 * party raised could not be typed away - the exact lockout this whole feature
 * is shaped around avoiding.
 */
@interface MacVNCRunningServerSecret : NSObject <MacVNCCurtainSecretSource>
@end

@implementation MacVNCRunningServerSecret

- (NSData *)copyCurtainSecret
{
    /* Comfortably larger than anything a VNC password can usefully be (DES
       keys itself from 8 bytes); an over-long one is refused by the core
       rather than truncated here. */
    char password[256];
    size_t length = vncServerCopyPassword(password, sizeof(password));
    /* MUTABLE on purpose: this is a cleartext copy of the password, made once
       per heartbeat while the curtain is up, and macVNCCurtainDiscardSecret()
       wipes it before releasing it. Handing back an immutable NSData would
       leave a readable copy in the heap for the allocator to recycle. */
    NSMutableData *secret = length > 0
                                ? [[NSMutableData alloc] initWithBytes:password
                                                                length:length]
                                : nil;
    /* memset_s, NOT memset: nothing reads `password` after this point, so a
       plain memset is a dead store the optimiser is free to delete - leaving
       the cleartext password in a stack frame that the next call reuses.
       memset_s is the one form the standard forbids eliding. (The heap copy
       needs no such care: macVNCCurtainDiscardSecret writes through
       -mutableBytes, an opaque pointer the compiler cannot prove is dead.) */
    memset_s(password, sizeof(password), 0, sizeof(password));
    return secret;    /* +1: the `copy` in the selector is the ownership rule */
}

@end

/*
 * The one-way back reference that keeps the tap and the controller from owning
 * each other.
 *
 * The controller RETAINS its input suppression, and MacVNCCurtainInput retains
 * its observer - so wiring the controller in as the observer directly would be
 * a retain cycle, and the tap would outlive the app's ability to tear it down.
 * The construction order forces the same shape anyway: the input has to exist
 * before the controller can be built with it, and the controller has to exist
 * before it can be observed.
 *
 * That the observer forwards to the controller is not a detail. Rule 7 of
 * MacVNCCurtainInput.h hands the keyboard focus to the curtain window when
 * secure input turns on, and that hand-over LATCHES; it is safe only because
 * the observer LIFTS synchronously in the same main-queue block, ending
 * suppression and giving the focus straight back. An observer that kept the
 * curtain up across secure input would leave the curtain window key, where
 * -keyDown: drops self-injected events - the REMOTE viewer's keyboard would go
 * dead while their mouse kept working. -setSecureInputActive: on the
 * controller lifts, and so does -noteInputSuppressionUnavailable.
 */
@interface MacVNCCurtainObserverBridge : NSObject <MacVNCCurtainInputObserver>
@property (nonatomic, assign) MacVNCCurtainController *controller;  /* not retained */
@end

@implementation MacVNCCurtainObserverBridge

- (void)noteLocalUnlockAccepted
{
    [_controller noteLocalUnlockAccepted];
}

- (void)setSecureInputActive:(BOOL)active
{
    [_controller setSecureInputActive:active];
}

- (void)noteInputSuppressionUnavailable
{
    [_controller noteInputSuppressionUnavailable];
}

@end

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
@property (nonatomic, retain) MacVNCPermissionsPanelController *permissionsPanel;
@property (nonatomic, assign) BOOL           relaunchScheduled;

/* Serial queue owning every server start/stop (see applicationDidFinishLaunching). */
@property (nonatomic, strong) dispatch_queue_t lifecycleQueue;

/* The generation whose capture failure we already acted on (see
   macVNCShouldActOnCaptureFailure). */
@property (nonatomic, assign) uint64_t handledFailureGeneration;

/* Curtain mode. The controller owns the curtain, the tap and the clock; this
   object owns the controller and the bridge that lets the tap talk back. */
@property (nonatomic, retain) MacVNCCurtainController *curtainController;
@property (nonatomic, retain) MacVNCCurtainObserverBridge *curtainObserver;
/* The three ways the local session stops being a place the curtain may cover,
   tracked separately because they start and stop independently: the screens
   can wake while the screensaver is still running, and a session can be
   switched away from and back with neither of the other two moving. The
   controller wants one answer, and it is the AND of all three. */
@property (nonatomic, assign) BOOL screensaverActive;
@property (nonatomic, assign) BOOL screensAsleep;
@property (nonatomic, assign) BOOL sessionResigned;

@end


static AppDelegate *gSharedAppDelegate = nil;

/* The server core asks before touching capture. Answered without prompting:
   CGPreflight never raises a dialog, and this app must never cause one. */
static bool macVNCCaptureAllowed_(void)
{
    return macVNCCheckPermission(MacVNCPermissionKindScreenRecording) ==
           MacVNCPermissionStatusGranted;
}

/* The one place that knows how "running" is determined. */
static BOOL macVNCServerIsRunning_(void)
{
    return vncServerGetPort() > 0;
}

/* The authenticated client count moved. Raised on client threads (and from the
   stop path, with the lifecycle lock held), so it must do nothing but hand the
   question to the main queue, which is where every curtain decision is made.
   A nil delegate makes this a no-op, which is what a server running without
   the app around wants. */
static void macVNCAuthenticatedClientsChanged_(void)
{
    /* The LibVNCServer client threads are plain pthreads with no pool of their
       own - this hook is the first thing on that path to enter the Objective-C
       runtime, and anything it autoreleases would otherwise be leaked (and
       announced as "autoreleased with no pool in place"). */
    @autoreleasepool {
        [gSharedAppDelegate performSelectorOnMainThread:@selector(refreshCurtainState)
                                             withObject:nil
                                          waitUntilDone:NO];
    }
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
    /* ALL server start/stop work runs on this ONE serial queue. It used to be
       three dispatches onto the CONCURRENT global queue, where a user's Start
       could win serverLifecycleMutex ahead of an in-flight stop, hear "already
       running", and then watch that stop tear the server down: the explicit
       request silently swallowed, the UI none the wiser. Serialised here, a
       Start pressed during a stop is simply queued behind it. */
    dispatch_queue_t q = dispatch_queue_create("net.christianbeier.macVNC.lifecycle",
                                                DISPATCH_QUEUE_SERIAL);
    self.lifecycleQueue = q;
    [q release]; /* the property holds its own retain */
    macVNCScreenCaptureFailureHandler = macVNCScreenCaptureFailed;
    macVNCCaptureAllowed = macVNCCaptureAllowed_;
    macVNCAuthenticatedClientsChangedHandler = macVNCAuthenticatedClientsChanged_;
    macVNCPermissionUIServerRunningProvider = macVNCServerIsRunning_;
    macVNCRegisterDefaults();
    [self setupCurtainMode];
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

    /* FIRST, and before anything that can block: this is what takes the black
       windows off every display and stops swallowing local input. The stop
       below waits up to 8 s, and spending those 8 s behind a curtain would be
       8 s in which the person at the Mac has neither screen nor keyboard while
       the app is on its way out. */
    [self.curtainController noteApplicationWillTerminate];
    self.curtainObserver.controller = nil;

    /* Stop OFF the main thread, then wait bounded: vncServerStop() joins client
       threads and waits for capture work that may sit behind a prompt (up to 5 s
       per display). Blocking the main thread here re-introduced exactly the
       freeze vncServerCloseListeners() was written to avoid on the Restart path.
       The process is about to exit anyway; the kernel reclaims anything we time
       out on. */
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    dispatch_async(self.lifecycleQueue, ^{
        vncServerStop();
        dispatch_group_leave(group);
    });
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 8LL * NSEC_PER_SEC));
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    _curtainObserver.controller = nil;
    [_curtainObserver release];
    [_curtainController release];
    [_updateTimer invalidate];
    [_statusItem release];
    [_statusMenuItem release];
    [_clientsMenuItem release];
    [_loginItemMenuItem release];
    [_permissionsPanel release];
    [_screenPermissionMenuItem release];
    [_lifecycleQueue release];
    [_accessibilityPermissionMenuItem release];
    [_updateTimer release];
    if (gSharedAppDelegate == self)
        gSharedAppDelegate = nil;
    [super dealloc];
}

/* -----------------------------------------------------------------------
 * Curtain mode
 * ----------------------------------------------------------------------- */

/*
 * Builds the three objects and subscribes to everything that can lift.
 *
 * Nothing here starts anything: MacVNCCurtain allocates no window until it is
 * raised, MacVNCCurtainInput creates no event tap until suppression begins,
 * and the controller cannot raise while the preference is off - which is the
 * default. So with curtain mode switched off this method costs three
 * allocations and a handful of notification registrations, and changes no
 * observable behaviour of the server.
 */
- (void)setupCurtainMode
{
    /* ONE curtain object, because its window set is also the tap's focus seam:
       the window the local user may type into while the tap path is
       unavailable has to be a window somebody actually shows. */
    MacVNCCurtain *curtain = [MacVNCCurtain curtainWithDefaultSeams];
    MacVNCRunningServerSecret *secret =
        [[[MacVNCRunningServerSecret alloc] init] autorelease];
    MacVNCCurtainObserverBridge *observer =
        [[[MacVNCCurtainObserverBridge alloc] init] autorelease];
    self.curtainObserver = observer;

    MacVNCCurtainInput *input =
        [MacVNCCurtainInput inputWithDefaultSeamsFocus:curtain.windowSet
                                             observer:observer
                                         secretSource:secret];
    self.curtainController =
        [MacVNCCurtainController controllerWithDefaultSeamsCurtain:curtain
                                                 inputSuppression:input
                                                     secretSource:secret];
    observer.controller = self.curtainController;

    /* Saving in Preferences writes defaults, so this is how "switched off"
       reaches the curtain WITHOUT waiting for a restart - the one setting in
       this app that must take effect at once, because the person it affects
       cannot see their screen while it is on. */
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(defaultsChanged:)
               name:NSUserDefaultsDidChangeNotification
             object:nil];

    /* Display sleep and fast user switching. Both mean the local half of the
       curtain is no longer covering what the local user is looking at. */
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(screensDidSleep:)
                      name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(screensDidWake:)
                      name:NSWorkspaceScreensDidWakeNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionDidResignActive:)
                      name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [workspace addObserver:self selector:@selector(sessionDidBecomeActive:)
                      name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];

    /* The screensaver announces itself only on the distributed centre; there is
       no NSWorkspace equivalent. Observing it needs no permission and raises no
       dialog. */
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(screensaverDidStart:)
               name:@"com.apple.screensaver.didstart" object:nil];
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(screensaverDidStop:)
               name:@"com.apple.screensaver.didstop" object:nil];

    [self refreshCurtainState];
}

/*
 * Everything the curtain's decision depends on that this object can observe,
 * re-stated as it is right now.
 *
 * Deliberately level-triggered and idempotent: the controller turns it into
 * the ONE edge that raises (0 -> non-zero authenticated clients) and treats
 * everything else as a reason to lift, so re-asserting the same values costs
 * nothing and a missed notification is corrected by the next call. Called from
 * the client-count hook, from the 2 s menu timer and after a start.
 *
 * ORDER MATTERS: the preference and the server flag can only refuse, and the
 * client count carries the raise edge, so the count goes last - against
 * conditions that have already been brought up to date.
 */
- (void)refreshCurtainState
{
    MacVNCCurtainController *controller = self.curtainController;
    if (!controller)
        return;
    [controller setCurtainPreferenceEnabled:
        [NSUserDefaults.standardUserDefaults boolForKey:MacVNCKeyCurtain]];
    [controller setServerRunning:vncServerGetPort() > 0];
    /* The NARROWER count, not vncConnectedClients: this method is called on a
       2 s timer as well as on the core's notification, so reading the count
       that moves at password-accept time would raise the curtain DURING the
       first-frame wait - the local screen black while the remote viewer still
       has a placeholder, which is exactly what waiting for frames exists to
       prevent. */
    int clients = vncAuthenticatedClientsReceivingUpdates;
    [controller setAuthenticatedClientCount:clients > 0 ? (NSUInteger)clients : 0];
}

- (void)defaultsChanged:(NSNotification *)notification
{
    (void)notification;
    /* Posted synchronously on whichever thread wrote a default; every curtain
       method is main-thread only. */
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self defaultsChanged:nil];
        });
        return;
    }
    [self refreshCurtainState];
    /* A saved password does not change what the RUNNING server accepts, so
       this usually decides nothing - but a server restarted in between
       installs a new one, and a curtain armed with the old secret must come
       down rather than stay up with an escape hatch that no longer opens it. */
    [self.curtainController noteSecretMayHaveChanged];
}

/* One answer out of three independent facts (see the properties). */
- (void)refreshCurtainLocalSession
{
    BOOL usable = !(self.screensaverActive || self.screensAsleep ||
                    self.sessionResigned);
    [self.curtainController setLocalSessionActive:usable];
}

- (void)screensDidSleep:(NSNotification *)notification
{
    (void)notification;
    self.screensAsleep = YES;
    [self refreshCurtainLocalSession];
}

- (void)screensDidWake:(NSNotification *)notification
{
    (void)notification;
    self.screensAsleep = NO;
    [self refreshCurtainLocalSession];
}

- (void)sessionDidResignActive:(NSNotification *)notification
{
    (void)notification;
    self.sessionResigned = YES;
    [self refreshCurtainLocalSession];
}

- (void)sessionDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    self.sessionResigned = NO;
    [self refreshCurtainLocalSession];
}

- (void)screensaverDidStart:(NSNotification *)notification
{
    (void)notification;
    self.screensaverActive = YES;
    [self refreshCurtainLocalSession];
}

- (void)screensaverDidStop:(NSNotification *)notification
{
    (void)notification;
    self.screensaverActive = NO;
    [self refreshCurtainLocalSession];
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

/* One construction site for menu rows: eleven near-identical NSMenuItem
   allocations differed only in title, action and key, and each repetition was
   a chance to forget the target (a nil target silently disables the row). */
static NSMenuItem *addRow(NSMenu *menu, NSString *title, SEL action,
                          NSString *key, id target)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:key ?: @""] autorelease];
    if (action)
        item.target = target;
    else
        item.enabled = NO; /* informational row */
    [menu addItem:item];
    return item;
}

- (void)buildMenu
{
    NSMenu *menu = [[[NSMenu alloc] init] autorelease];
    /* We set item.enabled ourselves; with the default YES AppKit would recompute
       enablement from the responder chain and could grey out our rows. */
    menu.autoenablesItems = NO;

    NSMenuItem *titleItem = addRow(menu, @"macVNC", nil, nil, self);
    titleItem.attributedTitle = [[[NSAttributedString alloc]
        initWithString:@"macVNC"
            attributes:@{NSFontAttributeName:
                             [NSFont boldSystemFontOfSize:NSFont.systemFontSize]}] autorelease];

    self.statusMenuItem  = addRow(menu, @"Starting…", nil, nil, self);
    self.clientsMenuItem = addRow(menu, @"No clients connected", nil, nil, self);

    /* Permission rows — the menu-bar equivalent of clipshot's banner.

       An accessory app has no window to host a banner, so the menu is the only
       always-reachable surface. Both rows are driven by the SAME resolver that
       renders the panel, so the two surfaces cannot disagree. They stay hidden
       while everything is granted (clipshot returns null in that case). */
    self.screenPermissionMenuItem =
        addRow(menu, @"", @selector(openScreenRecordingSettings:), nil, self);
    self.accessibilityPermissionMenuItem =
        addRow(menu, @"", @selector(openAccessibilitySettings:), nil, self);

    [menu addItem:[NSMenuItem separatorItem]];

    addRow(menu, @"Copy VNC Address", @selector(copyVNCAddress:), @"c", self);
    /* Permanent recovery affordance: the server can always be (re)started from
       the menu, so no dialog path can leave the app permanently stopped. */
    addRow(menu, @"Start Server", @selector(startServerFromMenu:), nil, self);
    addRow(menu, @"Permissions…", @selector(showPermissionsPanel), nil, self);
    addRow(menu, @"Preferences…", @selector(openPreferences:), @",", self);

    [menu addItem:[NSMenuItem separatorItem]];

    self.loginItemMenuItem =
        addRow(menu, @"Start at Login", @selector(toggleLoginItem:), nil, self);
    self.loginItemMenuItem.state = MacVNCLoginItem.isEnabled
                                       ? NSControlStateValueOn
                                       : NSControlStateValueOff;

    [menu addItem:[NSMenuItem separatorItem]];

    /* Quit targets the application, not us: nil target means "first responder",
       which for terminate: is NSApp. */
    addRow(menu, @"Quit macVNC", @selector(terminate:), @"q", nil);

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
        dispatch_async(self.lifecycleQueue, ^{
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
    MacVNCPermissionUIInput input = macVNCSamplePermissionUI();
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
    if (macVNCServerIsRunning_())
        return; /* already running */
    [self startServerIfPermitted];
}

- (void)showPermissionsPanel
{
    if (self.permissionsPanel) {
        /* Already up — re-front it instead of refusing. An accessory app has no
           Dock icon, so a buried panel would otherwise be unreachable. */
        [self.permissionsPanel bringToFront];
        return;
    }
    /* Let the single renderer own the text: writing a status string by hand here
       claimed "permissions required" even when the server was running, and the
       2 s timer silently corrected it moments later. */
    [self updateMenuStatus];

    MacVNCPermissionsPanelController *controller =
        [[[MacVNCPermissionsPanelController alloc] init] autorelease];
    self.permissionsPanel = controller;
    [controller presentWithCompletion:^(MacVNCPermissionPanelAction action) {
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
    /* BEFORE the generation filter, and unconditionally: this is the capture
       side reporting that a stream stopped or errored, and a curtain over a
       dead stream is a local user staring at black while the remote party sees
       nothing. Lifting is safe for a stale report too - the worst it can do is
       take down a curtain the next connection puts back up. */
    [self.curtainController noteCaptureStreamStopped];

    uint64_t reportedGeneration = [info[@"generation"] unsignedLongLongValue];
    if (!macVNCShouldActOnCaptureFailure(reportedGeneration,
                                         vncServerCurrentGeneration(),
                                         &_handledFailureGeneration))
        return;

    /* Stop OFF the main thread: vncServerStop() joins client threads and waits
       for in-flight ScreenCaptureKit work, which can be pending behind a system
       permission prompt. Blocking the main thread here would freeze the menu bar
       — including the very buttons the user needs to recover. */
    dispatch_async(self.lifecycleQueue, ^{
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
    dispatch_async(self.lifecycleQueue, ^{

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        MacVNCStartupConfig *startup = [MacVNCStartupConfig
            configWithDefaults:defaults
                   environment:NSProcessInfo.processInfo.environment];
        NSString *configurationError = startup.error;

        MacVNCServerConfig serverConfig;
        MacVNCServerStartResult startResult = MacVNCServerStartFailed;
        if ([startup fillServerConfig:&serverConfig])
            startResult = vncServerStartWithResult(&serverConfig);
        BOOL ok = startResult == MacVNCServerStartOK;

        dispatch_async(dispatch_get_main_queue(), ^{
            MacVNCStartOutcome outcome;
            outcome.started               = ok;
            outcome.alreadyRunning        =
                startResult == MacVNCServerStartAlreadyRunning;
            outcome.hasConfigurationError = configurationError != nil;
            /* Ask the sampler, which asks the provider: passing serverRunning=NO
               by hand fed the resolver a value already known to be wrong on the
               "already running" path. Only the permission answer is read here,
               but a resolver input that lies about one field invites the next
               caller to trust another. */
            outcome.permissionsGranted    =
                macVNCResolvePermissionUI(macVNCSamplePermissionUI())
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
    /* `port` was just read; reuse it rather than making the provider read the
       server again mid-render, which could observe a different state. */
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

    /* The backstop for the curtain's conditions: the client-count hook and the
       defaults notification are what make it prompt, this 2 s tick is what
       makes a missed one temporary rather than permanent. */
    [self refreshCurtainState];
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
