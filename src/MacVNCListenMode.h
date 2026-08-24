#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Loopback IPv4 as an NSString, derived from the shared C macro. */
extern NSString * const MacVNCLoopbackIPv4; /* @"127.0.0.1" */

/* Single source of truth for the listenMode string values. */
extern NSString * const MacVNCListenModeLocalhost; /* @"localhost" */
extern NSString * const MacVNCListenModeAll;       /* @"all"       */
extern NSString * const MacVNCListenModeCustom;    /* @"custom"    */
extern NSString * const MacVNCListenModeSelected;  /* @"selected"  */

/* Resolve the bound host string for display/URLs given a mode and address.
 * localhost -> 127.0.0.1; custom/selected -> address; all -> nil. */
NSString * _Nullable macVNCBindHostForMode(NSString *mode, NSString * _Nullable address);

NS_ASSUME_NONNULL_END
