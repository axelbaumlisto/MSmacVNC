#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * "Start at Login" management. Uses SMAppService on macOS 13+, falling back to
 * a per-user LaunchAgent plist on macOS 12.x. Pure model object: no UI.
 */
@interface MacVNCLoginItem : NSObject

/* YES if macVNC is currently registered to start at login. */
+ (BOOL)isEnabled;

/* Enable or disable start-at-login. Errors are logged, not thrown. */
+ (void)setEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
