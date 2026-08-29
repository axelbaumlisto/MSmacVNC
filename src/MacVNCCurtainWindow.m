#import "MacVNCCurtainWindow.h"

#import <AppKit/AppKit.h>

#import "MacVNCCaptureSession.h"
#import "MacVNCCurtainInput.h"   /* macVNCCurtainInputEventIsSelfInjected */

/* ------------------------------------------------------------------------- */
/* The window set: bookkeeping only, over the occluder seam.                  */
/* ------------------------------------------------------------------------- */

@implementation MacVNCCurtainWindowSet {
    id<MacVNCCurtainOccluders> _occluders;   /* retained */
    NSMutableArray<NSNumber *> *_identifiers;
    BOOL _visible;
    BOOL _acceptsKeyboardFocus;
    id<MacVNCCurtainKeyboardSink> _keyboardSink;   /* NOT retained: the input
                                                      module owns this set's
                                                      lifetime, not the other
                                                      way round */
}

- (instancetype)initWithOccluders:(id<MacVNCCurtainOccluders>)occluders
{
    if ((self = [super init])) {
        _occluders = [occluders retain];
        _identifiers = [[NSMutableArray alloc] init];
        _visible = NO;
    }
    return self;
}

- (void)synchronizeWithAttachedScreens
{
    NSArray<NSNumber *> *attached = [_occluders attachedScreenIdentifiers];
    if (!attached)
        attached = @[];

    /* Newly attached screens first: a screen that appears while the curtain is
       up must be covered, and the ONLY thing standing between it and the local
       user is this window creation - excluding by application means the filter
       already covers whatever we create. */
    for (NSNumber *identifier in attached) {
        if ([_identifiers containsObject:identifier]) {
            [_occluders updateOccluderGeometryForScreen:identifier];
            continue;
        }
        if ([_occluders createOccluderForScreen:identifier])
            [_identifiers addObject:identifier];
    }

    /* Then the screens that went away. Iterating a copy: the loop mutates. */
    NSArray<NSNumber *> *known = [[_identifiers copy] autorelease];
    for (NSNumber *identifier in known) {
        if ([attached containsObject:identifier])
            continue;
        [_occluders removeOccluderForScreen:identifier];
        [_identifiers removeObject:identifier];
    }

    /* Re-assert, so a window created a moment ago is shown rather than waiting
       for the next setVisible: nobody would call. */
    if (_visible)
        [_occluders setOccludersVisible:YES];
}

- (void)setVisible:(BOOL)visible
{
    _visible = visible;
    [_occluders setOccludersVisible:visible];
}

- (BOOL)visible
{
    return _visible;
}

- (void)setAcceptsKeyboardFocus:(BOOL)accepts
{
    _acceptsKeyboardFocus = accepts;
    if ([_occluders respondsToSelector:@selector(setOccludersAcceptKeyboardFocus:)])
        [_occluders setOccludersAcceptKeyboardFocus:accepts];
}

- (BOOL)acceptsKeyboardFocus
{
    return _acceptsKeyboardFocus;
}

- (void)setKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink
{
    _keyboardSink = sink;
    if ([_occluders respondsToSelector:@selector(setOccludersKeyboardSink:)])
        [_occluders setOccludersKeyboardSink:sink];
}

- (NSArray<NSNumber *> *)screenIdentifiers
{
    return [[_identifiers copy] autorelease];
}

- (void)dealloc
{
    [_identifiers release];
    [_occluders release];
    [super dealloc];
}

@end

/* ------------------------------------------------------------------------- */
/* The AppKit occluders: one borderless black window per NSScreen.            */
/* ------------------------------------------------------------------------- */

/*
 * The window itself, as a subclass for exactly two reasons.
 *
 * 1. A borderless window cannot become key at all unless it says so, and this
 *    one may say so ONLY while the tap path is unavailable - the flag is set
 *    from outside, never decided here.
 * 2. Its -keyDown: must ignore OUR OWN injected events by the same tag the tap
 *    uses. While this window is key, the remote viewer's keystrokes are posted
 *    into this session and land here; feeding them to the unlock policy would
 *    let whoever holds the VNC password lift the curtain by typing it
 *    remotely, which is the one party the escape hatch is not for.
 */
@interface MacVNCCurtainKeyWindow : NSWindow
@property (nonatomic, assign) BOOL acceptsKeyboardFocus;
@property (nonatomic, assign) id<MacVNCCurtainKeyboardSink> keyboardSink;  /* not retained */
@end

@implementation MacVNCCurtainKeyWindow

- (BOOL)canBecomeKeyWindow
{
    return _acceptsKeyboardFocus;
}

- (void)keyDown:(NSEvent *)event
{
    /* Dropped rather than passed to super, which would beep: a window that is
       still key after the focus was taken back must not feed a policy it is no
       longer allowed to feed. -setOccludersAcceptKeyboardFocus: is what makes
       this state momentary. */
    if (!_acceptsKeyboardFocus)
        return;
    if (macVNCCurtainInputEventIsSelfInjected((CGEventType)[event type],
                                              [event CGEvent]))
        return;                       /* the remote party's own keystroke */
    NSString *characters = [event characters];
    NSUInteger length = characters.length;
    if (length == 0 || !_keyboardSink)
        return;
    /* Bounded on purpose: the policy's own buffer is fixed too, and a held key
       must not turn into an unbounded copy. */
    unichar buffer[16];
    if (length > 16)
        length = 16;
    [characters getCharacters:buffer range:NSMakeRange(0, length)];
    [_keyboardSink curtainWindowDidReceiveCharacters:(const uint16_t *)buffer
                                               count:(size_t)length];
}

@end

@interface MacVNCCurtainScreenOccluders : NSObject <MacVNCCurtainOccluders>
@end

@implementation MacVNCCurtainScreenOccluders {
    NSMutableDictionary<NSNumber *, MacVNCCurtainKeyWindow *> *_windows;
    BOOL _acceptsKeyboardFocus;
    id<MacVNCCurtainKeyboardSink> _keyboardSink;   /* not retained */
}

- (instancetype)init
{
    if ((self = [super init]))
        _windows = [[NSMutableDictionary alloc] init];
    return self;
}

static NSNumber *screenIdentifier(NSScreen *screen)
{
    return screen.deviceDescription[@"NSScreenNumber"];
}

- (NSScreen *)screenForIdentifier:(NSNumber *)identifier
{
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *candidate = screenIdentifier(screen);
        if (candidate && [candidate isEqualToNumber:identifier])
            return screen;
    }
    return nil;
}

- (NSArray<NSNumber *> *)attachedScreenIdentifiers
{
    NSMutableArray<NSNumber *> *identifiers = [NSMutableArray array];
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *identifier = screenIdentifier(screen);
        if (identifier)
            [identifiers addObject:identifier];
    }
    return identifiers;
}

- (BOOL)createOccluderForScreen:(NSNumber *)identifier
{
    if (_windows[identifier])
        return YES;
    NSScreen *screen = [self screenForIdentifier:identifier];
    if (!screen)
        return NO;   /* it was attached a moment ago; it is not now */

    /* screen:nil plus a frame in global coordinates: with a screen argument the
       rect would be interpreted relative to THAT screen's origin, which reads
       like a bug on a multi-display desk. */
    MacVNCCurtainKeyWindow *window =
        [[MacVNCCurtainKeyWindow alloc] initWithContentRect:screen.frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO
                                                     screen:nil];
    /* MRR: an NSWindow that releases itself when closed would be freed out from
       under this dictionary. */
    [window setReleasedWhenClosed:NO];
    [window setLevel:NSScreenSaverWindowLevel];
    /* Level alone covers neither other Spaces nor a full-screen app. */
    [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary |
                                  NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorIgnoresCycle];
    [window setBackgroundColor:[NSColor blackColor]];
    /* NOT opaque, and alpha just under 1: see MACVNC_CURTAIN_ALPHA in the
       header for the luminance argument and for why an opaque curtain freezes
       the remote picture. */
    [window setOpaque:NO];
    [window setAlphaValue:MACVNC_CURTAIN_ALPHA];
    [window setHasShadow:NO];
    [window setHidesOnDeactivate:NO];
    [window setExcludedFromWindowsMenu:YES];
    /* Input is not this module's business. Swallowing clicks here would be an
       accidental, half-done version of the suppression that belongs in the
       event tap, and would silently change behaviour for a curtain that is only
       supposed to be a picture. */
    [window setIgnoresMouseEvents:YES];
    [window setFrame:screen.frame display:NO];
    /* A screen attached while the tap path is already unavailable gets the
       same focus rules as the rest, rather than a window that silently cannot
       take the password. */
    window.acceptsKeyboardFocus = _acceptsKeyboardFocus;
    window.keyboardSink = _keyboardSink;

    _windows[identifier] = window;
    [window release];
    return YES;
}

- (void)setOccludersKeyboardSink:(id<MacVNCCurtainKeyboardSink>)sink
{
    _keyboardSink = sink;
    for (NSNumber *identifier in _windows)
        _windows[identifier].keyboardSink = sink;
}

- (void)setOccludersAcceptKeyboardFocus:(BOOL)accepts
{
    _acceptsKeyboardFocus = accepts;
    MacVNCCurtainKeyWindow *candidate = nil;
    for (NSNumber *identifier in _windows) {
        MacVNCCurtainKeyWindow *window = _windows[identifier];
        window.acceptsKeyboardFocus = accepts;
        if (!candidate && window.isVisible)
            candidate = window;
    }
    if (accepts && candidate) {
        /* The ONE place this LSUIElement app takes focus, and it is the lesser
           evil: the alternative is the local user typing their password into
           whatever application the remote party is watching. */
        [NSApp activateIgnoringOtherApps:YES];
        [candidate makeKeyWindow];
    } else if (!accepts) {
        /* -resignKeyWindow is a NOTIFICATION hook, not a way to give key status
           up: AppKit calls it, clients do not, and calling it transfers
           nothing - the window stays key and keeps eating keystrokes,
           including the remote viewer's, which the tap has already passed
           through. Deactivating the application is the documented way back,
           and it is the exact undo of the -activateIgnoringOtherApps: above.
           (The lift orders these windows out moments later, which would also
           resign key - but this module publishes the rule as its own, so it
           has to hold on its own.) */
        if ([NSApp isActive])
            [NSApp deactivate];
    }
}

- (void)removeOccluderForScreen:(NSNumber *)identifier
{
    NSWindow *window = _windows[identifier];
    if (!window)
        return;
    [window orderOut:nil];
    [_windows removeObjectForKey:identifier];
}

- (void)updateOccluderGeometryForScreen:(NSNumber *)identifier
{
    NSWindow *window = _windows[identifier];
    NSScreen *screen = [self screenForIdentifier:identifier];
    if (!window || !screen)
        return;
    if (!NSEqualRects(window.frame, screen.frame))
        [window setFrame:screen.frame display:YES];
}

- (void)setOccludersVisible:(BOOL)visible
{
    for (NSNumber *identifier in _windows) {
        NSWindow *window = _windows[identifier];
        if (visible) {
            /* orderFrontRegardless, never makeKeyAndOrderFront: the app is an
               LSUIElement that must never activate or take focus. Whether the
               curtain window may become key is a decision the input task owns;
               a borderless window cannot, by default. */
            [window orderFrontRegardless];
        } else {
            [window orderOut:nil];
        }
    }
}

- (void)dealloc
{
    [self setOccludersVisible:NO];
    [_windows release];
    [super dealloc];
}

@end

/* ------------------------------------------------------------------------- */
/* The production seams: capture exclusion and the main-queue scheduler.      */
/* ------------------------------------------------------------------------- */

@interface MacVNCCurtainSessionExclusion : NSObject <MacVNCCurtainCaptureExclusion>
@end

/* Trampoline from the capture session's C completion back to the block. The
   block is Block_copy'd on the way out and released here, so it survives the
   hop through plain C. */
static void curtainExclusionCompleted(void *context, bool success)
{
    MacVNCCurtainCompletion completion = (MacVNCCurtainCompletion)context;
    if (!completion)
        return;
    @autoreleasepool {
        completion(success ? YES : NO);
    }
    [completion release];
}

@implementation MacVNCCurtainSessionExclusion

- (void)setCaptureExcludesOwnApplication:(BOOL)excluded
                              completion:(MacVNCCurtainCompletion)completion
{
    macVNCCaptureSessionSetSelfExcluded(excluded ? true : false,
                                        curtainExclusionCompleted,
                                        completion ? [completion copy] : NULL);
}

@end

@implementation MacVNCCurtainMainQueueScheduler

- (void)afterNanoseconds:(uint64_t)nanoseconds performBlock:(dispatch_block_t)block
{
    if (!block)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)nanoseconds),
                   dispatch_get_main_queue(), block);
}

@end

/* ------------------------------------------------------------------------- */
/* The curtain: ordering, one-shot resolution, timeout.                       */
/* ------------------------------------------------------------------------- */

@implementation MacVNCCurtain {
    MacVNCCurtainWindowSet *_windowSet;
    id<MacVNCCurtainCaptureExclusion> _exclusion;
    id<MacVNCCurtainScheduler> _scheduler;
    uint64_t _timeoutNanoseconds;
    MacVNCCurtainState _state;
    /* Tokens are MONOTONIC and never reused: each transition takes the next
       one, and resolving clears the active token. Whichever of the filter
       completion and the timeout arrives second finds a token that is no longer
       active and is ignored - and so does an answer belonging to a transition
       that was abandoned two transitions ago, which a counter that restarted
       would have accepted as the current one. */
    NSUInteger _nextToken;
    NSUInteger _activeToken;
    MacVNCCurtainCompletion _pendingCompletion;   /* copied */
}

- (instancetype)initWithWindowSet:(MacVNCCurtainWindowSet *)windowSet
                        exclusion:(id<MacVNCCurtainCaptureExclusion>)exclusion
                        scheduler:(id<MacVNCCurtainScheduler>)scheduler
               timeoutNanoseconds:(uint64_t)timeoutNanoseconds
{
    if ((self = [super init])) {
        _windowSet = [windowSet retain];
        _exclusion = [exclusion retain];
        _scheduler = [scheduler retain];
        _timeoutNanoseconds = timeoutNanoseconds;
        _state = MacVNCCurtainStateDown;
        _nextToken = 0;
        _activeToken = 0;
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(screenParametersChanged:)
                   name:NSApplicationDidChangeScreenParametersNotification
                 object:nil];
    }
    return self;
}

+ (instancetype)curtainWithDefaultSeams
{
    MacVNCCurtainScreenOccluders *occluders =
        [[MacVNCCurtainScreenOccluders alloc] init];
    MacVNCCurtainWindowSet *windowSet =
        [[MacVNCCurtainWindowSet alloc] initWithOccluders:occluders];
    MacVNCCurtainSessionExclusion *exclusion =
        [[MacVNCCurtainSessionExclusion alloc] init];
    MacVNCCurtainMainQueueScheduler *scheduler =
        [[MacVNCCurtainMainQueueScheduler alloc] init];
    MacVNCCurtain *curtain = [[self alloc]
        initWithWindowSet:windowSet
                exclusion:exclusion
                scheduler:scheduler
       timeoutNanoseconds:MACVNC_CURTAIN_FILTER_SWAP_TIMEOUT_NANOSECONDS];
    [occluders release];
    [windowSet release];
    [exclusion release];
    [scheduler release];
    return [curtain autorelease];
}

- (MacVNCCurtainState)state
{
    return _state;
}

- (MacVNCCurtainWindowSet *)windowSet
{
    return _windowSet;
}

- (void)screenParametersChanged:(NSNotification *)notification
{
    (void)notification;
    /* A curtain that is DOWN reconciles nothing: this notification fires for
       every resolution change and every display sleep, and answering it while
       nothing is raised would allocate a borderless window per screen that is
       never ordered in - falsifying the promise that this object touches no
       window until it is raised. A raise synchronises before it shows, so a
       screen attached while the curtain was down is covered then. */
    if (_state == MacVNCCurtainStateDown)
        return;
    /* Hot-plug, resolution change, arrangement change: one call covers all
       three, and it shows what it creates when the curtain is up. */
    [_windowSet synchronizeWithAttachedScreens];
}

/* Finishes a transition exactly once: the loser of the race between the filter
   completion and the timeout finds a stale token and returns. */
- (BOOL)claimTransition:(NSUInteger)token
{
    if (token == 0 || token != _activeToken)
        return NO;
    _activeToken = 0;
    return YES;
}

- (NSUInteger)beginTransitionWithCompletion:(MacVNCCurtainCompletion)completion
{
    [_pendingCompletion release];
    _pendingCompletion = completion ? [completion copy] : nil;
    _activeToken = ++_nextToken;
    return _activeToken;
}

- (void)finishWithSuccess:(BOOL)success
{
    MacVNCCurtainCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        completion(success);
        [completion release];
    }
}

- (void)raiseWithCompletion:(MacVNCCurtainCompletion)completion
{
    if (_state == MacVNCCurtainStateUp) {
        if (completion)
            completion(YES);       /* idempotent */
        return;
    }
    if (_state != MacVNCCurtainStateDown) {
        if (completion)
            completion(NO);        /* a transition is in flight; do not queue */
        return;
    }

    _state = MacVNCCurtainStateRaising;
    NSUInteger token = [self beginTransitionWithCompletion:completion];

    /* Filter FIRST. Only when the running stream confirms it is no longer
       showing this application do the windows come up. */
    [_exclusion setCaptureExcludesOwnApplication:YES completion:^(BOOL success) {
        [self resolveRaiseWithToken:token success:success];
    }];
    [_scheduler afterNanoseconds:_timeoutNanoseconds performBlock:^{
        /* A swap that never answers is a failure, not a slow success. */
        [self resolveRaiseWithToken:token success:NO];
    }];
}

- (void)resolveRaiseWithToken:(NSUInteger)token success:(BOOL)success
{
    if (_state != MacVNCCurtainStateRaising || ![self claimTransition:token])
        return;

    if (!success) {
        _state = MacVNCCurtainStateDown;
        /* Best effort: a late success from the swap we gave up on must not
           leave the stream excluding an application whose windows are not even
           shown. Nothing waits for this. */
        [_exclusion setCaptureExcludesOwnApplication:NO completion:nil];
        [self finishWithSuccess:NO];
        return;
    }

    [_windowSet synchronizeWithAttachedScreens];
    [_windowSet setVisible:YES];
    _state = MacVNCCurtainStateUp;
    [self finishWithSuccess:YES];
}

- (void)liftWithCompletion:(MacVNCCurtainCompletion)completion
{
    if (_state == MacVNCCurtainStateDown) {
        if (completion)
            completion(YES);       /* idempotent */
        return;
    }
    if (_state == MacVNCCurtainStateLifting) {
        if (completion)
            completion(NO);
        return;
    }

    _state = MacVNCCurtainStateLifting;
    /* Lifting out of Raising abandons that raise: it is told it failed here
       (before its completion is dropped), and the token taken on the next line
       supersedes its own, so the filter swap it is waiting for can no longer
       show anything. */
    [self finishWithSuccess:NO];
    NSUInteger token = [self beginTransitionWithCompletion:completion];

    /* Windows FIRST - the exact reverse of the raise. Everything after this
       point can fail without leaving the local user in front of a black
       screen. */
    [_windowSet setVisible:NO];

    [_exclusion setCaptureExcludesOwnApplication:NO completion:^(BOOL success) {
        [self resolveLiftWithToken:token success:success];
    }];
    [_scheduler afterNanoseconds:_timeoutNanoseconds performBlock:^{
        [self resolveLiftWithToken:token success:NO];
    }];
}

- (void)resolveLiftWithToken:(NSUInteger)token success:(BOOL)success
{
    if (_state != MacVNCCurtainStateLifting || ![self claimTransition:token])
        return;
    /* Down either way: the windows are already out. A failed restore only means
       the remote viewer keeps not seeing an application with nothing on
       screen. */
    _state = MacVNCCurtainStateDown;
    [self finishWithSuccess:success];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    /* An owner that lets go mid-transition still gets an ANSWER: dropping the
       completion unheard leaves whoever is waiting for it believing a raise or
       a lift is still in flight forever, which for a raise means a caller that
       never learns its curtain did not go up. */
    [self finishWithSuccess:NO];
    /* And a curtain that is deallocated while it is UP takes itself down on
       both sides. The window set hides its occluders on its own dealloc, but
       the stream would keep excluding this application - windows gone, remote
       viewer still not seeing us, and nobody left to restore it. */
    if (_state != MacVNCCurtainStateDown) {
        _state = MacVNCCurtainStateDown;
        _activeToken = 0;
        [_windowSet setVisible:NO];
        [_exclusion setCaptureExcludesOwnApplication:NO completion:nil];
    }
    [_scheduler release];
    [_exclusion release];
    [_windowSet release];
    [super dealloc];
}

@end
