#import "MacVNCStartupConfig.h"

#include "CaptureRate.h"
#include "MacVNCImageProfile.h"
#import "MacVNCDefaultsKeys.h"

#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* Build an isolated defaults suite so the test never touches the real app. */
static NSUserDefaults *makeDefaults(NSString *suite, NSDictionary *values)
{
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [d removePersistentDomainForName:suite];
    for (NSString *k in values)
        [d setObject:values[k] forKey:k];
    return d;
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    /* 1. Valid localhost config from defaults, no env overrides. */
    NSUserDefaults *d1 = makeDefaults(@"macvnc.test.startup1", @{
        MacVNCKeyPort:          @5910,
        MacVNCKeyPassword:      @"secret12",
        MacVNCKeyListenMode:    @"localhost",
        MacVNCKeyListenAddress: @"",
        MacVNCKeyAllowedClients:@"127.0.0.1",
        MacVNCKeyViewOnly:      @NO,
        MacVNCKeyDisplay:       @(-2),
    });
    MacVNCStartupConfig *c1 = [MacVNCStartupConfig configWithDefaults:d1 environment:@{}];
    assert(c1.error == nil);
    MacVNCServerConfig sc1;
    assert([c1 fillServerConfig:&sc1]);
    assert(sc1.port == 5910);
    assert(sc1.displayNumber == -2);
    assert(sc1.viewOnly == 0);
    assert(strcmp(sc1.password, "secret12") == 0);
    assert(strcmp(sc1.listenAddress, "127.0.0.1") == 0);
    assert(sc1.clientAccessMode == MACVNC_CLIENT_ACCESS_ALLOW_LIST);

    /* 2. Environment overrides win (port, display, listen). */
    MacVNCStartupConfig *c2 = [MacVNCStartupConfig configWithDefaults:d1 environment:@{
        @"MACVNC_PORT": @"5999",
        @"MACVNC_DISPLAY": @"-1",
        @"MACVNC_LISTEN": @"127.0.0.1",
        @"MACVNC_ALLOWED_CLIENTS": @"127.0.0.1",
    }];
    assert(c2.error == nil);
    MacVNCServerConfig sc2;
    assert([c2 fillServerConfig:&sc2]);
    assert(sc2.port == 5999);
    assert(sc2.displayNumber == -1);
    assert(c2.usedEnvironmentOverride == YES);

    /* 2b. Out-of-range port from defaults is a configuration error, NOT a
           silent 5900 fallback: an operator who set a port must never get a
           different listener than they asked for. */
    NSUserDefaults *d1b = makeDefaults(@"macvnc.test.startup2", @{
        MacVNCKeyPort:          @70000,
        MacVNCKeyPassword:      @"secret12",
        MacVNCKeyListenMode:    @"localhost",
        MacVNCKeyListenAddress: @"",
        MacVNCKeyAllowedClients:@"127.0.0.1",
        MacVNCKeyViewOnly:      @NO,
        MacVNCKeyDisplay:       @(-2),
    });
    MacVNCStartupConfig *c2b = [MacVNCStartupConfig configWithDefaults:d1b environment:@{}];
    assert(c2b.error != nil);

    /* 2c. A malformed MACVNC_PORT is an error too (it used to parse as 0 and
           silently mean "no override"). */
    MacVNCStartupConfig *c2c = [MacVNCStartupConfig configWithDefaults:d1 environment:@{
        @"MACVNC_PORT": @"abc",
    }];
    assert(c2c.error != nil);

    /* 3. Invalid capture FPS => error, cannot fill. */
    MacVNCStartupConfig *c3 = [MacVNCStartupConfig configWithDefaults:d1 environment:@{
        @"MACVNC_CAPTURE_FPS": @"999",
    }];
    assert(c3.error != nil);
    MacVNCServerConfig sc3;
    assert(![c3 fillServerConfig:&sc3]);

    /* 3b. A STORED capture rate is a different source with a different
           contract: a hand-edited value must not make the Mac unreachable, so
           it falls back to the default and the server still starts. */
    NSUserDefaults *d3b = makeDefaults(@"macvnc.test.startup3b", @{
        MacVNCKeyPort:          @5911,
        MacVNCKeyPassword:      @"secret",
        MacVNCKeyListenMode:    @"localhost",
        MacVNCKeyAllowedClients: @"127.0.0.1/32",
        MacVNCKeyCaptureFPS:    @999,
        MacVNCKeyImageProfile:  @"nonsense",
    });
    MacVNCStartupConfig *c3b = [MacVNCStartupConfig configWithDefaults:d3b
                                                          environment:@{}];
    assert(c3b.error == nil);
    MacVNCServerConfig sc3b;
    assert([c3b fillServerConfig:&sc3b]);
    assert(sc3b.captureFramesPerSecond == MACVNC_CAPTURE_FPS_DEFAULT);
    assert(sc3b.imageProfile.kind == MacVNCImageProfileJPEG);
    assert(sc3b.imageProfile.qualityLevel == MACVNC_IMAGE_QUALITY_DEFAULT);

    /* 3c. A VALID stored pair is honoured. */
    NSUserDefaults *d3c = makeDefaults(@"macvnc.test.startup3c", @{
        MacVNCKeyPort:          @5912,
        MacVNCKeyPassword:      @"secret",
        MacVNCKeyListenMode:    @"localhost",
        MacVNCKeyAllowedClients: @"127.0.0.1/32",
        MacVNCKeyCaptureFPS:    @20,
        MacVNCKeyImageProfile:  @"lossless",
    });
    MacVNCServerConfig sc3c;
    MacVNCStartupConfig *c3c = [MacVNCStartupConfig configWithDefaults:d3c
                                                          environment:@{}];
    assert([c3c fillServerConfig:&sc3c]);
    assert(sc3c.captureFramesPerSecond == 20);
    assert(sc3c.imageProfile.kind == MacVNCImageProfileLossless);

    /* 3d. The environment beats the stored setting - it is the debugging seam. */
    MacVNCServerConfig sc3d;
    MacVNCStartupConfig *c3d = [MacVNCStartupConfig configWithDefaults:d3c
                                                          environment:@{
        @"MACVNC_CAPTURE_FPS": @"45",
        @"MACVNC_IMAGE_PROFILE": @"2",
    }];
    assert([c3d fillServerConfig:&sc3d]);
    assert(sc3d.captureFramesPerSecond == 45);
    assert(sc3d.imageProfile.kind == MacVNCImageProfileJPEG);
    assert(sc3d.imageProfile.qualityLevel == 2);

    /* 3e. An invalid environment profile is an ERROR, unlike a stored one. */
    MacVNCStartupConfig *c3e = [MacVNCStartupConfig configWithDefaults:d3c
                                                          environment:@{
        @"MACVNC_IMAGE_PROFILE": @"9",
    }];
    assert(c3e.error != nil);

    /* 4. Invalid network policy (bad custom address) => error. */
    NSUserDefaults *d4 = makeDefaults(@"macvnc.test.startup4", @{
        MacVNCKeyPort:          @5910,
        MacVNCKeyPassword:      @"secret12",
        MacVNCKeyListenMode:    @"custom",
        MacVNCKeyListenAddress: @"not-an-ip",
        MacVNCKeyAllowedClients:@"127.0.0.1",
    });
    MacVNCStartupConfig *c4 = [MacVNCStartupConfig configWithDefaults:d4 environment:@{}];
    assert(c4.error != nil);

    /* 5. Empty/unset password => explicit error (mandatory auth). */
    NSUserDefaults *d5 = makeDefaults(@"macvnc.test.startup5", @{
        MacVNCKeyPort:          @5910,
        MacVNCKeyPassword:      @"",
        MacVNCKeyListenMode:    @"localhost",
        MacVNCKeyAllowedClients:@"127.0.0.1",
    });
    MacVNCStartupConfig *c5 = [MacVNCStartupConfig configWithDefaults:d5 environment:@{}];
    assert(c5.error != nil);
    MacVNCServerConfig sc5;
    assert(![c5 fillServerConfig:&sc5]);

    [d1 removePersistentDomainForName:@"macvnc.test.startup1"];
    [d4 removePersistentDomainForName:@"macvnc.test.startup4"];
    [d5 removePersistentDomainForName:@"macvnc.test.startup5"];
    [d1 release];
    [d4 release];
    [d5 release];

    puts("startup config tests passed");
    [pool drain];
    return 0;
}
