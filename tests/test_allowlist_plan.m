#import <Foundation/Foundation.h>

#include <assert.h>
#include <stdio.h>

#import "MacVNCAllowlistPlan.h"
#import "MacVNCListenMode.h"

/*
 * The security-relevant half of the Preferences dialog.
 *
 * This lived inside a 150-line -runModal between two NSAlerts, so none of it
 * could be exercised without opening a window - and every mistake here is
 * silent: an allowlist that admits nobody looks like a working save until the
 * server fails closed, and one that admits everyone looks fine until a stranger
 * connects.
 */

static void expectLines(NSString *combined, NSArray<NSString *> *want, const char *what)
{
    NSArray<NSString *> *got = macVNCTrimmedNonEmptyLines(combined);
    if (![got isEqualToArray:want]) {
        fprintf(stderr, "FAIL %s\n  got:  %s\n  want: %s\n",
                what, got.description.UTF8String, want.description.UTF8String);
        abort();
    }
}

int main(void)
{
    @autoreleasepool {
        /* Localhost implies exactly one client network, added automatically. */
        MacVNCAllowlistPlan *local =
            macVNCPlanAllowlist(MacVNCListenModeLocalhost, nil, @"");
        assert(local.verdict == MacVNCAllowlistVerdictOK);
        expectLines(local.combined, @[MacVNCLoopbackIPv4], "localhost preset");
        assert([local.autoAdded isEqualToArray:@[MacVNCLoopbackIPv4]]);

        /* An interface preset is added, and manual entries follow it in order. */
        MacVNCAllowlistPlan *iface =
            macVNCPlanAllowlist(MacVNCListenModeSelected, @"100.64.0.0/10",
                                @"192.168.1.5/32\n10.0.0.0/8");
        assert(iface.verdict == MacVNCAllowlistVerdictOK);
        expectLines(iface.combined,
                    (@[@"100.64.0.0/10", @"192.168.1.5/32", @"10.0.0.0/8"]),
                    "preset then manual, in order");
        /* Only the preset is recorded as auto: a later save must be able to drop
           a stale preset WITHOUT deleting anything the user typed. */
        assert([iface.autoAdded isEqualToArray:@[@"100.64.0.0/10"]]);

        /* Duplicates collapse, including a manual line equal to the preset. */
        MacVNCAllowlistPlan *dupes =
            macVNCPlanAllowlist(MacVNCListenModeSelected, @"100.64.0.0/10",
                                @"100.64.0.0/10\n  10.0.0.0/8  \n10.0.0.0/8\n\n");
        expectLines(dupes.combined, (@[@"100.64.0.0/10", @"10.0.0.0/8"]),
                    "de-duplicated, trimmed, blank lines dropped");

        /* No preset (point-to-point link) and no manual entries: the saved
           policy would admit nobody and the server would fail closed. */
        MacVNCAllowlistPlan *nobody =
            macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"   \n\n");
        assert(nobody.verdict == MacVNCAllowlistVerdictAdmitsNobody);

        /* No preset but a manual peer range is fine - that is the fix the alert
           tells the user to apply. */
        MacVNCAllowlistPlan *manualOnly =
            macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"100.101.102.103/32");
        assert(manualOnly.verdict == MacVNCAllowlistVerdictOK);
        assert(manualOnly.autoAdded.count == 0);

        /* Allow-all must be detected by PREFIX, not by matching the literal
           "0.0.0.0/0": 10.0.0.0/0 admits every IPv4 address just the same, and
           a substring check would let it through without confirmation. */
        assert(macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"0.0.0.0/0").verdict ==
               MacVNCAllowlistVerdictAdmitsEveryone);
        assert(macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"10.0.0.0/0").verdict ==
               MacVNCAllowlistVerdictAdmitsEveryone);
        assert(macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"1.2.3.4/0").verdict ==
               MacVNCAllowlistVerdictAdmitsEveryone);
        /* Hidden among ordinary entries. */
        assert(macVNCPlanAllowlist(MacVNCListenModeSelected, @"100.64.0.0/10",
                                   @"192.168.1.0/24\n172.16.0.0/0").verdict ==
               MacVNCAllowlistVerdictAdmitsEveryone);

        /* A /32 and a /8 are NOT allow-all. */
        assert(macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"10.0.0.0/8").verdict ==
               MacVNCAllowlistVerdictOK);
        assert(macVNCPlanAllowlist(MacVNCListenModeSelected, nil, @"1.2.3.4/32").verdict ==
               MacVNCAllowlistVerdictOK);

        printf("test_allowlist_plan: all assertions passed\n");
    }
    return 0;
}
