#import "MacVNCStatusText.h"

NSString *macVNCStatusLine(MacVNCStatusInput input, NSString *bindAddress)
{
    if (input.port > 0) {
        /* Report what the RUNNING server applied — never the saved defaults,
           which may describe an unsaved change or be overridden by MACVNC_* env
           vars. Claiming a restriction that is not in effect would be a
           security-relevant lie. */
        NSString *bind = bindAddress.length > 0 ? bindAddress : @"all interfaces";
        NSString *access = input.allowsEveryone ? @"allow all" : @"allowlist";
        return [NSString stringWithFormat:@"Running  •  %@:%d  •  %@",
                bind, input.port, access];
    }
    if (input.permissionsMissing)
        return @"Not running  •  permissions required";
    return @"Not running";
}

NSString *macVNCClientsLine(MacVNCStatusInput input)
{
    /* A stopped server has no clients whatever the counter holds: after the
       listeners are closed the port reads 0 while the counter is untouched,
       which produced "Not running" directly above "1 client connected". */
    int n = input.port > 0 ? input.clientCount : 0;
    if (n == 0)
        return @"No clients connected";
    if (n == 1)
        return @"1 client connected";
    return [NSString stringWithFormat:@"%d clients connected", n];
}
