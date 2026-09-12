
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
#import "DisplayReadiness.h"
#import "MacVNCLayoutRegistry.h"
#import "CaptureLiveness.h"
#import "MacVNCCaptureSupervisor.h"
#import "MacVNCPowerMgmt.h"
#import "MacVNCClamshell.h"
#import "mac.h"
#import <AppKit/AppKit.h>

/* The main LibVNCServer screen object */
static rfbScreenInfoPtr rfbScreen;

/* Set by AppDelegate; invoked on the main queue when capture fails at runtime. */
void (*macVNCScreenCaptureFailureHandler)(bool likelyPermissionDenial,
                                          uint64_t serverGeneration,
                                          uint64_t captureGeneration) = NULL;


/* Injected permission gate; see mac.h. NULL means unrestricted. */
bool (*macVNCCaptureAllowed)(void) = NULL;

/* Set by AppDelegate; see mac.h. Says only "the authenticated client count may
   have moved", never how far, so two notifications cannot be reordered into a
   connection that never happened. */
void (*macVNCAuthenticatedClientsChangedHandler)(void) = NULL;

static void notifyAuthenticatedClientsChanged(void)
{
    if (macVNCAuthenticatedClientsChangedHandler)
        macVNCAuthenticatedClientsChangedHandler();
}

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
/* The concrete display a `displayNumber >= 0` selection has pinned to, once
   resolved by position for the first time in a server run - owned by
   MacVNCLayoutRegistry now (see its header for the full reasoning); reset to
   0 at every server (re)start, alongside `displayNumber` itself, in
   vncServerStart below. */
static char macVNCListenAddress[MACVNC_LISTEN_ADDRESS_MAX] = {0};
static char macVNCAllowedClients[MACVNC_ALLOWED_CLIENTS_MAX] = {0};
static MacVNCClientAccessMode macVNCClientAccessMode = MACVNC_CLIENT_ACCESS_FAIL_CLOSED;
static MacVNCNetworkAccessList clientAccessList;

/* Password handed to LibVNCServer; must outlive rfbScreen. Zeroized + freed on
 * every (re)start and on server stop so cleartext does not linger. */
static char *gPasswdList[2] = {NULL, NULL};
/* Guards gPasswdList[0] against vncServerCopyPassword(), which curtain mode
   calls from the MAIN thread while a start or a stop may be replacing it.
   Deliberately NOT serverLifecycleMutex: that one is held across client-thread
   joins and bounded capture waits, i.e. for seconds, and the curtain asks this
   question once per heartbeat. A leaf lock held for a strlen and a memcpy
   cannot stall anything. LibVNCServer's own reads of authPasswdData are
   unchanged and unaffected: the list is only ever replaced while no client
   thread exists. */
static pthread_mutex_t passwordMutex = PTHREAD_MUTEX_INITIALIZER;

static void macVNCClearStoredPassword(void)
{
    pthread_mutex_lock(&passwordMutex);
    if (gPasswdList[0]) {
        memset(gPasswdList[0], 0, strlen(gPasswdList[0]));
        free(gPasswdList[0]);
        gPasswdList[0] = NULL;
    }
    pthread_mutex_unlock(&passwordMutex);
}

size_t
vncServerCopyPassword(char *buffer, size_t size)
{
    if (!buffer || size == 0)
        return 0;
    pthread_mutex_lock(&passwordMutex);
    size_t length = gPasswdList[0] ? strlen(gPasswdList[0]) : 0;
    if (length == 0 || length >= size)
        length = 0;   /* none, or it would not fit: see mac.h on truncation */
    else
        memcpy(buffer, gPasswdList[0], length);
    pthread_mutex_unlock(&passwordMutex);
    buffer[length] = '\0';
    return length;
}
/*
 * The published display layout (double-buffered) and the capture-session
 * generation counter both moved to MacVNCLayoutRegistry.{h,c}
 * (.pi/plans/core-decomposition.md, step 7) - see that header for the full
 * reasoning (why two slots, why the generation is never reset, why 0 is a
 * safe sentinel for each). This file reaches them only through
 * macVNCLayoutRegistryCurrent()/Publish()/NextSessionGeneration()/
 * CurrentSessionGeneration()/PinnedDisplay()/PinDisplay()/ResetPin() from
 * here on.
 */

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
/* True only for the SINGLE connect immediately following ScreenInit's own
   waking resolveDisplayLayout() - that Build is already fresh, so the very
   first client must not pay a second, non-waking rebuild for nothing.
   Consumed once, whether or not that connect succeeds. See ARCHITECTURE.md
   § CaptureLiveness (FIX-B item 1) for why every LATER arrival needs the
   rebuild this flag skips only for the first. */
static bool gCaptureSessionFreshAtStartup = false;

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

/* Liveness (gLastFrameNs, gCapturesStartedNs, gLastRearmNs,
   gRearmsSinceFrame, gCaptureLivenessTimer), the FIX-D desk-shape debounce
   (gDeskShapeDebounceTimer and its 500ms constant) and their test-only
   counters/overrides all moved to MacVNCCaptureSupervisor.{h,m}
   (.pi/plans/core-decomposition.md, step 8) - a pure move, same as step 7's
   MacVNCLayoutRegistry: this file reaches them only through
   macVNCCaptureSupervisor*() and the injected hooks configured in
   ensureCaptureSupervisorConfigured() below. See MacVNCCaptureSupervisor.h
   for the WHY comments this used to carry inline. */

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* F1 (post-effort test-gap fix): the pin itself, read-only - so a test can
   assert it is set exactly once per resolve, survives every re-arm trigger,
   and is never silently swapped for a different display's id. */
uint32_t macVNCPinnedDisplayIDForTesting(void)
{ return macVNCLayoutRegistryPinnedDisplay(); }
/* Forces applySelectionAndBuildLayout()'s pinned-id LOOKUP to miss, as if
   the pinned display had just been unplugged, without needing to physically
   remove a monitor: the ONE fault a test cannot otherwise produce on demand -
   the same reasoning as MacVNCCaptureSupervisor.h's own force-different
   desk-shape hook. Unlike an early return, this substitutes an impossible id
   into the value macVNCSelectDisplayByID() searches for (see
   applySelectionAndBuildLayout's own comment on `lookupID`) - every part of
   the refusal path this exercises, INCLUDING the miss itself, is real,
   unmocked applySelectionAndBuildLayout/rearmCaptures/macVNCSelectDisplayByID
   code. */
static _Atomic bool gForcePinnedDisplayGoneForTesting = false;
void macVNCForcePinnedDisplayGoneForTesting(bool force)
{ atomic_store(&gForcePinnedDisplayGoneForTesting, force); }
#endif

/* Per-client bookkeeping: which counters this client has been added to, so a
   disconnect subtracts from each exactly once. There are TWO because the two
   answers are needed at different moments - captures must start the instant a
   password is accepted (they are what produces the first frame), while the
   curtain may only hide a viewer that is already RECEIVING frames. A client
   that disconnects during the first-frame wait was never added to the second.
   A three-state readiness machine used to live here too; every one of its
   transitions produced nothing but a log line. */
typedef struct {
    rfbBool captureCounted;
    rfbBool updatesCounted;
} MacVNCClientState;

static rfbBool macVNCPasswordCheck(rfbClientPtr client,
                                   const char *encryptedPassword,
                                   int length);
void macVNCTLSHandleVeNCrypt(rfbClientPtr cl);

/* How long a freshly authenticated client waits for every display's first
   frame before the server gives up and lets it proceed - a CEILING, not a
   delay. See ARCHITECTURE.md § FirstFrameBudget for the measured cold-start
   numbers behind this value. */
#define INITIAL_READINESS_TIMEOUT_NANOSECONDS (8ULL * NSEC_PER_SEC)

/* Number of currently connected clients (read by AppDelegate for status display) */
_Atomic int vncConnectedClients = 0;

/* The narrower count: clients past the first-frame wait. See mac.h. */
_Atomic int vncAuthenticatedClientsReceivingUpdates = 0;



/* Which displays are ATTACHED, whether or not asleep - CGGetOnlineDisplayList
   is the only enumerator that survives display sleep, giving the wait below
   a target instead of a threshold. Mirrored secondaries are dropped (the
   online list, unlike the active list, reports them with identical bounds,
   which would make macVNCBuildDisplayLayout fail as overlapping). See
   ARCHITECTURE.md § DisplayReadiness for the measurement behind this. */
/* The active list as plain ids. Both the wait and its log line need it, and
   writing the CGGetActiveDisplayList dance twice is how the two drift. */
static size_t
readActiveDisplayIDs(uint32_t *out, size_t capacity)
{
  CGDirectDisplayID active[MACVNC_MAX_DISPLAYS];
  CGDisplayCount reported = 0;
  if (CGGetActiveDisplayList(MACVNC_MAX_DISPLAYS, active, &reported) != kCGErrorSuccess)
      return 0;

  size_t kept = 0;
  for (CGDisplayCount i = 0; i < reported && kept < capacity; ++i)
      out[kept++] = (uint32_t)active[i];
  return kept;
}

static size_t
readOnlineDisplays(uint32_t *out, size_t capacity)
{
  CGDirectDisplayID online[MACVNC_MAX_DISPLAYS];
  CGDisplayCount reported = 0;
  if (CGGetOnlineDisplayList(MACVNC_MAX_DISPLAYS, online, &reported) != kCGErrorSuccess)
      return 0;

  size_t kept = 0;
  for (CGDisplayCount i = 0; i < reported && kept < capacity; ++i) {
      if (CGDisplayMirrorsDisplay(online[i]) != kCGNullDirectDisplay)
          continue;
      out[kept++] = (uint32_t)online[i];
  }
  return kept;
}

/* Turn the CURRENTLY ACTIVE CoreGraphics display list into MacVNCDisplayInput
 * entries. No waking, no waiting - safe to call where lighting a sleeping
 * panel is forbidden (the re-arm path). Shared by startup's waking read and
 * the non-waking re-arm read, so the two cannot drift apart.
 * `logEnumeration` gates the "Found ... display ..." log line - FALSE for a
 * probe that only COMPARES against the published layout, so a settled
 * notification burst does not log a full enumeration for nothing. See
 * ARCHITECTURE.md § CaptureLiveness (FIX-E) for the bug this fixed. */
static rfbBool
collectDisplayInputs(MacVNCDisplayInput *displays, size_t *count, int *primaryIndex,
                     bool logEnumeration)
{
  CGDirectDisplayID ids[MACVNC_MAX_DISPLAYS];
  CGDisplayCount reported = 0;

  /* Ask for the TOTAL (NULL list), not just what fits: filling a 16-slot array
     caps the answer at 16, which would silently drop the 17th display instead
     of reporting an unsupported configuration. */
  CGGetActiveDisplayList(0, NULL, &reported);
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
      /* rfbLog, not printf. These lines used to go to stdout, and macVNC is
         launched with `open`, which captures only stderr - so the one piece of
         diagnostic output that says which monitors the server actually found
         was invisible in the log exactly when a monitor was missing. Gated on
         logEnumeration: a caller that is only comparing, not acting, gets this
         same list silently - see this function's header comment. */
      if (logEnumeration)
          rfbLog("Found %s display %zu id=%u at (%.0f,%.0f), logical %.0fx%.0f, pixels %dx%d\n",
                 ids[i] == mainID ? "primary" : "secondary", i, ids[i],
                 displays[i].logicalX, displays[i].logicalY,
                 displays[i].logicalWidth, displays[i].logicalHeight,
                 displays[i].pixelWidth, displays[i].pixelHeight);
  }
  *count = reported;
  return TRUE;
}

/* Enumerate the displays to capture, waiting for the WHOLE desk to wake -
 * see ARCHITECTURE.md § DisplayReadiness for the measured bug a
 * first-non-zero-count loop had. STARTUP ONLY: this wakes the desk; the
 * re-arm path re-reads with collectDisplayInputs() directly. */
static rfbBool
readAttachedDisplays(MacVNCDisplayInput *displays, size_t *count, int *primaryIndex)
{
  uint32_t expected[MACVNC_MAX_DISPLAYS];
  size_t expectedCount = readOnlineDisplays(expected, MACVNC_MAX_DISPLAYS);

  uint32_t awakeIDs[MACVNC_MAX_DISPLAYS];
  size_t awakeCount = 0;

  macVNCWakeDisplays();
  for (int attempt = 0; attempt < 20; ++attempt) {
      awakeCount = readActiveDisplayIDs(awakeIDs, MACVNC_MAX_DISPLAYS);
      if (awakeCount > 0 &&
          macVNCDisplaysAllActive(awakeIDs, awakeCount, expected, expectedCount))
          break;
      macVNCWakeDisplays();
      usleep(250000); /* 250ms */
  }

  /* Timed out with part of the desk still dark: serve what there is rather
     than refuse, and name what is missing - a bare count leaves the user
     guessing which cable to check. */
  uint32_t missing[MACVNC_MAX_DISPLAYS];
  size_t missingCount = macVNCDisplaysMissing(awakeIDs, awakeCount,
                                              expected, expectedCount,
                                              missing, MACVNC_MAX_DISPLAYS);
  for (size_t i = 0; i < missingCount; ++i)
      rfbLog("Display %u is attached but did not wake in time; it will not be "
             "part of this session\n", missing[i]);

  /* Startup: always a real resolution, never a probe - log every display. */
  return collectDisplayInputs(displays, count, primaryIndex, true);
}

/* Apply the configured selection to an already-read attached-display list
   and build the composite layout INTO *layout. Shared by startup (waking
   readAttachedDisplays()) and re-arm (non-waking collectDisplayInputs()),
   so the selection rules exist in one place regardless of how the desk was
   read. Does not log: callers differ on whether the result is a publish or
   only a probe to COMPARE against the live layout.

   E2: `displayNumber >= 0` resolves by POSITION only the first time per
   server run, then by DISPLAY IDENTITY forever after (never by position
   again); refuses rather than substitutes if that display vanishes. -1/-2
   bypass the pin and keep re-evaluating live. See ARCHITECTURE.md §
   MacVNCLayoutRegistry ("FIX-E") for the incident and proof. */
static rfbBool
applySelectionAndBuildLayout(const MacVNCDisplayInput *attached, size_t attachedCount,
                             int primaryIndex, MacVNCDisplayLayout *layout)
{
  MacVNCDisplayInput selected[MACVNC_MAX_DISPLAYS];
  size_t selectedCount = 0;
  uint32_t pinnedID = macVNCLayoutRegistryPinnedDisplay();

  if (displayNumber >= 0 && pinnedID != 0) {
      uint32_t lookupID = pinnedID;
#if defined(MACVNC_ENABLE_TEST_HOOKS)
      /* H1: substitutes only the LOOKUP id (never `pinnedID` itself, so the
         pin does not vanish) with 0 (kCGNullDirectDisplay), which can never
         match a real display - forcing the SAME unmocked refusal path a
         real vanished display takes. See
         macVNCForcePinnedDisplayGoneForTesting's own comment in mac.h for
         why this beats an early return. */
      if (atomic_load(&gForcePinnedDisplayGoneForTesting))
          lookupID = 0;
#endif
      if (macVNCSelectDisplayByID(attached, attachedCount, lookupID,
                                  selected, &selectedCount) != MACVNC_DISPLAY_SELECTION_OK) {
          rfbErr("Pinned display id=%u (selection %d) is no longer attached; "
                 "keeping the previous layout rather than silently capturing "
                 "a different monitor\n", pinnedID, displayNumber);
          return FALSE;
      }
  } else {
      switch (macVNCSelectDisplays(attached, attachedCount, primaryIndex,
                                   displayNumber, selected, &selectedCount)) {
      case MACVNC_DISPLAY_SELECTION_OK:
          if (displayNumber >= 0)
              macVNCLayoutRegistryPinDisplay(selected[0].displayID);
          break;
      case MACVNC_DISPLAY_SELECTION_NO_SUCH_DISPLAY:
          rfbErr("Specified display %d does not exist\n", displayNumber);
          return FALSE;
      case MACVNC_DISPLAY_SELECTION_UNSUPPORTED_COUNT:
      default:
          rfbErr("Unsupported display selection\n");
          return FALSE;
      }
  }

  if (!macVNCBuildDisplayLayout(selected, selectedCount, layout)) {
      rfbErr("Could not build a non-overlapping RFB display layout\n");
      return FALSE;
  }
  return TRUE;
}

/* Name the displays, not just how many. displayNumber >= 0 selects by
   POSITION in the enumeration, so after a monitor is unplugged the same
   stored number designates a different physical screen - a switch that would
   otherwise happen with nothing said. Split out of resolveDisplayLayout() so
   a re-arm that actually changes the published layout can announce it with
   the same line startup uses, instead of a second copy of this formatting. */
static void
logCapturingLayout(const MacVNCDisplayLayout *layout)
{
  char ids[MACVNC_MAX_DISPLAYS * 12 + 1];
  size_t used = 0;
  ids[0] = '\0';
  for (size_t i = 0; i < layout->count && used < sizeof ids - 1; ++i) {
      int n = snprintf(ids + used, sizeof ids - used, "%s%u",
                       i ? "," : "", layout->displays[i].input.displayID);
      if (n < 0)
          break;
      used += (size_t)n;
  }
  rfbLog("Capturing %zu display(s) [id %s]; composite framebuffer: %dx%d\n",
         layout->count, ids, layout->width, layout->height);
}

/* Discover displays, apply the configured selection, build the composite
   layout. Split out of ScreenInit: display topology has nothing to do with
   networking, auth or framebuffer setup, and the selection rules are now
   unit-tested in DisplaySelection.c. */
static rfbBool
resolveDisplayLayout(void)
{
  MacVNCDisplayInput attached[MACVNC_MAX_DISPLAYS];
  size_t attachedCount = 0;
  int primaryIndex = -1;

  if (!readAttachedDisplays(attached, &attachedCount, &primaryIndex))
      return FALSE;

  /* Build into a stack-local scratch layout, same as the re-arm path below,
     then publish through the one swap point - so "how a layout becomes THE
     published layout" has exactly one implementation, used at startup and at
     every re-arm alike. */
  MacVNCDisplayLayout freshLayout;
  if (!applySelectionAndBuildLayout(attached, attachedCount, primaryIndex, &freshLayout))
      return FALSE;
  logCapturingLayout(macVNCLayoutRegistryPublish(&freshLayout));
  return TRUE;
}

/* Re-read the desk WITHOUT waking it and run it through the SAME selection
   and layout rules resolveDisplayLayout() trusts at startup, into a caller-
   owned scratch layout rather than the published one - see rearmCaptures,
   which must not publish anything until the canvas it describes exists.

   `logEnumeration` passes straight through to collectDisplayInputs(): TRUE
   for a caller that is already committed to acting on this read (rearmCaptures,
   which only ever runs when a rebuild is actually happening), FALSE for a
   caller that is merely comparing this read against the published layout
   (FIX-D's debounce evaluation) and must stay silent when the two turn out
   equal - the only outcome most notifications ever produce. */
static rfbBool
resolveDeskLayoutWithoutWaking(MacVNCDisplayLayout *layout, bool logEnumeration)
{
  MacVNCDisplayInput attached[MACVNC_MAX_DISPLAYS];
  size_t attachedCount = 0;
  int primaryIndex = -1;

  if (!collectDisplayInputs(attached, &attachedCount, &primaryIndex, logEnumeration))
      return FALSE;
  return applySelectionAndBuildLayout(attached, attachedCount, primaryIndex, layout);
}

/* MacVNCCaptureSupervisor's `readDeskLayoutWithoutWaking` hook: the ONE
   caller inside this file that ever passed logEnumeration=false (the
   debounce's own probe, formerly deskShapeDebounceFired) - see
   resolveDeskLayoutWithoutWaking's own comment for why. `bool`, not
   `rfbBool`: the hook signature is plain C so MacVNCCaptureSupervisor.h
   never needs to know about LibVNCServer's boolean type. */
static bool
resolveDeskLayoutWithoutWakingQuiet(MacVNCDisplayLayout *out)
{
  return resolveDeskLayoutWithoutWaking(out, false) ? true : false;
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
  pthread_mutex_lock(&passwordMutex);
  gPasswdList[0] = strdup(password);
  pthread_mutex_unlock(&passwordMutex);
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

/*
 * The encoding settings for this run. Read by displayHook on the client
 * threads, written once before rfbInitServer publishes the screen.
 */
static MacVNCImageProfile gImageProfile;

/*
 * The capture rate this run was started with. Set once by ScreenInit,
 * re-read by the liveness watchdog's re-arm: it rebuilds the SAME session
 * ScreenInit built, and a session built at the wrong rate is exactly the kind
 * of silent mismatch this whole mechanism exists to avoid introducing.
 */
static int gCaptureFramesPerSecond;

/*
 * Whether an unencrypted viewer is admitted. Written once before
 * rfbInitServer publishes the screen, read on client threads.
 */
static MacVNCEncryptionPolicy gEncryptionPolicy = MacVNCEncryptionOptional;

/*
 * Imposes the configured image profile just before this client's update is
 * encoded, deliberately OVERRIDING what the viewer asked for (the "viewer"
 * profile is how to opt out). displayHook is the only seam LibVNCServer
 * offers after SetEncodings. See ARCHITECTURE.md's "Image profile is
 * imposed per frame, on purpose" for why and the live-measured proof.
 */
static void
applyImageProfile(rfbClientPtr cl)
{
    if (!cl)
        return;

    switch (gImageProfile.kind) {
        case MacVNCImageProfileFollowViewer:
            return; /* the hook is not installed in this case */
        case MacVNCImageProfileLossless:
            /* -1 is what keeps Tight on its lossless path: with a quality level
               set, photographic subrects go through JPEG. */
            cl->tightQualityLevel = -1;
            break;
        case MacVNCImageProfileJPEG:
            cl->tightQualityLevel = gImageProfile.qualityLevel;
            break;
    }
    cl->tightCompressLevel = MACVNC_IMAGE_COMPRESS_LEVEL;
}

static bool
compositeCapturedFrame(MacVNCCaptureFrameOrigin origin,
                       const uint8_t *pixels, size_t stride,
                       int width, int height,
                       const MacVNCDirtyHint *hint)
{
    if (!pixels)
        return true; /* nothing to composite; not a retryable condition */

    /* Reject a frame from a session that is no longer current BEFORE reading
       anything else - this replaces a scan that compared `geometry`'s
       ADDRESS against the published layout's slots, which only rejected a
       callback stuck across exactly ONE re-arm; reused two re-arms later, it
       could resurrect gLastFrameNs for a display the frame has nothing to do
       with (see MacVNCLayoutRegistry.c's published layout and MacVNCCaptureFrameOrigin). An explicit,
       monotonically increasing, NEVER REUSED generation has no reuse window:
       whatever this frame carries either equals the CURRENT generation or it
       does not, however many re-arms separate the two. */
    if (origin.generation != macVNCLayoutRegistryCurrentSessionGeneration())
        return true; /* stale session; not retryable, nothing to composite */

    /* Load the published layout EXACTLY ONCE and read every field below
       through this local - see MacVNCLayoutRegistry.c's own comment on the
       published layout for why. Before the
       double-buffer swap this touched the `displayLayout` global directly,
       field by field, which raced a re-arm's in-place overwrite of that same
       global; loading the pointer once makes this whole function see a
       single, self-consistent publish no matter what a concurrent re-arm
       publishes in the meantime. */
    const MacVNCDisplayLayout *layout = macVNCLayoutRegistryCurrent();

    /* Defensive, not expected: the generation check above already guarantees
       `origin.displayIndex` was valid for the layout the CURRENT generation
       was Built against, and that layout cannot have changed since without
       ALSO bumping the generation (both only ever change together, inside
       one re-arm, on the single serial gCaptureStopQueue writer - see
       nextCaptureSessionGeneration). Trusting an index from a capture
       callback without a bounds check anyway is the kind of shortcut that
       turns a future refactor into an out-of-bounds read. */
    if (origin.displayIndex >= layout->count)
        return true;

    /* The ONE write point for "a frame arrived", delegated to
       MacVNCCaptureSupervisor (step 8; I7: exactly two atomic ops, no lock).
       Reaching this call with a matching generation IS the liveness signal,
       independent of the size check below - wrong-sized frames are a
       different bug from no frames at all. See ARCHITECTURE.md §
       CaptureLiveness (FIX-C) for the MIN-to-MAX incident and the TOCTOU
       bound this relies on. */
    macVNCCaptureSupervisorNoteFrame(origin.displayIndex);

    /* Copy BY VALUE before using: a concurrent re-arm cannot publish a NEWER
       layout out from under `layout` without ALSO bumping the generation this
       function already checked above, so unlike before this snapshot is not
       guarding against that case - it exists so the width/height guard and
       the compositor call below read one coherent struct instead of the
       array element potentially twice, at two different optimizer-visible
       times. */
    MacVNCDisplayGeometry snapshot = layout->displays[origin.displayIndex];

    if (width != snapshot.input.pixelWidth ||
        height != snapshot.input.pixelHeight) {
        rfbErr("Unexpected display %u frame size %dx%d (expected %dx%d)\n",
               snapshot.input.displayID, width, height,
               snapshot.input.pixelWidth, snapshot.input.pixelHeight);
        return true; /* wrong geometry: retrying cannot help */
    }
    return macVNCCompositorSubmitFrame(&snapshot, pixels, stride, hint)
               ? true : false;
}

static void
reportCaptureFailure(bool likelyPermissionDenial)
{
    /* Stamp the run this failure belongs to, so a notification delivered late
       (queued behind a modal, after the server was stopped and restarted) can be
       discarded by the handler. */
    uint64_t generation = atomic_load(&serverGeneration);
    /* AND stamp which capture ATTEMPT it belongs to: the registry's session generation
       changes on every Build, successful or not (macVNCLayoutRegistryNextSessionGeneration()
       runs unconditionally at the top of rearmCaptures(), and again at every
       ScreenInit/reconcile Build) - so this is a distinct number per re-arm
       attempt within the SAME server run, which is exactly what
       macVNCShouldActOnCaptureFailure needs to stop deduplicating a failed
       re-arm, then another, then an honest GiveUp down to a single silent
       report. */
    uint64_t captureGeneration = macVNCLayoutRegistryCurrentSessionGeneration();
    /* No UI here: AppDelegate owns the single permission popup. */
    if (macVNCScreenCaptureFailureHandler)
        macVNCScreenCaptureFailureHandler(likelyPermissionDenial, generation, captureGeneration);
}

/* MacVNCCaptureSupervisor's `reportFailure` hook: both of its call sites
   (the silence watchdog's GiveUp case, a failed desk-shape rebuild) always
   passed `false` here, never `true` - this wrapper is that fixed argument,
   so the hook signature stays a plain `void (*)(void)` and the supervisor
   never needs to know a permission-denial flag exists. */
static void
reportCaptureFailureForSupervisor(void)
{
    reportCaptureFailure(false);
}

static rfbBool
ScreenInit(int port, const char *password, int captureFramesPerSecond,
           MacVNCImageProfile imageProfile,
           MacVNCEncryptionPolicy encryptionPolicy)
{
  int bitsPerSample = 8;

  if (captureFramesPerSecond < MACVNC_CAPTURE_FPS_MIN ||
      captureFramesPerSecond > MACVNC_CAPTURE_FPS_MAX) {
      rfbErr("Invalid capture rate: %d FPS\n", captureFramesPerSecond);
      return FALSE;
  }
  int framebufferDeferMilliseconds =
      macVNCFramebufferDeferMilliseconds(captureFramesPerSecond);
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
  /* Loaded once, right after publish, on this single-threaded startup path -
     no capture session or watchdog exists yet to publish a newer generation
     out from under this local, so one load is enough for the whole function. */
  const MacVNCDisplayLayout *layout = macVNCLayoutRegistryCurrent();

  rfbScreen = rfbGetScreen(&dummyArgc, dummyArgv,
                           layout->width,
                           layout->height,
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

  gCaptureFramesPerSecond = captureFramesPerSecond;
  gEncryptionPolicy = encryptionPolicy;
  rfbLog("Encryption: %s\n", macVNCEncryptionPolicyName(encryptionPolicy));
  gImageProfile = imageProfile;
  if (imageProfile.kind != MacVNCImageProfileFollowViewer)
      rfbScreen->displayHook = applyImageProfile;
  rfbLog("Image profile: %s\n", macVNCImageProfileName(imageProfile));

  gethostname(rfbScreen->thisHost, 255);
  rfbScreen->thisHost[254] = '\0'; /* gethostname need not NUL-terminate on truncation */

  /* A single zeroed composite canvas keeps uncovered display gaps black. */
  size_t bufSize = (size_t)layout->width * (size_t)layout->height * 4;
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
  macVNCInputSetContext(rfbScreen, layout);

  /* One call: MacVNCCaptureSession owns ScreenCaptureKit, unwraps each frame
     to plain pixels and classifies capture errors, so this file needs neither
     SCStream nor SCStreamError. The very first generation ever claimed - no
     older session exists yet to invalidate, so unlike rearmCaptures there is
     no ordering requirement on when this happens relative to anything else
     here. */
  if (!macVNCCaptureSessionBuild(layout, macVNCLayoutRegistryNextSessionGeneration(),
                                 captureFramesPerSecond,
                                 compositeCapturedFrame, reportCaptureFailure,
                                 false /* no client has ever raised the curtain yet */))
      return FALSE;
  /* No client has connected yet - nothing can race this write with a read in
     startCapturesForNewClient() (the server is not even listening). See
     gCaptureSessionFreshAtStartup for what it buys the very first connect. */
  gCaptureSessionFreshAtStartup = true;

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


/* A plain, cheap read of "is any display awake right now" - no waking, no
   display objects built, just the count collectDisplayInputs() itself checks
   first. Reused by nothing else: collectDisplayInputs() needs the full list
   to build a layout from, this needs only whether it would be empty, and a
   shared helper for one comparison against zero is not worth the coupling.
   Also MacVNCCaptureSupervisor's `anyDisplayActive` hook - its signature
   already matches exactly, so it is passed as-is, no wrapper needed. */
static bool
anyDisplayCurrentlyActive(void)
{
    CGDisplayCount reported = 0;
    CGGetActiveDisplayList(0, NULL, &reported);
    return reported > 0;
}

/* captureLivenessLimits() and freshestFrameStamp() moved to
   MacVNCCaptureSupervisor.m with the watchdog they served - see
   MacVNCCaptureSupervisor.h. */

/* E2 (.pi/plans/capture-liveness.md): this used to be
   logIfPinnedSelectionChangedDisplay(), which only DETECTED after the fact
   that a pinned `displayNumber >= 0` had silently resolved to a different
   physical display and logged about it. applySelectionAndBuildLayout() now
   PINS the selection to the display identity it first resolved
   (the registry's pin) and never substitutes another one, so that detector's
   only case (displayNumber >= 0) can no longer fire - before/after are always
   the same identity, or the resolution fails outright and is reported
   through reportCaptureFailure(false). Removed rather than left as dead code. */

/*
 * Stop, re-read the desk, and rebuild - either the SAME layout's streams (a
 * stream that went silent with no SCStream error to react to: the measured
 * bug, where the desk changed shape, `didStopWithError` never fired, and
 * viewers kept a 42-hour-old frame) or, when the re-read shows the desk
 * itself changed shape, a NEW canvas and layout to match it. That second case
 * is what actually fixes the measured incident: a stream restart alone cannot
 * help when the geometry it was restarted onto is no longer the truth.
 */
/*
 * Build + Start, the tail every rearmCaptures() branch below ends with:
 * failure leaves the compositor on whatever screen/frameBuffer it already
 * had (never a torn-down one - the caller's only recourse on `false` is
 * reportCaptureFailure(false), never a server stop), success starts
 * streaming on `layout` immediately. Written once so the two branches below
 * cannot drift on this shared ending - see ARCHITECTURE.md § CaptureLiveness.
 */
static bool
buildAndStartCapture(const MacVNCDisplayLayout *layout, uint64_t generation,
                     bool wasExcluded)
{
    if (!macVNCCaptureSessionBuild(layout, generation, gCaptureFramesPerSecond,
                                   compositeCapturedFrame, reportCaptureFailure,
                                   wasExcluded))
        return false;
    macVNCCaptureSessionStart();
    return true;
}

/* Same shape: rebuild onto the unchanged, already-published layout - see
   ScreenInit's own `if (!macVNCCaptureSessionBuild(...)) return FALSE;` for
   the same call on the same layout at startup. */
static bool
rearmSameShape(const MacVNCDisplayLayout *liveLayout, uint64_t generation, bool wasExcluded)
{
    return buildAndStartCapture(liveLayout, generation, wasExcluded);
}

/*
 * The desk changed shape: swap the canvas, THEN rebuild capture onto it.
 * Order is deliberate - detach (blocks out any in-flight composite) before
 * publish, publish before the pointer swap, swap before rfbNewFramebuffer,
 * re-attach only once the new screen is fully described, free the old
 * buffer only once nothing can still be reading or writing it. See
 * ARCHITECTURE.md § CaptureLiveness for the full step-by-step proof.
 */
static bool
swapCanvasAndRearm(const MacVNCDisplayLayout *freshLayout, uint64_t generation, bool wasExcluded)
{
    size_t bufSize = (size_t)freshLayout->width * (size_t)freshLayout->height * 4;
    void *newBuffer = calloc(1, bufSize);
    if (!newBuffer) {
        rfbErr("Re-arm could not allocate a %dx%d canvas for the new desk shape\n",
               freshLayout->width, freshLayout->height);
        return false;
    }

    macVNCCompositorSetScreen(NULL);
    void *oldBuffer = frameBufferOne;
    const MacVNCDisplayLayout *publishedLayout = macVNCLayoutRegistryPublish(freshLayout);
    frameBufferOne = newBuffer;
    rfbNewFramebuffer(rfbScreen, (char *)newBuffer,
                      publishedLayout->width, publishedLayout->height, 8, 3, 4);
    macVNCInputSetContext(rfbScreen, publishedLayout);
    macVNCCompositorSetScreen(rfbScreen);
    free(oldBuffer);

    rfbLog("Desk shape changed since this session started; rebuilding the composite canvas\n");
    logCapturingLayout(publishedLayout);

    return buildAndStartCapture(publishedLayout, generation, wasExcluded);
}

/*
 * Stop, re-read the desk, and rebuild onto whichever branch above applies.
 * See ARCHITECTURE.md § CaptureLiveness for why the generation is claimed
 * FIRST (before StopAndWait), why `wasExcluded` is read before StopAndWait
 * too, and why the re-read never wakes the desk.
 */
static bool
rearmCaptures(void)
{
    uint64_t generation = macVNCLayoutRegistryNextSessionGeneration();
    bool wasExcluded = macVNCCaptureSessionSelfExcluded();
    macVNCCaptureSessionStopAndWait();
    macVNCCaptureSupervisorNoteCapturesStarted();

    MacVNCDisplayLayout freshLayout;
    if (!resolveDeskLayoutWithoutWaking(&freshLayout, true)) {
        rfbErr("Re-arm could not re-read the desk\n");
        return false;
    }

    /* Loaded once, read through this SAME pointer by both branches below:
       re-arm is the ONLY writer (the sole thing scheduled on gCaptureStopQueue,
       a serial queue), so nothing can publish a newer generation between
       this load and the swap below - see ARCHITECTURE.md § CaptureLiveness
       for why re-deriving it would defeat the pointer swap's point. */
    const MacVNCDisplayLayout *liveLayout = macVNCLayoutRegistryCurrent();
    if (macVNCDisplayLayoutsEqual(liveLayout, &freshLayout))
        return rearmSameShape(liveLayout, generation, wasExcluded);
    return swapCanvasAndRearm(&freshLayout, generation, wasExcluded);
}

/* evaluateDeskShapeForRearm(), deskShapeDebounceFired(),
   captureLivenessWatchdogFired() and the Arm/Disarm pair moved to
   MacVNCCaptureSupervisor.m (.pi/plans/core-decomposition.md, step 8) with
   the state they served - see MacVNCCaptureSupervisor.h for the WHY
   comments this used to carry inline (silence is the FRESHEST stamp, a
   failed re-arm still counts toward the cap, the desk-shape rebuild gets
   its own counters, separate from the silence watchdog's). */

/*
 * Told by AppDelegate that macOS posted NSApplicationDidChangeScreenParameters
 * - see mac.h for the full contract. No AppKit here: this file only ever
 * hears about the notification, never registers for it.
 */
void
vncServerNoteDeskShapeMayHaveChanged(void)
{
    if (atomic_load(&vncConnectedClients) == 0)
        return; /* a change while idle is already covered: the next client to
                    connect reads the desk fresh (reconcileCaptureState ->
                    startCapturesForNewClient), so there is nothing here that
                    a later connect would not already fix - and reading now
                    would gain nothing while risking exactly the "re-resolve
                    wakes the screen at 3am" loop the original reconfiguration
                    plan rejected. This gate stays here, unmoved by step 8:
                    the supervisor's own NoteDeskShapeMayHaveChanged() runs
                    only once a caller has already decided a re-evaluation
                    might matter. */
    macVNCCaptureSupervisorNoteDeskShapeMayHaveChanged();
}

/* Silence looks identical whether the stream is genuinely dead or Screen
   Recording access was revoked/never granted: SCK raises no error either
   way, it simply delivers nothing (this file's captureIsAllowed() reads the
   same policy the permission owner already tracks - see macVNCCaptureAllowed).
   A one-word difference in the log line is the whole fix: no prompting, no
   branch in the resolver, just naming the more likely cause so an operator
   is not left guessing between "broken stream" and "permission row". Also
   MacVNCCaptureSupervisor's `permissionHintSuffix` hook - kept here, not
   moved, so the supervisor never needs to know macVNCCaptureAllowed exists;
   captureIsAllowed() is a permission-policy read, not capture supervision. */
static const char *
permissionHintSuffix(void)
{
    return captureIsAllowed() ? "" : " (Screen Recording permission is not granted)";
}

/* MacVNCCaptureSupervisor's `snapshot` hook: the only two fields a watchdog
   tick or a desk-shape debounce ever needed from behind captureControlMutex
   - everything else they read (gCapturesStartedNs, gLastRearmNs,
   gRearmsSinceFrame, gLastFrameNs[], the published layout) is already
   atomic or a pure peer module, so holding the lock across those too (as
   the pre-step-8 code did, by reading all of them into one struct literal
   in one locked statement) was never protecting anything beyond these two -
   compositeCapturedFrame has never taken this lock to WRITE gLastFrameNs[],
   so extracting the reads of it from under this lock changes no consistency
   guarantee that existed before. */
static void
captureSupervisorSnapshot(bool *capturesRunning, bool *clientsConnected)
{
    pthread_mutex_lock(&captureControlMutex);
    *capturesRunning = gCapturesRunning;
    *clientsConnected = atomic_load(&vncConnectedClients) > 0;
    pthread_mutex_unlock(&captureControlMutex);
}

/* Wires MacVNCCaptureSupervisor's injected hooks to this file's statics and
   static functions, exactly once, the first time any caller might need
   them. reconcileCaptureState() and vncServerStartWithResult() both call
   this at their own top - every real path to the supervisor (a client
   connecting or disconnecting, a direct vncServerStart(), the
   macVNCReconcileCaptureForTesting() test hook) goes through
   reconcileCaptureState() at least once, so configuring it there covers
   everything; the vncServerStartWithResult() call is belt-and-braces for a
   hypothetical future caller that reaches the supervisor before any client
   ever has. dispatch_once-guarded, so calling this from two places is not a
   double-configure - the second call is a no-op. */
static void
ensureCaptureSupervisorConfigured(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        macVNCEnsureStopQueue();
        MacVNCCaptureSupervisorHooks hooks = {
            .queue                       = gCaptureStopQueue,
            .rearm                       = rearmCaptures,
            .reportFailure               = reportCaptureFailureForSupervisor,
            .readDeskLayoutWithoutWaking = resolveDeskLayoutWithoutWakingQuiet,
            .anyDisplayActive            = anyDisplayCurrentlyActive,
            .snapshot                    = captureSupervisorSnapshot,
            .permissionHintSuffix        = permissionHintSuffix,
        };
        macVNCCaptureSupervisorConfigure(&hooks);
    });
}

/*
 * The actual "start capturing for a newly arrived client" work, split out of
 * reconcileCaptureState() so it can run OFF captureControlMutex. A reconnect
 * after captures were FULLY stopped must REBUILD, not merely restart -
 * neither keep-warm's stop nor a capture-failure drop ever calls Build
 * again on its own - so this reuses rearmCaptures()'s same-shape/
 * different-shape logic rather than a third copy of it. See
 * ARCHITECTURE.md § CaptureLiveness ("FIX-B") for the 42-hour incident this
 * closed and why the rebuild is serialised on gCaptureStopQueue, off the
 * lock, with a queued second arrival becoming a no-op.
 */
/*
 * Locked decision for a newly arrived client: skip, refuse (Screen Recording
 * not granted - alerts once per server run, not per attempt), or proceed
 * with whichever rebuild `needsRebuild` calls for. Entered/left with
 * captureControlMutex held exactly where the caller always held it. See
 * ARCHITECTURE.md § CaptureLiveness ("FIX-B") for why
 * gCaptureSessionFreshAtStartup is consumed here, once.
 */
typedef struct {
    bool proceed;
    bool needsRebuild;
} MacVNCClientArmDecision;

static MacVNCClientArmDecision
lockAndDecideClientArm(void)
{
    MacVNCClientArmDecision decision = { .proceed = false, .needsRebuild = false };
    pthread_mutex_lock(&captureControlMutex);
    if (gCapturesRunning || atomic_load(&vncConnectedClients) == 0) {
        pthread_mutex_unlock(&captureControlMutex);
        return decision;
    }
    if (!captureIsAllowed()) {
        rfbLog("Screen Recording is not granted; refusing to start capture\n");
        pthread_mutex_unlock(&captureControlMutex);
        if (macVNCScreenCaptureFailureHandler)
            macVNCScreenCaptureFailureHandler(true, vncServerCurrentGeneration(),
                                              macVNCLayoutRegistryCurrentSessionGeneration());
        return decision;
    }
    decision.proceed = true;
    decision.needsRebuild = !gCaptureSessionFreshAtStartup && macVNCLayoutRegistryCurrent() != NULL;
    gCaptureSessionFreshAtStartup = false;
    pthread_mutex_unlock(&captureControlMutex);
    return decision;
}

/* Off captureControlMutex, exactly like the two branches this replaces: a
   rebuild's StopAndWait blocks for bounded but real seconds and must never
   run with the lock held - see rearmCaptures(). A fresh watch on a fresh
   clock either way (rearmCaptures() resets it on the rebuild path; done
   here, once, for the plain-restart path it does not cover). */
static bool
armCaptureSession(bool needsRebuild)
{
    if (needsRebuild)
        return rearmCaptures();
    macVNCCaptureSessionStart();
    macVNCCaptureSupervisorNoteCapturesStarted();
    return true;
}

/* Relocks to publish the outcome: failure reports through the same path
   every other capture failure uses; success flips gCapturesRunning and arms
   the watchdog under the same lock span the pre-split code always used. */
static void
finishClientArm(bool ok)
{
    pthread_mutex_lock(&captureControlMutex);
    if (!ok) {
        pthread_mutex_unlock(&captureControlMutex);
        rfbErr("Could not rebuild display captures for the new client; reporting a capture failure\n");
        reportCaptureFailure(false);
        return;
    }
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(&gCaptureStartCount, 1);
#endif
    gCapturesRunning = true;
    macVNCCaptureSupervisorArm(); /* also resets gLastRearmNs/gRearmsSinceFrame - see its header */
    rfbLog("Client connected; starting %lu display captures\n",
           (unsigned long)macVNCCaptureSessionCount());
    pthread_mutex_unlock(&captureControlMutex);
}

static void
startCapturesForNewClient(void)
{
    MacVNCClientArmDecision decision = lockAndDecideClientArm();
    if (!decision.proceed)
        return;

    /* Awake-while-watched: the power assertions live as long as a viewer is
       connected, not as long as the LISTENER runs - see ARCHITECTURE.md's
       MacVNCPowerMgmt entry for the pmset bug this replaced. */
    if (dimmingInit() != 0)
        rfbLog("Power assertion failed; machine may idle-sleep during the session\n");

    bool ok = armCaptureSession(decision.needsRebuild);
    finishClientArm(ok);
}

/*
 * Drives captures to match the one invariant: they run iff at least one
 * authenticated client is connected. Called AFTER releasing
 * clientLifecycleMutex, re-reading the atomic count under its own lock, so
 * whichever of a racing connect/disconnect takes the lock last applies the
 * settled count. See ARCHITECTURE.md's Concurrency model §
 * captureControlMutex for why the two locks are never held together.
 */
/*
 * Schedules the actual stop 30s out and returns immediately - called with
 * captureControlMutex already held, matching reconcileCaptureState()'s own
 * span; the timer's own handler relocks separately when it fires, seconds
 * later, exactly as this code always has. macVNCMonotonicNow(), NOT
 * macVNCUptimeNow(): the dispatch_source timer fires in sleep-inclusive
 * (continuous) time regardless of which clock the deadline uses, so the
 * deadline must agree with it - see FirstFrameBudget.h's own comment on the
 * two clocks' separate purposes.
 */
static void
scheduleKeepWarmStop(void)
{
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
            /* Under the same lock as the write above: a plain pointer
               toggled from here and from the reconnect branch with no
               shared lock would race. */
            macVNCCaptureSupervisorDisarm();
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
        /* Paired with the assertions, not with the server stop - see
           ARCHITECTURE.md's MacVNCDisplayWake entry for the leaked-assertion
           bug this replaced. */
        macVNCReleaseDisplayAssertion();
        macVNCCaptureSessionStopAndWait();
        macVNCInputResetModifiers();
        rfbLog("Capture keep-warm window elapsed; %lu display captures stopped\n",
               (unsigned long)macVNCCaptureSessionCount());
    });
    dispatch_resume(timer);
}

/*
 * Drives captures to match the one invariant that matters: they run if and only
 * if at least one authenticated client is connected. See ARCHITECTURE.md's
 * CaptureLiveness/MacVNCClamshellPolicy entries for why the clamshell
 * reconciliation below runs unconditionally and outside the lock.
 */
static void reconcileCaptureState(void)
{
    ensureCaptureSupervisorConfigured();
    pthread_mutex_lock(&captureControlMutex);
    bool wanted = atomic_load(&vncConnectedClients) > 0;
    bool shouldStartNewSession = wanted && !gCapturesRunning;
    if (shouldStartNewSession) {
        atomic_store(&gCaptureWarmDeadlineNs, 0); /* reconnect beats the timer */
    } else if (!wanted && gCapturesRunning) {
        scheduleKeepWarmStop();
    }
    pthread_mutex_unlock(&captureControlMutex);

    if (shouldStartNewSession) {
        /* Off the lock entirely: startCapturesForNewClient() may run
           rearmCaptures(), which blocks for bounded StopAndWait work and must
           never run with captureControlMutex held. Synchronous, not async:
           the caller (prepareAuthenticatedClient) waits for first frames
           right after this returns. */
        macVNCEnsureStopQueue();
        dispatch_sync(gCaptureStopQueue, ^{ startCapturesForNewClient(); });
    }

    macVNCClamshellReevaluate();
}

void
vncServerDropCaptures(void)
{
    /* Mirrors the keep-warm timer's teardown, minus the timer: mark the
       captures stopped under the control lock, then do the slow stop OUTSIDE
       it, then reconcile - which restarts them when a viewer is still there
       and leaves them down when nobody is. */
    pthread_mutex_lock(&captureControlMutex);
    bool wasRunning = gCapturesRunning;
    gCapturesRunning = false;
    atomic_store(&gCaptureWarmDeadlineNs, 0);
    macVNCCaptureSupervisorDisarm(); /* under the lock - see MacVNCCaptureSupervisor.h */
    pthread_mutex_unlock(&captureControlMutex);

    /* Rendezvous BEFORE the wasRunning check, not after: wasRunning can read
       false here while a re-arm from a snapshot taken just before the flip
       above is still mid-flight on gCaptureStopQueue, unprotected by
       captureControlMutex by design (see rearmCaptures). That re-arm's own
       Build/Start would otherwise be free to run after this function returns,
       resurrecting a session nothing is left to stop - the fact that THIS
       call had nothing to do is not proof nothing else is doing something.
       Never called with captureControlMutex held (already released above),
       so this cannot deadlock against a keep-warm or watchdog block that
       needs it. */
    macVNCEnsureStopQueue();
    dispatch_sync(gCaptureStopQueue, ^{});

    if (!wasRunning)
        return;

    macVNCCaptureSessionStopAndWait();
    macVNCInputResetModifiers();
    rfbLog("Captures dropped after a capture failure; the listener stays up\n");
    reconcileCaptureState();
}

/*
 * The two counters' bookkeeping, in ONE place.
 *
 * Both production paths and the test hooks at the bottom of this file go
 * through these three functions, so a test cannot end up asserting against a
 * re-implementation of the rules it is meant to protect. clientLifecycleMutex
 * must be held by the caller - these touch per-client state as well as the
 * atomics, and the pair has to move together.
 */
static bool
countClientForCaptureLocked(MacVNCClientState *state)
{
    if (!state || state->captureCounted)
        return false;
    state->captureCounted = TRUE;
    atomic_fetch_add(&vncConnectedClients, 1);
    /* An authenticated viewer is arriving: light the display so it has
       something live to capture rather than a blank screen. Paired with the
       release in reconcileCaptureState, which is driven by this same counter -
       so unlike the old pre-auth wake, this assertion can never outlive the
       session that created it. */
    macVNCWakeDisplays();
    return true;
}

static void
countClientReceivingUpdatesLocked(MacVNCClientState *state)
{
    if (!state || state->updatesCounted)
        return;
    state->updatesCounted = TRUE;
    atomic_fetch_add(&vncAuthenticatedClientsReceivingUpdates, 1);
}

/* Returns how many authenticated clients remain (for the disconnect log). */
static int
uncountClientLocked(MacVNCClientState *state)
{
    /* Subtracted only if this client was ever added: one that left during the
       first-frame wait never reached the increment, and decrementing for it
       would drive the count negative - or, once clamped, drop the count to
       zero while another viewer IS watching, lifting a curtain that should
       have stayed up. */
    if (state && state->updatesCounted) {
        if (atomic_fetch_sub(&vncAuthenticatedClientsReceivingUpdates, 1) - 1 <= 0)
            atomic_store(&vncAuthenticatedClientsReceivingUpdates, 0);
    }
    if (state && state->captureCounted) {
        int remaining = atomic_fetch_sub(&vncConnectedClients, 1) - 1;
        if (remaining <= 0) {
            remaining = 0;
            atomic_store(&vncConnectedClients, 0);
        }
        return remaining;
    }
    /* Un-counted client (never authenticated): report the current count. */
    return atomic_load(&vncConnectedClients);
}

/*
 * Runs once per client, right after its password is accepted.
 *
 * Waits (bounded) for the first frame of every display so the auth OK is not
 * followed by a black screen. The wait is the point; its OUTCOME is logged but
 * never branched on - a viewer whose displays are slow is still a viewer, and
 * refusing to count it would silently disable curtain mode for exactly those
 * viewers. See vncAuthenticatedClientsReceivingUpdates in mac.h for why that
 * trade is the right way round, and what covers the genuinely broken case.
 */
static void
prepareAuthenticatedClient(rfbClientPtr cl)
{
    bool counted = false;

    pthread_mutex_lock(&clientLifecycleMutex);
    counted = countClientForCaptureLocked(cl->clientData);
    pthread_mutex_unlock(&clientLifecycleMutex);

    if (!counted)
        return;

    /* Outside the client lock: reconciling can stop captures, which waits. */
    reconcileCaptureState();

    /* Logged with the elapsed time: when this fires, the viewer WILL show its
       own "no data" placeholder, so the number is the thing to act on. */
    uint64_t waitStart = macVNCMonotonicNow();
    if (!macVNCCaptureSessionWaitForFirstFrames(INITIAL_READINESS_TIMEOUT_NANOSECONDS))
        rfbLog("Initial display readiness timed out after %.2f s; the viewer will "
               "show a placeholder until frames arrive\n",
               (double)(macVNCMonotonicNow() - waitStart) / 1e9);

    /* COUNTED here, not at the moment the password was accepted, and this is
       the count the curtain reads: what it may hide behind is a viewer that is
       RECEIVING UPDATES, and between those two points the streams are still
       warming up. Publishing it earlier would black the local screen out while
       the remote party was still looking at a placeholder - and the reader is
       LEVEL-triggered (it re-reads this atomic on a timer as well as on the
       notification below), so the increment itself has to be here. Announcing
       it late while incrementing early would have made the notification
       decorative and the timer authoritative.

       NOT gated on the wait SUCCEEDING - see mac.h: a viewer whose displays
       are slow is still a viewer. */
    pthread_mutex_lock(&clientLifecycleMutex);
    countClientReceivingUpdatesLocked(cl->clientData);
    pthread_mutex_unlock(&clientLifecycleMutex);

    notifyAuthenticatedClientsChanged();
}

static rfbBool
macVNCPasswordCheck(rfbClientPtr client,
                    const char *encryptedPassword,
                    int length)
{
    /*
     * The encryption policy is enforced HERE because this is the first moment
     * the answer is known: the security type is chosen by the client, and
     * cl->sslctx only becomes non-NULL once the VeNCrypt handshake has actually
     * completed. Refusing earlier would mean guessing, and refusing later would
     * mean the screen had already been published over a plaintext socket.
     *
     * The refusal is deliberately indistinguishable from a wrong password on
     * the wire - a probe learns nothing about the policy - while the log says
     * exactly what happened, because the owner locking themselves out is the
     * other way this can go wrong.
     */
    if (!macVNCEncryptionAdmits(gEncryptionPolicy, client->sslctx != NULL)) {
        rfbLog("Refused unencrypted client %s: encryption is set to 'required'. "
               "Use a viewer that supports VeNCrypt/TLS, or change the setting "
               "in Preferences.\n", client->host ? client->host : "(unknown)");
        return FALSE;
    }

    if (!rfbCheckPasswordByList(client, encryptedPassword, length))
        return FALSE;
    prepareAuthenticatedClient(client);
    return TRUE;
}

static void clientGone(rfbClientPtr cl)
{
    int remaining;

    /* Upstream leak, 16 bytes per TLS client: rfbssl_destroy() frees the SSL
       and SSL_CTX objects but never the little struct that holds them
       (0.9.15 rfbssl_openssl.c:128-135). rfbCloseClient always runs that
       destroy BEFORE rfbClientConnectionGone reaches this hook
       (sockets.c:572 vs rfbserver.c:606), so nothing can still be using it. */
    if (cl->sslctx) {
        free(cl->sslctx);
        cl->sslctx = NULL;
    }

    pthread_mutex_lock(&clientLifecycleMutex);
    MacVNCClientState *state = cl->clientData;
    remaining = uncountClientLocked(state);
    cl->clientData = NULL;
    free(state);
    pthread_mutex_unlock(&clientLifecycleMutex);

    reconcileCaptureState();
    rfbLog("Client %s disconnected (%d authenticated remaining)\n", cl->host, remaining);
    notifyAuthenticatedClientsChanged();
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
    /* One copy per process, not per connection: the paths never change, and
       strdup-ing on every TLS client leaked the previous pair (the screen does
       not own or free them). */
    static char *gCertPathOwned = NULL;
    static char *gKeyPathOwned = NULL;
    if (!gCertPathOwned) gCertPathOwned = strdup(certPath);
    if (!gKeyPathOwned)  gKeyPathOwned  = strdup(keyPath);
    cl->screen->sslcertfile = gCertPathOwned;
    cl->screen->sslkeyfile  = gKeyPathOwned;

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

    /*
     * Wire format, per the VeNCrypt specification and both reference
     * implementations (TigerVNC SSecurityVeNCrypt, QEMU vnc-auth-vencrypt):
     *
     *   U8   version ack       0 = the version we agreed on is acceptable
     *   U8   number of subtypes
     *   U32  subtype           x number-of-subtypes
     *   ---- client sends U32  its choice
     *   U8   subtype ack       1 = accepted, proceed to TLS
     *
     * This used to send the COUNT as a U32 and the final ack as a U32. A real
     * viewer read those four bytes as "ack 0, zero subtypes" and gave up with
     * "The server reported no VeNCrypt sub-types". It went unnoticed because
     * the only client that ever tested it was a script written against this
     * code rather than against the specification.
     */
    uint8_t greeting[8];
    size_t greetingLength = macVNCTLSBuildSubtypeGreeting(greeting, sizeof(greeting));
    if (greetingLength == 0 ||
        rfbWriteExact(cl, (char *)greeting, (int)greetingLength) < 0) {
        rfbCloseClient(cl);
        return;
    }

    uint32_t chosenRaw;
    if (rfbReadExact(cl, (char *)&chosenRaw, 4) < 0) { rfbCloseClient(cl); return; }
    if (!macVNCTLSValidateClientVersions(vReply[0], vReply[1],
                                         Swap32IfLE(chosenRaw))) {
        rfbErr("macVNC TLS: client picked version %d.%d subtype %u - refused\n",
               vReply[0], vReply[1], Swap32IfLE(chosenRaw));
        uint8_t reject = 0; /* subtype ack: 0 = refused */
        rfbWriteExact(cl, (char *)&reject, 1);
        rfbCloseClient(cl);
        return;
    }
    uint8_t subtypeAck = 1; /* accepted; the TLS handshake follows */
    if (rfbWriteExact(cl, (char *)&subtypeAck, 1) < 0) { rfbCloseClient(cl); return; }

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

  /* Deliberately NO display wake here. It used to live at this line, before
     authentication, and that was wrong twice over. It let anyone who could
     reach the port light up this Mac's screen without knowing the password -
     measured: a connection with a deliberately wrong password woke both
     displays. And because an unauthenticated client never increments
     vncConnectedClients, the reconciler never ran, so the UserIsActive
     assertion it created was held until some LATER successful session happened
     to end - or forever, if none ever did.

     The wake now happens where the client is counted, which is where capture
     starts and where the release is already paired. */

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
    macVNCCaptureSupervisorDisarm(); /* under the lock - see MacVNCCaptureSupervisor.h */
    pthread_mutex_unlock(&captureControlMutex);
    /* Rendezvous with gCaptureStopQueue BEFORE touching the session directly -
       see the identical comment in vncServerDropCaptures(). Disarming the
       timer above only stops FUTURE fires; a re-arm already past its
       mutex-protected snapshot runs StopAndWait/Build/Start unprotected by
       captureControlMutex (by design - see rearmCaptures), so without this a
       Build+Start landing after the Reset below would leave live SCStreams
       capturing after the server declared itself stopped, with nothing left
       to ever stop them. Called with the lock already released, so this
       cannot deadlock against a keep-warm or watchdog block that needs it. */
    macVNCEnsureStopQueue();
    dispatch_sync(gCaptureStopQueue, ^{});
    macVNCCaptureSessionStopAndWait();
    macVNCCaptureSessionReset();
    atomic_store(&vncConnectedClients, 0);
    atomic_store(&vncAuthenticatedClientsReceivingUpdates, 0);
    notifyAuthenticatedClientsChanged();
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
    /* Before the display assertion, and unlike it, this one can outlive the
       process: the kernel does not clear the clamshell bit for us. */
    /* The non-latching release: a server stop is reversible (the menu's Stop,
       a failed start, a future layout-driven restart), so it must not disable
       closed-display mode for the rest of the run. Termination latches
       separately, from applicationWillTerminate. */
    macVNCClamshellReleaseForServerStop();
    macVNCReleaseDisplayAssertion();
    macVNCInputShutdown();
    macVNCClearStoredPassword();
    free(frameBufferOne); frameBufferOne = NULL;
}

MacVNCServerStartResult
vncServerStartWithResult(const MacVNCServerConfig *config)
{
    ensureCaptureSupervisorConfigured(); /* belt-and-braces - see its own header */
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
    macVNCLayoutRegistryResetPin(); /* fresh run: re-pin from position on first resolve */
    macVNCClientAccessMode = config->clientAccessMode;
    snprintf(macVNCListenAddress, sizeof(macVNCListenAddress), "%s",
             config->listenAddress ? config->listenAddress : "");
    snprintf(macVNCAllowedClients, sizeof(macVNCAllowedClients), "%s",
             config->allowedClients ? config->allowedClients : "");

    if (!macVNCInputStart())
        goto FAILURE;

    if (!ScreenInit(config->port, config->password, config->captureFramesPerSecond,
                    config->imageProfile, config->encryptionPolicy))
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

/* macVNCCaptureRearmCountForTesting/macVNCCaptureRearmFailureCountForTesting/
   macVNCCaptureGiveUpCountForTesting/macVNCLastFrameTimestampForTesting moved
   to MacVNCCaptureSupervisor.h/.m with the state they read (step 8). */

/* Bypasses ScreenCaptureKit entirely - see mac.h for why a synthetic frame,
   sized off the real current layout, is the only deterministic way to prove
   a stale generation is rejected. */
void
macVNCCompositeSyntheticFrameForTesting(uint64_t generation, size_t displayIndex)
{
    const MacVNCDisplayLayout *layout = macVNCLayoutRegistryCurrent();
    if (displayIndex >= layout->count)
        return;
    const MacVNCDisplayGeometry *geometry = &layout->displays[displayIndex];
    int width = geometry->input.pixelWidth;
    int height = geometry->input.pixelHeight;
    size_t stride = (size_t)width * 4;
    uint8_t *pixels = calloc(1, stride * (size_t)height);
    if (!pixels)
        return;
    MacVNCCaptureFrameOrigin origin = { .generation = generation, .displayIndex = displayIndex };
    MacVNCDirtyHint hint = { NULL, 0 };
    compositeCapturedFrame(origin, pixels, stride, width, height, &hint);
    free(pixels);
}

/* How many displays the CURRENTLY published layout actually has - so a test
   for "an idle second display cannot trigger a re-arm" can find out at run
   time whether this machine even has a second display to make idle, and SKIP
   (the same convention test_capture_liveness_rearm.m already uses for "no
   usable display here") rather than assert something true only by accident
   on a single-display box. */
size_t
macVNCCurrentDisplayLayoutCountForTesting(void)
{
    return macVNCLayoutRegistryCurrent()->count;
}

/*
 * A synthetic client, so the window between "authenticated" and "receiving
 * updates" (the first-frame wait) can be driven without a socket, display or
 * viewer. Goes through the SAME countClient*Locked/uncountClientLocked
 * functions the real paths use, so a hook that re-implemented the counting
 * couldn't let the rules it tests be deleted while staying green. Does NOT
 * reconcile captures - the caller's job in production - so no
 * ScreenCaptureKit is needed here.
 */
void *
macVNCBeginClientForTesting(bool receivingUpdates)
{
    MacVNCClientState *state = calloc(1, sizeof(*state));
    if (!state)
        return NULL;
    pthread_mutex_lock(&clientLifecycleMutex);
    countClientForCaptureLocked(state);
    if (receivingUpdates)
        countClientReceivingUpdatesLocked(state);
    pthread_mutex_unlock(&clientLifecycleMutex);
    return state;
}

void
macVNCClientReceivedFirstFramesForTesting(void *client)
{
    pthread_mutex_lock(&clientLifecycleMutex);
    countClientReceivingUpdatesLocked(client);
    pthread_mutex_unlock(&clientLifecycleMutex);
}

void
macVNCEndClientForTesting(void *client)
{
    pthread_mutex_lock(&clientLifecycleMutex);
    (void)uncountClientLocked(client);
    pthread_mutex_unlock(&clientLifecycleMutex);
    free(client);
}

/* Drives the real reconciler, so a test exercises the decision the server
   actually makes rather than a re-implementation of it. */
void
macVNCResetCaptureStateForTesting(void)
{
    atomic_store(&vncConnectedClients, 0);
    atomic_store(&vncAuthenticatedClientsReceivingUpdates, 0);
    reconcileCaptureState();
    atomic_store(&gCaptureStartCount, 0);
    atomic_store(&gCaptureStopCount, 0);
    macVNCCaptureSupervisorResetForTesting(); /* the 7 supervisor-owned counters/flags */
    atomic_store(&gForcePinnedDisplayGoneForTesting, false);
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
