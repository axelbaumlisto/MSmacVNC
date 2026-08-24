#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Enumerate active IPv4 network interfaces as selectable rows for the
 * Preferences UI. Each row dict has keys: name, displayName, address, cidr,
 * allowCIDR, listenTitle, allowTitle, allowSummary, allowPresetVisible,
 * cgnatLike.
 */
NSArray<NSDictionary<NSString *, id> *> *macVNCActiveNetworkRows(void);

NS_ASSUME_NONNULL_END
