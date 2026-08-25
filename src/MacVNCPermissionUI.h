#import <Foundation/Foundation.h>
#import "MacVNCPermissions.h"

NS_ASSUME_NONNULL_BEGIN

/*
 * Pure presentation logic for the permission gate.
 *
 * Split out of MacVNCPermissionsPanel so it can be tested without AppKit. The
 * panel became a source of user-visible lies precisely because this logic lived
 * inside -refreshPermissions, where nothing could exercise it:
 *
 *   - a chip said "Restart required" while the hint said "All permissions
 *     granted" (two independent TCC samples in one render);
 *   - a chip said "Not granted" while capture was delivering 1162 frames;
 *   - a chip said "Not granted" for a permission the user had just enabled in
 *     System Settings.
 *
 * The last one is not a bug but a platform rule: macOS binds Screen Recording
 * AND Accessibility to a process at launch, so a process started before the
 * grant keeps reading "no" for its whole life. The wording therefore has to be
 * true for both readings — off in Settings, or on but not yet applied — and
 * "Run macVNC" (relaunch) is the answer either way.
 */

typedef struct {
    BOOL screenActive;        /* capture proven to work in THIS process */
    BOOL accessibilityActive; /* AXIsProcessTrusted() in THIS process    */
    BOOL serverRunning;       /* vncServerGetPort() > 0                  */
    /* Whether the bundle lives in /Applications. The "+" instruction says to
       pick macVNC from Applications; if it is running from Downloads or a
       mounted disk image, that instruction sends the user to the wrong copy and
       the permission they grant belongs to a different bundle path. */
    BOOL inApplicationsFolder;
} MacVNCPermissionUIInput;

/* Rendered state. One snapshot in, one description out: chips and hint can no
   longer disagree, because they are derived from the same input. */
@interface MacVNCPermissionUIState : NSObject
@property (nonatomic, copy)   NSString *screenChipTitle;
@property (nonatomic, copy)   NSString *accessibilityChipTitle;
@property (nonatomic, copy)   NSString *hint;
@property (nonatomic, copy)   NSString *buttonTitle;
@property (nonatomic, assign) BOOL      buttonEnabled;
@property (nonatomic, assign) BOOL      shouldShowPanel;
/* Whether the menu should show the permission rows at all (clipshot's banner
   returns null when nothing is missing). Owned here so the rows and the status
   line above them cannot be derived from different reasoning. */
@property (nonatomic, assign) BOOL      shouldShowPermissionRows;
/* Whether the server may be started now. The complement of shouldShowPanel is
   NOT the same question — a running server means "no panel" and also "do not
   start again" — so the resolver owns both rather than letting call sites
   re-derive one from the other. */
@property (nonatomic, assign) BOOL      shouldStartServer;
/* Pressing the button starts the server when both permissions are already
   active, and otherwise relaunches so macOS can apply what was granted. */
@property (nonatomic, assign) BOOL      buttonRelaunches;
@end

/*
 * Sample every signal ONCE and return the input for the resolver.
 *
 * The single construction site matters: the inputs used to be assembled by hand
 * in the panel and in the menu, which is how the two surfaces drifted apart
 * (and how a bare struct could be left partly uninitialised). Ask for the
 * snapshot here, render from it, and they cannot disagree.
 */
MacVNCPermissionUIInput macVNCSamplePermissionUIInput(BOOL serverRunning);

MacVNCPermissionUIState *macVNCResolvePermissionUI(MacVNCPermissionUIInput input);

NS_ASSUME_NONNULL_END
