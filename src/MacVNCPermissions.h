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

extern NSString * const MacVNCPermissionSnapshotKindKey;
extern NSString * const MacVNCPermissionSnapshotNameKey;
extern NSString * const MacVNCPermissionSnapshotDescriptionKey;
extern NSString * const MacVNCPermissionSnapshotStatusKey;
extern NSString * const MacVNCPermissionSnapshotSettingsURLKey;

NSArray<NSNumber *> *macVNCRequiredPermissionKinds(void);
NSString *macVNCPermissionDisplayName(MacVNCPermissionKind kind);
NSString *macVNCPermissionDescription(MacVNCPermissionKind kind);
NSString *macVNCPermissionSettingsURL(MacVNCPermissionKind kind);
NSString *macVNCPermissionStatusText(MacVNCPermissionStatus status);

MacVNCPermissionStatus macVNCCheckPermission(MacVNCPermissionKind kind);
NSDictionary<NSString *, id> *macVNCPermissionSnapshot(MacVNCPermissionKind kind,
                                                       MacVNCPermissionStatus status);
NSArray<NSDictionary<NSString *, id> *> *macVNCPermissionSnapshots(void);
NSArray<NSDictionary<NSString *, id> *> *macVNCMissingPermissionsFromSnapshots(NSArray<NSDictionary<NSString *, id> *> *snapshots);
NSArray<NSDictionary<NSString *, id> *> *macVNCMissingPermissions(void);
BOOL macVNCPermissionsAllGrantedFromSnapshots(NSArray<NSDictionary<NSString *, id> *> *snapshots);
BOOL macVNCPermissionsAllGranted(void);

void macVNCOpenPermissionSettings(MacVNCPermissionKind kind);

/*
 * Screen Recording has exactly ONE status reader:
 * CGPreflightScreenCaptureAccess(). It never prompts and is accurate for a
 * GUI-launched app, which is the only supported launch mode. These hooks are
 * informational; a second source of truth previously let the gate and the UI
 * disagree, so do not reintroduce one.
 */
/* Whether the running bundle sits in an Applications folder — the "+" flow
 * depends on it, see MacVNCPermissionUI.h. */
BOOL macVNCRunningFromApplicationsFolder(void);

void macVNCNoteScreenCaptureWorking(void);
BOOL macVNCScreenCaptureWorking(void);


NS_ASSUME_NONNULL_END
