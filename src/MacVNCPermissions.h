#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MacVNCPermissionKind) {
    MacVNCPermissionKindScreenRecording = 1,
    MacVNCPermissionKindAccessibility = 2,
};

typedef NS_ENUM(NSInteger, MacVNCPermissionStatus) {
    MacVNCPermissionStatusGranted = 1,
    MacVNCPermissionStatusNotGranted = 2,
    MacVNCPermissionStatusUnknown = 3,
};

/* Human-readable name, for the panel and the menu rows. */
NSString *macVNCPermissionDisplayName(MacVNCPermissionKind kind);

/* Non-prompting status read. See the note below on the single reader. */
MacVNCPermissionStatus macVNCCheckPermission(MacVNCPermissionKind kind);

/* TEST SEAM ONLY: replaces the Screen Recording probe for the duration of a
 * test. Production code never touches it; the default wraps
 * CGPreflightScreenCaptureAccess(), keeping exactly ONE call site. Reset to
 * NULL when done (a stale probe would lie for the whole process). */
typedef bool (*MacVNCPermissionProbeFn)(void);
extern MacVNCPermissionProbeFn macVNCPermissionScreenRecordingProbe;

/* Opens the relevant System Settings pane. Does NOT request the permission:
   only the user can grant it, via "+". */
void macVNCOpenPermissionSettings(MacVNCPermissionKind kind);

/*
 * Screen Recording has exactly ONE status reader:
 * CGPreflightScreenCaptureAccess(). It never prompts and is accurate for a
 * GUI-launched app, which is the only supported launch mode.
 *
 * There is deliberately no "capture worked at runtime" flag here. One used to
 * exist and let the gate and the UI disagree — the app reported all permissions
 * active while refusing to start. Do not reintroduce a second source of truth.
 */
/* Whether the running bundle sits in an Applications folder — the "+" flow
 * depends on it, see MacVNCPermissionUI.h. */
BOOL macVNCRunningFromApplicationsFolder(void);


NS_ASSUME_NONNULL_END
