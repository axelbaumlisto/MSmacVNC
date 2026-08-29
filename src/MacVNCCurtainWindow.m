#import "MacVNCCurtainWindow.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>   /* CATransaction: the commit, see the header */

#import "MacVNCCaptureSession.h"
#import "MacVNCCurtainInput.h"   /* macVNCCurtainInputEventIsSelfInjected */

double macVNCCurtainOccluderAlpha(bool covering)
{
    return covering ? MACVNC_CURTAIN_ALPHA : MACVNC_CURTAIN_ARMING_ALPHA;
}

/* Main thread only, like every other window operation in this file, so a plain
 * global needs no lock: the seam is installed by a test before it drives
 * anything, and never while a curtain is in flight. */
static MacVNCCurtainWindowCommit gWindowCommit;

void macVNCCurtainSetWindowCommit(MacVNCCurtainWindowCommit commit)
{
    MacVNCCurtainWindowCommit installed = [commit copy];   /* heap block */
    MacVNCCurtainWindowCommit previous = gWindowCommit;
    gWindowCommit = installed;
    [previous release];
}

void macVNCCurtainCommitWindowChanges(void)
{
    if (gWindowCommit) {
        gWindowCommit();
        return;
    }
    /* The one call that makes the change the window server's problem instead
       of this run-loop pass's. -displayIfNeeded was measured NOT to do it: it
       draws pixels, and the curtain's opacity is not a pixel. */
    [CATransaction flush];
}

/* ------------------------------------------------------------------------- */
/* The window set: bookkeeping only, over the occluder seam.                  */
/* ------------------------------------------------------------------------- */

@implementation MacVNCCurtainWindowSet {
    id<MacVNCCurtainOccluders> _occluders;   /* retained */
    NSMutableArray<NSNumber *> *_identifiers;
    BOOL _visible;
    BOOL _covering;
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
       for the next setVisible: nobody would call. Opacity BEFORE visibility: a
       window created for a screen attached mid-curtain must already be covering
       when it is ordered in, or that screen shows its desktop for a frame. */
    if (_covering)
        [self applyCovering:YES];
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

/* The optional seam, in one place: an occluder set that models no opacity is
   one for which "ordered in" and "covering" are the same thing, and the
   bookkeeping above must still be exact for it. */
- (void)applyCovering:(BOOL)covering
{
    if ([_occluders respondsToSelector:@selector(setOccludersCovering:)])
        [_occluders setOccludersCovering:covering];
}

- (void)setCovering:(BOOL)covering
{
    _covering = covering;
    [self applyCovering:covering];
}

- (BOOL)covering
{
    return _covering;
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

/*
 * The audit: the one place that treats "the curtain is up" as a claim to be
 * checked rather than a flag to be trusted.
 *
 * Two halves, and the first alone would have caught the failure it exists for:
 * an empty occluder set is a set every operation succeeds on. A desk with no
 * attached screen, or one where every window creation was refused, leaves
 * -setCovering: and -setVisible: iterating nothing, and everything above them
 * reports success. The second half is the one no test can reach: what AppKit
 * and the window server say about the windows themselves.
 */
- (NSString *)auditCoverageForPhase:(NSString *)phase
{
    NSArray<NSNumber *> *attached = [_occluders attachedScreenIdentifiers];
    if (!attached)
        attached = @[];

    NSString *failure = nil;
    if (!_visible)
        failure = @"the occluders are not ordered in";
    else if (!_covering)
        failure = @"the occluders are not at the covering alpha";
    else if (attached.count == 0)
        failure = @"no screen is attached, so nothing is covered";

    NSLog(@"macVNC: curtain audit at %@: screens attached=%lu, with an "
          @"occluder=%lu, visible=%d covering=%d",
          phase, (unsigned long)attached.count,
          (unsigned long)_identifiers.count, _visible ? 1 : 0,
          _covering ? 1 : 0);

    BOOL canMeasure = [_occluders respondsToSelector:
                          @selector(occluderReportForScreen:failureReason:)];
    for (NSNumber *identifier in attached) {
        if (![_identifiers containsObject:identifier]) {
            /* A display with no occluder is the local user watching the remote
               party work, which is the one thing this feature exists to stop -
               so it is a failure even when every OTHER screen is covered. */
            NSLog(@"macVNC: curtain audit at %@: screen %@ has NO occluder",
                  phase, identifier);
            if (!failure)
                failure = [NSString stringWithFormat:
                              @"screen %@ has no occluder", identifier];
            continue;
        }
        if (!canMeasure)
            continue;
        NSString *reason = nil;
        NSString *report = [_occluders occluderReportForScreen:identifier
                                                 failureReason:&reason];
        NSLog(@"macVNC: curtain audit at %@: %@%@", phase,
              report ? report : @"(no report)",
              reason ? [@" -> NOT COVERING: " stringByAppendingString:reason]
                     : @"");
        if (reason && !failure)
            failure = reason;
    }
    return failure;
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
/* NO is the armed alpha of header note 4: on screen for ScreenCaptureKit,
   invisible to the local user and to the remote viewer alike. */
@property (nonatomic, assign) BOOL covering;
@property (nonatomic, assign) id<MacVNCCurtainKeyboardSink> keyboardSink;  /* not retained */
@end

@implementation MacVNCCurtainKeyWindow

- (BOOL)canBecomeKeyWindow
{
    return _acceptsKeyboardFocus;
}

- (void)setCovering:(BOOL)covering
{
    _covering = covering;
    [self setAlphaValue:macVNCCurtainOccluderAlpha(covering ? true : false)];
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
    BOOL _covering;
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
    /* NOT opaque, and alpha just under 1 once it covers: see
       MACVNC_CURTAIN_ALPHA in the header for the luminance argument and for why
       an opaque curtain freezes the remote picture. Created ARMED (or covering,
       if this window is joining a curtain that is already up), never at an
       alpha the local user could notice before the filter swap. */
    [window setOpaque:NO];
    window.covering = _covering;
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
    /* Committed BEFORE this window can be ordered in: an alpha the window
       server has not been told about is not the alpha it composites, and the
       default is 1.0 - a window ordered in with the arming alpha still pending
       would be a full black frame on both sides, which is the exact opposite
       of what "armed" means. */
    macVNCCurtainCommitWindowChanges();
    return YES;
}

- (void)setOccludersCovering:(BOOL)covering
{
    _covering = covering;
    for (NSNumber *identifier in _windows)
        _windows[identifier].covering = covering;
    /* THE FIX. Without this the loop above is a change AppKit agrees with and
       the compositor never hears about: measured live as "alpha=0.99900 |
       window server alpha=0.00392" with the curtain "up" and nothing covered.
       Committed here, at the seam that owns the windows, so every route to an
       alpha change - raise, lift, hot-plug through
       -synchronizeWithAttachedScreens - commits by construction rather than by
       each caller remembering to. */
    macVNCCurtainCommitWindowChanges();
}

/*
 * What is ACTUALLY on the glass, from the two authorities that know.
 *
 * AppKit answers what this process asked for; the window server answers what
 * it agreed to composite, and only the second can contradict the state
 * machine. Nothing here reads a window NAME - the one part of
 * CGWindowListCopyWindowInfo that TCC gates - so this can raise no permission
 * prompt on a path that runs while a remote party is already connected.
 */
- (NSString *)occluderReportForScreen:(NSNumber *)identifier
                        failureReason:(NSString **)reason
{
    MacVNCCurtainKeyWindow *window = _windows[identifier];
    if (!window) {
        if (reason)
            *reason = [NSString stringWithFormat:
                          @"screen %@ has no occluder window", identifier];
        return [NSString stringWithFormat:@"screen %@: no window", identifier];
    }

    NSScreen *screen = [self screenForIdentifier:identifier];
    NSRect screenFrame = screen ? screen.frame : NSZeroRect;

    CGRect serverBounds = CGRectNull;
    double serverAlpha = -1.0;
    long serverLayer = 0;
    BOOL serverKnows = NO;
    BOOL serverOnScreen = NO;
    CFArrayRef list =
        CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                   (CGWindowID)window.windowNumber);
    if (list) {
        if (CFArrayGetCount(list) > 0) {
            NSDictionary *info =
                (NSDictionary *)CFArrayGetValueAtIndex(list, 0);
            serverKnows = YES;
            serverAlpha = [info[(id)kCGWindowAlpha] doubleValue];
            serverLayer = [info[(id)kCGWindowLayer] longValue];
            /* kCGWindowIsOnscreen is ABSENT, not false, for a window the
               compositor is not showing. */
            serverOnScreen = [info[(id)kCGWindowIsOnscreen] boolValue];
            CGRectMakeWithDictionaryRepresentation(
                (CFDictionaryRef)info[(id)kCGWindowBounds], &serverBounds);
        }
        CFRelease(list);
    }

    NSString *failure = nil;
    if (!screen)
        failure = [NSString stringWithFormat:
                      @"screen %@ is no longer attached", identifier];
    else if (!window.isVisible)
        failure = [NSString stringWithFormat:@"window %ld is not ordered in",
                                             (long)window.windowNumber];
    else if (!serverKnows || !serverOnScreen)
        failure = [NSString stringWithFormat:
                      @"the window server does not list window %ld on screen",
                      (long)window.windowNumber];
    else if (!NSContainsRect(window.frame, screenFrame))
        failure = [NSString stringWithFormat:
                      @"window %ld frame %@ does not cover screen %@ %@",
                      (long)window.windowNumber,
                      NSStringFromRect(window.frame), identifier,
                      NSStringFromRect(screenFrame)];
    /* Half an 8-bit level of tolerance, the same criterion the alpha itself is
       derived from: the window server round-trips the value through a float. */
    else if (serverAlpha < MACVNC_CURTAIN_ALPHA - (0.5 / 255.0))
        failure = [NSString stringWithFormat:
                      @"window %ld composites at alpha %.5f, not the covering "
                      @"alpha %.5f",
                      (long)window.windowNumber, serverAlpha,
                      (double)MACVNC_CURTAIN_ALPHA];

    if (reason)
        *reason = failure;
    return [NSString stringWithFormat:
               @"screen %@: window %ld frame=%@ screenFrame=%@ alpha=%.5f "
               @"visible=%d onActiveSpace=%d level=%ld opaque=%d "
               @"occlusion=0x%lx | window server: known=%d onscreen=%d "
               @"layer=%ld alpha=%.5f bounds=%@",
               identifier, (long)window.windowNumber,
               NSStringFromRect(window.frame), NSStringFromRect(screenFrame),
               (double)window.alphaValue, window.isVisible ? 1 : 0,
               window.isOnActiveSpace ? 1 : 0, (long)window.level,
               window.isOpaque ? 1 : 0, (unsigned long)window.occlusionState,
               serverKnows ? 1 : 0, serverOnScreen ? 1 : 0, serverLayer,
               serverAlpha, NSStringFromRect(NSRectFromCGRect(serverBounds))];
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
    macVNCCurtainCommitWindowChanges();
}

- (void)updateOccluderGeometryForScreen:(NSNumber *)identifier
{
    NSWindow *window = _windows[identifier];
    NSScreen *screen = [self screenForIdentifier:identifier];
    if (!window || !screen)
        return;
    if (!NSEqualRects(window.frame, screen.frame))
        [window setFrame:screen.frame display:YES];
    macVNCCurtainCommitWindowChanges();
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
            /* Drawn NOW rather than at the end of this run-loop pass. What
               follows a show during a raise is a shareable-content discovery
               in ANOTHER process, and the whole point of showing first is that
               the discovery finds a window of ours; an ordered-in window whose
               content has not been drawn yet is the one thing that could make
               that measurement lie. */
            [window displayIfNeeded];
        } else {
            [window orderOut:nil];
        }
    }
    /* Same rule as the covering alpha, applied to ordering: this module never
       returns from a change with the window server still holding the previous
       state, because the very next thing that happens - a shareable-content
       discovery in ANOTHER process, or this curtain's own audit - asks the
       window server what is true. */
    macVNCCurtainCommitWindowChanges();
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

    /* WINDOWS FIRST, INVISIBLY - and this order is not a preference, it is the
       platform's (header note 1). ScreenCaptureKit lists an application only
       while it owns a window, so until these are ordered in there is no
       SCRunningApplication to name and the swap below can only refuse. They go
       up ARMED: on screen for the discovery, invisible to the local user and
       carrying no black frame to the remote viewer. */
    [_windowSet synchronizeWithAttachedScreens];
    [_windowSet setCovering:NO];
    [_windowSet setVisible:YES];

    /* Filter SECOND. Only when the running stream confirms it is no longer
       showing this application does the curtain become opaque. */
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
        [self failRaiseBecause:
                  @"the capture filter swap failed or never answered"];
        return;
    }

    /* The stream confirmed it is no longer carrying this application: the
       windows that are already on screen may now hide it. Re-synchronised
       first, because a display attached during the swap has no window yet. */
    [_windowSet synchronizeWithAttachedScreens];
    [_windowSet setCovering:YES];
    [_windowSet setVisible:YES];

    /* MEASURE, THEN CLAIM. Everything above this line is bookkeeping, and
       bookkeeping is never wrong about itself: with no screen attached, or
       with every window creation refused, the two calls above iterate an empty
       set and succeed at nothing. This is the only step that can say the local
       screen is NOT black - and it logs the numbers either way, so one run of
       the app settles what the next reading of this file cannot.

       Nothing turns the run loop between making the windows opaque and
       ordering them out again below, so a refused raise still costs the local
       user no black frame. */
    NSString *notCovering = [_windowSet auditCoverageForPhase:@"raise"];
    if (notCovering) {
        [self failRaiseBecause:notCovering];
        return;
    }

    _state = MacVNCCurtainStateUp;
    [self finishWithSuccess:YES];
}

/* The one fail-safe way out of a raise, whatever refused it. */
- (void)failRaiseBecause:(NSString *)reason
{
    NSLog(@"macVNC: curtain raise refused - %@", reason);
    _state = MacVNCCurtainStateDown;
    /* The windows go away, so a failed raise leaves nothing on the local
       screen: the property the live run confirmed for the armed case, and the
       one the measurement above must not spend for the covering one. */
    [_windowSet setVisible:NO];
    [_windowSet setCovering:NO];
    /* Best effort: a late success from the swap we gave up on must not
       leave the stream excluding an application whose windows are not even
       shown. Nothing waits for this. */
    [_exclusion setCaptureExcludesOwnApplication:NO completion:nil];
    [self finishWithSuccess:NO];
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

    MacVNCCurtainState previous = _state;
    _state = MacVNCCurtainStateLifting;
    /* Lifting out of Raising abandons that raise: it is told it failed here
       (before its completion is dropped), and the token taken on the next line
       supersedes its own, so the filter swap it is waiting for can no longer
       show anything. */
    [self finishWithSuccess:NO];
    NSUInteger token = [self beginTransitionWithCompletion:completion];

    /* The other end of the bracket: the raise measured this curtain on the way
       up and this measures it on the way down, so the log says what the
       windows were doing over the WHOLE interval a viewer was connected -
       which is what a sample taken somewhere in the middle actually asks.
       Only out of Up: a raise still in flight is not supposed to be covering,
       and auditing it would report a state as a failure. */
    if (previous == MacVNCCurtainStateUp)
        (void)[_windowSet auditCoverageForPhase:@"lift"];

    /* Windows FIRST - the exact reverse of the raise. Everything after this
       point can fail without leaving the local user in front of a black
       screen. Both halves: ordered out AND no longer covering, so the next
       raise arms from a known state rather than inheriting this one's alpha. */
    [_windowSet setVisible:NO];
    [_windowSet setCovering:NO];

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
        [_windowSet setCovering:NO];
        [_exclusion setCaptureExcludesOwnApplication:NO completion:nil];
    }
    [_scheduler release];
    [_exclusion release];
    [_windowSet release];
    [super dealloc];
}

@end
