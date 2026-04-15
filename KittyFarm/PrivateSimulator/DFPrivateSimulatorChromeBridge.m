#import "DFPrivateSimulatorChromeBridge.h"
#import <objc/message.h>

@implementation DFPrivateSimulatorChromeBridge

+ (nullable NSView *)chromeViewForDeviceName:(NSString *)deviceName
                                 displaySize:(CGSize)displaySize {
    // Load frameworks
    NSBundle *simKit = [NSBundle bundleWithPath:@"/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework"];
    if (![simKit isLoaded]) {
        if (![simKit load]) {
            NSLog(@"[KittyFarm] Failed to load SimulatorKit");
            return nil;
        }
    }

    NSBundle *coreSim = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
    if (![coreSim isLoaded]) {
        if (![coreSim load]) {
            NSLog(@"[KittyFarm] Failed to load CoreSimulator");
            return nil;
        }
    }

    id deviceType = [self deviceTypeForName:deviceName];
    if (!deviceType) {
        NSLog(@"[KittyFarm] No device type found for '%@'", deviceName);
        return nil;
    }

    Class chromeViewClass = NSClassFromString(@"_TtC12SimulatorKit20SimDisplayChromeView");
    if (!chromeViewClass) {
        NSLog(@"[KittyFarm] SimDisplayChromeView class not found");
        return nil;
    }

    NSView *chromeView = [[chromeViewClass alloc] initWithFrame:NSZeroRect];
    if (!chromeView) {
        return nil;
    }

    @try {
        [chromeView setValue:deviceType forKey:@"deviceType"];
        [chromeView setValue:[NSValue valueWithSize:displaySize] forKey:@"displaySize"];
    } @catch (NSException *exception) {
        NSLog(@"[KittyFarm] Failed to configure chrome view: %@", exception);
        return nil;
    }

    @try {
        [chromeView setValue:@YES forKey:@"preferSimpleChrome"];
    } @catch (NSException *exception) {
        // Optional
    }

    return chromeView;
}

+ (nullable id)deviceTypeForName:(NSString *)deviceName {
    NSString *basePath = @"/Library/Developer/CoreSimulator/Profiles/DeviceTypes";
    NSString *bundlePath = [NSString stringWithFormat:@"%@/%@.simdevicetype", basePath, deviceName];

    Class simDeviceTypeClass = NSClassFromString(@"SimDeviceType");
    if (!simDeviceTypeClass) {
        NSLog(@"[KittyFarm] SimDeviceType class not found");
        return nil;
    }

    NSBundle *deviceBundle = [NSBundle bundleWithPath:bundlePath];
    if (!deviceBundle) {
        NSLog(@"[KittyFarm] Device type bundle not found at '%@'", bundlePath);
        return nil;
    }

    // Use objc_msgSend to call initWithBundle:error: safely
    typedef id (*InitWithBundleIMP)(id, SEL, NSBundle *, NSError **);

    SEL initSel = NSSelectorFromString(@"initWithBundle:error:");
    if (![simDeviceTypeClass instancesRespondToSelector:initSel]) {
        NSLog(@"[KittyFarm] SimDeviceType does not respond to initWithBundle:error:");
        return nil;
    }

    id instance = [simDeviceTypeClass alloc];
    NSError *error = nil;

    InitWithBundleIMP imp = (InitWithBundleIMP)objc_msgSend;
    id deviceType = imp(instance, initSel, deviceBundle, &error);

    if (error) {
        NSLog(@"[KittyFarm] Failed to init device type for '%@': %@", deviceName, error);
        return nil;
    }

    return deviceType;
}

@end
