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
 * `closeListeners` runs immediately before the spawn, once the call is committed:
 * the child inherits descriptors, and an open listener makes its bind() fail.
 * Doing it earlier would strand the app with no listeners if the spawn failed.
 */
+ (BOOL)relaunchClosingListeners:(void (^)(void))closeListeners;

@end

NS_ASSUME_NONNULL_END
