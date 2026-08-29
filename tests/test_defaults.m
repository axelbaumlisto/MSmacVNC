#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCDefaultsKeys.h"

#include "CaptureRate.h"
#include "MacVNCEncryptionPolicy.h"
#include "MacVNCImageProfile.h"
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

        /* Performance settings: the shipped defaults are the measured best
           pair (30 FPS capture, JPEG quality 5). Pinned as VALUES, not just as
           registered keys, because changing either silently changes what every
           viewer experiences. */
        assert([defaults integerForKey:MacVNCKeyCaptureFPS] ==
               MACVNC_CAPTURE_FPS_DEFAULT);
        MacVNCImageProfile profile;
        assert(macVNCParseImageProfile(
                   [defaults stringForKey:MacVNCKeyImageProfile].UTF8String,
                   &profile));
        assert(profile.kind == MacVNCImageProfileJPEG);
        assert(profile.qualityLevel == MACVNC_IMAGE_QUALITY_DEFAULT);

        /* Encryption defaults to the COMPATIBLE choice on purpose: shipping
           "required" would lock out every viewer without VeNCrypt support on
           an upgrade, which is a worse failure than an unencrypted session on
           a trusted network. */
        MacVNCEncryptionPolicy encryption;
        assert(macVNCParseEncryptionPolicy(
                   [defaults stringForKey:MacVNCKeyEncryption].UTF8String,
                   &encryption));
        assert(encryption == MacVNCEncryptionOptional);

        /* Curtain mode is OFF on a fresh install, and that is a SAFETY value
           rather than a taste one: the curtain is raised by whoever connects
           with the VNC password, so a default of YES would let the remote
           party blind the person standing at the Mac without anybody at this
           machine having asked for it. Pinned as a VALUE for the same reason
           the performance defaults are. */
        assert([defaults boolForKey:MacVNCKeyCurtain] == NO);

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

        /* SET equality of NAMES, not just counts: counts stayed equal when a
           key was renamed in the header and its old name left in the array -
           the cross-check advertised as drift-proof passed while the renamed
           key had no default. The array holds VALUES (@"rfbPort"), so the
           comparison is textual: every declared symbol name must appear in
           macVNCAllDefaultsKeys()'s own definition inside the .m, and the .m
           must not reference any MacVNCKey* symbol the header does not declare. */
        NSMutableSet *declared = [NSMutableSet set];
        for (NSTextCheckingResult *m in matches)
            [declared addObject:[header substringWithRange:[m rangeAtIndex:1]]];

        NSString *impl = [NSString stringWithContentsOfFile:@MACVNC_DEFAULTS_KEYS_IMPL
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (impl.length == 0) {
            fprintf(stderr, "FAIL cannot read the defaults-keys implementation\n");
            abort();
        }
        NSRegularExpression *arrayDecl = [NSRegularExpression
            regularExpressionWithPattern:@"macVNCAllDefaultsKeys\\(void\\)\\s*\\{\\s*return[^;]+;"
                                 options:0 error:NULL];
        NSTextCheckingResult *arrayMatch =
            [arrayDecl firstMatchInString:impl options:0
                                    range:NSMakeRange(0, impl.length)];
        assert(arrayMatch != nil);
        NSString *arrayBody = [impl substringWithRange:arrayMatch.range];

        for (NSString *symbol in declared) {
            if ([arrayBody rangeOfString:symbol].location == NSNotFound) {
                fprintf(stderr, "FAIL %s is declared but missing from "
                                "macVNCAllDefaultsKeys()\n", symbol.UTF8String);
                abort();
            }
        }
        NSRegularExpression *usedSyms = [NSRegularExpression
            regularExpressionWithPattern:@"MacVNCKey\\w+" options:0 error:NULL];
        NSArray *used = [usedSyms matchesInString:arrayBody options:0
                                            range:NSMakeRange(0, arrayBody.length)];
        for (NSTextCheckingResult *u in used) {
            NSString *sym = [arrayBody substringWithRange:[u rangeAtIndex:0]];
            if (![declared containsObject:sym]) {
                fprintf(stderr, "FAIL %s used in the array but not declared\n",
                        sym.UTF8String);
                abort();
            }
        }

        /* The one key whose absent default was the original bug: its value is
           a contract (fresh install symmetric with a saved one), not just
           "present". */
        if (![[defaults stringForKey:MacVNCKeyAutoAllowedClients]
                isEqualToString:MacVNCLoopbackIPv4]) {
            fprintf(stderr, "FAIL autoAllowedClients default is not loopback\n");
            abort();
        }

        printf("test_defaults: all assertions passed\n");
    }
    return 0;
}
