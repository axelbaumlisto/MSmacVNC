
/*
 *  OSXvnc Copyright (C) 2001 Dan McGuirk <mcguirk@incompleteness.net>.
 *  Original Xvnc code Copyright (C) 1999 AT&T Laboratories Cambridge.
 *  All Rights Reserved.
 *
 * Cut in two parts by Johannes Schindelin (2001): libvncserver and OSXvnc.
 *
 * Completely revamped and adapted to work with contemporary APIs by Christian Beier (2020).
 *
 * This file implements the macOS VNC server core: screen capture,
 * compositing, client lifecycle and server start/stop. Keyboard/pointer
 * input injection lives in MacVNCInput; power management in MacVNCPowerMgmt.
 */

#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include <rfb/rfb.h>
#include <rfb/keysym.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <arpa/inet.h>
#include <time.h>

#import "ScreenCapturer.h"
#import "RFBKeySym.h"
#import "DisplayLayout.h"
#import "DisplaySelection.h"
#import "MacVNCCompositor.h"
#import "MacVNCInput.h"
#import "ReadinessPolicy.h"
#import "CaptureRate.h"
#import "NetworkAccess.h"
#import "NetworkPolicyResolver.h"
#import "MacVNCDisplayWake.h"
#import "MacVNCPowerMgmt.h"
#import "mac.h"
#import <AppKit/AppKit.h>

/* The main LibVNCServer screen object */
static rfbScreenInfoPtr rfbScreen;

/* Set by AppDelegate; invoked on the main queue when capture fails at runtime. */
void (*macVNCScreenCaptureFailureHandler)(bool likelyPermissionDenial,
                                          uint64_t serverGeneration) = NULL;

/* Set by AppDelegate; invoked once when capture first delivers a frame.
   Informational: the authoritative status reader is
   CGPreflightScreenCaptureAccess() (see mac.h). */
void (*macVNCScreenCaptureWorkingHandler)(void) = NULL;

/* Injected permission gate; see mac.h. NULL means unrestricted. */
bool (*macVNCCaptureAllowed)(void) = NULL;

static bool captureIsAllowed(void)
{
    return !macVNCCaptureAllowed || macVNCCaptureAllowed();
}

/* One composite framebuffer; uncovered regions remain black. */
static void *frameBufferOne;

/* Private copy of the immutable server configuration for this run, populated
 * by vncServerStart() from the caller's MacVNCServerConfig. */
static rfbBool viewOnly = FALSE;
static int displayNumber = -1;               /* -2 all, -1 primary, >=0 one. */
static char macVNCListenAddress[MACVNC_LISTEN_ADDRESS_MAX] = {0};
static char macVNCAllowedClients[MACVNC_ALLOWED_CLIENTS_MAX] = {0};
static MacVNCClientAccessMode macVNCClientAccessMode = MACVNC_CLIENT_ACCESS_FAIL_CLOSED;
static MacVNCNetworkAccessList clientAccessList;

/* Password handed to LibVNCServer; must outlive rfbScreen. Zeroized + freed on
 * every (re)start and on server stop so cleartext does not linger. */
static char *gPasswdList[2] = {NULL, NULL};

static void macVNCClearStoredPassword(void)
{
    if (gPasswdList[0]) {
        memset(gPasswdList[0], 0, strlen(gPasswdList[0]));
        free(gPasswdList[0]);
        gPasswdList[0] = NULL;
    }
}
static MacVNCDisplayLayout displayLayout;
static NSMutableArray<ScreenCapturer *> *screenCapturers;
static rfbBool rfbServerInitialized = FALSE;
static _Atomic int publishedServerPort = -1;
/* Bumped by every start; stamped into capture-failure notifications so stale
 * ones (raised by a previous run, delivered after a modal) can be ignored. */
static _Atomic uint64_t serverGeneration = 0;
static pthread_mutex_t serverLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t clientLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    rfbBool captureCounted;
    MacVNCReadinessPolicy readiness;
} MacVNCClientState;

static rfbBool macVNCPasswordCheck(rfbClientPtr client,
                                   const char *encryptedPassword,
                                   int length);

#define INITIAL_READINESS_TIMEOUT_NANOSECONDS (3ULL * NSEC_PER_SEC)

/* Number of currently connected clients (read by AppDelegate for status display) */
_Atomic int vncConnectedClients = 0;



/* Enumerate the attached displays. Retries because a dimmed or slept screen
   reports zero active displays and capture would then fail. */
static rfbBool
readAttachedDisplays(MacVNCDisplayInput *displays, size_t *count, int *primaryIndex)
{
  CGDirectDisplayID ids[MACVNC_MAX_DISPLAYS];
  CGDisplayCount reported = 0;

  macVNCWakeDisplays();
  for (int attempt = 0; attempt < 20; ++attempt) {
      CGGetActiveDisplayList(MACVNC_MAX_DISPLAYS, ids, &reported);
      if (reported > 0)
          break;
      macVNCWakeDisplays();
      usleep(250000); /* 250ms */
  }
  if (reported == 0 || reported > MACVNC_MAX_DISPLAYS) {
      rfbErr("Unsupported active display count: %u\n", reported);
      return FALSE;
  }

  CGDirectDisplayID mainID = CGMainDisplayID();
  *primaryIndex = -1;
  for (size_t i = 0; i < reported; ++i) {
      CGRect bounds = CGDisplayBounds(ids[i]);
      displays[i] = (MacVNCDisplayInput){
          .displayID     = ids[i],
          .logicalX      = bounds.origin.x,
          .logicalY      = bounds.origin.y,
          .logicalWidth  = bounds.size.width,
          .logicalHeight = bounds.size.height,
          .pixelWidth    = (int)CGDisplayPixelsWide(ids[i]),
          .pixelHeight   = (int)CGDisplayPixelsHigh(ids[i]),
      };
      if (ids[i] == mainID)
          *primaryIndex = (int)i;
      printf("Found %s display %zu id=%u at (%.0f,%.0f), logical %.0fx%.0f, pixels %dx%d\n",
             ids[i] == mainID ? "primary" : "secondary", i, ids[i],
             displays[i].logicalX, displays[i].logicalY,
             displays[i].logicalWidth, displays[i].logicalHeight,
             displays[i].pixelWidth, displays[i].pixelHeight);
  }
  *count = reported;
  return TRUE;
}

/* Discover displays, apply the configured selection, build the composite
   layout. Split out of ScreenInit: display topology has nothing to do with
   networking, auth or framebuffer setup, and the selection rules are now
   unit-tested in DisplaySelection.c. */
static rfbBool
resolveDisplayLayout(void)
{
  MacVNCDisplayInput attached[MACVNC_MAX_DISPLAYS];
  MacVNCDisplayInput selected[MACVNC_MAX_DISPLAYS];
  size_t attachedCount = 0, selectedCount = 0;
  int primaryIndex = -1;

  if (!readAttachedDisplays(attached, &attachedCount, &primaryIndex))
      return FALSE;

  switch (macVNCSelectDisplays(attached, attachedCount, primaryIndex,
                               displayNumber, selected, &selectedCount)) {
  case MACVNC_DISPLAY_SELECTION_OK:
      break;
  case MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY:
      rfbErr("Specified display %d does not exist\n", displayNumber);
      return FALSE;
  case MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT:
  default:
      rfbErr("Unsupported display selection\n");
      return FALSE;
  }

  if (!macVNCBuildDisplayLayout(selected, selectedCount, &displayLayout)) {
      rfbErr("Could not build a non-overlapping RFB display layout\n");
      return FALSE;
  }
  printf("Capturing %zu display(s); composite framebuffer: %dx%d\n",
         displayLayout.count, displayLayout.width, displayLayout.height);
  return TRUE;
}

/* Install VNC password authentication. Refuses an empty password: an
   unauthenticated listener on a remote-control server is not an option. */
static rfbBool
installPassword(const char *password)
{
  if (!password || strlen(password) == 0) {
      rfbErr("A non-empty VNC password is required\n");
      return FALSE;
  }
  macVNCClearStoredPassword();
  gPasswdList[0] = strdup(password);
  if (!gPasswdList[0]) {
      rfbErr("Out of memory storing the VNC password\n");
      return FALSE;
  }
  rfbScreen->authPasswdData = gPasswdList;
  rfbScreen->passwordCheck = macVNCPasswordCheck;
  return TRUE;
}

static rfbBool
buildClientAccessList(void)
{
  char accessError[160] = {0};
  clientAccessList.count = 0;

  if (macVNCClientAccessMode == MACVNC_CLIENT_ACCESS_FAIL_CLOSED) {
      rfbErr("Client access policy is fail-closed; no listener opened\n");
      return FALSE;
  }
  if (macVNCClientAccessMode == MACVNC_CLIENT_ACCESS_ALLOW_LIST) {
      if (!macVNCParseAccessList(macVNCAllowedClients, &clientAccessList,
                                 accessError, sizeof(accessError))) {
          rfbErr("Invalid allowed clients list: %s\n", accessError);
          return FALSE;
      }
      if (clientAccessList.count == 0) {
          rfbErr("Client access policy allowList has no entries\n");
          return FALSE;
      }
  }
  return TRUE;
}

static rfbBool
ScreenInit(int port, const char *password, int captureFramesPerSecond)
{
  int bitsPerSample = 8;

  if (captureFramesPerSecond < MACVNC_CAPTURE_FPS_MIN ||
      captureFramesPerSecond > MACVNC_CAPTURE_FPS_MAX) {
      rfbErr("Invalid capture rate: %d FPS\n", captureFramesPerSecond);
      return FALSE;
  }
  int framebufferDeferMilliseconds =
      macVNCCaptureFrameIntervalMilliseconds(captureFramesPerSecond);
  if (framebufferDeferMilliseconds == 0) {
      rfbErr("Could not derive framebuffer interval for %d FPS\n",
             captureFramesPerSecond);
      return FALSE;
  }
  rfbLog("Screen capture rate: %d FPS per display; client framebuffer updates deferred %d ms\n",
         captureFramesPerSecond, framebufferDeferMilliseconds);

  /* Build a minimal argv so rfbGetScreen() has a program name but does
     not try to parse any options — we configure everything manually.
     The array must be NULL-terminated; rfbGetScreen() may check argv[argc]. */
  int   dummyArgc       = 1;
  char  progName[]      = "macVNC";
  char *dummyArgv[2]    = {progName, NULL};

  if (!resolveDisplayLayout())
      return FALSE;


  rfbScreen = rfbGetScreen(&dummyArgc, dummyArgv,
                           displayLayout.width,
                           displayLayout.height,
                           bitsPerSample,
                           3,
                           4);
  if(!rfbScreen) {
      rfbErr("Could not init rfbScreen.\n");
      return FALSE;
  }

  /* Configure listen port from already-resolved GUI/headless policy. */
  rfbScreen->port = port;
  const char *listenAddress = macVNCListenAddress;
  if (listenAddress && *listenAddress) {
      struct in_addr parsedAddress;
      if (inet_pton(AF_INET, listenAddress, &parsedAddress) != 1) {
          rfbErr("Invalid listen address: %s\n", listenAddress);
          return FALSE;
      }
      rfbScreen->listenInterface = parsedAddress.s_addr;
  }
  /* v1 network policy is IPv4-only; do not expose an IPv6 listener. */
  rfbScreen->ipv6port = 0;

  if (!buildClientAccessList())
      return FALSE;

  if (!installPassword(password))
      return FALSE;

  rfbScreen->serverFormat.redShift   = bitsPerSample * 2;
  rfbScreen->serverFormat.greenShift = bitsPerSample * 1;
  rfbScreen->serverFormat.blueShift  = 0;

  /* Coalesce dirty regions from every display into one per-client framebuffer
     transmission ceiling. Input processing and deferPtrUpdateTime are unchanged. */
  rfbScreen->deferUpdateTime = framebufferDeferMilliseconds;

  gethostname(rfbScreen->thisHost, 255);
  rfbScreen->thisHost[254] = '\0'; /* gethostname need not NUL-terminate on truncation */

  /* A single zeroed composite canvas keeps uncovered display gaps black. */
  size_t bufSize = (size_t)displayLayout.width * (size_t)displayLayout.height * 4;
  frameBufferOne = calloc(1, bufSize);
  if (!frameBufferOne) {
      rfbErr("Could not allocate composite framebuffer\n");
      return FALSE;
  }
  rfbScreen->frameBuffer = frameBufferOne;

  /* ScreenCaptureKit bakes the correctly oriented system cursor into the frame. */
  rfbScreen->cursor = NULL;

  /* Allow multiple VNC clients to connect simultaneously */
  rfbScreen->alwaysShared = TRUE;

  /* Bound how long LibVNCServer waits on a stalled client socket. Without this
     a viewer that stops reading (suspended laptop, dead link, hostile peer)
     keeps its send in flight for a very long time; with the compositor's
     non-blocking trylock this only costs that client, but a bounded wait lets
     the server actually drop it instead of pinning resources. */
  rfbScreen->maxClientWait = 10000; /* ms */

  rfbScreen->ptrAddEvent = PtrAddEvent;
  rfbScreen->kbdAddEvent = KbdAddEvent;
  macVNCInputSetContext(rfbScreen, &displayLayout);

  void (^captureErrorHandler)(NSError *) = ^(NSError *error) {
      rfbLog("Screen capture error: %s\n", [error.description UTF8String]);
      /* Distinguish a real TCC denial from unrelated capture failures (display
         unplugged, stream stopped). Only the former may latch a permanent
         "Screen Recording missing" state upstream. */
      bool likelyPermissionDenial =
          [error.domain isEqualToString:SCStreamErrorDomain] &&
          (error.code == SCStreamErrorUserDeclined ||
           error.code == SCStreamErrorMissingEntitlements);
      /* Stamp the run this failure belongs to, so a notification that is
         delivered late (e.g. queued behind a modal, after the server was
         already stopped and restarted) can be discarded by the handler. */
      uint64_t generation = atomic_load(&serverGeneration);
      /* Do not show UI here. Report upward; AppDelegate owns the single
         permission popup and decides how to recover. */
      dispatch_async(dispatch_get_main_queue(), ^{
          if (macVNCScreenCaptureFailureHandler)
              macVNCScreenCaptureFailureHandler(likelyPermissionDenial, generation);
      });
  };

  /* displayLayout.count is the single source for how many displays were
     selected; a parallel local counter was the same fact stored twice. */
  screenCapturers = [[NSMutableArray alloc] initWithCapacity:displayLayout.count];
  for (size_t i = 0; i < displayLayout.count; ++i) {
      const MacVNCDisplayGeometry *geometry = &displayLayout.displays[i];
      ScreenCapturer *capturer = [[ScreenCapturer alloc]
          initWithDisplay:geometry->input.displayID
          captureFramesPerSecond:captureFramesPerSecond
          frameHandler:^BOOL(CMSampleBufferRef sampleBuffer) {
              static _Atomic bool reportedWorking = false;
              bool expected = false;
              if (atomic_compare_exchange_strong(&reportedWorking, &expected, true) &&
                  macVNCScreenCaptureWorkingHandler)
                  macVNCScreenCaptureWorkingHandler();
              return macVNCCompositorSubmitFrame(rfbScreen, sampleBuffer, geometry) ? YES : NO;
          }
          errorHandler:captureErrorHandler];
      if (!capturer) {
          rfbErr("Could not initialize display capture mailbox\n");
          return FALSE;
      }
      [screenCapturers addObject:capturer];
      [capturer release];
  }

  rfbInitServer(rfbScreen);
  rfbServerInitialized = TRUE;

  /* rfbInitServer() does not report bind failures through a return value: on a
     port collision (e.g. macOS Screen Sharing already owns 5900, or a second
     macVNC instance) it leaves the listen socket invalid. Without this check the
     app would happily report "Running" on a port served by someone else, with a
     different auth and allowlist policy. */
  if (rfbScreen->listenSock < 0 && rfbScreen->inetdSock < 0) {
      rfbErr("Could not listen on port %d (already in use?)\n", rfbScreen->port);
      return FALSE;
  }

  return TRUE;
}


static void
startDisplayCaptures(void)
{
    for (ScreenCapturer *capturer in screenCapturers)
        [capturer startCapture];
}

static void
stopDisplayCapturesAndWait(void)
{
    for (ScreenCapturer *capturer in screenCapturers)
        [capturer stopCaptureAndWait];
}

static BOOL
prepareAuthenticatedClient(rfbClientPtr cl)
{
    MacVNCClientState *state = NULL;
    pthread_mutex_lock(&clientLifecycleMutex);
    state = cl->clientData;
    if (!state) {
        pthread_mutex_unlock(&clientLifecycleMutex);
        return NO;
    }
    if (!state->captureCounted) {
        state->captureCounted = TRUE;
        int previous = atomic_fetch_add(&vncConnectedClients, 1);
        if (previous == 0) {
            /* Never touch capture without the permission: doing so is what
               makes macOS raise its own dialog. The decision belongs to the
               permission owner, injected via macVNCCaptureAllowed, so this
               core file neither reads TCC nor depends on AppKit for it. */
            if (!captureIsAllowed()) {
                rfbLog("Screen Recording is not granted; refusing to start capture\n");
                if (macVNCScreenCaptureFailureHandler)
                    macVNCScreenCaptureFailureHandler(true, vncServerCurrentGeneration());
            } else {
                startDisplayCaptures();
                rfbLog("First client password accepted; starting %lu display captures\n",
                       (unsigned long)screenCapturers.count);
            }
        }
    }
    BOOL alreadyReady = macVNCReadinessIsReady(&state->readiness);
    pthread_mutex_unlock(&clientLifecycleMutex);

    BOOL allReady = alreadyReady;
    if (!alreadyReady) {
        MacVNCReadinessBudget budget = macVNCReadinessBudgetStart(
            macVNCReadinessNow(), INITIAL_READINESS_TIMEOUT_NANOSECONDS);
        allReady = YES;
        for (ScreenCapturer *capturer in screenCapturers) {
            uint64_t remaining = macVNCReadinessBudgetRemaining(
                &budget, macVNCReadinessNow());
            if (remaining == 0 ||
                ![capturer waitForFirstFrameWithTimeout:
                    (NSTimeInterval)remaining / NSEC_PER_SEC]) {
                allReady = NO;
                break;
            }
        }
        BOOL logTimeout = NO;
        pthread_mutex_lock(&clientLifecycleMutex);
        if (cl->clientData == state)
            logTimeout = macVNCReadinessRecordInitialResult(&state->readiness, allReady);
        pthread_mutex_unlock(&clientLifecycleMutex);
        if (logTimeout)
            rfbLog("Initial display readiness timed out; waiting for late frames\n");
    }
    return allReady;
}

static rfbBool
macVNCPasswordCheck(rfbClientPtr client,
                    const char *encryptedPassword,
                    int length)
{
    if (!rfbCheckPasswordByList(client, encryptedPassword, length))
        return FALSE;
    prepareAuthenticatedClient(client);
    return TRUE;
}

static void
displayHook(rfbClientPtr cl)
{
    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    BOOL timedOut = state && state->readiness.state == MACVNC_READINESS_TIMED_OUT;
    pthread_mutex_unlock(&clientLifecycleMutex);
    if (!timedOut)
        return;

    BOOL allReady = YES;
    for (ScreenCapturer *capturer in screenCapturers) {
        if (![capturer isCurrentGenerationReady]) {
            allReady = NO;
            break;
        }
    }
    if (!allReady)
        return;

    BOOL logRecovery = NO;
    pthread_mutex_lock(&clientLifecycleMutex);
    if (cl->clientData == state)
        logRecovery = macVNCReadinessPromoteIfReady(&state->readiness, true);
    pthread_mutex_unlock(&clientLifecycleMutex);
    if (logRecovery)
        rfbLog("All display captures became ready after the initial timeout\n");
}

static void clientGone(rfbClientPtr cl)
{
    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    int remaining;
    if (state && state->captureCounted) {
        remaining = atomic_fetch_sub(&vncConnectedClients, 1) - 1;
        if (remaining <= 0) {
            remaining = 0;
            atomic_store(&vncConnectedClients, 0);
            stopDisplayCapturesAndWait();
            macVNCInputResetModifiers();
            rfbLog("Last authenticated client disconnected; %lu display captures stopped and modifiers reset\n",
                   (unsigned long)screenCapturers.count);
        }
    } else {
        /* Un-counted client (never authenticated): report the current count. */
        remaining = atomic_load(&vncConnectedClients);
    }
    cl->clientData = NULL;
    free(state);
    pthread_mutex_unlock(&clientLifecycleMutex);
    rfbLog("Client %s disconnected (%d authenticated remaining)\n", cl->host, remaining);
}

static enum rfbNewClientAction newClient(rfbClientPtr cl)
{
  const char *host = cl->host ? cl->host : "";
  if (!macVNCNetworkAccessAllows(&clientAccessList, host)) {
      rfbLog("Refusing client %s: not in allowed clients list\n", host);
      return RFB_CLIENT_REFUSE;
  }

  /* A client is connecting: make sure the display is awake so it has something
     live to capture instead of a blank/dimmed screen. */
  macVNCWakeDisplays();

  MacVNCClientState *state = calloc(1, sizeof(*state));
  if (!state)
      return RFB_CLIENT_REFUSE;
  rfbLog("New client connected from %s; capture waits for authenticated frame request\n", host);
  cl->clientData = state;
  cl->clientGoneHook = clientGone;
  cl->viewOnly = viewOnly;
  return RFB_CLIENT_ACCEPT;
}


/* -----------------------------------------------------------------------
 * Public API — called from AppDelegate
 * ----------------------------------------------------------------------- */

static bool
serverHasLifecycleResourcesLocked(void)
{
    return rfbScreen || frameBufferOne || screenCapturers ||
           macVNCInputHasResources();
}

static void
vncServerStopLocked(void)
{
    atomic_store_explicit(&publishedServerPort, -1, memory_order_release);
    /* LibVNCServer >=0.9.15 reverted detached client threads. This call stops
       accepting clients and joins every client/listener thread before lifecycle
       objects they can access are released. */
    if (rfbScreen && rfbServerInitialized)
        rfbShutdownServer(rfbScreen, TRUE);
    rfbServerInitialized = FALSE;

    stopDisplayCapturesAndWait();
    [screenCapturers release];
    screenCapturers = nil;
    atomic_store(&vncConnectedClients, 0);
    if (rfbScreen) {
        rfbScreenCleanup(rfbScreen);
        rfbScreen = NULL;
    }
    dimmingShutdown();
    macVNCReleaseDisplayAssertion();
    macVNCInputShutdown();
    macVNCClearStoredPassword();
    free(frameBufferOne); frameBufferOne = NULL;
}

rfbBool
vncServerStart(const MacVNCServerConfig *config)
{
    if (!config) {
        rfbErr("vncServerStart: NULL configuration\n");
        return FALSE;
    }
    pthread_mutex_lock(&serverLifecycleMutex);
    if (serverHasLifecycleResourcesLocked()) {
        rfbErr("VNC server lifecycle is already initialized\n");
        pthread_mutex_unlock(&serverLifecycleMutex);
        return FALSE;
    }
    atomic_store_explicit(&publishedServerPort, -1, memory_order_release);
    atomic_fetch_add(&serverGeneration, 1);
    /* Permission gating (Screen Recording + Accessibility) is owned by
       AppDelegate via MacVNCPermissions before the server is ever started. */

    /* Adopt the immutable configuration into the server's private state. */
    viewOnly = config->viewOnly;
    displayNumber = config->displayNumber;
    macVNCClientAccessMode = config->clientAccessMode;
    snprintf(macVNCListenAddress, sizeof(macVNCListenAddress), "%s",
             config->listenAddress ? config->listenAddress : "");
    snprintf(macVNCAllowedClients, sizeof(macVNCAllowedClients), "%s",
             config->allowedClients ? config->allowedClients : "");

    dimmingInit();

    if (!macVNCInputStart())
        goto FAILURE;

    if (!ScreenInit(config->port, config->password, config->captureFramesPerSecond))
        goto FAILURE;

    rfbScreen->newClientHook = newClient;
    rfbScreen->displayHook = displayHook;
    rfbRunEventLoop(rfbScreen, -1, TRUE);
    atomic_store_explicit(&publishedServerPort, rfbScreen->port, memory_order_release);
    pthread_mutex_unlock(&serverLifecycleMutex);
    return TRUE;

FAILURE:
    vncServerStopLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
    return FALSE;
}

void
vncServerStop(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    vncServerStopLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
}

void
vncServerCloseListeners(void)
{
    /* Free the port immediately, without the cost of a full stop.

       Used just before relaunching: the child inherits open descriptors, and a
       still-open listening socket makes its bind() fail ("port already in use").
       BOTH listeners must go — closing only the IPv4 one leaves the IPv6 socket
       holding the port.

       Deliberately NOT vncServerStop(): that joins client threads and waits for
       in-flight ScreenCaptureKit work, which can sit behind a system prompt and
       would freeze the menu bar at the very moment the user pressed Restart.
       This only drops the listeners; the process is about to exit anyway. */
    /* Needs the lifecycle lock (vncServerStopLocked() frees rfbScreen from
       another thread), but must never BLOCK: this runs on the main thread while
       relaunching, and the lock can be held by a stop that is waiting on capture
       work stuck behind a system prompt — that would freeze the menu bar.
       If the lock is busy a stop is already in progress, which closes the
       listeners anyway, so skipping is correct. */
    if (pthread_mutex_trylock(&serverLifecycleMutex) != 0)
        return;
    if (!rfbScreen) {
        pthread_mutex_unlock(&serverLifecycleMutex);
        return;
    }
    if (rfbScreen->listenSock >= 0) {
        shutdown(rfbScreen->listenSock, SHUT_RDWR);
        close(rfbScreen->listenSock);
        rfbScreen->listenSock = -1;
    }
    if (rfbScreen->listen6Sock >= 0) {
        shutdown(rfbScreen->listen6Sock, SHUT_RDWR);
        close(rfbScreen->listen6Sock);
        rfbScreen->listen6Sock = -1;
    }
    /* Stop publishing a port nobody is listening on: the menu reads this and
       would otherwise keep claiming "Running • …:5903" over a dead socket. */
    atomic_store_explicit(&publishedServerPort, 0, memory_order_release);
    pthread_mutex_unlock(&serverLifecycleMutex);
}

int
vncServerGetPort(void)
{
    return atomic_load_explicit(&publishedServerPort, memory_order_acquire);
}

rfbBool
vncServerCopyActiveBindAddress(char *bindAddress, size_t size)
{
    if (!bindAddress || size == 0)
        return FALSE;
    if (atomic_load_explicit(&publishedServerPort, memory_order_acquire) <= 0)
        return FALSE;
    pthread_mutex_lock(&serverLifecycleMutex);
    snprintf(bindAddress, size, "%s", macVNCListenAddress);
    pthread_mutex_unlock(&serverLifecycleMutex);
    return TRUE;
}

MacVNCClientAccessMode
vncServerActiveAccessMode(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    MacVNCClientAccessMode mode = macVNCClientAccessMode;
    pthread_mutex_unlock(&serverLifecycleMutex);
    return mode;
}

uint64_t
vncServerCurrentGeneration(void)
{
    return atomic_load(&serverGeneration);
}

rfbBool
vncServerActivePolicyAllowsEveryone(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    /* An ALLOW_LIST that contains a /0 entry admits everyone just as surely as
       an explicitly confirmed allow-all — report the effect, not the label. */
    rfbBool everyone =
        macVNCClientAccessMode == MACVNC_CLIENT_ACCESS_ALLOW_ALL_CONFIRMED ||
        (macVNCClientAccessMode == MACVNC_CLIENT_ACCESS_ALLOW_LIST &&
         macVNCNetworkAccessContainsAllowAll(&clientAccessList));
    pthread_mutex_unlock(&serverLifecycleMutex);
    return everyone;
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
bool
macVNCCaptureIsAllowedForTesting(void)
{
    return captureIsAllowed();
}

bool
macVNCServerHasLifecycleResourcesForTesting(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    bool hasResources = serverHasLifecycleResourcesLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
    return hasResources;
}
#endif
