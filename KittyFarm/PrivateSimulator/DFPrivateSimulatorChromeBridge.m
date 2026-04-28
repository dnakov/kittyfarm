#import "DFPrivateSimulatorChromeBridge.h"
#import <objc/message.h>

static NSString *DFXcodeSelectDeveloperDirectory(void) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return nil;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        return nil;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return path.length > 0 ? path : nil;
}

static NSString *DFDeveloperDirectory(void) {
    NSString *environmentValue = [NSProcessInfo processInfo].environment[@"DEVELOPER_DIR"];
    if (environmentValue.length > 0) {
        return environmentValue.stringByStandardizingPath;
    }

    NSString *selected = DFXcodeSelectDeveloperDirectory();
    if (selected.length > 0) {
        return selected.stringByStandardizingPath;
    }

    return @"/Applications/Xcode.app/Contents/Developer";
}

@implementation DFPrivateSimulatorChromeBridge

+ (nullable NSView *)chromeViewForDeviceName:(NSString *)deviceName
                                 displaySize:(CGSize)displaySize {
    // Load frameworks
    NSString *simulatorKitPath = [DFDeveloperDirectory() stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework"];
    NSBundle *simKit = [NSBundle bundleWithPath:simulatorKitPath];
    if (![simKit isLoaded]) {
        if (![simKit load]) {
            NSLog(@"[KittyFarm] Failed to load SimulatorKit from %@", simulatorKitPath);
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
