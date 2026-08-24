#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * VNC password storage and loading.
 *
 * By request the password is stored as plaintext in NSUserDefaults (not the
 * Keychain). All values are trimmed of surrounding whitespace/newlines so a
 * pasted value with a hidden trailing newline cannot break VNC DES auth.
 * A legacy Keychain-stored password is migrated into defaults on first load.
 */

/* Load the effective password (trimmed). Migrates a legacy Keychain value into
 * defaults and removes it from the Keychain. Returns @"" when none is set. */
NSString *macVNCLoadPassword(NSUserDefaults *defaults);

/* Persist a password in plaintext defaults (trimmed) and remove any Keychain
 * copy. Pass the raw text field value; trimming is applied here. */
void macVNCStorePassword(NSUserDefaults *defaults, NSString *rawPassword);

/* Read a password from a secure file referenced by MACVNC_PASSWORD_FILE.
 * The file must be a regular file, owned by the current uid, not group/other
 * accessible, and 1..4096 bytes. Returns the trimmed password, or nil with
 * *errorMessage set. */
NSString * _Nullable macVNCReadSecurePasswordFile(NSString *path,
                                                  NSString * _Nullable * _Nullable errorMessage);

NS_ASSUME_NONNULL_END
