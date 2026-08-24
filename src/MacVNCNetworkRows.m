#import "MacVNCNetworkRows.h"
#import "NetworkInventory.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

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
        NSString *allowTitle = row.cgnatLike
            ? [NSString stringWithFormat:@"Tailscale tailnet / CGNAT range — %@ (broad; use Tailscale ACLs)", allowCIDR]
            : [NSString stringWithFormat:@"Same network as %@ — %@", displayName, allowCIDR];
        NSString *allowSummary = row.cgnatLike
            ? [NSString stringWithFormat:@"Auto: Tailscale clients — %@", allowCIDR]
            : [NSString stringWithFormat:@"Auto: same network — %@", allowCIDR];
        [rows addObject:@{
            @"name": name,
            @"displayName": displayName,
            @"address": ip,
            @"cidr": cidr,
            @"allowCIDR": allowCIDR,
            @"listenTitle": listenTitle,
            @"allowTitle": allowTitle,
            @"allowSummary": allowSummary,
            @"allowPresetVisible": @(row.allowPresetVisible),
            @"cgnatLike": @(row.cgnatLike),
        }];
    }
    freeifaddrs(interfaces);
    return rows;
}
