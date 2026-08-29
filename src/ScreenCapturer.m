#import "ScreenCapturer.h"
#import "FirstFrameBudget.h"
#import "FrameMailbox.h"
#include <assert.h>
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <time.h>

/* Identity key for the sample-handler queue (see -dealloc). The address of this
   static is the key; its value is irrelevant. */
static const void * const kMacVNCSampleQueueKey = &kMacVNCSampleQueueKey;
/* Same purpose for the state queue: the last reference can be dropped by a
   block finishing there, and a dispatch_sync from that thread would deadlock. */
static const void * const kMacVNCStateQueueKey = &kMacVNCStateQueueKey;

@interface ScreenCapturer () {
    pthread_mutex_t _readinessMutex;
    pthread_cond_t _readinessCondition;
    BOOL _firstFrameReady;
    /* Set when this generation's capture failed: a waiter must stop waiting
       for a first frame that is never coming. Guarded by _readinessMutex. */
    BOOL _captureFailed;
    NSUInteger _readinessGeneration;
    MacVNCFrameMailbox _frameMailbox;
    BOOL _frameMailboxInitialized;
}

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, strong) SCStream *stream;
/* Captured from the discovery this stream already does at start, so a later
   content-filter swap needs no SCShareableContent round trip of its own.
   Both are read and written on stateQueue only. */
@property (nonatomic, strong) SCDisplay *captureDisplay;
@property (nonatomic, strong) SCRunningApplication *ownApplication;
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) dispatch_queue_t frameQueue;
@property (nonatomic, strong) dispatch_queue_t sampleHandlerQueue;
@property (nonatomic, strong) dispatch_group_t operationGroup;
@property (nonatomic, assign) BOOL captureRequested;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign, readonly) NSInteger captureFramesPerSecond;

// handlers
@property (nonatomic, copy, nonnull) BOOL (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

/* On stateQueue: the exclusion decision and, if it passes, the filter swap. */
- (void)applyOwnApplicationExclusion:(BOOL)excluded
                   completionHandler:(nullable void (^)(BOOL success))completionHandler;

@end


#if defined(MACVNC_ENABLE_TEST_HOOKS)
static NSInteger captureInitializationsBeforeFailure = -1;
static _Atomic bool captureInitializationFaultConsumed = false;

void
macVNCFailCaptureInitializationAfter(NSInteger successfulInitializations)
{
    captureInitializationsBeforeFailure = successfulInitializations;
    atomic_store(&captureInitializationFaultConsumed, false);
}

bool
macVNCCaptureInitializationFaultWasConsumed(void)
{
    return atomic_load(&captureInitializationFaultConsumed);
}
#endif

/*
 * The installed discovery seam, and the lock that lets a test swap it while a
 * capturer's state queue may be reading it. A plain global would be a data race
 * the project's TSan build would (rightly) report.
 */
static pthread_mutex_t gOwnApplicationDiscoveryMutex = PTHREAD_MUTEX_INITIALIZER;
static MacVNCOwnApplicationDiscovery gOwnApplicationDiscovery;

void
macVNCSetOwnApplicationDiscovery(MacVNCOwnApplicationDiscovery discovery)
{
    MacVNCOwnApplicationDiscovery installed = [discovery copy];   /* heap block */
    pthread_mutex_lock(&gOwnApplicationDiscoveryMutex);
    MacVNCOwnApplicationDiscovery previous = gOwnApplicationDiscovery;
    gOwnApplicationDiscovery = installed;
    pthread_mutex_unlock(&gOwnApplicationDiscoveryMutex);
    [previous release];
}

bool
macVNCCaptureExclusionMayProceed(bool haveStream,
                                 bool haveDisplay,
                                 bool haveOwnApplication,
                                 bool excluded)
{
    /* Restoring the default filter needs no application; excluding does, and
       without one the request must refuse rather than swap in a filter that
       hides nothing. */
    return haveStream && haveDisplay && (!excluded || haveOwnApplication);
}

/*
 * This process's entry in a discovery result, or nil.
 *
 * One place, used by both the start-time capture and the on-demand resolution,
 * so "which application is ours" cannot drift between them.
 */
static SCRunningApplication *
ownApplicationInList(NSArray<SCRunningApplication *> *applications)
{
    pid_t ownProcessID = getpid();
    NSUInteger index = [applications indexOfObjectPassingTest:^BOOL(
        SCRunningApplication *_Nonnull application, NSUInteger idx, BOOL *_Nonnull stop) {
        (void)idx; (void)stop;
        return application.processID == ownProcessID;
    }];
    return index == NSNotFound ? nil : applications[index];
}

MacVNCShareableContentCensus
macVNCTakeShareableContentCensus(NSArray<SCRunningApplication *> *applications,
                                 NSArray<SCWindow *> *windows,
                                 pid_t ownProcessID)
{
    MacVNCShareableContentCensus census = {0, 0, 0, 0, false};
    census.applications = (unsigned long)applications.count;
    census.windows = (unsigned long)windows.count;
    for (SCRunningApplication *application in applications) {
        if (application.processID == ownProcessID) {
            census.ownApplicationPresent = true;
            break;
        }
    }
    for (SCWindow *window in windows) {
        SCRunningApplication *owner = window.owningApplication;
        if (!owner || owner.processID != ownProcessID)
            continue;
        ++census.ownWindows;
        if (window.isOnScreen)
            ++census.ownWindowsOnScreen;
    }
    return census;
}

void
macVNCLogShareableContentCensus(const char *phase,
                                unsigned int displayID,
                                MacVNCShareableContentCensus census)
{
    NSLog(@"macVNC: SCK census at %s (display %u, pid %d): applications=%lu, "
          @"this process %s; windows=%lu, owned by this process=%lu (%lu on screen)",
          phase ? phase : "?", displayID, (int)getpid(), census.applications,
          census.ownApplicationPresent ? "PRESENT" : "ABSENT", census.windows,
          census.ownWindows, census.ownWindowsOnScreen);
    /* The one line that would settle the remaining question by itself: if SCK
       can see our windows and STILL does not list us, no ordering of window
       creation against the request can ever make application-level exclusion
       work, and the filter would have to name windows. */
    if (!census.ownApplicationPresent && census.ownWindows > 0)
        NSLog(@"macVNC: SCK lists %lu window(s) of this process (%lu on screen) "
              @"but not the process itself - application-level exclusion is "
              @"impossible on this system",
              census.ownWindows, census.ownWindowsOnScreen);
}

/*
 * The applications and windows of one discovery, through the seam.
 *
 * onScreenWindowsOnly:NO is kept even though a live run proved it insufficient:
 * it costs nothing and it is still the only variant that could ever list a
 * window that is not on screen. What actually decides the outcome is that the
 * CALLER owns a window by the time it asks - see the header. The completion may
 * run on any thread and runs exactly once.
 */
static void
discoverShareableContent(void (^completion)(NSArray<SCRunningApplication *> *applications,
                                            NSArray<SCWindow *> *windows))
{
    pthread_mutex_lock(&gOwnApplicationDiscoveryMutex);
    MacVNCOwnApplicationDiscovery discovery = [gOwnApplicationDiscovery retain];
    pthread_mutex_unlock(&gOwnApplicationDiscoveryMutex);
    if (discovery) {
        discovery(completion);
        [discovery release];
        return;
    }
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                              onScreenWindowsOnly:NO
                                completionHandler:^(SCShareableContent *content, NSError *error) {
          @autoreleasepool {
            if (error)
                NSLog(@"macVNC: shareable content discovery failed: %@",
                      error.description);
            completion(content.applications, content.windows);
          }
        }];
}

static void releaseMailboxFrame(void *frame)
{
    CFRelease(frame);
}

static void beginMailboxActivity(void *context)
{
    dispatch_group_enter((dispatch_group_t)context);
}

static void endMailboxActivity(void *context)
{
    dispatch_group_leave((dispatch_group_t)context);
}

@implementation ScreenCapturer {
    /* Set when a stop timed out with capture work still in flight; read by
       -isSafeToDeallocate from another thread, hence atomic. */
    _Atomic bool _stuckWork;
}

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
        captureFramesPerSecond:(NSInteger)captureFramesPerSecond
                   frameHandler:(BOOL (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler {
    if (self = [super init]) {
        _displayID = displayID;
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
        _stateQueue = dispatch_queue_create("net.christianbeier.macVNC.capture-state", DISPATCH_QUEUE_SERIAL);
        _frameQueue = dispatch_queue_create("net.christianbeier.macVNC.capture-frame", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_attr_t qosAttr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _sampleHandlerQueue = dispatch_queue_create(
            "net.christianbeier.macVNC.capture-sample", qosAttr);
        /* Tag the queue so -dealloc can detect it is already running on it and
           skip the final dispatch_sync (which would self-deadlock). This can
           happen when GCD releases the last block-captured self reference on
           this very queue after stopCaptureAndWait has returned. */
        dispatch_queue_set_specific(_sampleHandlerQueue,
                                    kMacVNCSampleQueueKey,
                                    (void *)kMacVNCSampleQueueKey,
                                    NULL);
        dispatch_queue_set_specific(_stateQueue,
                                    kMacVNCStateQueueKey,
                                    (void *)kMacVNCStateQueueKey,
                                    NULL);
        _operationGroup = dispatch_group_create();
        _captureRequested = NO;
        _generation = 0;
        _captureFramesPerSecond = captureFramesPerSecond;
        pthread_mutex_init(&_readinessMutex, NULL);
        pthread_cond_init(&_readinessCondition, NULL);
        _firstFrameReady = NO;
        _captureFailed = NO;
        _readinessGeneration = 0;
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        if (captureInitializationsBeforeFailure == 0) {
            atomic_store(&captureInitializationFaultConsumed, true);
            [self release];
            return nil;
        }
        if (captureInitializationsBeforeFailure > 0)
            --captureInitializationsBeforeFailure;
#endif
        _frameMailboxInitialized = macVNCFrameMailboxInit(
            &_frameMailbox, releaseMailboxFrame, beginMailboxActivity,
            endMailboxActivity, (void *)_operationGroup);
        if (!_frameMailboxInitialized) {
            [self release];
            return nil;
        }
    }
    return self;
}

/*
 * Everything from "display found" to "stream started", extracted from
 * startCapture so each method states one thing: startCapture is the
 * lifecycle decision (generation, group accounting, discovery), this is the
 * ScreenCaptureKit plumbing (configuration, filter, output wiring, start).
 *
 * Runs on stateQueue; caller has already validated generation and taken one
 * operationGroup reference, which this method leaves ONLY when the stream is
 * started and the start-completion has its own reference pending - every
 * early exit releases the caller's reference.
 */
- (void)beginStreamingWithDisplay:(SCDisplay *)display generation:(NSUInteger)generation
{
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = (int)CGDisplayPixelsWide(self.displayID);
    config.height = (int)CGDisplayPixelsHigh(self.displayID);
    if (@available(macOS 13.0, *))
        config.showsCursor = YES;
    config.minimumFrameInterval = CMTimeMake(1, (int32_t)self.captureFramesPerSecond);
    config.queueDepth = 2;
    config.pixelFormat = kCVPixelFormatType_32BGRA;

    self.captureDisplay = display;
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    [filter release];
    [config release];

    NSError *addOutputError = nil;
    [stream addStreamOutput:self
                       type:SCStreamOutputTypeScreen
         sampleHandlerQueue:self.sampleHandlerQueue
                      error:&addOutputError];
    if (addOutputError) {
        [stream release];
        [self reportCaptureError:addOutputError];
        dispatch_group_leave(self.operationGroup);
        return;
    }

    self.stream = stream;
    dispatch_group_enter(self.operationGroup);
    [stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        dispatch_async(self.stateQueue, ^{
            if (startError && self.captureRequested &&
                self.generation == generation && self.stream == stream)
                [self reportCaptureError:startError];
            dispatch_group_leave(self.operationGroup);
        });
    }];
    [stream release];
    dispatch_group_leave(self.operationGroup);
}

- (void)startCapture {
    dispatch_async(self.stateQueue, ^{
        if (self.captureRequested)
            return;
        self.captureRequested = YES;
        NSUInteger generation = ++self.generation;
        pthread_mutex_lock(&self->_readinessMutex);
        self->_readinessGeneration = generation;
        self->_firstFrameReady = NO;
        self->_captureFailed = NO;
        pthread_cond_broadcast(&self->_readinessCondition);
        pthread_mutex_unlock(&self->_readinessMutex);
        dispatch_group_enter(self.operationGroup);

        /* onScreenWindowsOnly:NO for the same reason the resolution below uses
           it: the plain getShareableContentWithCompletionHandler: is the
           on-screen variant, whose `applications` cannot contain a windowless
           menu-bar app. `displays` is the same either way. */
        [SCShareableContent
            getShareableContentExcludingDesktopWindows:NO
                                  onScreenWindowsOnly:NO
                                    completionHandler:^(SCShareableContent *content, NSError *error) {
            dispatch_async(self.stateQueue, ^{
                /* A disconnect may have arrived while content discovery was pending. */
                if (!self.captureRequested || self.generation != generation) {
                    dispatch_group_leave(self.operationGroup);
                    return;
                }
                if (error) {
                    [self reportCaptureError:error];
                    dispatch_group_leave(self.operationGroup);
                    return;
                }

                NSUInteger displayIndex = [content.displays indexOfObjectPassingTest:^BOOL(
                    SCDisplay *_Nonnull display, NSUInteger idx, BOOL *_Nonnull stop) {
                    return display.displayID == self.displayID;
                }];
                if (displayIndex == NSNotFound) {
                    NSError *noDisplayError = [NSError errorWithDomain:@"ScreenCapturerErrorDomain"
                                                                  code:1
                                                              userInfo:@{NSLocalizedDescriptionKey : @"Display not available for capture"}];
                    [self reportCaptureError:noDisplayError];
                    dispatch_group_leave(self.operationGroup);
                    return;
                }
                /* Our own SCRunningApplication, taken from the list this call
                   already returned: it is the only way to name ourselves to
                   -initWithDisplay:excludingApplications:, and taking it here
                   keeps a later curtain raise free of a round trip.
                   Absent is EXPECTED for a menu-bar app that owns no window
                   yet - it is not an error here, and it is not final either:
                   -setExcludesOwnApplication: resolves it again when it is
                   actually needed.

                   Censused because this is measurement point (a): the state of
                   the discovery while this process owns NO curtain window. Its
                   difference against the census at the exclusion request is the
                   whole experiment.

                   ONCE PER PROCESS, AND THAT IS THE POINT. Captures start on
                   every 0 -> 1 client edge, on every display, for every user,
                   whether or not curtain mode is switched on - so an
                   unconditional line here would print internal ScreenCaptureKit
                   census data into the log of somebody who never asked the
                   question this measures, once per display per connection,
                   forever. The experiment needs the answer once: the state of a
                   discovery taken while this process owns no curtain window
                   does not change with the connection that triggered it.
                   Measurement point (b) stays unconditional because it only
                   runs when a curtain is actually being raised. */
                static dispatch_once_t censusOnce;
                dispatch_once(&censusOnce, ^{
                    macVNCLogShareableContentCensus(
                        "stream start", self.displayID,
                        macVNCTakeShareableContentCensus(content.applications,
                                                         content.windows,
                                                         getpid()));
                });
                self.ownApplication = ownApplicationInList(content.applications);

                [self beginStreamingWithDisplay:content.displays[displayIndex]
                                           generation:generation];
            });
        }];
    });
}

- (void)stopCaptureAndWait {
    __block SCStream *stream = nil;
    dispatch_sync(self.stateQueue, ^{
        self.captureRequested = NO;
        ++self.generation;
        pthread_mutex_lock(&self->_readinessMutex);
        self->_readinessGeneration = self.generation;
        self->_firstFrameReady = NO;
        self->_captureFailed = NO;
        pthread_cond_broadcast(&self->_readinessCondition);
        pthread_mutex_unlock(&self->_readinessMutex);
        stream = [self.stream retain];
        self.stream = nil;
        self.captureDisplay = nil;
        self.ownApplication = nil;
        /* Keep the group nonzero from invalidation through definitive stream
           stop and the owned callback queue drain. */
        if (stream)
            dispatch_group_enter(self.operationGroup);
    });
    if (stream) {
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            (void)error;
            /* Stop completion prevents new ScreenCaptureKit submissions, but
               does not promise its serial sample queue is drained. This sentinel
               runs after every callback already admitted to the owned queue. */
            dispatch_async(self.sampleHandlerQueue, ^{
                dispatch_group_leave(self.operationGroup);
            });
        }];
    }
    /* Covers discovery/start/mailbox work, definitive stream stop, and every
       sample callback admitted to the owned serial queue before stop completed.

       BOUNDED on purpose: SCShareableContent discovery can stay pending behind a
       system "wants to record this screen" prompt. An unbounded wait here would
       hang whichever thread called stop — including the main thread on the
       permission-failure and quit paths — leaving the menu bar (and the recovery
       affordances in it) permanently unresponsive. */
    if (dispatch_group_wait(self.operationGroup,
                            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        NSLog(@"macVNC: capture stop timed out waiting for in-flight "
              @"ScreenCaptureKit work (display %u); continuing shutdown",
              self.displayID);
        /* Remember it: -dealloc must not free state a live callback still uses,
           and it cannot re-derive this - the group may complete later. */
        atomic_store(&_stuckWork, true);
    }
    [stream release];
}

- (void)resolveOwnApplicationWithCompletionHandler:
    (void (^)(SCRunningApplication *application))handler
{
    dispatch_async(self.stateQueue, ^{
      @autoreleasepool {
        /* Cached from the stream's own discovery, or from an earlier raise:
           one round trip per stream, not one per raise. */
        if (self.ownApplication) {
            NSLog(@"macVNC: own application for display %u answered from cache",
                  self.displayID);
            if (handler)
                handler(self.ownApplication);
            return;
        }
        discoverShareableContent(^(NSArray<SCRunningApplication *> *applications,
                                   NSArray<SCWindow *> *windows) {
            /* Back onto the queue that owns the cache; the discovery answers on
               a thread of ScreenCaptureKit's choosing. */
            dispatch_async(self.stateQueue, ^{
              @autoreleasepool {
                /* Measurement point (b): the same census, taken at the moment
                   the exclusion is needed - by which time the caller has
                   ordered its (invisible) curtain window in. */
                macVNCLogShareableContentCensus(
                    "exclusion request", self.displayID,
                    macVNCTakeShareableContentCensus(applications, windows, getpid()));
                SCRunningApplication *application = ownApplicationInList(applications);
                if (application)
                    self.ownApplication = application;
                else
                    NSLog(@"macVNC: this process is not among the %lu shareable "
                          @"applications; own-window exclusion must refuse",
                          (unsigned long)applications.count);
                if (handler)
                    handler(application);
              }
            });
        });
      }
    });
}

- (void)setExcludesOwnApplication:(BOOL)excluded
                completionHandler:(void (^)(BOOL success))completionHandler
{
    /* stateQueue owns stream/display/application, so the decision is made where
       a concurrent stop cannot half-apply it. */
    dispatch_async(self.stateQueue, ^{
      @autoreleasepool {
        /* Resolve our own application at the moment it is needed - the
           start-time answer is nil for a menu-bar app with no window of its
           own, and that nil is what kept the curtain down on real hardware.

           Only ever behind a RUNNING stream: a discovery is what can raise a
           Screen Recording prompt, and a live stream is the proof that the
           permission is already granted. With no stream this falls straight
           through to the refusal below, exactly as it did before. */
        if (excluded && !self.ownApplication && self.stream && self.captureDisplay) {
            [self resolveOwnApplicationWithCompletionHandler:^(SCRunningApplication *application) {
                (void)application;   /* the cache is the answer; re-checked below */
                [self applyOwnApplicationExclusion:excluded
                                 completionHandler:completionHandler];
            }];
            return;
        }
        [self applyOwnApplicationExclusion:excluded completionHandler:completionHandler];
      }
    });
}

/* The decision and the swap, on stateQueue. Split out so the resolution above
   can re-enter it with exactly the same rules once it has an answer. */
- (void)applyOwnApplicationExclusion:(BOOL)excluded
                   completionHandler:(void (^)(BOOL success))completionHandler
{
  @autoreleasepool {
    SCStream *stream = self.stream;
    SCDisplay *display = self.captureDisplay;
    SCRunningApplication *application = self.ownApplication;
    if (!macVNCCaptureExclusionMayProceed(stream != nil, display != nil,
                                          application != nil, excluded != NO)) {
        NSLog(@"macVNC: cannot %s own windows for display %u "
              @"(stream %s, display %s, application %s)",
              excluded ? "exclude" : "restore", self.displayID,
              stream ? "yes" : "no", display ? "yes" : "no",
              application ? "yes" : "no");
        if (completionHandler)
            completionHandler(NO);
        return;
    }
    /* What the gate just guaranteed, restated for the reader and for the static
       analyzer, which does not see through the call above: everything the
       filter is built from below is non-nil. */
    assert(stream != nil && display != nil && (!excluded || application != nil));

    /* By application, never by window: a window-based filter would have to
       enumerate a window that is on screen, forcing the curtain to be shown
       before the stream stops carrying it. */
    SCContentFilter *filter = excluded
        ? [[SCContentFilter alloc] initWithDisplay:display
                             excludingApplications:@[ application ]
                                  exceptingWindows:@[]]
        : [[SCContentFilter alloc] initWithDisplay:display
                                  excludingWindows:@[]];
    /* Swap on the RUNNING stream - never a stop/start. */
    [stream updateContentFilter:filter completionHandler:^(NSError *error) {
      @autoreleasepool {
        if (error)
            NSLog(@"macVNC: content filter update failed for display %u: %@",
                  self.displayID, error.description);
        if (completionHandler)
            completionHandler(error == nil);
      }
    }];
    [filter release];
  }
}

/*
 * NO when in-flight capture work never finished, so this object must not be
 * deallocated - freeing its queues and mailbox would be a use-after-free from
 * the stuck callback. The owner keeps such a capturer alive on purpose; that
 * leak only happens on an already-degraded shutdown and is far cheaper than
 * either a crash or the unbounded wait it replaced.
 */
- (BOOL)isSafeToDeallocate
{
    return !atomic_load(&_stuckWork);
}


/*
  SCStreamDelegate methods
*/

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(self.stateQueue, ^{
        if (self.captureRequested && self.stream == stream)
            [self reportCaptureError:error];
    });
}


/*
  SCStreamOutput methods
*/

- (void)drainFrameMailbox {
    for (;;) {
        MacVNCFrameMailboxItem item;
        BOOL haveItem = macVNCFrameMailboxTake(&_frameMailbox, &item);
        NSAssert(haveItem, @"scheduled frame drain must own a pending frame");
        if (!haveItem) {
            macVNCFrameMailboxEndDrainIteration(&_frameMailbox);
            return;
        }

        __block BOOL valid = NO;
        dispatch_sync(self.stateQueue, ^{
            valid = self.captureRequested &&
                    self.generation == item.generation &&
                    self.stream == (SCStream *)item.stream;
        });
        if (valid) {
            /* The handler may decline the frame when the compositor cannot take
               every client's send lock right now. Simply dropping it would lose
               those pixels until the screen changes again — and if the screen
               then goes static, permanently. Retry briefly, bounded, right here.

               Bounded is essential: an unbounded wait would recreate the very
               deadlock the non-blocking lock was introduced to fix (a client
               thread can hold its send lock while waiting on the client
               lifecycle mutex that a stopping capture holds). The mailbox
               coalesces any newer frame meanwhile, so nothing queues up. */
            static const int kMaxComposeAttempts = 12;   /* ~120 ms total */
            static const useconds_t kComposeRetryUs = 10000;
            BOOL composited = self.frameHandler((CMSampleBufferRef)item.frame);
            for (int attempt = 1; !composited && attempt < kMaxComposeAttempts; ++attempt) {
                usleep(kComposeRetryUs);
                composited = self.frameHandler((CMSampleBufferRef)item.frame);
            }
            if (!composited) {
                /* Give up on this frame: a client has been mid-send for >100 ms.
                   Do NOT mark readiness — nothing was drawn for this generation. */
                CFRelease(item.frame);
                if (!macVNCFrameMailboxEndDrainIteration(&_frameMailbox))
                    return;
                continue;
            }
            /* Ready means the generation's frame has finished composition. */
            dispatch_sync(self.stateQueue, ^{
                if (self.captureRequested &&
                    self.generation == item.generation &&
                    self.stream == (SCStream *)item.stream) {
                    pthread_mutex_lock(&self->_readinessMutex);
                    self->_readinessGeneration = item.generation;
                    self->_firstFrameReady = YES;
                    pthread_cond_broadcast(&self->_readinessCondition);
                    pthread_mutex_unlock(&self->_readinessMutex);
                }
            });
        }
        CFRelease(item.frame);
        if (!macVNCFrameMailboxEndDrainIteration(&_frameMailbox))
            return;
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen)
        return;


    /* Cover admission before consulting lifecycle state. If stop invalidates
       concurrently, it cannot observe quiescence while this callback is live. */
    dispatch_group_enter(self.operationGroup);
    __block BOOL accept = NO;
    __block NSUInteger generation = 0;
    dispatch_sync(self.stateQueue, ^{
        accept = self.captureRequested && self.stream == stream;
        generation = self.generation;
    });
    if (!accept) {
        dispatch_group_leave(self.operationGroup);
        return;
    }

    CFRetain(sampleBuffer);
    BOOL scheduleDrain = macVNCFrameMailboxSubmit(&_frameMailbox,
                                                   (void *)sampleBuffer,
                                                   (void *)stream,
                                                   generation);
    if (scheduleDrain) {
        dispatch_async(self.frameQueue, ^{
            [self drainFrameMailbox];
        });
    }
    dispatch_group_leave(self.operationGroup);
}

/*
 * Deliver a capture failure, waking anyone blocked on the first frame first.
 *
 * Without this a freshly authenticated client sat out the WHOLE first-frame
 * budget on a failure it could already have been told about - eight silent
 * seconds for a stream that will never produce a frame. The wake does not
 * fake readiness: _firstFrameReady stays NO, so the waiter simply stops
 * waiting and reports "not ready".
 */
- (void)reportCaptureError:(NSError *)error
{
    pthread_mutex_lock(&_readinessMutex);
    _captureFailed = YES;
    pthread_cond_broadcast(&_readinessCondition);
    pthread_mutex_unlock(&_readinessMutex);
    if (self.errorHandler)
        self.errorHandler(error);
}

- (BOOL)waitForFirstFrameWithTimeout:(NSTimeInterval)timeout {
    __block NSUInteger generation = 0;
    __block BOOL requested = NO;
    dispatch_sync(self.stateQueue, ^{
        generation = self.generation;
        requested = self.captureRequested;
    });
    if (!requested)
        return NO;

    uint64_t durationNanoseconds = 0;
    if (isfinite(timeout) && timeout > 0) {
        long double scaled = (long double)timeout * NSEC_PER_SEC;
        durationNanoseconds = scaled >= ldexpl(1.0L, 64)
            ? UINT64_MAX
            : (uint64_t)scaled;
    }
    MacVNCFirstFrameBudget budget = macVNCFirstFrameBudgetStart(
        macVNCMonotonicNow(), durationNanoseconds);

    pthread_mutex_lock(&_readinessMutex);
    while (_readinessGeneration == generation && !_firstFrameReady &&
           !_captureFailed) {
        uint64_t remaining = macVNCFirstFrameBudgetRemaining(
            &budget, macVNCMonotonicNow());
        if (remaining == 0)
            break;
        struct timespec relativeWait = macVNCRelativeWaitFromNanoseconds(remaining);
        int result = pthread_cond_timedwait_relative_np(
            &_readinessCondition, &_readinessMutex, &relativeWait);
        if (result != 0 && result != ETIMEDOUT)
            break;
    }
    BOOL ready = _readinessGeneration == generation && _firstFrameReady;
    pthread_mutex_unlock(&_readinessMutex);
    return ready;
}


/* Waits, bounded, for every already-admitted sample callback to finish. */
- (BOOL)waitForSampleQueueDrain
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_sampleHandlerQueue, ^{ dispatch_semaphore_signal(done); });
    BOOL drained = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    dispatch_release(done);
    return drained;
}

- (void)dealloc {
    /* Bounded final drain. -isSafeToDeallocate has already told the owner not to
       release a capturer whose work never quiesced, so reaching here means the
       stream was stopped cleanly; this only waits out callbacks already admitted
       to the owned queue. Skipped when we are running ON one of those queues,
       where a sync would deadlock on ourselves. */
    if (dispatch_get_specific(kMacVNCSampleQueueKey) == NULL &&
        dispatch_get_specific(kMacVNCStateQueueKey) == NULL)
        [self waitForSampleQueueDrain];

    if (_frameMailboxInitialized)
        macVNCFrameMailboxDestroy(&_frameMailbox);
    pthread_cond_destroy(&_readinessCondition);
    pthread_mutex_destroy(&_readinessMutex);
    [_captureDisplay release];
    [_ownApplication release];
    [_stream release];
    [_frameHandler release];
    [_errorHandler release];
    dispatch_release(_operationGroup);
    dispatch_release(_sampleHandlerQueue);
    dispatch_release(_frameQueue);
    dispatch_release(_stateQueue);
    [super dealloc];
}

@end
