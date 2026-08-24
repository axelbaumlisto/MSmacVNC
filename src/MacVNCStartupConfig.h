#import <Foundation/Foundation.h>
#import "mac.h"

NS_ASSUME_NONNULL_BEGIN

/*
 * Pure, testable assembler of a MacVNCServerConfig from NSUserDefaults + an
 * environment dictionary. It resolves the network policy and applies all
 * MACVNC_* overrides, and OWNS the backing storage (password string, resolved
 * policy buffers) so the produced config's const char* fields stay valid for
 * the lifetime of this object.
 */
@interface MacVNCStartupConfig : NSObject

/* Non-nil error message if the configuration is invalid (do not start). */
@property (nonatomic, readonly, copy, nullable) NSString *error;

/* YES if an environment override affected the network policy. */
@property (nonatomic, readonly) BOOL usedEnvironmentOverride;

/* Build from defaults + environment (e.g. NSProcessInfo.processInfo.environment).
   passwordFileReader mirrors macVNCReadSecurePasswordFile; injectable for tests. */
+ (instancetype)configWithDefaults:(NSUserDefaults *)defaults
                       environment:(NSDictionary<NSString *, NSString *> *)environment;

/* Fill out a MacVNCServerConfig that points into this object's storage.
   Valid only while the receiver is alive. Returns NO if self.error is set. */
- (BOOL)fillServerConfig:(MacVNCServerConfig *)config;

@end

NS_ASSUME_NONNULL_END
