#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Row dictionary keys — single source of truth shared by the producer
 * (MacVNCNetworkRows) and the consumer (MacVNCPreferences), so a typo cannot
 * silently mismatch the two sides.
 */
extern NSString * const MacVNCRowKeyName;               /* interface name */
extern NSString * const MacVNCRowKeyDisplayName;        /* human label */
extern NSString * const MacVNCRowKeyAddress;           /* IPv4 address */
extern NSString * const MacVNCRowKeyCIDR;              /* interface CIDR */
extern NSString * const MacVNCRowKeyAllowCIDR;        /* allowlist CIDR */
extern NSString * const MacVNCRowKeyListenTitle;      /* popup title */
extern NSString * const MacVNCRowKeyAllowTitle;       /* allow title */
extern NSString * const MacVNCRowKeyAllowSummary;     /* allow summary */
extern NSString * const MacVNCRowKeyAllowPresetVisible; /* NSNumber(BOOL) */
extern NSString * const MacVNCRowKeyCGNATLike;        /* NSNumber(BOOL) */

/*
 * Enumerate active IPv4 network interfaces as selectable rows for the
 * Preferences UI. Each row dict is keyed by the MacVNCRowKey* constants above.
 */
NSArray<NSDictionary<NSString *, id> *> *macVNCActiveNetworkRows(void);

NS_ASSUME_NONNULL_END
