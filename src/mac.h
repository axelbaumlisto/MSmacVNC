#pragma once

#include <rfb/rfb.h>
#include <stdatomic.h>
#include <stddef.h>
#include "NetworkPolicyResolver.h"

#define MACVNC_LISTEN_ADDRESS_MAX 64
#define MACVNC_ALLOWED_CLIENTS_MAX 4096

/* -----------------------------------------------------------------------
 * Immutable server configuration passed by value to vncServerStart().
 * Replaces the former ambient mutable globals: AppDelegate builds this from
 * the resolved network policy and defaults, and the server owns a private
 * copy for its lifetime.
 * ----------------------------------------------------------------------- */
typedef struct {
    int port;                    /* TCP port (5900 = VNC default). */
    const char *password;        /* Shared password; must be non-empty. */
    int captureFramesPerSecond;  /* Validated capture rate for every display. */
    rfbBool viewOnly;            /* TRUE = accept clients but ignore input. */
    int displayNumber;           /* -2 = all displays, -1 = primary, >=0 = one. */
    const char *listenAddress;   /* IPv4 bind address; NULL/empty = all. */
    const char *allowedClients;  /* IPv4/CIDR allowlist; meaning per access mode. */
    MacVNCClientAccessMode clientAccessMode;
} MacVNCServerConfig;

/* -----------------------------------------------------------------------
 * Live statistics (updated atomically from LibVNCServer threads).
 * ----------------------------------------------------------------------- */

/* Number of VNC clients currently connected. */
extern _Atomic int vncConnectedClients;

/* Optional handler invoked when screen capture cannot proceed, e.g. Screen
 * Recording is not effectively granted or ScreenCaptureKit failed at runtime.
 * The server shows no UI itself; AppDelegate owns the permission popup.
 *
 * THREAD: any. Raised from the ScreenCaptureKit error queue AND from a client
 * thread when a connection is refused for lack of permission. The handler must
 * therefore hop to the main queue itself (AppDelegate does, via
 * performSelectorOnMainThread:). An earlier version of this comment promised
 * "on the main queue", which was not true of every call site. */
/* likelyPermissionDenial is TRUE only when the underlying error is consistent
 * with a TCC/Screen-Recording denial. Other capture failures (display removed,
 * stream stopped for unrelated reasons) pass FALSE so the caller does not latch
 * a permanent "permission missing" state on a transient/topology error. */
extern void (*macVNCScreenCaptureFailureHandler)(bool likelyPermissionDenial,
                                                 uint64_t serverGeneration);


/*
 * Answers "may we touch screen capture right now?".
 *
 * Injected by the owner of permission policy (AppDelegate) so the server core
 * holds no opinion about TCC: the core must never be the thing that asks macOS
 * for a permission, because touching capture without it is exactly what makes
 * the system raise its own "macVNC wants to record this screen" dialog - the
 * one dialog this app must never cause.
 *
 * Must not prompt and must be safe to call from a client thread. NULL means
 * "unrestricted", which is what unit tests and any embedder without a
 * permission model want.
 */
extern bool (*macVNCCaptureAllowed)(void);

/*
 * Monotonic id of the current server run, incremented by every start.
 * A capture-failure notification carries the generation it was raised for, so a
 * notification queued by an already-stopped run (e.g. delivered after a modal
 * finishes) can be discarded instead of killing a freshly started server.
 *
 * The stamp is read when the notification is RAISED and compared when it is
 * HANDLED on the main queue, so it can only filter out notifications from a run
 * that had already ended by then — which is exactly its purpose. It is not a
 * lock: a start that lands between the two points is handled by the handler
 * re-checking live state.
 */
uint64_t vncServerCurrentGeneration(void);

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

/*
 * Outcome of a start attempt. "Already running" must be distinguishable from a
 * genuine failure: reporting it as one made the UI advise the user to change the
 * port while the server was in fact serving on the current one.
 */
typedef enum {
    MacVNCServerStartOK = 0,
    /* A run is already live; nothing was changed. */
    MacVNCServerStartAlreadyRunning,
    /* Bad configuration, no displays, bind refused, out of memory, ... */
    MacVNCServerStartFailed,
} MacVNCServerStartResult;

/*
 * Initialise and start the VNC server from an immutable configuration.
 * config->password must be non-empty (authentication is mandatory); a NULL
 * or empty password makes this fail.
 *
 * On failure the reason is printed via rfbLog().
 * Must not be called on the main thread because rfbInitServer() briefly
 * blocks while binding the listen socket.
 */
MacVNCServerStartResult vncServerStartWithResult(const MacVNCServerConfig *config);

/* Convenience wrapper: TRUE only for MacVNCServerStartOK. */
rfbBool vncServerStart(const MacVNCServerConfig *config);

/*
 * Disconnect all clients, stop the server and free all resources.
 * Safe to call from any thread.
 */
void vncServerStop(void);

/*
 * Close the listening sockets without a full stop, freeing the port.
 *
 * Used immediately before relaunching: the successor inherits descriptors, and
 * a still-open listener makes its bind() fail. Both the IPv4 and IPv6 listeners
 * are closed and the published port is zeroed, so the UI stops advertising a
 * dead socket.
 *
 * Deliberately NOT vncServerStop(): that joins client threads and waits for
 * in-flight capture work, which can sit behind a system prompt and would freeze
 * the menu bar at the moment the user pressed Restart.
 *
 * Takes the lifecycle lock with a bounded retry, never a blocking wait, and
 * logs if it cannot get it — a concurrent start would otherwise reopen the
 * listener after this returns.
 */
void vncServerCloseListeners(void);

/*
 * Return the TCP port the server is listening on.
 *
 * <= 0 means "not serving": -1 before a run has ever started or after a stop,
 * and 0 once vncServerCloseListeners() has freed the port for a successor.
 * Callers must test for > 0, never for != -1.
 */
int vncServerGetPort(void);

/*
 * Report the configuration the RUNNING server actually applied, so the UI can
 * never claim a restriction that is not in effect (saved defaults and env
 * overrides can differ from the live server until it is restarted).
 *
 * bindAddress receives the bound IPv4 address, or an empty string when the
 * server listens on all interfaces. Returns FALSE (and writes nothing) when
 * the server is not running.
 */
rfbBool vncServerCopyActiveBindAddress(char *bindAddress, size_t size);


/*
 * TRUE when the RUNNING server's effective policy admits every IPv4 client —
 * either an explicitly confirmed allow-all, or an allowlist that contains a /0
 * entry (which matches everyone). The UI must use this rather than inferring
 * "allowlist" from the mode, or it would report a restriction that is not real.
 */
rfbBool vncServerActivePolicyAllowsEveryone(void);

#if defined(MACVNC_ENABLE_TEST_HOOKS)
#include <stdbool.h>
/* Exposes the core's own capture decision so the "no permission, no capture"
   rule can be asserted without a real TCC grant. */
bool macVNCCaptureIsAllowedForTesting(void);

/* Number of times the core actually started the capture streams. Lets a test
   assert that a refused permission produces NO start, rather than only that the
   gate returned false. */
unsigned macVNCCaptureStartCountForTesting(void);
void macVNCResetCaptureStateForTesting(void);
/* Runs the real start/stop reconciler for the current client count. */
void macVNCReconcileCaptureForTesting(void);

bool macVNCServerHasLifecycleResourcesForTesting(void);
#endif
