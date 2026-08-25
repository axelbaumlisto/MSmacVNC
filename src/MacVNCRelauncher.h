#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Restarting macVNC so macOS applies a newly granted permission.
 *
 * Both Screen Recording and Accessibility are bound to a process at launch, so a
 * process that was running before the grant can never see it: relaunching is the
 * only way to pick it up.
 *
 * Extracted from AppDelegate because the mechanism is subtle and was got wrong
 * repeatedly: a /bin/sh helper that waited for the old pid and then ran
 * `open -n` could be refused by LaunchServices, could time out and leave TWO
 * instances, and inherited the listening socket so the successor's bind() failed.
 * The working shape (the same one clipshot uses) is to spawn our own executable
 * directly and exit.
 */
@interface MacVNCRelauncher : NSObject

/*
 * Spawns a fresh instance of this app's executable.
 *
 * Returns YES if a successor was started. On NO nothing was spawned and the
 * caller MUST stay alive: this is an accessory app with no Dock icon, so quitting
 * without a successor leaves the user nothing to click.
 *
 * `closeListeners` runs immediately before the spawn. It cannot be deferred:
 * the child inherits descriptors, and a listener still held here makes its
 * bind() fail.
 *
 * So the port IS already released when a spawn fails. On NO the caller must
 * therefore stop the server as well, or the app keeps advertising a port it no
 * longer serves (see -[AppDelegate scheduleRelaunchHelper]).
 */
+ (BOOL)relaunchClosingListeners:(void (^)(void))closeListeners;

@end

NS_ASSUME_NONNULL_END
