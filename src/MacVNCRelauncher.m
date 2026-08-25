#import "MacVNCRelauncher.h"

#import <limits.h>
#import <spawn.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>

extern char **environ;

@implementation MacVNCRelauncher

+ (BOOL)relaunchClosingListeners:(void (^)(void))closeListeners
{
    NSString *exePath = NSBundle.mainBundle.executablePath;
    if (exePath.length == 0)
        return NO;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attr, &none);
    /* Reset dispositions: a SIG_IGN inherited from us would otherwise make the
       successor ignore signals it must handle. */
    posix_spawnattr_setsigdefault(&attr, &all);
    /* CLOEXEC_DEFAULT: no descriptor leaks to the child — not the listening
       socket, not accepted client sockets, not capture machinery. */
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK |
                                    POSIX_SPAWN_SETSIGDEF |
                                    POSIX_SPAWN_CLOEXEC_DEFAULT);

    /* CLOEXEC_DEFAULT closes 0/1/2 too, so hand them back explicitly: otherwise
       the child's first socket() lands on fd 1 or 2 and a stray log write would
       go straight into a VNC client connection. */
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO,  "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    /* Copy out of the autoreleased buffer: fileSystemRepresentation returns
       pool-owned memory, and it is used after the caller's closeListeners block
       has run. Owning the bytes removes the dependency on what that block does
       with the current pool. */
    char path[PATH_MAX];
    if (![exePath getFileSystemRepresentation:path maxLength:sizeof(path)]) {
        NSLog(@"macVNC relaunch failed: executable path too long");
        return NO;
    }
    char *const argv[] = { path, NULL };

    if (closeListeners)
        closeListeners();

    pid_t child = 0;
    int rc = posix_spawn(&child, path, &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        NSLog(@"macVNC relaunch failed: %s", strerror(rc));
        return NO;
    }
    return YES;
}

@end
