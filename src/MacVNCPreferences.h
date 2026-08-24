#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Preferences modal (port, password, listen interface, client allowlist).
 * Reads and writes NSUserDefaults. Changes take effect on next server start.
 */
@interface MacVNCPreferencesController : NSObject

- (void)runModal;

@end

NS_ASSUME_NONNULL_END
