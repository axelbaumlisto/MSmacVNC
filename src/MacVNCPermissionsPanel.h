#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/* Result of the startup permissions panel modal. */
typedef NS_ENUM(NSInteger, MacVNCPermissionPanelAction) {
    MacVNCPermissionPanelActionQuit        = -1,
    MacVNCPermissionPanelActionNone        = 0,
    MacVNCPermissionPanelActionStart       = 1,
    MacVNCPermissionPanelActionPreferences = 2,
    MacVNCPermissionPanelActionRestart     = 3,
};

/*
 * Modal panel shown at startup when required permissions are missing.
 * Presents a clickable chip per permission (Screen Recording, Accessibility),
 * auto-refreshes their status, and returns the user's chosen action.
 */
@interface MacVNCPermissionsPanelController : NSObject

- (MacVNCPermissionPanelAction)runModal;

@end

NS_ASSUME_NONNULL_END
