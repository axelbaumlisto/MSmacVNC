#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Turning a Preferences selection into the allowlist that will be saved.
 *
 * This is the security-relevant half of the Preferences dialog, and it used to
 * live inside a 150-line -runModal between two NSAlerts, so none of it could be
 * exercised without opening a window: not the de-duplication, not the refusal of
 * a policy that admits nobody, and not the detection of an entry that admits
 * everyone. Those are exactly the parts where a mistake is silent and unsafe.
 */

typedef NS_ENUM(NSInteger, MacVNCAllowlistVerdict) {
    /* Usable as-is. */
    MacVNCAllowlistVerdictOK = 1,
    /* Nothing would be admitted: the chosen interface implies no client network
       (a point-to-point VPN link, whose "CIDR" is the host's own /32) and no
       manual entries were given. Saving this would fail closed at startup. */
    MacVNCAllowlistVerdictAdmitsNobody,
    /* Some entry has a /0 prefix, so every reachable IPv4 client is admitted.
       Not an error - it needs explicit confirmation. */
    MacVNCAllowlistVerdictAdmitsEveryone,
};

@interface MacVNCAllowlistPlan : NSObject
/* One entry per line, in order, de-duplicated. */
@property (nonatomic, copy, readonly) NSString *combined;
/* The entries this module added on the user's behalf. Persisted separately so a
   later save can drop a stale auto entry without deleting user-typed ones. */
@property (nonatomic, copy, readonly) NSArray<NSString *> *autoAdded;
@property (nonatomic, assign, readonly) MacVNCAllowlistVerdict verdict;
@end

/*
 * Builds the plan.
 *
 * `autoCIDR` is the preset implied by the chosen interface, or nil when it
 * implies none. `manualText` is the free-text advanced field; blank lines and
 * surrounding whitespace are ignored.
 *
 * Auto entries come first and manual ones keep their order, because the saved
 * string is what the user sees on the next open.
 */
/* Split newline-separated text into trimmed, non-empty lines. */
NSArray<NSString *> *macVNCTrimmedNonEmptyLines(NSString *text);

MacVNCAllowlistPlan *macVNCPlanAllowlist(NSString *listenMode,
                                         NSString *_Nullable autoCIDR,
                                         NSString *_Nullable manualText);

NS_ASSUME_NONNULL_END
