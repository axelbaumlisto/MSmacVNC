#import "MacVNCAllowlistPlan.h"

#import "MacVNCListenMode.h"
#import "NetworkAccess.h"

@interface MacVNCAllowlistPlan ()
@property (nonatomic, copy) NSString *combined;
@property (nonatomic, copy) NSArray<NSString *> *autoAdded;
@property (nonatomic, assign) MacVNCAllowlistVerdict verdict;
@end

@implementation MacVNCAllowlistPlan
- (void)dealloc
{
    [_combined release];
    [_autoAdded release];
    [super dealloc];
}
@end

NSArray<NSString *> *macVNCTrimmedNonEmptyLines(NSString *text)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                                NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0)
            [lines addObject:trimmed];
    }
    return lines;
}

MacVNCAllowlistPlan *macVNCPlanAllowlist(NSString *listenMode,
                                         NSString *autoCIDR,
                                         NSString *manualText)
{
    MacVNCAllowlistPlan *plan = [[[MacVNCAllowlistPlan alloc] init] autorelease];

    NSMutableOrderedSet<NSString *> *entries = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSString *> *autoAdded = [NSMutableArray array];

    if ([listenMode isEqualToString:MacVNCListenModeLocalhost]) {
        /* Listening on loopback implies exactly one client network. */
        [entries addObject:MacVNCLoopbackIPv4];
        [autoAdded addObject:MacVNCLoopbackIPv4];
    } else if (autoCIDR.length > 0) {
        [entries addObject:autoCIDR];
        [autoAdded addObject:autoCIDR];
    }

    for (NSString *line in macVNCTrimmedNonEmptyLines(manualText ?: @""))
        [entries addObject:line];

    NSMutableString *combined = [NSMutableString string];
    for (NSString *entry in entries)
        [combined appendFormat:@"%@\n", entry];

    plan.combined = combined;
    plan.autoAdded = autoAdded;

    if (entries.count == 0) {
        plan.verdict = MacVNCAllowlistVerdictAdmitsNobody;
        return plan;
    }

    /* ANY /0 prefix admits every IPv4 address, not just the literal
       "0.0.0.0/0" - 10.0.0.0/0 and 1.2.3.4/0 do too. Parse and ask the access
       module instead of matching substrings, which is how a disguised allow-all
       would slip through unconfirmed. */
    MacVNCNetworkAccessList probe;
    if (macVNCParseAccessList(combined.UTF8String, &probe, NULL, 0) &&
        macVNCNetworkAccessContainsAllowAll(&probe)) {
        plan.verdict = MacVNCAllowlistVerdictAdmitsEveryone;
        return plan;
    }

    plan.verdict = MacVNCAllowlistVerdictOK;
    return plan;
}
