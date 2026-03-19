#pragma once

#include <rfb/rfb.h>
#include <stdatomic.h>

/* -----------------------------------------------------------------------
 * Globals that AppDelegate may read or write before calling vncServerStart().
 * ----------------------------------------------------------------------- */

/* When TRUE the server accepts connections but ignores all input events. */
extern rfbBool viewOnly;

/* Index of the display to share (-1 = primary). */
extern int displayNumber;

/* -----------------------------------------------------------------------
 * Live statistics (updated atomically from LibVNCServer threads).
 * ----------------------------------------------------------------------- */

/* Number of VNC clients currently connected. */
extern _Atomic int vncConnectedClients;

/* -----------------------------------------------------------------------
 * Server lifecycle
 * ----------------------------------------------------------------------- */

/*
 * Initialise and start the VNC server.
 *
 * port     – TCP port to listen on (5900 is the VNC default).
 * password – Shared password string, or NULL to disable authentication.
 *
 * Returns TRUE on success. On failure the reason is printed via rfbLog().
 * Must not be called on the main thread because rfbInitServer() briefly
 * blocks while binding the listen socket.
 */
rfbBool vncServerStart(int port, const char *password);

/*
 * Disconnect all clients, stop the server and free all resources.
 * Safe to call from any thread.
 */
void vncServerStop(void);

/*
 * Return the TCP port the server is listening on, or -1 if not started.
 */
int vncServerGetPort(void);
