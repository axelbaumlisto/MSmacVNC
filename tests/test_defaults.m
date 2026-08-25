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

        /* Every declared key must have a fallback. Checked as a set so adding
           a key without a default fails here rather than in the field. */
        NSDictionary *registered =
            [defaults volatileDomainForName:NSRegistrationDomain];
        NSArray *required = @[MacVNCKeyPort, MacVNCKeyPassword, MacVNCKeyViewOnly,
                              MacVNCKeyDisplay, MacVNCKeyListenMode,
                              MacVNCKeyListenAddress, MacVNCKeyAllowedClients,
                              MacVNCKeyAllowAllConfirmed];
        for (NSString *key in required) {
            if (registered[key] == nil) {
                fprintf(stderr, "FAIL no registered default for %s\n", key.UTF8String);
                abort();
            }
        }

        printf("test_defaults: all assertions passed\n");
    }
    return 0;
}
