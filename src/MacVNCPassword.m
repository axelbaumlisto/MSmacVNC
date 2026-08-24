#import "MacVNCPassword.h"
#import "MacVNCDefaultsKeys.h"

#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Reuse the single-source-of-truth defaults key + bundle id (no re-hardcoding).
 * The legacy Keychain account name matches the defaults key by historical design. */
#define kKeyPassword               MacVNCKeyPassword
#define kKeychainService           MacVNCBundleID
#define kKeychainPasswordAccount   MacVNCKeyPassword

static NSString *macVNCTrim(NSString *value)
{
    return [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static NSMutableDictionary *macVNCKeychainQuery(void)
{
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainPasswordAccount,
    } mutableCopy];
}

static NSString *macVNCReadKeychainPassword(void)
{
    NSMutableDictionary *query = macVNCKeychainQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    [query release];
    if (status != errSecSuccess || !result)
        return nil;

    NSData *data = [(NSData *)result autorelease];
    NSString *password = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return password.length > 0 ? password : nil;
}

static BOOL macVNCDeleteKeychainPassword(void)
{
    NSMutableDictionary *query = macVNCKeychainQuery();
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    [query release];
    return status == errSecSuccess || status == errSecItemNotFound;
}

NSString *macVNCLoadPassword(NSUserDefaults *defaults)
{
    NSString *plain = macVNCTrim([defaults stringForKey:kKeyPassword]);
    if (plain.length > 0)
        return plain;

    NSString *legacy = macVNCTrim(macVNCReadKeychainPassword());
    if (legacy.length > 0) {
        [defaults setObject:legacy forKey:kKeyPassword];
        [defaults synchronize];
        macVNCDeleteKeychainPassword();
        return legacy;
    }
    return @"";
}

void macVNCStorePassword(NSUserDefaults *defaults, NSString *rawPassword)
{
    macVNCDeleteKeychainPassword();
    [defaults setObject:macVNCTrim(rawPassword) forKey:kKeyPassword];
}

NSString *macVNCReadSecurePasswordFile(NSString *path, NSString **errorMessage)
{
    const char *fileSystemPath = path.fileSystemRepresentation;
    int fd = open(fileSystemPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        if (errorMessage)
            *errorMessage = [NSString stringWithFormat:@"Cannot open MACVNC_PASSWORD_FILE %@: %s",
                             path, strerror(errno)];
        return nil;
    }

    NSString *failure = nil;
    char *bytes = NULL;
    size_t size = 0;

    struct stat info;
    if (fstat(fd, &info) != 0)
        failure = [NSString stringWithFormat:@"Cannot inspect MACVNC_PASSWORD_FILE %@: %s",
                   path, strerror(errno)];
    else if (!S_ISREG(info.st_mode))
        failure = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ must be a regular file", path];
    else if (info.st_uid != getuid())
        failure = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ is not owned by uid %u",
                   path, getuid()];
    else if ((info.st_mode & 0077) != 0)
        failure = [NSString stringWithFormat:
                   @"MACVNC_PASSWORD_FILE %@ must not be accessible by group/others", path];
    else if (info.st_size <= 0 || info.st_size > 4096)
        failure = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ is empty or too large", path];
    if (failure)
        goto fail;

    size = (size_t)info.st_size;
    bytes = malloc(size);
    size_t received = 0;
    while (received < size) {
        ssize_t count = read(fd, bytes + received, size - received);
        if (count <= 0) break;
        received += (size_t)count;
    }
    if (received != size) {
        failure = [NSString stringWithFormat:@"Could not completely read MACVNC_PASSWORD_FILE %@", path];
        goto fail;
    }
    close(fd);

    /* Copy into the NSString (initWithBytes:) and free the buffer explicitly.
       initWithBytesNoCopy:freeWhenDone:YES does not reliably free the buffer
       when the bytes are invalid UTF-8 and the initializer returns nil. */
    {
        NSString *raw = [[[NSString alloc] initWithBytes:bytes
                                                  length:size
                                                encoding:NSUTF8StringEncoding] autorelease];
        free(bytes);
        bytes = NULL;
        NSString *password = macVNCTrim(raw);
        if (!raw || password.length == 0) {
            if (errorMessage)
                *errorMessage = [NSString stringWithFormat:@"MACVNC_PASSWORD_FILE %@ is not valid non-empty UTF-8", path];
            return nil;
        }
        return password;
    }

fail:
    if (bytes)
        free(bytes);
    if (fd >= 0)
        close(fd);
    if (errorMessage)
        *errorMessage = failure;
    return nil;
}
