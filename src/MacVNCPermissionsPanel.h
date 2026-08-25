#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/* Result of the startup permissions panel. */
typedef NS_ENUM(NSInteger, MacVNCPermissionPanelAction) {
    MacVNCPermissionPanelActionQuit        = -1,
    MacVNCPermissionPanelActionNone        = 0,
    MacVNCPermissionPanelActionStart       = 1,
    MacVNCPermissionPanelActionPreferences = 2,
    MacVNCPermissionPanelActionRestart     = 3,
};

/*
 * Panel shown when required permissions are missing. Presents a clickable chip
 * per permission (Screen Recording, Accessibility), auto-refreshes their status,
 * and reports the user's chosen action.
 *
 * NON-MODAL on purpose. As a modal it ran runModalForWindow:, which blocks the
 * run loop: -terminate: issued right after -stopModal was dropped (so the
 * relaunch button did nothing), Apple Events — including "quit" — were never
 * delivered while it was open, and the panel could end up stacked underneath
 * macOS's own alerts. clipshot, which works, uses a plain non-blocking banner.
 */
@interface MacVNCPermissionsPanelController : NSObject

/* Shows the window and returns immediately. `completion` runs on the main queue
 * once the user picks an action; the controller keeps itself alive until then. */
- (void)presentWithCompletion:(void (^)(MacVNCPermissionPanelAction action))completion;

/* Re-front an already-presented panel. Without this the window can end up
 * buried behind other apps with no way back: an accessory app has no Dock icon
 * to click, and the gate refuses to present a second one. */
- (void)bringToFront;

@end

NS_ASSUME_NONNULL_END
