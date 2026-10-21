#import <Foundation/Foundation.h>

/* The VNC (RFB) protocol's DES-based VncAuth derives its key from the first 8
 * bytes of the password only (LibVNCServer MAXPWLEN). Anything beyond byte 8 is
 * ignored, so a "longer" password adds no entropy and rotating only the tail
 * does not change the credential. UI/config paths must surface this. */
#define MACVNC_VNC_PASSWORD_EFFECTIVE_MAX 8

NS_ASSUME_NONNULL_BEGIN

/*
 * VNC password storage and loading.
 *
 * By request the password is stored as plaintext in NSUserDefaults (not the
 * Keychain). All values are trimmed of surrounding whitespace/newlines so a
 * pasted value with a hidden trailing newline cannot break VNC DES auth.
 * NSUserDefaults is the ONLY store: there is no Keychain copy to migrate,
 * delete or keep in sync.
 */

/* Load the effective password (trimmed) from defaults. Returns @"" when none
 * is set. */
NSString *macVNCLoadPassword(NSUserDefaults *defaults);

/* Persist a password in plaintext defaults (trimmed). Pass the raw text field
 * value; trimming is applied here. */
void macVNCStorePassword(NSUserDefaults *defaults, NSString *rawPassword);

/* Read a password from a secure file referenced by MACVNC_PASSWORD_FILE.
 * The file must be a regular file, owned by the current uid, not group/other
 * accessible, and 1..4096 bytes. Returns the trimmed password, or nil with
 * *errorMessage set. */
NSString * _Nullable macVNCReadSecurePasswordFile(NSString *path,
                                                  NSString * _Nullable * _Nullable errorMessage);

NS_ASSUME_NONNULL_END
