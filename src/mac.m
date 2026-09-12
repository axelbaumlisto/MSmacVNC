
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
#import "CaptureLiveness.h"
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
/* E2: once a `displayNumber >= 0` selection has been resolved by POSITION for
   the first time in a server run, this remembers the concrete display it
   picked, so every LATER re-resolution (a capture-liveness re-arm, mid-
   session) follows that identity rather than re-reading the same numeric
   position - which a desk event can silently hand to a different physical
   monitor. 0 (kCGNullDirectDisplay) means "not yet pinned this run": real
   CGDirectDisplayID values are never 0. Reset to 0 at every server (re)start,
   alongside `displayNumber` itself - see vncServerStart. -1 (primary) and -2
   (all) never populate this; they keep re-evaluating live, which is what
   those settings mean. */
static uint32_t gPinnedDisplayID;
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
 * The published display layout, double-buffered.
 *
 * Before this, `displayLayout` was a single static struct that a re-arm
 * overwrote IN PLACE (`displayLayout = freshLayout;`) whenever the desk
 * changed shape. compositeCapturedFrame() - the per-display capture hot path,
 * running at up to 60 fps per display - read that same struct with no lock:
 * it scans `displayLayout.count` comparing `&displayLayout.displays[i]` against
 * its `geometry` pointer, then snapshots `*geometry`. A capture callback from
 * the just-stopped OLD session can still be in flight when that copy runs -
 * MacVNCCaptureSession.h documents exactly this: StopAndWait's wait is
 * bounded, and a stream whose work never quiesced is deliberately leaked
 * rather than freed because a callback may still touch it. So the multi-field
 * copy could tear against that read: `count` from one publish compared
 * against `displays[]` from another. Bounded (displays[] is a fixed
 * MACVNC_MAX_DISPLAYS array, never out-of-bounds; worst case is a dropped
 * frame or one stale-pixel frame that heals on the next real one - see
 * .pi/plans/capture-liveness.md), but new exposure from the shape-changed
 * re-arm, not present before it.
 *
 * The fix is PUBLISH BY POINTER SWAP, never mutate what is currently
 * published: two fixed slots hold successive publications of the layout, and
 * an atomic pointer says which one is current. A reader loads that pointer
 * ONCE and reads only through it, so every field it sees belongs to the same
 * publish - no lock needed on the hot path, because nothing ever writes into
 * the slot the pointer currently designates as published.
 *
 * Two slots, not one-per-publish: a writer publishing into slot N+1 always
 * targets whichever slot is NOT currently published (the one last holding
 * publish N-1, already retired one publish ago), so it never touches the live
 * slot. A stuck callback from publish N-1 keeps a valid (never freed) pointer
 * into that slot; if TWO MORE re-arms land before that callback finally shows
 * up, the slot has since been reused for publish N+1, and the callback reads
 * WHATEVER publish N+1 put there - not a torn read (still one atomic load's
 * worth of a complete, self-consistent MacVNCDisplayLayout, never
 * out-of-bounds, never freed memory), but not that callback's own generation
 * either.
 *
 * That residual case is closed by a DIFFERENT mechanism, not by adding a
 * third slot: compositeCapturedFrame no longer identifies a frame by which
 * slot its geometry pointer happens to still address at all - see
 * MacVNCCaptureFrameOrigin and gCaptureSessionGeneration below, which reject
 * a stale frame by an explicit, never-reused counter BEFORE it ever reads a
 * slot's content, so a callback from ANY retired generation - one re-arm
 * stale or a hundred - never reaches a read of this structure in the first
 * place. What these two slots still exist for is narrower and unrelated: give
 * every reader that DOES pass that check (or never needed it - freshestFrameStamp,
 * ScreenInit) a torn-free, single-load view of the layout's own fields, so a
 * concurrent re-arm publishing a new shape can never be observed as `count`
 * from one shape and `displays[]` from another.
 *
 * Writers (resolveDisplayLayout at startup, rearmCaptures on re-arm) are
 * always serialised - startup runs once before any capture session exists,
 * and re-arm is the only thing scheduled on gCaptureStopQueue, a serial
 * queue - so no lock is needed on the write side either; the atomic pointer
 * is what makes the SWAP itself visible to readers as a single indivisible
 * step, not what serialises writers against each other.
 */
static MacVNCDisplayLayout gDisplayLayoutSlots[2];
static _Atomic(MacVNCDisplayLayout *) gPublishedLayout = NULL;

/* The currently published layout. Callers that need more than one field must
   load this ONCE into a local and read every field through that local - see
   compositeCapturedFrame for why re-reading this accessor mid-function would
   defeat the whole point of the pointer swap below. */
static MacVNCDisplayLayout *
currentDisplayLayout(void)
{
    return atomic_load(&gPublishedLayout);
}

/* Copy `fresh` into whichever slot is NOT currently published, then publish
   it with one atomic store. Returns the new current pointer, so a caller that
   just published can keep using it without a second load. */
static MacVNCDisplayLayout *
publishDisplayLayout(const MacVNCDisplayLayout *fresh)
{
    MacVNCDisplayLayout *live = atomic_load(&gPublishedLayout);
    MacVNCDisplayLayout *target = (live == &gDisplayLayoutSlots[0])
        ? &gDisplayLayoutSlots[1] : &gDisplayLayoutSlots[0];
    *target = *fresh;
    atomic_store(&gPublishedLayout, target);
    return target;
}

/*
 * Which capture session a frame came from - orthogonal to which LAYOUT is
 * published above. A re-arm that finds the desk unchanged rebuilds its
 * session onto the SAME already-published MacVNCDisplayLayout object (see
 * rearmCaptures's same-shape branch) rather than publishing a second,
 * identical copy of it - so a layout publish and a new capture session are
 * NOT the same event, and identifying a session by "which layout publish it
 * used" would fail to tell two such sessions apart. This counter is bumped
 * once per macVNCCaptureSessionBuild() call, always, whether or not the
 * layout changed, and never reused - so a frame carrying any value other than
 * the CURRENT one came from a session that is no longer THE session,
 * regardless of how many re-arms separate the two or whether the desk's
 * shape ever changed at all. See MacVNCCaptureFrameOrigin for how a frame
 * carries this, and compositeCapturedFrame for where it is checked.
 *
 * 0 is reserved for "never Built against a real generation" and cannot
 * collide with a real one - the first claimed generation is 1 (see
 * nextCaptureSessionGeneration). No capture session is ever Built with
 * generation 0 in practice, but reserving it costs nothing and gives a
 * frame with a garbage/zeroed origin an unambiguous "never matches" answer.
 */
static _Atomic uint64_t gCaptureSessionGeneration = 0;

/* Claims the generation the NEXT macVNCCaptureSessionBuild() call will use.
   Called exactly once per Build call site, and in rearmCaptures BEFORE
   StopAndWait rather than right before Build - see rearmCaptures for why
   that ordering, not proximity to Build, is what actually matters: claiming
   it here means ANY frame the old, about-to-be-stopped session might still
   deliver - even one delivered while StopAndWait is still draining, even one
   from a stream that never quiesced and was deliberately leaked - already
   finds gCaptureSessionGeneration advanced past its own value, however early
   it arrives. */
static uint64_t
nextCaptureSessionGeneration(void)
{
    /* fetch_add returns the PRE-increment value; +1 gives the generation this
       call just claimed, so the very first call returns 1, never the 0
       sentinel above. */
    return atomic_fetch_add(&gCaptureSessionGeneration, 1) + 1;
}

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
/* True only for the SINGLE connect that immediately follows ScreenInit's own
   WAKING resolveDisplayLayout() - that Build is already as fresh as this
   server run has ever been, so the very first client must not immediately
   discard it and pay a second, non-waking rebuild for nothing. Consumed
   (cleared) the first time startCapturesForNewClient() runs, whether or not
   that connect succeeds - it describes ONE upcoming connect, not a mode.
   Every LATER arrival - after keep-warm's own stop, or vncServerDropCaptures()
   following a capture failure - finds the SAME ScreenCapturer set ScreenInit
   or the last rearmCaptures() built, silently bound to whatever the desk
   looked like back then (audit_integration.md items 2 and 3): a monitor added
   or removed while nobody was connected stayed invisible to the composite
   canvas forever, and a capture failure's KeepServing recovery kept
   restarting streams already known dead. Both close the same way a live
   re-arm already does: re-read the desk and rebuild before starting. */
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

/*
 * Whether a technically-running stream is delivering frames - see
 * CaptureLiveness.h for why silence, not an SCStream error, is the signal
 * this watches for.
 *
 * gLastFrameNs is indexed by the `displayIndex` a frame's MacVNCCaptureFrameOrigin
 * carries - the same position within the layout its session was Built
 * against (MacVNCCaptureSession.m mints one origin per display, in loop
 * order). A callback whose session is no longer the current one is rejected
 * by its `generation` (see gCaptureSessionGeneration) before
 * compositeCapturedFrame ever reaches this array, so an index here is always
 * live-session-fresh, never a stale session's position reinterpreted against
 * the current one. 0 means "no frame yet for that slot" - macVNCUptimeNow()
 * never returns 0, so it doubles as a safe sentinel with no separate bool
 * needed alongside it. This array, gCapturesStartedNs and gLastRearmNs are
 * ALL stamped with macVNCUptimeNow(), never macVNCMonotonicNow(): the
 * watchdog measures elapsed AWAKE time, so a long system sleep is never
 * mistaken for a dead stream (see macVNCUptimeNow()'s own comment for the
 * measurement that established this).
 */
static _Atomic uint64_t gLastFrameNs[MACVNC_MAX_DISPLAYS];
/* When the currently running captures were told to start - the watchdog's
   grace-period anchor and, absent any frame yet, its silence anchor too. */
static _Atomic uint64_t gCapturesStartedNs = 0;
static _Atomic uint64_t gLastRearmNs = 0;
static _Atomic unsigned gRearmsSinceFrame = 0;
/* Armed and disarmed by reconcileCaptureState() and its stop paths, always
   under captureControlMutex alongside the gCapturesRunning write they pair
   with - a plain (non-atomic) pointer toggled from more than one call site
   would otherwise race between one thread's disarm and another's re-arm. */
static dispatch_source_t gCaptureLivenessTimer;
#if defined(MACVNC_ENABLE_TEST_HOOKS)
static _Atomic unsigned gCaptureRearmCount = 0;
/* Counts a FAILED rearmCaptures() attempt, and a GiveUp resolution,
   separately from the success-only counter above - see FIX-A/audit item 1
   and B4's integration test, which is the one place these are read. */
static _Atomic unsigned gCaptureRearmFailureCount = 0;
static _Atomic unsigned gCaptureGiveUpCount = 0;
/* 0 = no override, same sentinel style as gCaptureKeepWarmOverrideNs.
   maxRearms is not overridable: a test can already reach it by advancing
   through cooldown windows, and a zero override would be ambiguous between
   "unset" and "give up on the first attempt". */
static _Atomic uint64_t gCaptureLivenessGraceOverrideNs = 0;
static _Atomic uint64_t gCaptureLivenessSilenceOverrideNs = 0;
static _Atomic uint64_t gCaptureLivenessCooldownOverrideNs = 0;
void macVNCSetCaptureLivenessLimitsForTesting(uint64_t graceNs, uint64_t silenceNs,
                                              uint64_t cooldownNs)
{
    atomic_store(&gCaptureLivenessGraceOverrideNs, graceNs);
    atomic_store(&gCaptureLivenessSilenceOverrideNs, silenceNs);
    atomic_store(&gCaptureLivenessCooldownOverrideNs, cooldownNs);
}
#endif

/*
 * FIX-D: the watchdog above only ever reacts to SILENCE, and a display that
 * is RESIZED rather than silenced never produces any - ScreenCapturer.m pins
 * SCStreamConfiguration.width/height at Build time, so a reconfigured display
 * keeps delivering frames, just rescaled to the OLD dimensions, forever.
 * Measured on the installed build (2026-09-12): changing the built-in
 * display's mode mid-session produced 753 client updates and ZERO re-arms
 * while the canvas stayed stuck at the pre-change 5552x2715 composite size -
 * see .pi/plans/capture-liveness.md. This timer is the other half of
 * liveness: react to macOS's OWN notice that something about the screens
 * changed, instead of waiting to notice its effect.
 *
 * Queue-confined like gCaptureLivenessTimer above: only ever created,
 * rescheduled or read from gCaptureStopQueue, so no lock guards it.
 * Deliberately REUSED across an entire notification burst rather than
 * cancelled-and-recreated per call (unlike the one-shot keep-warm timer,
 * which only ever arms once per stop transition): rescheduling an
 * already-armed dispatch timer source via dispatch_source_set_timer() is
 * exactly how a debounce coalesces a burst into one firing, and the source
 * lives for the rest of the process once first created rather than being
 * torn down between bursts.
 */
static dispatch_source_t gDeskShapeDebounceTimer;

/*
 * How long to wait after the LAST NSApplicationDidChangeScreenParameters
 * notification before actually re-reading the desk.
 *
 * Not the first notification: macOS fires this notification once per
 * attached display as a reconfiguration settles, sometimes more than once per
 * display while resolution/scaling negotiation is still in progress, so
 * reading immediately risks reading a HALF-settled desk and rebuilding onto
 * geometry that is itself about to change again. 500ms is long enough to
 * coalesce that burst (measured reconfiguration bursts on this machine
 * complete well under it) and short enough that a real change still resolves
 * far inside the watchdog's own ~10s recovery budget, so this path is
 * strictly faster than falling back on silence detection, never slower.
 */
#define MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS (500ULL * NSEC_PER_MSEC)

#if defined(MACVNC_ENABLE_TEST_HOOKS)
/* Counts every DEBOUNCED firing (i.e. every time the notification burst
   actually gets re-evaluated), regardless of what it decides - the one
   number that lets a test tell "a burst of N notifications produced ONE
   evaluation" from "produced N". */
static _Atomic unsigned gDeskShapeRecheckCount = 0;
unsigned macVNCDeskShapeRecheckCountForTesting(void)
{ return atomic_load(&gDeskShapeRecheckCount); }
/* 0 = use the shipped 500ms; matches gCaptureKeepWarmOverrideNs's sentinel
   style. Without this a test exercising the debounce would need to either
   wait out the real 500ms (slow but not wrong) or never observe a SECOND,
   separate firing within a bounded test budget. */
static _Atomic uint64_t gDeskShapeDebounceOverrideNs = 0;
void macVNCSetDeskShapeDebounceForTesting(uint64_t ns)
{ atomic_store(&gDeskShapeDebounceOverrideNs, ns); }
/* Forces evaluateDeskShapeForRearm() below to treat the freshly re-read desk
   as DIFFERENT from the published layout, without needing to fake a
   MacVNCDisplayLayout or physically reconfigure a display: a test can prove
   "differing layout => exactly one rebuild" against the ALREADY-tested
   rearmCaptures() by forcing the one decision this file adds - the rest of
   the rebuild path is real ScreenCaptureKit/LibVNCServer work, unmocked. */
static _Atomic bool gForceDeskShapeDifferentForTesting = false;
void macVNCForceDeskShapeDifferentForTesting(bool force)
{ atomic_store(&gForceDeskShapeDifferentForTesting, force); }
/* Counts evaluateDeskShapeForRearm()'s own rearmCaptures() outcome,
   DELIBERATELY separate from gCaptureRearmCount - see that function's own
   comment for why a shape-driven rearm must not share the silence
   watchdog's cooldown/maxRearms bookkeeping. */
static _Atomic unsigned gDeskShapeRebuildCount = 0;
unsigned macVNCDeskShapeRebuildCountForTesting(void)
{ return atomic_load(&gDeskShapeRebuildCount); }
static _Atomic unsigned gDeskShapeRebuildFailureCount = 0;
unsigned macVNCDeskShapeRebuildFailureCountForTesting(void)
{ return atomic_load(&gDeskShapeRebuildFailureCount); }
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

/*
 * How long a freshly authenticated client waits for the first frame of every
 * display before the server gives up and lets it proceed.
 *
 * This wait is why viewers historically never showed their "no data yet"
 * placeholder (the checkerboard): AUTH_OK is held back until real pixels
 * exist. The budget used to be 3s, chosen when captures were always warm.
 * Measured cold starts on this machine are 1.3-2.1s for two displays - and
 * that margin disappeared once power assertions became session-scoped, since
 * the panel may now be asleep and ScreenCaptureKit has to wake it first.
 * The budget is a CEILING, not a delay: the wait returns the moment every
 * display has delivered, so a warm reconnect still costs 0.00s.
 */
#define INITIAL_READINESS_TIMEOUT_NANOSECONDS (8ULL * NSEC_PER_SEC)

/* Number of currently connected clients (read by AppDelegate for status display) */
_Atomic int vncConnectedClients = 0;

/* The narrower count: clients past the first-frame wait. See mac.h. */
_Atomic int vncAuthenticatedClientsReceivingUpdates = 0;



/*
 * Which displays are ATTACHED, whether or not they happen to be awake.
 *
 * CGGetOnlineDisplayList is the only enumerator that survives display sleep -
 * measured on this desk with both panels off: the active list was empty while
 * the online list still reported both, with correct bounds. It is what gives
 * the wait below a target instead of a threshold.
 *
 * Mirrored secondaries are dropped. The ACTIVE list excludes them; the online
 * list does not, and two displays reporting identical bounds make
 * macVNCBuildDisplayLayout fail as overlapping - so passing them through would
 * turn "the user enabled mirroring" into "the server refuses to start".
 */
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

/*
 * Turn the CURRENTLY ACTIVE CoreGraphics display list into MacVNCDisplayInput
 * entries. No waking, no waiting - a plain read of whatever is awake right
 * now, so it is safe to call from a context that must not light a sleeping
 * panel (see the re-arm path below).
 *
 * Split out of readAttachedDisplays() so that path (startup, which must wait
 * for a sleeping desk to wake) and the capture-liveness re-arm path (which
 * must NOT wake one - .pi/plans/display-reconfiguration.md rejected a
 * reconfiguration watcher partly because re-resolving woke the panel at 3am)
 * share this one reading, instead of a second copy that could drift from it.
 *
 * `logEnumeration` gates the one "Found ... display ..." line per display
 * below: FALSE for a probe read that only ever COMPARES against the
 * published layout (FIX-D's debounce evaluation, which runs on every settled
 * screen-parameter notification whether or not the desk actually changed) -
 * printing those lines there logged a full display enumeration on every
 * notification burst even when nothing had changed, which is not a
 * diagnostic, it is noise timed to coincide with one. TRUE for every caller
 * that is either always real (startup) or already committed to an actual
 * rebuild (rearmCaptures' own re-read) - see those call sites for why each
 * chose the value it did. */
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

/*
 * Enumerate the displays to capture, waiting for the whole desk.
 *
 * This used to break out of its retry loop at the FIRST non-zero active count.
 * On a sleeping desk that is whichever panel woke first: macVNC came up with a
 * 3840x2160 canvas for a 5550x2715 desk and the second monitor stayed invisible
 * to every viewer until the app was restarted by hand. The loop knew a slept
 * screen reports zero - its own comment said so - but had no idea how many to
 * expect, so any partial answer ended it.
 *
 * STARTUP ONLY: this wakes the desk. The re-arm path re-reads with
 * collectDisplayInputs() directly and never calls this function.
 */
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

/* Apply the configured selection to an already-read attached-display list and
   build the composite layout INTO *layout. Shared by startup (fed by the
   waking readAttachedDisplays()) and re-arm (fed by the non-waking
   collectDisplayInputs()), so the selection rules - and macVNCBuildDisplayLayout
   itself - exist in exactly one place regardless of how the desk was read.
   Does not log the result: callers differ on whether "Capturing N
   display(s)..." is the right line to emit (a probe made only to COMPARE
   against the live layout is not a publish), so that stays with them.

   E2: a `displayNumber >= 0` selection is resolved by POSITION only the
   FIRST time this runs in a server run (gPinnedDisplayID still 0) - every
   later call selects by the DISPLAY IDENTITY that first resolution picked
   (macVNCSelectDisplayByID), never by position again, so a desk event that
   reorders CoreGraphics' enumeration cannot silently hand a live capture to a
   different physical monitor mid-session. If the pinned display is no longer
   attached, this refuses rather than substituting whatever else is around -
   the caller's only recourse is the same reportCaptureFailure(false) path a
   failed rebuild already uses, never a server stop. -1 (primary) and -2
   (all) never touch gPinnedDisplayID: re-evaluating live on every call is
   what those settings mean. */
static rfbBool
applySelectionAndBuildLayout(const MacVNCDisplayInput *attached, size_t attachedCount,
                             int primaryIndex, MacVNCDisplayLayout *layout)
{
  MacVNCDisplayInput selected[MACVNC_MAX_DISPLAYS];
  size_t selectedCount = 0;

  if (displayNumber >= 0 && gPinnedDisplayID != 0) {
      if (macVNCSelectDisplayByID(attached, attachedCount, gPinnedDisplayID,
                                  selected, &selectedCount) != MACVNC_DISPLAY_SELECTION_OK) {
          rfbErr("Pinned display id=%u (selection %d) is no longer attached; "
                 "keeping the previous layout rather than silently capturing "
                 "a different monitor\n", gPinnedDisplayID, displayNumber);
          return FALSE;
      }
  } else {
      switch (macVNCSelectDisplays(attached, attachedCount, primaryIndex,
                                   displayNumber, selected, &selectedCount)) {
      case MACVNC_DISPLAY_SELECTION_OK:
          if (displayNumber >= 0)
              gPinnedDisplayID = selected[0].displayID;
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
  logCapturingLayout(publishDisplayLayout(&freshLayout));
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
 * Impose the configured image profile just before this client's update is
 * encoded.
 *
 * This deliberately OVERRIDES what the viewer asked for. Most viewers send
 * their own quality level, so a setting that only applied when they stayed
 * silent would do nothing on the devices people actually use. The honest way
 * to disagree is the "viewer" profile, which does not install this hook at all.
 *
 * displayHook is the only seam available: LibVNCServer has no hook after
 * SetEncodings, but it calls this one before every framebuffer update
 * (rfb.h:307), by which point the client's levels are ours to set.
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
       with (see gPublishedLayout and MacVNCCaptureFrameOrigin). An explicit,
       monotonically increasing, NEVER REUSED generation has no reuse window:
       whatever this frame carries either equals the CURRENT generation or it
       does not, however many re-arms separate the two. */
    if (origin.generation != atomic_load(&gCaptureSessionGeneration))
        return true; /* stale session; not retryable, nothing to composite */

    /* Load the published layout EXACTLY ONCE and read every field below
       through this local - see gPublishedLayout above for why. Before the
       double-buffer swap this touched the `displayLayout` global directly,
       field by field, which raced a re-arm's in-place overwrite of that same
       global; loading the pointer once makes this whole function see a
       single, self-consistent publish no matter what a concurrent re-arm
       publishes in the meantime. */
    MacVNCDisplayLayout *layout = currentDisplayLayout();

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

    /* The ONE write point for "a frame arrived" - see CaptureLiveness.h. The
       call reaching this function AND matching the current generation is the
       liveness signal, independent of whether the size check below turns out
       to match: a stream delivering wrong-sized frames is a different bug
       from one that stopped delivering anything, and only the watchdog cares
       about the latter. */
    atomic_store(&gLastFrameNs[origin.displayIndex], macVNCUptimeNow());
    /* A delivered frame from ANY display proves the stream that produced it
       is alive again, so whatever re-arm count a PRIOR silence ran up no
       longer describes the current situation - without this reset a stream
       that recovers on its own after two re-arms would need only one more
       silent minute to hit maxRearms and GiveUp.

       This reset and silence share the EXACT same trigger, by construction:
       silence is freshestFrameStamp(), the MAXIMUM stamp over the layout's
       displays, and this line is the only writer of any display's stamp -
       so on any tick where this store just ran, the NEXT watchdog read of
       freshestFrameStamp() is already recent, and CaptureLiveness.c's own
       silence rule reports Alive before rearmsSinceFrame is ever consulted.
       The only way rearmsSinceFrame can climb to maxRearms and reach GiveUp
       is a stretch where NO display delivers a frame for the whole
       grace+silence+maxRearms*cooldown budget - and across exactly that
       stretch this store never runs, so nothing rescues the counter.

       Bounded, not absolute: captureLivenessWatchdogFired() reads
       freshestFrameStamp() and rearmsSinceFrame as two SEPARATE lock-free
       loads (see its `input` snapshot), not one atomic transaction, so a
       frame that lands on the capture-callback thread between those two
       reads pairs a now-stale timestamp (read before the frame) with a
       just-cleared counter (reset by the frame that landed after). That
       reads as MORE silence than is true for exactly one watchdog tick,
       which can cost at most one spurious re-arm - the next tick reads both
       values fresh again, so this cannot compound, and true silence (no
       frame arriving during the ENTIRE window) is untouched by it: GiveUp
       remains reachable within maxRearms+1 attempts, never blocked, only
       possibly delayed by one.

       Before the MIN-to-MAX fix on freshestFrameStamp(), this same
       unconditional reset was the other half of a measured production bug:
       silence was judged by the OLDEST (idle display's) stamp while this
       reset fired on the NEWEST (working display's) frame, so the two
       disagreed - the working display's frames kept clearing a counter that
       the idle display's silence kept trying to raise, twelve re-arms in
       two minutes, GiveUp never reached. Fixing the silence definition
       alone already closes that: it was never a separate defect in the
       reset, just a mismatch between what "silence" and what "reset" each
       looked at. */
    atomic_store(&gRearmsSinceFrame, 0);

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
    /* AND stamp which capture ATTEMPT it belongs to: gCaptureSessionGeneration
       changes on every Build, successful or not (nextCaptureSessionGeneration()
       runs unconditionally at the top of rearmCaptures(), and again at every
       ScreenInit/reconcile Build) - so this is a distinct number per re-arm
       attempt within the SAME server run, which is exactly what
       macVNCShouldActOnCaptureFailure needs to stop deduplicating a failed
       re-arm, then another, then an honest GiveUp down to a single silent
       report. */
    uint64_t captureGeneration = atomic_load(&gCaptureSessionGeneration);
    /* No UI here: AppDelegate owns the single permission popup. */
    if (macVNCScreenCaptureFailureHandler)
        macVNCScreenCaptureFailureHandler(likelyPermissionDenial, generation, captureGeneration);
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
  MacVNCDisplayLayout *layout = currentDisplayLayout();

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
  if (!macVNCCaptureSessionBuild(layout, nextCaptureSessionGeneration(),
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


static MacVNCCaptureLivenessLimits
captureLivenessLimits(void)
{
    MacVNCCaptureLivenessLimits limits = {
        .graceNs    = MACVNC_CAPTURE_LIVENESS_GRACE_NANOSECONDS,
        .silenceNs  = MACVNC_CAPTURE_LIVENESS_SILENCE_NANOSECONDS,
        .cooldownNs = MACVNC_CAPTURE_LIVENESS_COOLDOWN_NANOSECONDS,
        .maxRearms  = MACVNC_CAPTURE_LIVENESS_MAX_REARMS,
    };
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    uint64_t override;
    if ((override = atomic_load(&gCaptureLivenessGraceOverrideNs)) != 0)
        limits.graceNs = override;
    if ((override = atomic_load(&gCaptureLivenessSilenceOverrideNs)) != 0)
        limits.silenceNs = override;
    if ((override = atomic_load(&gCaptureLivenessCooldownOverrideNs)) != 0)
        limits.cooldownNs = override;
#endif
    return limits;
}

/* A plain, cheap read of "is any display awake right now" - no waking, no
   display objects built, just the count collectDisplayInputs() itself checks
   first. Reused by nothing else: collectDisplayInputs() needs the full list
   to build a layout from, this needs only whether it would be empty, and a
   shared helper for one comparison against zero is not worth the coupling. */
static bool
anyDisplayCurrentlyActive(void)
{
    CGDisplayCount reported = 0;
    CGGetActiveDisplayList(0, NULL, &reported);
    return reported > 0;
}

/*
 * The MOST RECENT stamp over the displays actually in the layout.
 *
 * This used to be the MINIMUM - "one dead panel of two must be caught, not
 * averaged away by a lively one" - on the assumption that ScreenCaptureKit
 * keeps delivering frames at the configured rate whether or not pixels
 * changed. Measured false in production (2026-09-12): a two-display desk
 * where the user worked on only one panel produced NINE re-arms in about two
 * minutes on the IDLE panel's stale stamp alone, tearing down and rebuilding
 * BOTH displays' capture every ~10s while the active display's session was
 * healthy and its viewer was receiving real frames the whole time
 * (end-of-session stats for that run: 3144 ZRLE events, 1547
 * FramebufferUpdate requests). A display with nothing to redraw simply does
 * not get a new sample buffer - see the corrected claim in
 * CaptureLiveness.h and .pi/plans/capture-liveness.md.
 *
 * Silence must therefore mean "NO display in the layout is producing
 * frames", which is the MAXIMUM stamp, not the minimum. This deliberately
 * gives up catching "one of several displays went dead while the rest keep
 * working" - that is a different, narrower failure this function no longer
 * detects. Adding it back would need its own, more conservative mechanism
 * (a much longer per-display threshold, re-arming only the affected display)
 * and is left undone on purpose - see .pi/plans/capture-liveness.md, which
 * this comment's production measurement was written into. */
static uint64_t
freshestFrameStamp(void)
{
    MacVNCDisplayLayout *layout = currentDisplayLayout();
    if (layout->count == 0)
        return 0;
    uint64_t freshest = 0;
    for (size_t i = 0; i < layout->count; ++i) {
        uint64_t stamp = atomic_load(&gLastFrameNs[i]);
        if (stamp > freshest)
            freshest = stamp;
    }
    return freshest;
}

/* E2 (.pi/plans/capture-liveness.md): this used to be
   logIfPinnedSelectionChangedDisplay(), which only DETECTED after the fact
   that a pinned `displayNumber >= 0` had silently resolved to a different
   physical display and logged about it. applySelectionAndBuildLayout() now
   PINS the selection to the display identity it first resolved
   (gPinnedDisplayID) and never substitutes another one, so that detector's
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
static bool
rearmCaptures(void)
{
    /* Claim the NEW generation FIRST, before anything else - see
       nextCaptureSessionGeneration for why order matters here: any frame the
       OLD session might still deliver (StopAndWait's drain is bounded, and a
       stream whose work never quiesced is deliberately leaked rather than
       freed while a callback may still touch it, per
       MacVNCCaptureSession.h) must find gCaptureSessionGeneration ALREADY
       advanced, however early it arrives - even mid-drain, even before the
       new session exists. Claiming it any later would leave exactly that
       window open. Used by whichever branch below actually rebuilds. */
    uint64_t generation = nextCaptureSessionGeneration();

    /* Read BEFORE StopAndWait/Build: this is the only moment that can still
       say whether curtain mode's exclusion was in effect a moment ago, and it
       is passed to Build below as `desiredExcluded` - which is what keeps
       macVNCCaptureSessionSelfExcluded() reporting true for the WHOLE rebuild
       rather than only after it, closing (not just narrowing) the window the
       curtain's un-debounced heartbeat could otherwise observe. See
       MacVNCCaptureSession.h's header on macVNCCaptureSessionBuild. */
    bool wasExcluded = macVNCCaptureSessionSelfExcluded();

    macVNCCaptureSessionStopAndWait();
    for (size_t i = 0; i < MACVNC_MAX_DISPLAYS; ++i)
        atomic_store(&gLastFrameNs[i], 0);
    atomic_store(&gCapturesStartedNs, macVNCUptimeNow());

    /* Re-read the desk WITHOUT waking it: resolveDeskLayoutWithoutWaking()
       calls collectDisplayInputs(), never readAttachedDisplays(), and a
       Rearm verdict already implies a client is connected (CaptureLiveness's
       first rule), so there is no viewer-less desk here to needlessly light
       up. On failure there is nothing left to retry into - same as a failed
       rebuild below. */
    MacVNCDisplayLayout freshLayout;
    if (!resolveDeskLayoutWithoutWaking(&freshLayout, true)) {
        rfbErr("Re-arm could not re-read the desk\n");
        return false;
    }

    /* Loaded once: re-arm is the only writer that ever runs (it is the sole
       thing scheduled on gCaptureStopQueue, a serial queue, and startup's
       resolveDisplayLayout() cannot overlap it - the server is already up),
       so nothing can publish a newer generation between this load and the
       swap below. Both branches below compare against and read through this
       SAME pointer rather than re-deriving it, for the same reason
       compositeCapturedFrame loads it once - see gPublishedLayout. */
    MacVNCDisplayLayout *liveLayout = currentDisplayLayout();

    if (macVNCDisplayLayoutsEqual(liveLayout, &freshLayout)) {
        /* Same shape: rebuild onto the unchanged, already-published layout.
           Checked, not discarded: a failed rebuild leaves Count() == 0 (per
           the session header), and starting anyway would be exactly the
           silent nothing-happens failure this whole mechanism exists to
           replace. Mirrors ScreenInit's own
           `if (!macVNCCaptureSessionBuild(...)) return FALSE;` (this file,
           above) for the same call, on the same layout. */
        if (!macVNCCaptureSessionBuild(liveLayout, generation, gCaptureFramesPerSecond,
                                       compositeCapturedFrame, reportCaptureFailure,
                                       wasExcluded))
            return false;
        macVNCCaptureSessionStart();
        return true;
    }

    /* The desk changed shape: swap the canvas before rebuilding capture on
       the new layout. The order below is deliberate, and every early return
       from here on leaves the compositor attached to a VALID screen with a
       VALID (never freed) frameBuffer - the caller's only recourse on
       `false` is reportCaptureFailure(false), never a server stop, so
       nothing downstream may assume a torn-down screen.
         1. Allocate and zero the NEW canvas FIRST, before touching anything
            published: a failed allocation then leaves the old canvas and the
            currently published layout completely untouched.
         2. Detach the compositor: macVNCCompositorSetScreen(NULL) blocks
            until any in-flight composite finishes, so once it returns
            nothing can still be writing through the OLD width/stride - the
            publish below would otherwise race a composite mid-frame.
         3. Publish the new layout - via publishDisplayLayout()'s atomic
            pointer swap into the OTHER slot, never the in-place
            `displayLayout = freshLayout` this replaced (see gPublishedLayout
            for the race that had with compositeCapturedFrame's unsynchronised
            hot-path read) - and swap frameBufferOne only once the canvas they
            describe exists and no composite can touch the old one, then
            rfbNewFramebuffer - LibVNCServer resizes the screen and tells
            every connected client (NewFBSize/ExtDesktopSize, confirmed in a
            real TigerVNC handshake), which is why no client needs to be
            dropped for this.
         4. macVNCInputSetContext right after: PtrAddEvent maps a client's
            pointer through the OLD layout/screen until this call, and it is
            reachable the instant rfbNewFramebuffer returns.
         5. Re-attach the compositor last, only once the screen it will
            composite onto is fully described.
         6. Free the OLD canvas only now: no composite can still be running
            against it (step 2) and rfbScreen->frameBuffer no longer points at
            it (step 3), so freeing earlier would be premature and freeing
            never would leak one canvas per re-arm. */
    size_t bufSize = (size_t)freshLayout.width * (size_t)freshLayout.height * 4;
    void *newBuffer = calloc(1, bufSize);
    if (!newBuffer) {
        rfbErr("Re-arm could not allocate a %dx%d canvas for the new desk shape\n",
               freshLayout.width, freshLayout.height);
        return false;
    }

    macVNCCompositorSetScreen(NULL);
    void *oldBuffer = frameBufferOne;
    MacVNCDisplayLayout *publishedLayout = publishDisplayLayout(&freshLayout);
    frameBufferOne = newBuffer;
    rfbNewFramebuffer(rfbScreen, (char *)newBuffer,
                      publishedLayout->width, publishedLayout->height, 8, 3, 4);
    macVNCInputSetContext(rfbScreen, publishedLayout);
    macVNCCompositorSetScreen(rfbScreen);
    free(oldBuffer);

    rfbLog("Desk shape changed since this session started; rebuilding the composite canvas\n");
    logCapturingLayout(publishedLayout);

    if (!macVNCCaptureSessionBuild(publishedLayout, generation, gCaptureFramesPerSecond,
                                   compositeCapturedFrame, reportCaptureFailure,
                                   wasExcluded))
        return false;
    macVNCCaptureSessionStart();
    return true;
}

/*
 * The decision half of FIX-D: given a FRESH re-read of the desk, rebuild
 * ONLY if it actually differs from what is currently published.
 *
 * Split out from the notification handler below so a test can drive this
 * exact decision (via macVNCForceDeskShapeDifferentForTesting) without
 * needing to physically reconfigure a display or fake a CoreGraphics read -
 * rearmCaptures() performs its OWN independent re-read when it actually
 * rebuilds, so an equal-in-practice `fresh` here still only ever leads to a
 * real, live-desk-accurate rebuild, never a fabricated one.
 *
 * An equal layout does nothing and logs nothing, exactly as a desk that never
 * changed deserves: this function runs on every settled notification burst,
 * which on a machine nobody is reconfiguring is silence the rest of the time.
 */
static void
evaluateDeskShapeForRearm(const MacVNCDisplayLayout *fresh)
{
    MacVNCDisplayLayout *live = currentDisplayLayout();
    bool equal = live != NULL && macVNCDisplayLayoutsEqual(live, fresh);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    if (atomic_load(&gForceDeskShapeDifferentForTesting))
        equal = false;
#endif
    if (equal)
        return;

    /* Named here, distinctly from rearmCaptures()'s own "rebuilding the
       composite canvas" line: that line says WHAT happened (a new canvas of
       a given size), this one says WHY a rebuild is starting at all and what
       the comparison that triggered it looked like - the two are read
       together, not as duplicates of each other, the same way
       captureLivenessWatchdogFired's "No capture frames for Xs" line and
       rearmCaptures()'s own logging already coexist for the silence path. */
    rfbLog("Display configuration changed: canvas %dx%d -> %dx%d; re-arming display captures\n",
          live ? live->width : 0, live ? live->height : 0,
          fresh->width, fresh->height);

    /* The return value matters here exactly as much as it does in
       captureLivenessWatchdogFired()'s own Rearm case: a failed rebuild
       triggered by a real reconfiguration is not silently swallowed just
       because THIS trigger is a notification rather than measured silence -
       reportCaptureFailure() is the same one path every other capture
       failure already goes through (KeepServing/StopServer decided there,
       never here). Deliberately NOT gCaptureRearmCount/gRearmsSinceFrame/
       gLastRearmNs - those belong to the SILENCE-driven watchdog's own
       cooldown/maxRearms budget, and folding a shape-driven rearm into that
       counter would let an unrelated cause (a display reconfiguring several
       times in a row) push the silence watchdog toward a GiveUp it did not
       earn. This trigger gets its own counters - see
       gDeskShapeRebuildCount/gDeskShapeRebuildFailureCount. */
    bool rebuilt = rearmCaptures();
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(rebuilt ? &gDeskShapeRebuildCount : &gDeskShapeRebuildFailureCount, 1);
#endif
    if (!rebuilt) {
        rfbErr("Could not rebuild display captures after a display configuration change\n");
        reportCaptureFailure(false);
    }
}

/*
 * gCaptureStopQueue-confined: the debounce timer's event handler, so this
 * only ever runs on the one queue rearmCaptures() has always required.
 */
static void
deskShapeDebounceFired(void)
{
#if defined(MACVNC_ENABLE_TEST_HOOKS)
    atomic_fetch_add(&gDeskShapeRecheckCount, 1);
#endif
    pthread_mutex_lock(&captureControlMutex);
    bool shouldEvaluate = gCapturesRunning && atomic_load(&vncConnectedClients) > 0;
    pthread_mutex_unlock(&captureControlMutex);
    if (!shouldEvaluate)
        return; /* nothing running to rebuild, or the last client left while
                    this was in flight - the next connect reads the desk
                    fresh regardless (startCapturesForNewClient). */

    /* Re-read the desk WITHOUT waking it - the same call and the same
       reasoning as rearmCaptures()'s own re-read: a notification implies a
       real reconfiguration happened, not that any display needs waking.
       logEnumeration=false: this is a PROBE, only ever used to compare
       against the published layout below - most notifications turn out
       equal, and rearmCaptures() below already does its own logged re-read
       the moment this comparison finds a real difference, so logging here
       too would print the same display list twice for one real change and
       once for nothing on every notification that changed nothing at all. */
    MacVNCDisplayLayout fresh;
    if (!resolveDeskLayoutWithoutWaking(&fresh, false)) {
        rfbErr("Could not re-read the desk after a display configuration change\n");
        return;
    }
    evaluateDeskShapeForRearm(&fresh);
}

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
                    plan rejected. */
    macVNCEnsureStopQueue();
    dispatch_async(gCaptureStopQueue, ^{
        if (!gDeskShapeDebounceTimer) {
            gDeskShapeDebounceTimer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gCaptureStopQueue);
            dispatch_source_set_event_handler(gDeskShapeDebounceTimer, ^{
                deskShapeDebounceFired();
            });
            dispatch_resume(gDeskShapeDebounceTimer);
        }
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        uint64_t debounce = atomic_load(&gDeskShapeDebounceOverrideNs);
        if (debounce == 0)
            debounce = MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS;
#else
        uint64_t debounce = MACVNC_DESK_SHAPE_DEBOUNCE_NANOSECONDS;
#endif
        /* Rescheduling an ALREADY-armed source restarts its deadline rather
           than stacking a second firing - this is the coalescing itself: a
           burst of N calls inside one debounce window produces exactly one
           firing, timed from the LAST call, not the first. */
        dispatch_source_set_timer(gDeskShapeDebounceTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)debounce),
            DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 10);
    });
}

/* Silence looks identical whether the stream is genuinely dead or Screen
   Recording access was revoked/never granted: SCK raises no error either
   way, it simply delivers nothing (this file's captureIsAllowed() reads the
   same policy the permission owner already tracks - see macVNCCaptureAllowed).
   A one-word difference in the log line is the whole fix: no prompting, no
   branch in the resolver, just naming the more likely cause so an operator
   is not left guessing between "broken stream" and "permission row". */
static const char *
permissionHintSuffix(void)
{
    return captureIsAllowed() ? "" : " (Screen Recording permission is not granted)";
}

static void
captureLivenessWatchdogFired(void)
{
    pthread_mutex_lock(&captureControlMutex);
    MacVNCCaptureLivenessInput input = {
        .capturesRunning   = gCapturesRunning,
        .clientsConnected  = atomic_load(&vncConnectedClients) > 0,
        .anyDisplayActive  = anyDisplayCurrentlyActive(),
        .nowNs             = macVNCUptimeNow(),
        .lastFrameNs       = freshestFrameStamp(),
        .capturesStartedNs = atomic_load(&gCapturesStartedNs),
        .lastRearmNs       = atomic_load(&gLastRearmNs),
        .rearmsSinceFrame  = atomic_load(&gRearmsSinceFrame),
    };
    pthread_mutex_unlock(&captureControlMutex);

    MacVNCCaptureLivenessLimits limits = captureLivenessLimits();
    switch (macVNCResolveCaptureLiveness(&input, &limits)) {
    case MacVNCCaptureAlive:
        return;
    case MacVNCCaptureRearm: {
        uint64_t sinceActivity = input.nowNs -
            (input.lastFrameNs ? input.lastFrameNs : input.capturesStartedNs);
        rfbLog("No capture frames for %.1f s; re-arming display captures%s\n",
               (double)sinceActivity / 1e9, permissionHintSuffix());
        if (!rearmCaptures()) {
            /* Bookkeeping advances on failure too, not only on success below -
               this was the bug a whole-diff audit caught: leaving
               gLastRearmNs/gRearmsSinceFrame untouched here meant the very
               next 1Hz tick saw the SAME inputs it just saw, resolved to
               Rearm again, failed again, forever - maxRearms and GiveUp were
               unreachable on exactly the path most likely to need them (a
               re-read or rebuild that keeps failing the same way). A failed
               attempt is still an attempt and must count toward the cap.
               The immediate report below is kept ON TOP of that, not instead
               of it: same layout, same call ScreenInit already trusted at
               startup, now failing mid-run - there is nothing left to retry
               into THIS attempt, so telling the user now rather than after
               more silent cooldown cycles is still right. If this report is
               swallowed by a stale/duplicate check upstream, the advanced
               counters here are what still gets an honest GiveUp out within
               the budget. */
            atomic_store(&gLastRearmNs, macVNCUptimeNow());
            atomic_fetch_add(&gRearmsSinceFrame, 1);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
            atomic_fetch_add(&gCaptureRearmFailureCount, 1);
#endif
            /* B5: LOG this attempt, do not ALERT for it. reportCaptureFailure()
               is what turns into an NSAlert (or a KeepServing/StopServer
               decision) in AppDelegate, and with a failed attempt now
               individually counted (the block above), calling it here too
               would mean up to maxRearms distinct alerts inside one ~30s
               budget for a condition that is, until the LAST attempt, still
               recoverable - the exact opposite of "invisible when it works".
               The honest shape: an intermediate failed attempt is a LOG
               event; only GiveUp below is a USER event. Bookkeeping still
               advances above regardless, so GiveUp remains reachable within
               the same budget whether or not anyone is watching the log. */
            rfbErr("Re-arm attempt %u/%u failed; retrying after the cooldown\n",
                   atomic_load(&gRearmsSinceFrame), limits.maxRearms);
            return;
        }
        atomic_store(&gLastRearmNs, macVNCUptimeNow());
        atomic_fetch_add(&gRearmsSinceFrame, 1);
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        atomic_fetch_add(&gCaptureRearmCount, 1);
#endif
        return;
    }
    case MacVNCCaptureGiveUp:
#if defined(MACVNC_ENABLE_TEST_HOOKS)
        atomic_fetch_add(&gCaptureGiveUpCount, 1);
#endif
        rfbLog("Display captures did not recover after %u re-arm(s); "
               "reporting a capture failure%s\n", limits.maxRearms,
               permissionHintSuffix());
        reportCaptureFailure(false);
        return;
    }
}

/* Armed only while gCapturesRunning: an idle server with no client has
   nothing to watch (the pure resolver already answers Alive for it), but
   arming the timer anyway would tick forever on a server nobody is using.
   Caller must hold captureControlMutex - see gCaptureLivenessTimer. */
static void
startCaptureLivenessWatchdog(void)
{
    if (gCaptureLivenessTimer)
        return;
    macVNCEnsureStopQueue();
    gCaptureLivenessTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gCaptureStopQueue);
    dispatch_source_set_timer(gCaptureLivenessTimer,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC, NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(gCaptureLivenessTimer, ^{
        captureLivenessWatchdogFired();
    });
    dispatch_resume(gCaptureLivenessTimer);
}

/* Caller must hold captureControlMutex - see gCaptureLivenessTimer. */
static void
stopCaptureLivenessWatchdog(void)
{
    if (!gCaptureLivenessTimer)
        return;
    dispatch_source_cancel(gCaptureLivenessTimer);
    dispatch_release(gCaptureLivenessTimer);
    gCaptureLivenessTimer = NULL;
}

/*
 * The actual "start capturing for a newly arrived client" work, split out of
 * reconcileCaptureState() so it can run OFF captureControlMutex.
 *
 * A reconnect after captures were FULLY stopped - keep-warm's own timer
 * already fired, or vncServerDropCaptures() dropped them after a capture
 * failure - must REBUILD, not merely restart, the same ScreenCapturer set:
 * macVNCCaptureSessionStart() only re-opens a stream on whatever displayIDs
 * and composite canvas the last successful Build established, and neither a
 * full keep-warm stop nor a capture-failure drop ever calls Build again on
 * its own (only Reset, which a full SERVER stop performs, does). A desk that
 * changed shape while nobody was connected - a monitor added or removed
 * between sessions, the ordinary way the measured 42-hour incident's own
 * trigger happens - would otherwise stay invisible to the composite canvas
 * forever, and a capture failure's KeepServing recovery would keep
 * restarting streams already known dead (audit_integration.md items 2 and
 * 3). Both close the same way a live re-arm already does: re-read the desk
 * and rebuild before starting - see rearmCaptures(), reused here rather than
 * a third copy of its same-shape/different-shape logic.
 *
 * That rebuild's StopAndWait blocks for bounded but real seconds, which must
 * never happen with captureControlMutex held (see rearmCaptures()'s own
 * header note) - this is why reconcileCaptureState() calls this OFF its
 * lock, dispatched synchronously onto gCaptureStopQueue: the SAME serial
 * queue rearmCaptures() has always run on exclusively, so two clients
 * connecting together cannot rebuild the session twice at once. The re-check
 * below is what makes the SECOND arrival, queued behind the first, a no-op
 * instead of a redundant rebuild: by the time it runs, the first arrival has
 * already flipped gCapturesRunning.
 */
static void
startCapturesForNewClient(void)
{
    pthread_mutex_lock(&captureControlMutex);
    if (gCapturesRunning || atomic_load(&vncConnectedClients) == 0) {
        pthread_mutex_unlock(&captureControlMutex);
        return;
    }
    if (!captureIsAllowed()) {
        /* Never touch capture without the permission: doing so is what makes
           macOS raise its own dialog. The decision belongs to the permission
           owner, injected via macVNCCaptureAllowed. */
        rfbLog("Screen Recording is not granted; refusing to start capture\n");
        pthread_mutex_unlock(&captureControlMutex);
        /* No Build was even attempted here, so there is no fresh capture
           attempt to identify - pass whatever gCaptureSessionGeneration
           already holds. Every repeated connection attempt while the
           permission stays denied therefore collapses to ONE alert per
           server run, deliberately: unlike a re-arm's distinct failed
           attempts, a denied permission does not change from one connection
           attempt to the next, and the fix is the user's to make -
           re-nagging on every attempt would not be more honest, only
           noisier. */
        if (macVNCScreenCaptureFailureHandler)
            macVNCScreenCaptureFailureHandler(true, vncServerCurrentGeneration(),
                                              atomic_load(&gCaptureSessionGeneration));
        return;
    }
    /* Consumed here, once: see gCaptureSessionFreshAtStartup for why the
       VERY FIRST connect after ScreenInit must not pay a second, non-waking
       rebuild for a layout that is already as fresh as this run has ever
       been, while every later arrival needs exactly that rebuild.

       ALSO requires a published layout to rebuild against: a synthetic test
       that drives this reconciler directly (macVNCReconcileCaptureForTesting)
       without ever running a real ScreenInit has no layout published at all
       (currentDisplayLayout() == NULL) and no capturers to rebuild in the
       first place - rearmCaptures() would have nothing real to compare
       against or Build onto. In production this can never be false while
       gCaptureSessionFreshAtStartup is also false: ScreenInit publishes a
       layout and sets that flag together, in that order, and nothing ever
       un-publishes it back to NULL for the life of the process. */
    bool needsRebuild = !gCaptureSessionFreshAtStartup && currentDisplayLayout() != NULL;
    gCaptureSessionFreshAtStartup = false;
    pthread_mutex_unlock(&captureControlMutex);

    /* Awake-while-watched: the power assertions live as long as a viewer is
       connected, not as long as the LISTENER runs. With "Start at Login" the
       server may run for weeks; holding the assertions that whole time would
       be the pmset bug again with a nicer implementation. */
    if (dimmingInit() != 0)
        rfbLog("Power assertion failed; machine may idle-sleep during the session\n");

    bool ok;
    if (needsRebuild) {
        /* rearmCaptures() claims its own generation, stops (a StopAndWait on
           an already-stopped session is a harmless no-op), re-reads the desk
           WITHOUT waking it - countClientForCaptureLocked() already called
           macVNCWakeDisplays() for this very client before
           reconcileCaptureState() ran, so there is nothing this would need to
           wake that is not already on its way up - and rebuilds onto
           whatever the desk turns out to be, same-shape or not. */
        ok = rearmCaptures();
    } else {
        macVNCCaptureSessionStart();
        /* A fresh watch on a fresh clock: whatever the previous run's streams
           did or did not deliver is not this run's problem, and starting the
           grace window from a stale gCapturesStartedNs would let the
           watchdog fire on its very first tick. rearmCaptures() already does
           this same reset for the needsRebuild branch above; done here, once,
           for the one case it does not cover. */
        for (size_t i = 0; i < MACVNC_MAX_DISPLAYS; ++i)
            atomic_store(&gLastFrameNs[i], 0);
        atomic_store(&gCapturesStartedNs, macVNCUptimeNow());
        ok = true;
    }

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
    atomic_store(&gLastRearmNs, 0);
    atomic_store(&gRearmsSinceFrame, 0);
    gCapturesRunning = true;
    startCaptureLivenessWatchdog();
    rfbLog("Client connected; starting %lu display captures\n",
           (unsigned long)macVNCCaptureSessionCount());
    pthread_mutex_unlock(&captureControlMutex);
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
    bool shouldStartNewSession = wanted && !gCapturesRunning;
    if (shouldStartNewSession) {
        atomic_store(&gCaptureWarmDeadlineNs, 0); /* reconnect beats the timer */
    } else if (!wanted && gCapturesRunning) {
        /* Keep warm: schedule the real stop 30s out. The decision here stays
           instant and lock-consistent; the stop itself runs OFF the control
           mutex (it waits seconds for in-flight SCK work).

           Deliberately macVNCMonotonicNow(), NOT macVNCUptimeNow(): the
           dispatch_source timer below is itself scheduled in sleep-inclusive
           (continuous) time by the OS and will not fire until that much real
           time, asleep or not, has passed - comparing its firing against an
           awake-only deadline could read as "not due yet" right when this
           ONE-SHOT timer fires, with nothing left to ever re-check. The
           watchdog's clock and this one answer different questions on
           purpose; see macVNCMonotonicNow()'s comment. */
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
                stopCaptureLivenessWatchdog();
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
            /* Paired with the assertions, not with the server stop. This is a
               UserIsActive assertion, and holding it with no viewer connected
               is a caffeinate by another name - measured on a live machine as
               "macVNC remote session" held for hours after the last client
               left, which by itself stopped the display ever idle-sleeping. */
            macVNCReleaseDisplayAssertion();
            macVNCCaptureSessionStopAndWait();
            macVNCInputResetModifiers();
            rfbLog("Capture keep-warm window elapsed; %lu display captures stopped\n",
                   (unsigned long)macVNCCaptureSessionCount());
        });
        dispatch_resume(timer);
    }
    pthread_mutex_unlock(&captureControlMutex);

    if (shouldStartNewSession) {
        /* Off the lock entirely: startCapturesForNewClient() may run
           rearmCaptures(), which blocks for bounded StopAndWait work and must
           never run with captureControlMutex held - see rearmCaptures()'s own
           header note and startCapturesForNewClient()'s. Synchronous, not
           async: the caller (prepareAuthenticatedClient) waits for first
           frames right after this returns, and starting that wait before the
           rebuild has even begun would just make it time out instead. */
        macVNCEnsureStopQueue();
        dispatch_sync(gCaptureStopQueue, ^{ startCapturesForNewClient(); });
    }

    /* Closed-display mode is reconciled here, unconditionally and OUTSIDE the
       lock, and both properties were earned.

       Unconditionally, because the two branches above are edge-triggered on
       CAPTURE state, not on the client count: a viewer reconnecting inside the
       30 s keep-warm window takes neither branch, so a re-evaluation hung off
       them would silently skip that session. It also makes the release happen
       when the last viewer actually leaves rather than 30 s later, which is
       what the Preferences text promises.

       Outside the lock, because this does a synchronous cfprefsd round trip and
       three IOKit calls, and captureControlMutex serialises every connect and
       disconnect. The stop branch already unlocks before its slow work for the
       same reason. */
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
    stopCaptureLivenessWatchdog(); /* under the lock - see gCaptureLivenessTimer */
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
    stopCaptureLivenessWatchdog(); /* under the lock - see gCaptureLivenessTimer */
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
    gPinnedDisplayID = 0; /* fresh run: re-pin from position on first resolve */
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

unsigned
macVNCCaptureRearmCountForTesting(void)
{
    return atomic_load(&gCaptureRearmCount);
}

unsigned
macVNCCaptureRearmFailureCountForTesting(void)
{
    return atomic_load(&gCaptureRearmFailureCount);
}

unsigned
macVNCCaptureGiveUpCountForTesting(void)
{
    return atomic_load(&gCaptureGiveUpCount);
}

/* Bypasses ScreenCaptureKit entirely - see mac.h for why a synthetic frame,
   sized off the real current layout, is the only deterministic way to prove
   a stale generation is rejected. */
void
macVNCCompositeSyntheticFrameForTesting(uint64_t generation, size_t displayIndex)
{
    MacVNCDisplayLayout *layout = currentDisplayLayout();
    if (displayIndex >= layout->count)
        return;
    MacVNCDisplayGeometry *geometry = &layout->displays[displayIndex];
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

uint64_t
macVNCCurrentCaptureGenerationForTesting(void)
{
    return atomic_load(&gCaptureSessionGeneration);
}

uint64_t
macVNCLastFrameTimestampForTesting(size_t displayIndex)
{
    if (displayIndex >= MACVNC_MAX_DISPLAYS)
        return 0;
    return atomic_load(&gLastFrameNs[displayIndex]);
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
    return currentDisplayLayout()->count;
}

/*
 * A synthetic client, so the window between "authenticated" and "receiving
 * updates" - in production the first-frame wait, which can be seconds - can be
 * driven without a socket, a display or a viewer.
 *
 * These go through the SAME countClient*Locked/uncountClientLocked functions
 * the real client paths use, which is the whole point: a hook that
 * re-implemented the counting would let the rules it is protecting be deleted
 * while the test stayed green.
 *
 * Deliberately does NOT reconcile captures - that is the caller's job in
 * production and is a different rule - so a test of the counters needs no
 * ScreenCaptureKit at all.
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
    atomic_store(&gCaptureRearmCount, 0);
    atomic_store(&gCaptureRearmFailureCount, 0);
    atomic_store(&gCaptureGiveUpCount, 0);
    atomic_store(&gDeskShapeRecheckCount, 0);
    atomic_store(&gForceDeskShapeDifferentForTesting, false);
    atomic_store(&gDeskShapeRebuildCount, 0);
    atomic_store(&gDeskShapeRebuildFailureCount, 0);
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
