#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(PrivateSimulatorChromeBridge)
@interface DFPrivateSimulatorChromeBridge : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Returns the chrome view for a simulator device type, or nil if unavailable.
/// @param deviceName The display name of the device (e.g. "iPhone 17 Pro Max")
/// @param displaySize The pixel size of the display
+ (nullable NSView *)chromeViewForDeviceName:(NSString *)deviceName
                                 displaySize:(CGSize)displaySize NS_SWIFT_NAME(chromeView(deviceName:displaySize:));

@end

NS_ASSUME_NONNULL_END
