#import "MacVNCClamshellMarker.h"

#import <Foundation/Foundation.h>

#include <libproc.h>
#include <signal.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <rfb/rfb.h>

/* Deliberately NOT one of the user-facing keys in macVNCAllDefaultsKeys(): it
   is crash bookkeeping, it has no default, and its absence is the normal
   state. */
static NSString * const kMarkerKey     = @"clamshellArmedBy";
static NSString * const kMarkerPidKey  = @"pid";
static NSString * const kMarkerBootKey = @"boot";

static NSString *
currentBootSession(void)
{
    uuid_string_t value = {0};
    size_t size = sizeof value;
    if (sysctlbyname("kern.bootsessionuuid", value, &size, NULL, 0) != 0)
        return nil;
    return [NSString stringWithUTF8String:value];
}

static bool
processIsALiveMacVNC(pid_t pid)
{
    if (pid <= 0 || kill(pid, 0) != 0)
        return false;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof path) <= 0)
        return false;
    return strstr(path, "macVNC") != NULL;
}

MacVNCClamshellMarkerState
macVNCClamshellMarkerRead(void)
{
    MacVNCClamshellMarkerState state = { false, false, false };
    @autoreleasepool {
        NSDictionary *marker =
            [NSUserDefaults.standardUserDefaults dictionaryForKey:kMarkerKey];
        if (marker == nil)
            return state;

        state.present = true;
        NSString *boot = currentBootSession();
        state.sameBootSession =
            boot != nil && [boot isEqualToString:marker[kMarkerBootKey]];
        /* Liveness is only meaningful within our own boot: a pid from a
           previous boot names an unrelated process today. */
        state.ownerAlive =
            state.sameBootSession &&
            processIsALiveMacVNC((pid_t)[marker[kMarkerPidKey] intValue]);
    }
    return state;
}

bool
macVNCClamshellMarkerWrite(bool present)
{
    bool ok = false;
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (present) {
            NSString *boot = currentBootSession();
            if (boot == nil) {
                rfbLog("Closed-display mode: cannot identify this boot "
                       "session, so refusing to record an armed state\n");
                return false;
            }
            [defaults setObject:@{ kMarkerPidKey: @((int)getpid()),
                                   kMarkerBootKey: boot }
                         forKey:kMarkerKey];
        } else {
            [defaults removeObjectForKey:kMarkerKey];
        }

        /* Synchronous, then read back. The whole value of this record is that
           it is on disk BEFORE the kernel call and still there after a crash,
           and a wedged or read-only preferences domain must be able to say so:
           reporting a write we did not achieve is how an unrecoverable bit gets
           set. */
        [defaults synchronize];
        bool nowPresent =
            [defaults dictionaryForKey:kMarkerKey] != nil;
        ok = (nowPresent == present);
        if (!ok)
            rfbLog("Closed-display mode: could not %s its state on disk\n",
                   present ? "record" : "clear");
    }
    return ok;
}
