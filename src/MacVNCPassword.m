#import "MacVNCPassword.h"
#import "MacVNCDefaultsKeys.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Reuse the single-source-of-truth defaults key (no re-hardcoding).
 *
 * The password has exactly ONE owner: NSUserDefaults. Older builds kept a copy
 * in the Keychain; that store is gone, and so is the migration that read it —
 * a second copy would mean two places to keep in sync and an ACL prompt from a
 * re-signed binary. Anyone upgrading from such a build keeps the defaults value
 * written by their last Preferences save. */
#define kKeyPassword               MacVNCKeyPassword

static NSString *macVNCTrim(NSString *value)
{
    return [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

NSString *macVNCLoadPassword(NSUserDefaults *defaults)
{
    return macVNCTrim([defaults stringForKey:kKeyPassword]);
}

void macVNCStorePassword(NSUserDefaults *defaults, NSString *rawPassword)
{
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
