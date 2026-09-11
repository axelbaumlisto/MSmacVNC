#pragma once

#include <stdbool.h>
#include <stddef.h>

/*
 * A log line that never reaches disk. macVNC's stderr is /dev/null when the
 * app is launched from Finder - the normal way - because LibVNCServer logs
 * through two bare function pointers, rfbLog and rfbErr, that default to
 * "print to stderr" and nothing else. During a 42-hour capture outage this
 * plan's earlier steps were written to catch, not one line of the 29744
 * bytes of rfbLog output the server produced was ever readable: it had gone
 * into that void along with everything else. This file exists so a future
 * outage leaves something to read.
 *
 * Split the way every other module here is: the one decision that can be
 * gotten wrong - when to rotate - is pure C with no filesystem in it, right
 * below, tested in isolation in tests/test_log_sink.c. Opening the file,
 * building its path and holding the mutex is Objective-C glue in
 * MacVNCLogSink.m, kept thin enough to trust by reading it once.
 */

/*
 * One rotated generation, sized for a server that can run for weeks. It logs
 * one line per event - client connect/disconnect, capture start/stop,
 * keep-warm, a liveness re-arm - so even a busy week is a few thousand lines,
 * each well under 200 bytes. 5 MiB holds many such weeks; live file plus one
 * ".1" generation is 10 MiB at most, small enough to still open instantly in
 * a text editor when someone finally reads it after an outage, which is the
 * entire point of keeping it at all.
 */
extern const size_t kMacVNCLogSinkCapBytes;

extern const char *const kMacVNCLogSinkFileName;        /* "macvnc.log"   */
extern const char *const kMacVNCLogSinkRotatedFileName; /* "macvnc.log.1" */

/*
 * Should the file be rotated BEFORE writing a line of `pendingLineLength`
 * bytes, given the live file is already `currentFileSize` bytes?
 *
 * `currentFileSize == 0` never rotates, even when the single pending line
 * alone would exceed the cap: rotating an already-empty file discards
 * nothing and gains nothing, and without this guard a run that ever logs one
 * line bigger than the cap - a large display list is a format string away
 * from doing that - would rotate again on every following line forever.
 */
bool macVNCLogSinkShouldRotate(size_t currentFileSize, size_t pendingLineLength);

/*
 * Installs this sink as LibVNCServer's rfbLog and rfbErr and returns. Call
 * once, before the server can start - mac.m's ScreenInit is the first place
 * a client thread can reach rfbLog. There is no matching uninstall: see
 * MacVNCLogSink.m for why that is the deliberate choice, not an omission.
 *
 * A failure to open the log file (no HOME, read-only volume, full disk) is
 * silent and leaves logging on stderr only - exactly the visibility the
 * server shipped with before this file existed, never worse, and never
 * something that stops the server or blocks the caller.
 */
void macVNCLogSinkInstall(void);
