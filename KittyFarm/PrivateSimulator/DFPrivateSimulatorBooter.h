#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(PrivateSimulatorBooter)
@interface DFPrivateSimulatorBooter : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)new NS_UNAVAILABLE;

+ (BOOL)bootDeviceWithUDID:(NSString *)udid
                    error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(bootDevice(udid:));

@end

NS_ASSUME_NONNULL_END
