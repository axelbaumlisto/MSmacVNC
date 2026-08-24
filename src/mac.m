
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
#import "CompositeFramebuffer.h"
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
void (*macVNCScreenCaptureFailureHandler)(void) = NULL;

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
static pthread_mutex_t serverLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t compositorMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t clientLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    rfbBool captureCounted;
    MacVNCReadinessPolicy readiness;
} MacVNCClientState;

static rfbBool macVNCPasswordCheck(rfbClientPtr client,
                                   const char *encryptedPassword,
                                   int length);

/* Tile size (pixels) for dirty-region comparison */
#define TILE_SIZE 64
#define INITIAL_READINESS_TIMEOUT_NANOSECONDS (3ULL * NSEC_PER_SEC)

/* Number of currently connected clients (read by AppDelegate for status display) */
_Atomic int vncConnectedClients = 0;



static void
markCompositeDirty(void *context, int x, int y, int width, int height)
{
    (void)context;
    rfbMarkRectAsModified(rfbScreen, x, y, x + width, y + height);
}

typedef struct {
    rfbClientPtr *items;
    size_t count;
} LockedClientSet;

static rfbBool
lockCurrentClients(LockedClientSet *set)
{
    memset(set, 0, sizeof(*set));
    size_t capacity = 0;
    rfbClientIteratorPtr iterator = rfbGetClientIterator(rfbScreen);
    rfbClientPtr client;
    while ((client = rfbClientIteratorNext(iterator))) {
        if (set->count == capacity) {
            size_t nextCapacity = capacity ? capacity * 2 : 4;
            rfbClientPtr *next = realloc(set->items, nextCapacity * sizeof(*next));
            if (!next) {
                rfbReleaseClientIterator(iterator);
                for (size_t i = 0; i < set->count; ++i)
                    rfbDecrClientRef(set->items[i]);
                free(set->items);
                memset(set, 0, sizeof(*set));
                return FALSE;
            }
            set->items = next;
            capacity = nextCapacity;
        }
        rfbIncrClientRef(client);
        set->items[set->count++] = client;
    }
    rfbReleaseClientIterator(iterator);
    for (size_t i = 0; i < set->count; ++i)
        LOCK(set->items[i]->sendMutex);
    return TRUE;
}

static void
unlockCurrentClients(LockedClientSet *set)
{
    for (size_t i = set->count; i > 0; --i)
        UNLOCK(set->items[i - 1]->sendMutex);
    for (size_t i = 0; i < set->count; ++i)
        rfbDecrClientRef(set->items[i]);
    free(set->items);
    memset(set, 0, sizeof(*set));
}

static void
updateCompositeFrame(CMSampleBufferRef sampleBuffer,
                     const MacVNCDisplayGeometry *geometry)
{
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer)
        return;
    if ((int)CVPixelBufferGetWidth(pixelBuffer) != geometry->input.pixelWidth ||
        (int)CVPixelBufferGetHeight(pixelBuffer) != geometry->input.pixelHeight) {
        rfbErr("Unexpected display %u frame size %zux%zu (expected %dx%d)\n",
               geometry->input.displayID,
               CVPixelBufferGetWidth(pixelBuffer),
               CVPixelBufferGetHeight(pixelBuffer),
               geometry->input.pixelWidth,
               geometry->input.pixelHeight);
        return;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *source = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer);

    pthread_mutex_lock(&compositorMutex);
    LockedClientSet lockedClients;
    if (!lockCurrentClients(&lockedClients)) {
        pthread_mutex_unlock(&compositorMutex);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        rfbErr("Could not retain current VNC clients for framebuffer update\n");
        return;
    }

    macVNCCompositeDisplayFrame((uint8_t *)rfbScreen->frameBuffer,
                                rfbScreen->width,
                                rfbScreen->height,
                                geometry,
                                source,
                                sourceStride,
                                TILE_SIZE,
                                markCompositeDirty,
                                NULL);

    unlockCurrentClients(&lockedClients);
    pthread_mutex_unlock(&compositorMutex);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

static rfbBool
ScreenInit(int port, const char *password, int captureFramesPerSecond)
{
  int bitsPerSample = 8;
  CGDisplayCount displayCount;
  CGDirectDisplayID displays[32];
  CGDirectDisplayID selectedDisplays[MACVNC_MAX_DISPLAYS];
  MacVNCDisplayInput layoutInputs[MACVNC_MAX_DISPLAYS];
  size_t selectedCount = 0;

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

  /* Wake the display first: if the Mac dimmed/slept the screen there are 0
     active displays and capture would fail. Nudge it awake, then retry. */
  macVNCWakeDisplays();
  displayCount = 0;
  for (int attempt = 0; attempt < 20; ++attempt) {
      CGGetActiveDisplayList(32, displays, &displayCount);
      if (displayCount > 0)
          break;
      macVNCWakeDisplays();
      usleep(250000); /* 250ms */
  }
  if (displayCount == 0 || displayCount > MACVNC_MAX_DISPLAYS) {
      rfbErr("Unsupported active display count: %u\n", displayCount);
      return FALSE;
  }
  for (int i = 0; i < (int)displayCount; ++i) {
      CGRect bounds = CGDisplayBounds(displays[i]);
      printf("Found %s display %d id=%u at (%.0f,%.0f), logical %.0fx%.0f, pixels %zux%zu\n",
             CGDisplayIsMain(displays[i]) ? "primary" : "secondary",
             i, displays[i], bounds.origin.x, bounds.origin.y,
             bounds.size.width, bounds.size.height,
             CGDisplayPixelsWide(displays[i]), CGDisplayPixelsHigh(displays[i]));
  }

  if (displayNumber == -2) {
      selectedCount = displayCount;
      for (size_t i = 0; i < selectedCount; ++i)
          selectedDisplays[i] = displays[i];
      printf("Using all %zu active displays in one framebuffer\n", selectedCount);
  } else if (displayNumber == -1) {
      selectedCount = 1;
      selectedDisplays[0] = CGMainDisplayID();
      printf("Using primary display\n");
  } else if (displayNumber >= 0 && displayNumber < (int)displayCount) {
      selectedCount = 1;
      selectedDisplays[0] = displays[displayNumber];
      printf("Using specified display %d\n", displayNumber);
  } else {
      rfbErr("Specified display %d does not exist\n", displayNumber);
      return FALSE;
  }

  for (size_t i = 0; i < selectedCount; ++i) {
      CGRect bounds = CGDisplayBounds(selectedDisplays[i]);
      layoutInputs[i] = (MacVNCDisplayInput){
          .displayID = selectedDisplays[i],
          .logicalX = bounds.origin.x,
          .logicalY = bounds.origin.y,
          .logicalWidth = bounds.size.width,
          .logicalHeight = bounds.size.height,
          .pixelWidth = (int)CGDisplayPixelsWide(selectedDisplays[i]),
          .pixelHeight = (int)CGDisplayPixelsHigh(selectedDisplays[i]),
      };
  }
  if (!macVNCBuildDisplayLayout(layoutInputs, selectedCount, &displayLayout)) {
      rfbErr("Could not build a non-overlapping RFB display layout\n");
      return FALSE;
  }
  printf("Composite framebuffer: %dx%d\n", displayLayout.width, displayLayout.height);


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

  /* Configure password authentication if a password was supplied. */
  if (password && strlen(password) > 0) {
      macVNCClearStoredPassword();
      gPasswdList[0] = strdup(password);
      rfbScreen->authPasswdData = gPasswdList;
      rfbScreen->passwordCheck = macVNCPasswordCheck;
  } else {
      rfbErr("A non-empty VNC password is required\n");
      return FALSE;
  }

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

  rfbScreen->ptrAddEvent = PtrAddEvent;
  rfbScreen->kbdAddEvent = KbdAddEvent;
  macVNCInputSetContext(rfbScreen, &displayLayout);

  void (^captureErrorHandler)(NSError *) = ^(NSError *error) {
      rfbLog("Screen capture error: %s\n", [error.description UTF8String]);
      /* Do not show UI here. Report upward; AppDelegate owns the single
         permission popup and decides how to recover. */
      dispatch_async(dispatch_get_main_queue(), ^{
          if (macVNCScreenCaptureFailureHandler)
              macVNCScreenCaptureFailureHandler();
      });
  };

  screenCapturers = [[NSMutableArray alloc] initWithCapacity:selectedCount];
  for (size_t i = 0; i < selectedCount; ++i) {
      const MacVNCDisplayGeometry *geometry = &displayLayout.displays[i];
      ScreenCapturer *capturer = [[ScreenCapturer alloc]
          initWithDisplay:geometry->input.displayID
          captureFramesPerSecond:captureFramesPerSecond
          frameHandler:^(CMSampleBufferRef sampleBuffer) {
              updateCompositeFrame(sampleBuffer, geometry);
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
            startDisplayCaptures();
            rfbLog("First client password accepted; starting %lu display captures\n",
                   (unsigned long)screenCapturers.count);
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
    int remaining = atomic_load(&vncConnectedClients);
    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
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

int
vncServerGetPort(void)
{
    return atomic_load_explicit(&publishedServerPort, memory_order_acquire);
}

#if defined(MACVNC_ENABLE_TEST_HOOKS)
bool
macVNCServerHasLifecycleResourcesForTesting(void)
{
    pthread_mutex_lock(&serverLifecycleMutex);
    bool hasResources = serverHasLifecycleResourcesLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
    return hasResources;
}
#endif
