#import <Foundation/Foundation.h>
#import <assert.h>
#import "MacVNCStatusText.h"

static void expectEqual(NSString *got, NSString *want, const char *what)
{
    if (![got isEqualToString:want]) {
        fprintf(stderr, "FAIL %s\n  got:  %s\n  want: %s\n",
                what, got.UTF8String, want.UTF8String);
        abort();
    }
}

static MacVNCStatusInput makeInput(int port, int clients, BOOL missing, BOOL all)
{
    MacVNCStatusInput in;
    in.port = port;
    in.clientCount = clients;
    in.permissionsMissing = missing;
    in.allowsEveryone = all;
    return in;
}

int main(void)
{
    @autoreleasepool {
        /* Running: the line must name the live bind address and policy, never
           the saved defaults. */
        expectEqual(macVNCStatusLine(makeInput(5903, 0, NO, NO), @"100.70.214.41"),
                    @"Running  •  100.70.214.41:5903  •  allowlist",
                    "running, restricted");
        expectEqual(macVNCStatusLine(makeInput(5903, 0, NO, YES), @"0.0.0.0"),
                    @"Running  •  0.0.0.0:5903  •  allow all",
                    "running, allow all");
        /* No bind address known — must not print an empty host. */
        expectEqual(macVNCStatusLine(makeInput(5903, 0, NO, NO), nil),
                    @"Running  •  all interfaces:5903  •  allowlist",
                    "running, unknown bind");

        /* Stopped, and the reason must come from the permission resolver rather
           than a second sample of TCC. */
        expectEqual(macVNCStatusLine(makeInput(0, 0, YES, NO), nil),
                    @"Not running  •  permissions required", "stopped, missing");
        expectEqual(macVNCStatusLine(makeInput(0, 0, NO, NO), nil),
                    @"Not running", "stopped, granted");

        /* Regression: closing the listeners zeroes the port but not the client
           counter, which printed "Not running" above "1 client connected". */
        expectEqual(macVNCClientsLine(makeInput(0, 1, NO, NO)),
                    @"No clients connected", "stopped server reports no clients");
        expectEqual(macVNCClientsLine(makeInput(0, 7, NO, NO)),
                    @"No clients connected", "stopped server ignores the counter");

        expectEqual(macVNCClientsLine(makeInput(5903, 0, NO, NO)),
                    @"No clients connected", "running, none");
        expectEqual(macVNCClientsLine(makeInput(5903, 1, NO, NO)),
                    @"1 client connected", "running, singular");
        expectEqual(macVNCClientsLine(makeInput(5903, 3, NO, NO)),
                    @"3 clients connected", "running, plural");

        printf("test_status_text: all assertions passed\n");
    }
    return 0;
}
