#import "MacVNCNetworkRows.h"
#import "NetworkInventory.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

NSString * const MacVNCRowKeyName               = @"name";
NSString * const MacVNCRowKeyDisplayName        = @"displayName";
NSString * const MacVNCRowKeyAddress            = @"address";
NSString * const MacVNCRowKeyCIDR               = @"cidr";
NSString * const MacVNCRowKeyAllowCIDR          = @"allowCIDR";
NSString * const MacVNCRowKeyListenTitle        = @"listenTitle";
NSString * const MacVNCRowKeyAllowTitle         = @"allowTitle";
NSString * const MacVNCRowKeyAllowSummary       = @"allowSummary";
NSString * const MacVNCRowKeyAllowPresetVisible = @"allowPresetVisible";
NSString * const MacVNCRowKeyCGNATLike          = @"cgnatLike";

NSArray<NSDictionary<NSString *, id> *> *macVNCActiveNetworkRows(void)
{
    NSMutableArray<NSDictionary<NSString *, id> *> *rows = [NSMutableArray array];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0)
        return rows;

    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_name || !item->ifa_addr || !item->ifa_netmask)
            continue;
        if (item->ifa_addr->sa_family != AF_INET)
            continue;
        if ((item->ifa_flags & IFF_UP) == 0 || (item->ifa_flags & IFF_RUNNING) == 0)
            continue;

        char address[INET_ADDRSTRLEN] = {0};
        char netmask[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *addr = (struct sockaddr_in *)item->ifa_addr;
        struct sockaddr_in *mask = (struct sockaddr_in *)item->ifa_netmask;
        if (!inet_ntop(AF_INET, &addr->sin_addr, address, sizeof(address)) ||
            !inet_ntop(AF_INET, &mask->sin_addr, netmask, sizeof(netmask)))
            continue;

        MacVNCNetworkInterfaceRow row;
        MacVNCNetworkInterfaceSnapshot snapshot = {
            .name = item->ifa_name,
            .active = true,
            .address = address,
            .netmask = netmask,
        };
        if (!macVNCBuildNetworkInterfaceRow(&snapshot, &row) || !row.selectable)
            continue;

        NSString *name = [NSString stringWithUTF8String:row.name];
        NSString *displayName = [NSString stringWithUTF8String:row.displayName];
        NSString *ip = [NSString stringWithUTF8String:row.address];
        NSString *cidr = [NSString stringWithUTF8String:row.cidr];
        NSString *allowCIDR = [NSString stringWithUTF8String:row.suggestedAllowCIDR];
        NSString *listenTitle = [NSString stringWithFormat:@"%@ — %@", displayName, ip];
        /* Only label it a tailnet when the broad CGNAT preset was actually applied
           (point-to-point utun). A CGNAT address on a normal LAN keeps its own
           subnet and must not be presented as "Tailscale clients". */
        BOOL usesTailnetPreset = [allowCIDR isEqualToString:@"100.64.0.0/10"];
        NSString *allowTitle = usesTailnetPreset
            ? [NSString stringWithFormat:@"Tailscale tailnet / CGNAT range — %@ (broad; use Tailscale ACLs)", allowCIDR]
            : [NSString stringWithFormat:@"Same network as %@ — %@", displayName, allowCIDR];
        NSString *allowSummary = usesTailnetPreset
            ? [NSString stringWithFormat:@"Auto: Tailscale clients — %@", allowCIDR]
            : [NSString stringWithFormat:@"Auto: same network — %@", allowCIDR];
        [rows addObject:@{
            MacVNCRowKeyName: name,
            MacVNCRowKeyDisplayName: displayName,
            MacVNCRowKeyAddress: ip,
            MacVNCRowKeyCIDR: cidr,
            MacVNCRowKeyAllowCIDR: allowCIDR,
            MacVNCRowKeyListenTitle: listenTitle,
            MacVNCRowKeyAllowTitle: allowTitle,
            MacVNCRowKeyAllowSummary: allowSummary,
            MacVNCRowKeyAllowPresetVisible: @(row.allowPresetVisible),
            MacVNCRowKeyCGNATLike: @(row.cgnatLike),
        }];
    }
    freeifaddrs(interfaces);
    return rows;
}
