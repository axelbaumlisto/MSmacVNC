#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Single source of truth for NSUserDefaults keys and app identifiers. */
extern NSString * const MacVNCKeyPort;
extern NSString * const MacVNCKeyPassword;
extern NSString * const MacVNCKeyViewOnly;
extern NSString * const MacVNCKeyDisplay;
extern NSString * const MacVNCKeyListenMode;
extern NSString * const MacVNCKeyListenAddress;
extern NSString * const MacVNCKeyAllowedClients;
extern NSString * const MacVNCKeyAllowAllConfirmed;
/* CIDRs that Preferences added automatically for the selected interface. Kept
 * separately so a later save can drop stale ones instead of mistaking them for
 * user-typed entries (which would accumulate every network ever joined). */
extern NSString * const MacVNCKeyAutoAllowedClients;
/* Frames captured per display, per second. Server-wide by construction: one
 * ScreenCaptureKit stream per display is shared by every viewer. */
extern NSString * const MacVNCKeyCaptureFPS;
/* How pixels are encoded: "viewer", "lossless", or a quality level "0".."7".
 * See MacVNCImageProfile.h for the measurements behind the ladder. */
extern NSString * const MacVNCKeyImageProfile;
/* "optional" or "required": whether a viewer may connect without TLS.
 * See MacVNCEncryptionPolicy.h for why refusing is the only reliable lever. */
extern NSString * const MacVNCKeyEncryption;
/* Curtain mode: while a viewer is connected, hide this Mac's screen and
 * swallow local keyboard and pointer input until the VNC password is typed
 * locally. OFF by default, and that default is a safety decision rather than a
 * taste one: the curtain is raised by whoever holds the VNC password, so
 * shipping it on would let the REMOTE party blind the person standing at the
 * Mac without anyone here having asked for it. It never locks the Mac.
 * See MacVNCCurtainController.h for when it goes up and every way it comes
 * back down. */
extern NSString * const MacVNCKeyCurtain;

extern NSString * const MacVNCBundleID;

extern const int MacVNCDefaultPort;

/*
 * Registers the fallback value for every key above.
 *
 * Lives with the key declarations so adding a key and forgetting its default
 * is one edit away from being noticed: a missing default reads as nil/0, which
 * for MacVNCKeyAllowedClients would mean an empty allowlist rather than
 * loopback-only.
 */
void macVNCRegisterDefaults(void);

/*
 * Every key the app reads, as a set.
 *
 * Exposed so a completeness check does not have to restate the list: a
 * hand-kept copy in the test had already drifted, omitting the one key that
 * actually lacked a registered default - so the check could not see the very
 * bug it existed to catch.
 */
NSArray<NSString *> *macVNCAllDefaultsKeys(void);

NS_ASSUME_NONNULL_END
