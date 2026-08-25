#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Text for the status-bar menu, as a pure function of observed state.
 *
 * Extracted from AppDelegate because it was assembled inline in AppKit code and
 * therefore untestable — the same shape that let the status line contradict the
 * permission rows directly beneath it, and that once printed "1 client
 * connected" under "Not running".
 */

typedef struct {
    int  port;              /* 0 when the server is not listening              */
    int  clientCount;       /* raw counter; ignored when port == 0             */
    BOOL permissionsMissing;/* from the permission resolver, not sampled again */
    BOOL allowsEveryone;    /* live server policy, never saved defaults        */
} MacVNCStatusInput;

/* "Running  •  100.70.214.41:5903  •  allowlist", or the stopped variants. */
NSString *macVNCStatusLine(MacVNCStatusInput input, NSString *_Nullable bindAddress);

/* "No clients connected" / "1 client connected" / "N clients connected".
   A stopped server always reports none, whatever the counter last held. */
NSString *macVNCClientsLine(MacVNCStatusInput input);

NS_ASSUME_NONNULL_END
