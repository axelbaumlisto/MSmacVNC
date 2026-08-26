#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCDefaultsKeys.h"
#import "MacVNCListenMode.h"

/*
 * Registered fallbacks. A key without a default reads as nil or 0, and for the
 * network keys that is not a harmless blank: an absent allowlist default would
 * mean "no entries" rather than loopback-only, and an absent listen-mode would
 * drop the localhost default that keeps a fresh install off the network.
 */
int main(void)
{
    @autoreleasepool {
        macVNCRegisterDefaults();
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

        /* Safe-by-default network posture on a fresh install. */
        assert([[defaults stringForKey:MacVNCKeyListenMode]
                   isEqualToString:MacVNCListenModeLocalhost]);
        assert([[defaults stringForKey:MacVNCKeyAllowedClients]
                   isEqualToString:MacVNCLoopbackIPv4]);
        assert([defaults boolForKey:MacVNCKeyAllowAllConfirmed] == NO);
        assert([[defaults stringForKey:MacVNCKeyListenAddress] isEqualToString:@""]);

        /* Server basics. */
        assert([defaults integerForKey:MacVNCKeyPort] == MacVNCDefaultPort);
        assert([defaults integerForKey:MacVNCKeyDisplay] == -1);
        assert([defaults boolForKey:MacVNCKeyViewOnly] == NO);

        /* Empty password is the registered default; the startup gate is what
           refuses to run without one, so this must not be a made-up value. */
        assert([[defaults stringForKey:MacVNCKeyPassword] isEqualToString:@""]);

        /* Every key the app reads must have a registered fallback.
           The list comes from macVNCAllDefaultsKeys(), not from a copy kept in
           this file: the copy had already drifted - it omitted
           MacVNCKeyAutoAllowedClients, which was the one key genuinely missing
           a default, so the completeness check could not see the bug it existed
           to catch. */
        NSDictionary *registered =
            [defaults volatileDomainForName:NSRegistrationDomain];
        NSArray<NSString *> *allKeys = macVNCAllDefaultsKeys();

        for (NSString *key in allKeys) {
            if (registered[key] == nil) {
                fprintf(stderr, "FAIL no registered default for %s\n", key.UTF8String);
                abort();
            }
        }

        /* And macVNCAllDefaultsKeys() must itself stay complete: cross-check it
           against the DECLARATIONS in the header, so adding an extern without
           adding it to the list fails here. Reading the header keeps this honest
           - deriving both sides from the same array would prove nothing. */
        NSString *header = [NSString stringWithContentsOfFile:@MACVNC_DEFAULTS_KEYS_HEADER
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
        if (header.length == 0) {
            fprintf(stderr, "FAIL cannot read the defaults-keys header\n");
            abort();
        }
        NSRegularExpression *decl = [NSRegularExpression
            regularExpressionWithPattern:@"^extern NSString \\* const (MacVNCKey\\w+);"
                                 options:NSRegularExpressionAnchorsMatchLines
                                   error:NULL];
        NSArray *matches = [decl matchesInString:header options:0
                                           range:NSMakeRange(0, header.length)];
        /* A regex that matched nothing would make the loop below vacuous. */
        if (matches.count != allKeys.count) {
            fprintf(stderr, "FAIL header declares %lu MacVNCKey* symbols but "
                            "macVNCAllDefaultsKeys() returns %lu\n",
                    (unsigned long)matches.count, (unsigned long)allKeys.count);
            abort();
        }

        printf("test_defaults: all assertions passed\n");
    }
    return 0;
}
