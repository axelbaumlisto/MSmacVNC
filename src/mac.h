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

/* Optional handler invoked (on the main queue) when ScreenCaptureKit fails at
 * runtime, e.g. Screen Recording permission is not effectively granted. The
 * server does not show any UI itself; AppDelegate owns the permission popup. */
/* likelyPermissionDenial is TRUE only when the underlying error is consistent
 * with a TCC/Screen-Recording denial. Other capture failures (display removed,
 * stream stopped for unrelated reasons) pass FALSE so the caller does not latch
 * a permanent "permission missing" state on a transient/topology error. */
extern void (*macVNCScreenCaptureFailureHandler)(bool likelyPermissionDenial,
                                                 uint64_t serverGeneration);

/*
 * Invoked once per server run, from the capture queue, when the first frame is
 * actually delivered. Informational only — permission STATUS is read from
 * CGPreflightScreenCaptureAccess(), which is accurate for a GUI-launched app and
 * never prompts. (Earlier readings suggesting otherwise were taken from
 * shell-launched runs, where TCC attributes the request to the terminal.)
 */
extern void (*macVNCScreenCaptureWorkingHandler)(void);

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
 * Monotonic id of the current server run, incremented by every vncServerStart().
 * A capture-failure notification carries the generation it was raised for, so a
 * notification queued by an already-stopped run (e.g. delivered after a modal
 * finishes) can be discarded instead of killing a freshly started server.
 */
uint64_t vncServerCurrentGeneration(void);

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

/*
 * Initialise and start the VNC server from an immutable configuration.
 * config->password must be non-empty (authentication is mandatory); a NULL
 * or empty password makes this fail.
 *
 * Returns TRUE on success. On failure the reason is printed via rfbLog().
 * Must not be called on the main thread because rfbInitServer() briefly
 * blocks while binding the listen socket.
 */
rfbBool vncServerStart(const MacVNCServerConfig *config);

/*
 * Disconnect all clients, stop the server and free all resources.
 * Safe to call from any thread.
 */
void vncServerStop(void);

/*
 * Close the listening sockets (IPv4 and IPv6) and nothing else.
 *
 * For the relaunch path: the new process inherits our descriptors, and a still
 * open listener makes its bind() fail. Cheap and non-blocking, unlike
 * vncServerStop(), which joins client threads and waits on capture work.
 */
void vncServerCloseListeners(void);

/*
 * Return the TCP port the server is listening on, or -1 if not started.
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

/* Client access mode of the RUNNING server. Only valid when the server runs. */
MacVNCClientAccessMode vncServerActiveAccessMode(void);

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

bool macVNCServerHasLifecycleResourcesForTesting(void);
#endif
