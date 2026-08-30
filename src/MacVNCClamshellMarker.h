#pragma once

#include <stdbool.h>

/*
 * The record of "macVNC set the machine-wide clamshell bit", and WHO set it.
 *
 * Split out of the adapter because it is the one part with its own reason to
 * change: where the record lives, what identifies its owner, and how liveness
 * is decided. The adapter next door is about talking to the kernel and to the
 * run loop, and mixing the two made a file that had to be read whole before any
 * of it could be trusted.
 *
 * A bare boolean here was a genuine defect. The bit is machine-wide, shared
 * with powerd and with apps like Amphetamine, and carries no reference count,
 * so an anonymous marker turned every launch into a licence to clear whatever
 * the kernel happened to hold - including another app's setting after a reboot,
 * or a second macVNC instance's, since instances share a bundle id and
 * therefore a defaults domain. Hence pid + boot session.
 */

typedef struct {
    bool present;
    /* Written during the boot we are in now. The kernel zeroes the mask at
       boot, so a record from an earlier boot describes a bit that is already
       gone and must never be "cleared". */
    bool sameBootSession;
    /* The process that wrote it is still running, and is still a macVNC. The
       name check is not paranoia: pids are reused, and an unrelated process
       inheriting the pid would otherwise look like a live owner forever. */
    bool ownerAlive;
} MacVNCClamshellMarkerState;

MacVNCClamshellMarkerState macVNCClamshellMarkerRead(void);

/*
 * Writes or removes the record, and reports whether the change actually
 * persisted. That answer is load-bearing rather than informational: a bit we
 * could not record is a bit no later run can recover, so the caller refuses to
 * arm on false.
 */
bool macVNCClamshellMarkerWrite(bool present);
