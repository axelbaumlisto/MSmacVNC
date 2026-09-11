#import "MacVNCLogSink.h"

#import <Foundation/Foundation.h>

#include <pthread.h>
#include <rfb/rfb.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

/*
 * Glue only: the decision that can be gotten wrong - when to rotate - lives
 * in MacVNCLogSink.c and knows nothing about any of this. This file's whole
 * job is opening one file, building its path, and never letting two threads
 * write half a line each.
 *
 * Thread-safety, stated rather than assumed:
 *   - GUARANTEED: every call into macVNCLogSinkEmit (i.e. every rfbLog/rfbErr
 *     call anywhere in the process) is fully serialised by gLogSinkMutex -
 *     one thread's stamp+message reaches stderr and the file as one
 *     contiguous unit before the next thread's does, and the rotate decision
 *     always sees a size consistent with every write counted so far.
 *   - NOT GUARANTEED: async-signal-safety. This takes a pthread mutex and
 *     calls fopen/fputs/vsnprintf, none of which are safe to call from a
 *     POSIX signal handler - macVNCLogSinkLog/Err must only ever be reached
 *     from ordinary threads, which is the only way rfbLog/rfbErr are used
 *     anywhere in this codebase today.
 *   - NOT GUARANTEED: ordering against anything that writes to stderr
 *     WITHOUT going through rfbLog/rfbErr. Nothing in this project does, but
 *     a third-party library linked in later could still interleave with a
 *     line from here at the libc buffering layer.
 */

static pthread_mutex_t gLogSinkMutex = PTHREAD_MUTEX_INITIALIZER;
static FILE *gLogSinkFile = NULL;   /* NULL until installed, or on open failure */
static size_t gLogSinkFileSize = 0; /* tracked here so a write never needs an fstat() */

/* Retained once at install time and never released - see the "Never torn
   down" note at the end of macVNCLogSinkInstall for why that is deliberate,
   not an oversight. */
static NSString *gLogSinkDirectory = nil;

static NSString *
macVNCLogSinkDirectoryPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/macVNC"];
}

/* Called with gLogSinkMutex already held. Moves the live file to the ".1"
   name - replacing whatever ".1" already held, which IS the "exactly one
   rotated generation" contract - then opens a fresh file at the primary
   name, still inside the same critical section. No other thread can ever
   observe gLogSinkFile in a closed-but-not-yet-reopened state. */
static void
macVNCLogSinkRotateLocked(void)
{
    if (gLogSinkFile) {
        fclose(gLogSinkFile);
        gLogSinkFile = NULL;
    }
    NSString *path = [gLogSinkDirectory stringByAppendingPathComponent:
                       [NSString stringWithUTF8String:kMacVNCLogSinkFileName]];
    NSString *rotatedPath = [gLogSinkDirectory stringByAppendingPathComponent:
                       [NSString stringWithUTF8String:kMacVNCLogSinkRotatedFileName]];
    /* A failed rename (e.g. the directory vanished under us) just leaves the
       old file where it was; the fopen below either recovers it in place or
       leaves gLogSinkFile NULL, which callers already treat as "file
       logging unavailable this line" - never a reason to stop the server. */
    rename(path.fileSystemRepresentation, rotatedPath.fileSystemRepresentation);
    gLogSinkFile = fopen(path.fileSystemRepresentation, "a");
    gLogSinkFileSize = 0;
}

/*
 * The one function both rfbLog and rfbErr become. LibVNCServer's own default
 * logger backs both symbols with the same implementation too - the
 * distinction between "log" and "err" lives in what a caller puts in its
 * format string ("Could not listen on port %d..."), not in how a line is
 * stamped or where it is sent.
 */
static void
macVNCLogSinkEmit(const char *format, va_list args)
{
    char stamp[32];
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    /* Matches LibVNCServer's own default stamp shape byte for byte (measured
       from this app's pre-existing logs, e.g.
       "07/08/2026 17:50:35 Listening for VNC connections on TCP port 5903"),
       so installing this sink changes WHERE lines go, never their shape -
       and every caller's format string may go on assuming its message is
       the whole line after one prefix, never stamped twice. */
    strftime(stamp, sizeof stamp, "%d/%m/%Y %H:%M:%S ", &local);

    char message[4096];
    vsnprintf(message, sizeof message, format, args);
    /* Every rfbLog/rfbErr call site in this project already ends its format
       string in "\n" - the sink adds a prefix, it does not also manage line
       endings. */

    size_t lineLength = strlen(stamp) + strlen(message);

    pthread_mutex_lock(&gLogSinkMutex);

    /* stderr first and unconditionally: this is what the server has always
       done, the README documents running it from a terminal, and a full
       disk or a missing HOME below must not take away the one sink that
       never depended on either. */
    fputs(stamp, stderr);
    fputs(message, stderr);
    fflush(stderr);

    if (gLogSinkFile) {
        if (macVNCLogSinkShouldRotate(gLogSinkFileSize, lineLength))
            macVNCLogSinkRotateLocked();
        if (gLogSinkFile) {
            fputs(stamp, gLogSinkFile);
            fputs(message, gLogSinkFile);
            fflush(gLogSinkFile);
            gLogSinkFileSize += lineLength;
        }
    }

    pthread_mutex_unlock(&gLogSinkMutex);
}

static void
macVNCLogSinkLog(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    macVNCLogSinkEmit(format, args);
    va_end(args);
}

static void
macVNCLogSinkErr(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    macVNCLogSinkEmit(format, args);
    va_end(args);
}

void
macVNCLogSinkInstall(void)
{
    @autoreleasepool {
        gLogSinkDirectory = [macVNCLogSinkDirectoryPath() retain];

        NSError *error = nil;
        BOOL ready = [[NSFileManager defaultManager]
            createDirectoryAtPath:gLogSinkDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];
        if (ready) {
            NSString *path = [gLogSinkDirectory stringByAppendingPathComponent:
                               [NSString stringWithUTF8String:kMacVNCLogSinkFileName]];
            pthread_mutex_lock(&gLogSinkMutex);
            gLogSinkFile = fopen(path.fileSystemRepresentation, "a");
            if (gLogSinkFile) {
                struct stat info;
                if (fstat(fileno(gLogSinkFile), &info) == 0)
                    gLogSinkFileSize = (size_t)info.st_size;
            }
            pthread_mutex_unlock(&gLogSinkMutex);
        }
        /* ready == NO, or fopen failing anyway (permissions, full disk): NOT
           an error path. gLogSinkFile stays NULL, macVNCLogSinkEmit already
           treats that as "stderr only" for that line, and nothing here may
           raise a UI or refuse to start the server over where its own log
           file happens to end up. */
    }

    /*
     * Never uninstalled. gLogSinkFile is only ever closed from inside
     * macVNCLogSinkRotateLocked, which reopens it before releasing the
     * mutex, so no thread can ever observe a closed descriptor. rfbLog and
     * rfbErr themselves have no uninstall API either - they are two
     * process-lifetime globals, and the only correct lifetime for what
     * backs them is the same one.
     *
     * An explicit teardown would have to run during
     * -applicationWillTerminate:, racing every other thread that can still
     * call rfbLog while the app quits - a client thread, a capture callback,
     * the keep-warm timer on gCaptureStopQueue - for the very mutex that
     * guards this file. That is the shutdown deadlock class this design
     * exists to avoid, not one to reintroduce on purpose for symmetry.
     * Letting process exit reclaim the descriptor costs nothing observable:
     * the last fflush already ran inside macVNCLogSinkEmit.
     */
    rfbLog = macVNCLogSinkLog;
    rfbErr = macVNCLogSinkErr;
}
