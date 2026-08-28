
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

#include <rfb/rfb.h>
#include <rfb/keysym.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <libgen.h>
#import "MacVNCTLS.h"

/* Mirror of the private constants in MacVNCTLS.c - kept tiny on purpose. */
#define MACVNC_VENCRYPT_MAJOR 0
#define MACVNC_VENCRYPT_MINOR 2
#define MACVNC_SUBTYPE_TLSVNC 258u
#include <sys/socket.h>
#include <time.h>

#import "RFBKeySym.h"
#import "DisplayLayout.h"
#import "DisplaySelection.h"
#import "MacVNCCompositor.h"
#import "MacVNCCaptureSession.h"
#import "MacVNCInput.h"
#import "FirstFrameBudget.h"
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


/* Injected permission gate; see mac.h. NULL means unrestricted. */
bool (*macVNCCaptureAllowed)(void) = NULL;

#if defined(MACVNC_ENABLE_TEST_HOOKS)
static _Atomic unsigned gCaptureStartCount = 0;
static _Atomic unsigned gCaptureStopCount = 0;
#endif

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
static rfbBool rfbServerInitialized = FALSE;
static _Atomic int publishedServerPort = -1;
/* Bumped by every start; stamped into capture-failure notifications so stale
 * ones (raised by a previous run, delivered after a modal) can be ignored. */
static _Atomic uint64_t serverGeneration = 0;
static pthread_mutex_t serverLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t clientLifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
/* Serialises capture start/stop ONLY. Never held together with
   clientLifecycleMutex, so no lock-order relation can arise between them. */
static pthread_mutex_t captureControlMutex = PTHREAD_MUTEX_INITIALIZER;
static bool gCapturesRunning = false;

/* Keep-warm window: after the last viewer leaves, captures are kept alive for
   this long so a quick reconnect (unlock, second device, app switch) does not
   pay the ScreenCaptureKit warm-up again - which showed up as the server
   sending its placeholder checkerboard for seconds. The privacy indicator
   stays lit during the window BY DESIGN; the hard stop still happens. */
#define MACVNC_CAPTURE_KEEP_WARM_NANOSECONDS (30ULL * NSEC_PER_SEC)
static _Atomic uint64_t gCaptureWarmDeadlineNs = 0; /* 0 = no pending stop */
#if defined(MACVNC_ENABLE_TEST_HOOKS)
static _Atomic uint64_t gCaptureKeepWarmOverrideNs = 0;
void macVNCSetCaptureKeepWarmForTesting(uint64_t ns)
{ atomic_store(&gCaptureKeepWarmOverrideNs, ns); }
#endif
static dispatch_queue_t gCaptureStopQueue;
static void macVNCEnsureStopQueue(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCaptureStopQueue = dispatch_queue_create(
            "net.christianbeier.macVNC.captureStop", DISPATCH_QUEUE_SERIAL);
    });
}

/* Per-client bookkeeping. Only one fact needs remembering: whether this client
   has been counted towards vncConnectedClients, so a disconnect decrements
   exactly once. A three-state readiness machine used to live here too; every
   one of its transitions produced nothing but a log line. */
typedef struct {
    rfbBool captureCounted;
} MacVNCClientState;

static rfbBool macVNCPasswordCheck(rfbClientPtr client,
                                   const char *encryptedPassword,
                                   int length);
void macVNCTLSHandleVeNCrypt(rfbClientPtr cl);

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
      /* Ask for the TOTAL first (NULL list), not just what fits: filling a
         16-slot array caps the answer at 16, which would silently drop the
         17th display instead of reporting an unsupported configuration. */
      CGGetActiveDisplayList(0, NULL, &reported);
      if (reported > 0)
          break;
      macVNCWakeDisplays();
      usleep(250000); /* 250ms */
  }
  if (reported == 0 || reported > MACVNC_MAX_DISPLAYS) {
      rfbErr("Unsupported active display count: %u\n", reported);
      return FALSE;
  }
  if (CGGetActiveDisplayList(MACVNC_MAX_DISPLAYS, ids, &reported) != kCGErrorSuccess ||
      reported == 0 || reported > MACVNC_MAX_DISPLAYS) {
      rfbErr("Could not enumerate %u active displays\n", reported);
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

  /* VeNCrypt TLSVnc (19/258): encrypted channel, password auth inside it.
     Registered IN ADDITION to classic type 2 so older clients keep working;
     viewers that care about encryption pick 19 and stop warning. */
  {
      static rfbSecurityHandler veNCryptHandler;
      veNCryptHandler.type = 19; /* rfbVeNCrypt */
      veNCryptHandler.handler = macVNCTLSHandleVeNCrypt;
      rfbRegisterSecurityHandler(&veNCryptHandler);
  }
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

/* Capture callbacks. Plain C function pointers rather than blocks: the session
   must not capture this file's state, and these two are the whole seam. */

static bool
compositeCapturedFrame(const MacVNCDisplayGeometry *geometry,
                       const uint8_t *pixels, size_t stride,
                       int width, int height)
{
    if (!pixels || !geometry)
        return true; /* nothing to composite; not a retryable condition */

    /* Copy BY VALUE before checking and using: `geometry` points into
       displayLayout, a static the NEXT start memsets and rewrites. The
       stuck-capturer path deliberately leaves a callback of the old run
       running across that boundary, so without the snapshot the check can
       pass against the old dimensions and the composite loop read the new
       ones - an out-of-bounds source read. */
    MacVNCDisplayGeometry snapshot = *geometry;

    if (width != snapshot.input.pixelWidth ||
        height != snapshot.input.pixelHeight) {
        rfbErr("Unexpected display %u frame size %dx%d (expected %dx%d)\n",
               snapshot.input.displayID, width, height,
               snapshot.input.pixelWidth, snapshot.input.pixelHeight);
        return true; /* wrong geometry: retrying cannot help */
    }
    return macVNCCompositorSubmitFrame(&snapshot, pixels, stride)
               ? true : false;
}

static void
reportCaptureFailure(bool likelyPermissionDenial)
{
    /* Stamp the run this failure belongs to, so a notification delivered late
       (queued behind a modal, after the server was stopped and restarted) can be
       discarded by the handler. */
    uint64_t generation = atomic_load(&serverGeneration);
    /* No UI here: AppDelegate owns the single permission popup. */
    if (macVNCScreenCaptureFailureHandler)
        macVNCScreenCaptureFailureHandler(likelyPermissionDenial, generation);
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
      /* Pre-flight: a syntactically valid address that no longer belongs to
         any interface (Wi-Fi off, VPN down, DHCP change) would only surface
         as a generic bind failure AFTER rfbInitServer, phrased like a port
         collision. Tell the user what actually happened, before we bind. */
      bool addressIsLocal = false;
      struct ifaddrs *interfaces = NULL;
      if (getifaddrs(&interfaces) == 0) {
          for (struct ifaddrs *ifa = interfaces; ifa; ifa = ifa->ifa_next) {
              if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET &&
                  ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr ==
                      parsedAddress.s_addr) {
                  addressIsLocal = true;
                  break;
              }
          }
          freeifaddrs(interfaces);
      }
      if (!addressIsLocal) {
          rfbErr("Listen address %s is not assigned to any active interface; "
                 "the selected network may be gone (Wi-Fi off, VPN down). "
                 "Re-select the interface in Preferences.\n", listenAddress);
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

  /* One call: MacVNCCaptureSession owns ScreenCaptureKit, unwraps each frame
     to plain pixels and classifies capture errors, so this file needs neither
     SCStream nor SCStreamError. */
  if (!macVNCCaptureSessionBuild(&displayLayout, captureFramesPerSecond,
                                 compositeCapturedFrame, reportCaptureFailure))
      return FALSE;

  rfbInitServer(rfbScreen);
  rfbServerInitialized = TRUE;
  /* From here the compositor owns the pointer: capture callbacks may fire at
     any time, and only its lock can make "detach" wait out an in-flight
     frame. */
  macVNCCompositorSetScreen(rfbScreen);

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


/*
 * Drives captures to match the one invariant that matters: they run if and only
 * if at least one authenticated client is connected.
 *
 * Both the connect and disconnect paths call this AFTER updating the count and
 * AFTER releasing clientLifecycleMutex - stopping can wait seconds for
 * in-flight ScreenCaptureKit work, and holding the client lock across that
 * would stall every other client thread, including a reconnect.
 *
 * Serialised on its own lock and re-reading the atomic count, so a disconnect
 * racing a reconnect cannot leave captures stopped while a client is watching:
 * whichever call takes the lock last applies the settled count.
 */
static void reconcileCaptureState(void)
{
    pthread_mutex_lock(&captureControlMutex);
    bool wanted = atomic_load(&vncConnectedClients) > 0;
    if (wanted && !gCapturesRunning) {
        atomic_store(&gCaptureWarmDeadlineNs, 0); /* reconnect beats the timer */
        if (captureIsAllowed()) {
            /* Awake-while-watched: the power assertions live as long as a
               viewer is connected, not as long as the LISTENER runs. With
               "Start at Login" the server may run for weeks; holding the
               assertions that whole time would be the pmset bug again with a
               nicer implementation. */
            if (dimmingInit() != 0)
                rfbLog("Power assertion failed; machine may idle-sleep during the session\n");
            macVNCCaptureSessionStart();
#if defined(MACVNC_ENABLE_TEST_HOOKS)
            atomic_fetch_add(&gCaptureStartCount, 1);
#endif
            gCapturesRunning = true;
            rfbLog("Client connected; starting %lu display captures\n",
                   (unsigned long)macVNCCaptureSessionCount());
        } else {
            /* Never touch capture without the permission: doing so is what
               makes macOS raise its own dialog. The decision belongs to the
               permission owner, injected via macVNCCaptureAllowed. */
            rfbLog("Screen Recording is not granted; refusing to start capture\n");
            if (macVNCScreenCaptureFailureHandler)
                macVNCScreenCaptureFailureHandler(true, vncServerCurrentGeneration());
        }
    } else if (!wanted && gCapturesRunning) {
        /* Keep warm: schedule the real stop 30s out. The decision here stays
           instant and lock-consistent; the stop itself runs OFF the control
           mutex (it waits seconds for in-flight SCK work). */
        macVNCEnsureStopQueue();
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        uint64_t warm = atomic_load(&gCaptureKeepWarmOverrideNs);
#else
        uint64_t warm = MACVNC_CAPTURE_KEEP_WARM_NANOSECONDS;
#endif
        uint64_t deadline = macVNCMonotonicNow() + warm;
        atomic_store(&gCaptureWarmDeadlineNs, deadline);
        __block dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gCaptureStopQueue);
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)warm),
            DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(timer, ^{
            dispatch_source_cancel(timer); /* one-shot */
            dispatch_release(timer); /* cancel stops the runtime retain */
            pthread_mutex_lock(&captureControlMutex);
            bool due = atomic_load(&gCaptureWarmDeadlineNs) != 0 &&
                       macVNCMonotonicNow() >=
                           atomic_load(&gCaptureWarmDeadlineNs);
            bool stillRunning = gCapturesRunning;
            bool stillWanted = atomic_load(&vncConnectedClients) > 0;
            if (due && stillRunning && !stillWanted) {
                gCapturesRunning = false;
                atomic_store(&gCaptureWarmDeadlineNs, 0);
            } else {
                due = false; /* reconnected meanwhile: keep warm wins */
            }
            pthread_mutex_unlock(&captureControlMutex);
            if (!due)
                return;
#if defined(MACVNC_ENABLE_TEST_HOOKS)
            atomic_fetch_add(&gCaptureStopCount, 1);
#endif
            dimmingShutdown();
            macVNCCaptureSessionStopAndWait();
            macVNCInputResetModifiers();
            rfbLog("Capture keep-warm window elapsed; %lu display captures stopped\n",
                   (unsigned long)macVNCCaptureSessionCount());
        });
        dispatch_resume(timer);
    }
    pthread_mutex_unlock(&captureControlMutex);
}

/*
 * Runs once per client, right after its password is accepted.
 *
 * Waits (bounded) for the first frame of every display so the auth OK is not
 * followed by a black screen. The wait is the point; nothing is remembered
 * about its outcome, because nothing acted on it.
 */
static void
prepareAuthenticatedClient(rfbClientPtr cl)
{
    bool counted = false;

    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    if (state && !state->captureCounted) {
        state->captureCounted = TRUE;
        atomic_fetch_add(&vncConnectedClients, 1);
        counted = true;
    }
    pthread_mutex_unlock(&clientLifecycleMutex);

    if (!counted)
        return;

    /* Outside the client lock: reconciling can stop captures, which waits. */
    reconcileCaptureState();

    if (!macVNCCaptureSessionWaitForFirstFrames(INITIAL_READINESS_TIMEOUT_NANOSECONDS))
        rfbLog("Initial display readiness timed out; sending frames as they arrive\n");
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

static void clientGone(rfbClientPtr cl)
{
    int remaining;

    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    if (state && state->captureCounted) {
        remaining = atomic_fetch_sub(&vncConnectedClients, 1) - 1;
        if (remaining <= 0) {
            remaining = 0;
            atomic_store(&vncConnectedClients, 0);
        }
    } else {
        /* Un-counted client (never authenticated): report the current count. */
        remaining = atomic_load(&vncConnectedClients);
    }
    cl->clientData = NULL;
    free(state);
    pthread_mutex_unlock(&clientLifecycleMutex);

    reconcileCaptureState();
    rfbLog("Client %s disconnected (%d authenticated remaining)\n", cl->host, remaining);
}

/* Classic VNC auth INSIDE the TLS channel for the VeNCrypt security type:
   send 16 random bytes, read 16 back, verify against our password list,
   report SecurityResult. Reuses the SAME store and check as type-2 auth -
   one password source, two transports. Runs on the client thread. */
bool
macVNCTLSRunVNCAuthInsideTLS(rfbClientPtr client)
{
    rfbRandomBytes(client->authChallenge);
    if (rfbWriteExact(client, (char *)client->authChallenge,
                      CHALLENGESIZE) < 0)
        return false;

    char response[CHALLENGESIZE];
    if (rfbReadExact(client, response, CHALLENGESIZE) <= 0)
        return false;

    bool ok = macVNCPasswordCheck(client, response, CHALLENGESIZE) ? true : false;

    uint32_t result = Swap32IfLE(ok ? 0 : 1); /* 0=OK 1=fail per RFB */
    if (rfbWriteExact(client, (char *)&result, 4) < 0)
        return false;
    if (!ok)
        rfbErr("macVNC TLS: password check failed\n");
    return ok;
}

/* ---------- VeNCrypt TLSVnc security handler (type 19 -> subtype 258) ----------
 * Wire order per VeNCrypt 0.2 after the client picks type 19:
 *   server: u8 major(0) u8 minor(2)
 *   client: echo
 *   server: u32 count, u32[] subtypes   (we offer exactly 258 = TLSVnc)
 *   client: u32 chosen
 *   ...TLS handshake (self-signed cert; transport trust comes from Tailscale
 *      + allowlist, the cert exists so the channel CAN be encrypted)...
 *   classic VNC password auth INSIDE the encrypted channel.
 * sockets.c routes all later I/O through SSL once cl->sslctx is set. */
void macVNCTLSHandleVeNCrypt(rfbClientPtr cl)
{
    char certPath[PATH_MAX], keyPath[PATH_MAX];
    if (!macVNCTLSEnsureCertificate(certPath, sizeof(certPath),
                                    keyPath, sizeof(keyPath))) {
        rfbErr("macVNC TLS: cannot obtain self-signed certificate\n");
        uint32_t fail = Swap32IfLE(0xFFFFFFFFu);
        rfbWriteExact(cl, (char *)&fail, 4);
        rfbCloseClient(cl);
        return;
    }
    cl->screen->sslcertfile = strdup(certPath);
    cl->screen->sslkeyfile  = strdup(keyPath);

    /* OpenSSL 4 defaults may exclude our self-signed-RSA setup ("library has
       no ciphers" at handshake). Point the TLS library at an explicit config
       BEFORE SSL_CTX creation; rfbssl_init runs right after this handler. */
    static char confPath[PATH_MAX];
    snprintf(confPath, sizeof(confPath), "%s/openssl-macvnc.cnf",
             dirname(certPath));
    FILE *f = fopen(confPath, "w");
    if (f) {
        fprintf(f,
            "openssl_conf = openssl_init\n"
            "\n"
            "[openssl_init]\n"
            "ssl_conf = ssl_sect\n"
            "\n"
            "[ssl_sect]\n"
            "system_default = system_default_sect\n"
            "\n"
            "[system_default_sect]\n"
            "CipherString = DEFAULT@SECLEVEL=0\n");
        fclose(f);
        setenv("OPENSSL_CONF", confPath, 1);
    }

    uint8_t ver[2] = { MACVNC_VENCRYPT_MAJOR, MACVNC_VENCRYPT_MINOR };
    if (rfbWriteExact(cl, (char *)ver, 2) < 0) { rfbCloseClient(cl); return; }
    uint8_t vReply[2];
    if (rfbReadExact(cl, (char *)vReply, 2) < 0) { rfbCloseClient(cl); return; }

    uint32_t count = Swap32IfLE(1);
    uint32_t sub   = Swap32IfLE(MACVNC_SUBTYPE_TLSVNC);
    if (rfbWriteExact(cl, (char *)&count, 4) < 0 ||
        rfbWriteExact(cl, (char *)&sub, 4) < 0) { rfbCloseClient(cl); return; }

    uint32_t chosenRaw;
    if (rfbReadExact(cl, (char *)&chosenRaw, 4) < 0) { rfbCloseClient(cl); return; }
    if (!macVNCTLSValidateClientVersions(vReply[0], vReply[1],
                                         Swap32IfLE(chosenRaw))) {
        rfbErr("macVNC TLS: client picked version %d.%d subtype %u - refused\n",
               vReply[0], vReply[1], Swap32IfLE(chosenRaw));
        uint32_t fail = Swap32IfLE(0xFFFFFFFFu);
        rfbWriteExact(cl, (char *)&fail, 4);
        rfbCloseClient(cl);
        return;
    }
    uint32_t ok = Swap32IfLE(1); /* VeNCrypt SecurityResult */
    if (rfbWriteExact(cl, (char *)&ok, 4) < 0) { rfbCloseClient(cl); return; }

    /* Exported by the dylib; header is internal to libvncserver. After a
       successful init sockets.c transparently SSL-wraps this client's I/O. */
    extern int rfbssl_init(rfbClientPtr cl);
    /* OpenSSL 3/4: SSL_library_init() inside rfbssl_init does NOT load the
       config, and without it SSL_CTX ends up with an EMPTY cipher list
       ("library has no ciphers"). Loading the default provider explicitly
       populates the algorithm table - the fix that made handshakes pass. */
    extern void *OSSL_PROVIDER_load(void *libctx, const char *name);
    static void *defaultProvider = NULL;
    if (!defaultProvider)
        defaultProvider = OSSL_PROVIDER_load(NULL, "default");
    if (rfbssl_init(cl) < 0) {
        rfbErr("macVNC TLS: handshake failed\n");
        rfbCloseClient(cl);
        return;
    }
    rfbLog("macVNC: client %s upgraded to encrypted (VeNCrypt TLSVnc)\n",
           cl->host ? cl->host : "?");

    /* BEFORE auth: prepareAuthenticatedClient (inside the password check)
       can block up to 3s waiting for first frames; the client's ClientInit
       may arrive during that wait and must land in the right state. The
       stock flow transitions before auth completes for the same reason. */
    cl->state = RFB_INITIALISATION;

    /* Classic VNC auth INSIDE the encrypted channel. */
    rfbRandomBytes(cl->authChallenge);
    bool authed = false;
    if (rfbWriteExact(cl, (char *)cl->authChallenge, CHALLENGESIZE) >= 0) {
        char response[CHALLENGESIZE];
        if (rfbReadExact(cl, response, CHALLENGESIZE) > 0) {
            authed = macVNCPasswordCheck(cl, response, CHALLENGESIZE) ? true : false;
        }
    }
    uint32_t result = Swap32IfLE(authed ? 0 : 1);
    rfbWriteExact(cl, (char *)&result, 4);
    if (!authed) {
        rfbErr("macVNC TLS: password check failed\n");
        rfbCloseClient(cl);
        return;
    }
    /* Authed over the encrypted channel: ClientInit has likely already
       arrived during the first-frame wait and been buffered/processed in
       RFB_INITIALISATION state. */
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
    return rfbScreen || frameBufferOne || macVNCCaptureSessionCount() > 0 ||
           macVNCInputHasResources();
}

static void
vncServerStopLocked(void)
{
    atomic_store_explicit(&publishedServerPort, -1, memory_order_release);
    /* A stop ENDS the run's identity, exactly as a start begins one. The
       capture-failure path stamps vncServerCurrentGeneration() into every
       notification it raises; with N displays that is N notifications for one
       run. Only the first must act - but if the generation only moved on
       START, all N still compare equal to the current run after the first one
       stopped us, and each stacks another modal alert. Bumping here makes
       notifications from a stopped run stale on arrival. */
    atomic_fetch_add(&serverGeneration, 1);
    /* LibVNCServer >=0.9.15 reverted detached client threads. This call stops
       accepting clients and joins every client/listener thread before lifecycle
       objects they can access are released. */
    if (rfbScreen && rfbServerInitialized)
        rfbShutdownServer(rfbScreen, TRUE);
    rfbServerInitialized = FALSE;

    pthread_mutex_lock(&captureControlMutex);
    gCapturesRunning = false;
    atomic_store(&gCaptureWarmDeadlineNs, 0); /* full stop beats keep-warm */
    pthread_mutex_unlock(&captureControlMutex);
    macVNCCaptureSessionStopAndWait();
    macVNCCaptureSessionReset();
    atomic_store(&vncConnectedClients, 0);
    if (rfbScreen) {
        /* Detach the compositor FIRST: SetScreen(NULL) takes the compositor
           lock, so it blocks until any in-flight composite has finished, and
           after it returns no callback can reach this screen. (The old order -
           NULL the global, then free - had a window: a callback that loaded
           the still-non-NULL pointer and was then descheduled walked into
           rfbGetClientIterator on freed memory. The stuck-capturer path makes
           that window real, since its callbacks deliberately keep running.) */
        rfbScreenInfoPtr dying = rfbScreen;
        rfbScreen = NULL;
        macVNCCompositorSetScreen(NULL);
        rfbScreenCleanup(dying);
    }
    /* Backstop: normally released when the last client leaves, but a stop
       with captures never started (permission denied at connect) or a crash
       path must not leak the assertions either. Idempotent. */
    dimmingShutdown();
    macVNCReleaseDisplayAssertion();
    macVNCInputShutdown();
    macVNCClearStoredPassword();
    free(frameBufferOne); frameBufferOne = NULL;
}

MacVNCServerStartResult
vncServerStartWithResult(const MacVNCServerConfig *config)
{
    if (!config) {
        rfbErr("vncServerStart: NULL configuration\n");
        return MacVNCServerStartFailed;
    }
    pthread_mutex_lock(&serverLifecycleMutex);
    if (serverHasLifecycleResourcesLocked()) {
        /* Not a failure: a run is already live. Told apart from a real failure
           so the UI does not advise changing the port while the server is
           serving on the current one. */
        rfbLog("VNC server is already running; start request ignored\n");
        pthread_mutex_unlock(&serverLifecycleMutex);
        return MacVNCServerStartAlreadyRunning;
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

    if (!macVNCInputStart())
        goto FAILURE;

    if (!ScreenInit(config->port, config->password, config->captureFramesPerSecond))
        goto FAILURE;

    rfbScreen->newClientHook = newClient;
    rfbRunEventLoop(rfbScreen, -1, TRUE);
    atomic_store_explicit(&publishedServerPort, rfbScreen->port, memory_order_release);
    pthread_mutex_unlock(&serverLifecycleMutex);
    return MacVNCServerStartOK;

FAILURE:
    vncServerStopLocked();
    pthread_mutex_unlock(&serverLifecycleMutex);
    return MacVNCServerStartFailed;
}

rfbBool
vncServerStart(const MacVNCServerConfig *config)
{
    return vncServerStartWithResult(config) == MacVNCServerStartOK ? TRUE : FALSE;
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
       another thread) but must never block the main thread, where this runs
       during a relaunch: the lock can be held for seconds by a stop waiting on
       capture work, or by a START doing display-wake retries and rfbInitServer.

       So: retry on a bounded budget rather than give up at once. Giving up
       immediately was wrong — a concurrent START would open the listener AFTER
       our "close", and the successor process would then fail to bind and report
       the port as in use. If the budget runs out we say so instead of leaving
       the caller believing the port was freed. */
    bool locked = false;
    for (int attempt = 0; attempt < 50 && !locked; ++attempt) {
        locked = pthread_mutex_trylock(&serverLifecycleMutex) == 0;
        if (!locked)
            usleep(10000); /* 10ms; 500ms total */
    }
    if (!locked) {
        rfbErr("Could not close listeners: server lifecycle busy; "
               "the successor may fail to bind\n");
        return;
    }
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
    /* Never BLOCK: this is called by the menu-refresh timer on the main thread,
       and the lifecycle lock can be held by a stop that is waiting on capture
       work. Blocking here would freeze the menu bar - the exact failure the
       relaunch path already guards against. A busy lock means the server is
       being reconfigured, so there is no stable address to report yet. */
    if (pthread_mutex_trylock(&serverLifecycleMutex) != 0)
        return FALSE;
    snprintf(bindAddress, size, "%s", macVNCListenAddress);
    pthread_mutex_unlock(&serverLifecycleMutex);
    return TRUE;
}


uint64_t
vncServerCurrentGeneration(void)
{
    return atomic_load(&serverGeneration);
}

rfbBool
vncServerActivePolicyAllowsEveryone(void)
{
    /* Main-thread caller (menu refresh): must not block on a stop in progress.
       Report the SAFE answer when the lock is busy - claiming "allow all" that
       is not in effect would be a security-relevant lie, and the next refresh
       a second later will read the settled value. */
    if (pthread_mutex_trylock(&serverLifecycleMutex) != 0)
        return FALSE;
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

void
macVNCReconcileCaptureForTesting(void)
{
    reconcileCaptureState();
}

unsigned
macVNCCaptureStartCountForTesting(void)
{
    return atomic_load(&gCaptureStartCount);
}

unsigned
macVNCCaptureStopCountForTesting(void)
{
    return atomic_load(&gCaptureStopCount);
}

/* Drives the real reconciler, so a test exercises the decision the server
   actually makes rather than a re-implementation of it. */
void
macVNCResetCaptureStateForTesting(void)
{
    atomic_store(&vncConnectedClients, 0);
    reconcileCaptureState();
    atomic_store(&gCaptureStartCount, 0);
    atomic_store(&gCaptureStopCount, 0);
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
