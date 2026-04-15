#import "DFPrivateSimulatorDisplayBridge.h"

#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdarg.h>

static NSString * const DFPrivateSimulatorErrorDomain = @"KittyFarm.PrivateSimulator";
static NSString * const DFSimulatorKitPath = @"/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit";
static NSString * const DFCoreSimulatorPath = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
static NSString * const DFPrivateSimulatorLogPath = @"/tmp/kittyfarm-private-bridge.log";
static const void *DFPrivateSimulatorCallbackQueueKey = &DFPrivateSimulatorCallbackQueueKey;
static const void *DFDigitizerDelegateAssociationKey = &DFDigitizerDelegateAssociationKey;
static const void *DFDigitizerWakeDelegateAssociationKey = &DFDigitizerWakeDelegateAssociationKey;

typedef struct IndigoHIDMessageStruct IndigoHIDMessage;
typedef uint32_t IndigoHIDEdge;

typedef IndigoHIDMessage *(*DFIndigoHIDMessageForMouseNSEventFn)(CGPoint *location, CGPoint *windowLocation, uint32_t target, NSEventType type, NSSize displaySize, IndigoHIDEdge edge);
typedef IndigoHIDMessage *(*DFIndigoHIDMessageForKeyboardArbitraryFn)(int keyCode, int op);
typedef IndigoHIDMessage *(*DFIndigoHIDMessageForKeyboardNSEventFn)(NSEvent *event);
typedef IndigoHIDMessage *(*DFIndigoHIDMessageForButtonFn)(uint32_t buttonCode, uint32_t operation, uint32_t target);
typedef void (*DFSimDigitizerTouchMethodFn)(id inputView, const void *touchEvent);

typedef struct {
    CGPoint touch1;
    CGPoint touch2;
    uint8_t touch2IsNil;
    uint8_t phase;
    uint8_t reserved[6];
    int64_t type;
    uint64_t edge;
} DFSimDigitizerTouchEvent;

#pragma pack(push, 4)
typedef struct {
    uint32_t msgh_bits;
    uint32_t msgh_size;
    uint32_t msgh_remote_port;
    uint32_t msgh_local_port;
    uint32_t msgh_voucher_port;
    int32_t msgh_id;
} DFMachMessageHeader;

typedef struct {
    uint32_t field1;
    uint32_t field2;
    uint32_t field3;
    double xRatio;
    double yRatio;
    double field6;
    double field7;
    double field8;
    uint32_t field9;
    uint32_t field10;
    uint32_t field11;
    uint32_t field12;
    uint32_t field13;
    double field14;
    double field15;
    double field16;
    double field17;
    double field18;
} DFIndigoTouch;

typedef union {
    DFIndigoTouch touch;
} DFIndigoEvent;

typedef struct {
    uint32_t field1;
    uint64_t timestamp;
    uint32_t field3;
    DFIndigoEvent event;
} DFIndigoPayload;

typedef struct {
    DFMachMessageHeader header;
    uint32_t innerSize;
    uint8_t eventType;
    uint8_t reserved[3];
    DFIndigoPayload payload;
} DFIndigoMessage;
#pragma pack(pop)

static const uint32_t DFIndigoTouchTarget = 0x32;
static const uint8_t DFIndigoEventTypeTouch = 0x02;
static const uint32_t DFIndigoTouchEventKind = 0x0b;
static const int DFKeyboardDirectionDown = 1;
static const int DFKeyboardDirectionUp = 2;
static const uint32_t DFButtonDirectionDown = 1;
static const uint32_t DFButtonDirectionUp = 2;
// Apple Simulator sends Indigo button code 0x191 for Home; 1 is Lock.
static const uint32_t DFHomeButtonCode = 0x191;
static const NSUInteger DFKeyboardModifierShift = 1 << 0;
static const NSUInteger DFKeyboardModifierControl = 1 << 1;
static const NSUInteger DFKeyboardModifierOption = 1 << 2;
static const NSUInteger DFKeyboardModifierCommand = 1 << 3;
static const NSUInteger DFKeyboardModifierCapsLock = 1 << 4;
static const NSUInteger DFKeyboardModifierFunction = 1 << 5;

typedef struct {
    __unsafe_unretained id unit;
    double value;
} DFUnitAngleMeasurement;

typedef NS_ENUM(NSInteger, DFPrivateSimulatorErrorCode) {
    DFPrivateSimulatorErrorCodeFrameworkLoadFailed = 1,
    DFPrivateSimulatorErrorCodeServiceContextFailed = 2,
    DFPrivateSimulatorErrorCodeDeviceLookupFailed = 3,
    DFPrivateSimulatorErrorCodeDisplayAttachFailed = 4,
    DFPrivateSimulatorErrorCodeTouchDispatchFailed = 5,
};

static NSError * DFMakeError(DFPrivateSimulatorErrorCode code, NSString *description) {
    return [NSError errorWithDomain:DFPrivateSimulatorErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description,
    }];
}

static void DFLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"[KittyFarm][PrivateSim] %@", message);
    NSString *line = [NSString stringWithFormat:@"%@ [KittyFarm][PrivateSim] %@\n", [NSDate date], message];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:DFPrivateSimulatorLogPath]) {
        [line writeToFile:DFPrivateSimulatorLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:DFPrivateSimulatorLogPath];
    if (handle == nil) {
        [line writeToFile:DFPrivateSimulatorLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

static id DFDigitizerDelegateGetter(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, DFDigitizerDelegateAssociationKey);
}

static id DFDigitizerWakeDelegateGetter(id self, SEL _cmd) {
    return objc_getAssociatedObject(self, DFDigitizerWakeDelegateAssociationKey);
}

static Class DFEnsureDigitizerProxyClass(Class baseClass) {
    if (baseClass == Nil) {
        return Nil;
    }

    NSString *subclassName = [NSString stringWithFormat:@"%@_KittyFarmProxy", NSStringFromClass(baseClass)];
    Class subclass = NSClassFromString(subclassName);
    if (subclass != Nil) {
        return subclass;
    }

    subclass = objc_allocateClassPair(baseClass, subclassName.UTF8String, 0);
    if (subclass == Nil) {
        return baseClass;
    }

    class_addMethod(subclass, sel_registerName("delegate"), (IMP)DFDigitizerDelegateGetter, "@@:");
    class_addMethod(subclass, sel_registerName("wakeOnTouchDelegate"), (IMP)DFDigitizerWakeDelegateGetter, "@@:");
    objc_registerClassPair(subclass);
    return subclass;
}

static id DFSendObject(id target, const char *selectorName) {
    return ((id(*)(id, SEL))objc_msgSend)(target, sel_registerName(selectorName));
}

static id DFAllocInitRect(Class cls, NSRect rect) {
    id instance = ((id(*)(id, SEL))objc_msgSend)(cls, sel_registerName("alloc"));
    return ((id(*)(id, SEL, NSRect))objc_msgSend)(instance, sel_registerName("initWithFrame:"), rect);
}

static id DFCallSwiftSelfGetter(id selfObject, const char *symbolName) {
    if (selfObject == nil) {
        return nil;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return nil;
    }

    id result = nil;
    __asm__ volatile(
        "mov x20, %1\n"
        "blr %2\n"
        "mov %0, x0\n"
        : "=r" (result)
        : "r" (selfObject), "r" (function)
        : "x0", "x20", "x30", "memory"
    );
    return result;
}

static NSDictionary<NSNumber *, id> * DFReadAdapterScreens(id adapter) {
    id screens = DFCallSwiftSelfGetter(adapter, "$s12SimulatorKit22SimDeviceScreenAdapterC7screensSDys6UInt32VSo0cE0_pGvg");
    return [screens isKindOfClass:[NSDictionary class]] ? screens : @{};
}

static uint32_t DFCallSwiftSelfGetterU32(id selfObject, const char *symbolName) {
    if (selfObject == nil) {
        return 0;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return 0;
    }

    uint32_t result = 0;
    __asm__ volatile(
        "mov x20, %1\n"
        "blr %2\n"
        "mov %w0, w0\n"
        : "=r" (result)
        : "r" (selfObject), "r" (function)
        : "x0", "x20", "x30", "memory"
    );
    return result;
}

static BOOL DFCallSwiftVoidMethodWithSelfAndTwoArgs(id selfObject, id firstArgument, const void *secondArgument, const char *symbolName) {
    if (selfObject == nil || firstArgument == nil || secondArgument == nil) {
        return NO;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return NO;
    }

    __asm__ volatile(
        "mov x20, %0\n"
        "mov x0, %1\n"
        "mov x1, %2\n"
        "blr %3\n"
        :
        : "r" (selfObject), "r" (firstArgument), "r" (secondArgument), "r" (function)
        : "x0", "x1", "x20", "x30", "memory"
    );
    return YES;
}

static BOOL DFCallSwiftVoidMethodWithSelfAndObject(id selfObject, id firstArgument, const char *symbolName) {
    if (selfObject == nil || firstArgument == nil) {
        return NO;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return NO;
    }

    __asm__ volatile(
        "mov x20, %0\n"
        "mov x0, %1\n"
        "blr %2\n"
        :
        : "r" (selfObject), "r" (firstArgument), "r" (function)
        : "x0", "x20", "x30", "memory"
    );
    return YES;
}

static BOOL DFCallSwiftVoidMethodWithSelfAndUWordAndBool(id selfObject, uintptr_t firstArgument, BOOL secondArgument, const char *symbolName) {
    if (selfObject == nil) {
        return NO;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return NO;
    }

    uintptr_t enabledValue = secondArgument ? 1 : 0;
    __asm__ volatile(
        "mov x20, %0\n"
        "mov x0, %1\n"
        "mov x1, %2\n"
        "blr %3\n"
        :
        : "r" (selfObject), "r" (firstArgument), "r" (enabledValue), "r" (function)
        : "x0", "x1", "x20", "x30", "memory"
    );
    return YES;
}

static BOOL DFCallSwiftThrowingMethodWithSelfAndObjectAndUWord(id selfObject, id firstArgument, uintptr_t secondArgument, const char *symbolName, NSError **error) {
    if (selfObject == nil || firstArgument == nil) {
        return NO;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return NO;
    }

    uintptr_t thrownBits = 0;
    __asm__ volatile(
        "mov x20, %1\n"
        "mov x0, %2\n"
        "mov x1, %3\n"
        "mov x21, xzr\n"
        "blr %4\n"
        "mov %0, x21\n"
        : "=r" (thrownBits)
        : "r" (selfObject), "r" (firstArgument), "r" (secondArgument), "r" (function)
        : "x0", "x1", "x20", "x21", "x30", "memory"
    );

    if (thrownBits >= 0x1000) {
        DFLog(@"SimulatorKit connect(screen:inputs:) returned x21 = 0x%llx", (unsigned long long)thrownBits);
    }

    if (error != NULL) {
        *error = nil;
    }

    return YES;
}

static void DFSpinRunLoop(NSTimeInterval duration) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    while ([deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:0.05];
            if ([NSThread isMainThread]) {
                [[NSRunLoop currentRunLoop] runUntilDate:slice];
            } else {
                [NSThread sleepForTimeInterval:0.05];
            }
        }
    }
}

static void DFRunOnMainSync(dispatch_block_t block) {
    if (block == nil) {
        return;
    }

    if ([NSThread isMainThread]) {
        block();
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), block);
}

static void DFRunOnMainAsync(dispatch_block_t block) {
    if (block == nil) {
        return;
    }

    if ([NSThread isMainThread]) {
        block();
        return;
    }

    dispatch_async(dispatch_get_main_queue(), block);
}

static CVPixelBufferRef DFCreatePixelBufferFromSurface(IOSurfaceRef surface) {
    if (surface == nil) {
        return nil;
    }

    CVPixelBufferRef pixelBuffer = nil;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVReturn status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (status != kCVReturnSuccess) {
        DFLog(@"CVPixelBufferCreateWithIOSurface failed: %d", status);
    }
    return status == kCVReturnSuccess ? pixelBuffer : nil;
}

static Ivar DFGetIvar(id object, const char *name) {
    if (object == nil || name == NULL) {
        return NULL;
    }
    return class_getInstanceVariable([object class], name);
}

static void DFSetBoolIvar(id object, const char *name, BOOL value) {
    Ivar ivar = DFGetIvar(object, name);
    if (ivar == NULL) {
        return;
    }

    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    bytes[ivar_getOffset(ivar)] = value ? 1 : 0;
}

static void DFSetCGFloatIvar(id object, const char *name, CGFloat value) {
    Ivar ivar = DFGetIvar(object, name);
    if (ivar == NULL) {
        return;
    }

    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    *((CGFloat *)(bytes + ivar_getOffset(ivar))) = value;
}

static void DFSetNSEdgeInsetsIvar(id object, const char *name, NSEdgeInsets value) {
    Ivar ivar = DFGetIvar(object, name);
    if (ivar == NULL) {
        return;
    }

    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    *((NSEdgeInsets *)(bytes + ivar_getOffset(ivar))) = value;
}

static void DFSetCGSizeIvar(id object, const char *name, CGSize value) {
    Ivar ivar = DFGetIvar(object, name);
    if (ivar == NULL) {
        return;
    }

    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    *((CGSize *)(bytes + ivar_getOffset(ivar))) = value;
}

static void DFStoreWeakObjectIvar(id object, const char *name, id value) {
    Ivar ivar = DFGetIvar(object, name);
    if (ivar == NULL) {
        return;
    }

    object_setIvar(object, ivar, value);
}

static void DFSetStrongObjectIvar(id object, const char *name, id value) {
    Ivar ivar = DFGetIvar(object, name);
    if (ivar == NULL) {
        return;
    }

    object_setIvar(object, ivar, value);
}

static BOOL DFSendHIDMessage(id hidClient, IndigoHIDMessage *message, BOOL freeWhenDone, NSError **error) {
    if (hidClient == nil || message == nil) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"Private SimulatorKit HID transport was unavailable."
            );
        }
        return NO;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *sendError = nil;

    ((void(*)(id, SEL, IndigoHIDMessage *, BOOL, dispatch_queue_t, id))objc_msgSend)(
        hidClient,
        sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:"),
        message,
        freeWhenDone,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(NSError *completionError) {
            sendError = completionError;
            dispatch_semaphore_signal(semaphore);
        }
    );

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"Timed out waiting for SimulatorKit HID delivery."
            );
        }
        return NO;
    }

    if (sendError != nil) {
        if (error != NULL) {
            *error = sendError;
        }
        return NO;
    }

    return YES;
}

static DFIndigoMessage *DFCreateIndigoTouchMessage(CGPoint normalizedPoint, NSSize displaySize, BOOL touchDown, NSError **error) {
    DFIndigoHIDMessageForMouseNSEventFn mouseMessage = (DFIndigoHIDMessageForMouseNSEventFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
    if (mouseMessage == NULL) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not expose IndigoHIDMessageForMouseNSEvent."
            );
        }
        return NULL;
    }

    NSEventType eventType = touchDown ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp;
    CGPoint ratioPoint = CGPointMake(
        fmax(0.0, fmin(1.0, normalizedPoint.x)),
        fmax(0.0, fmin(1.0, normalizedPoint.y))
    );

    DFIndigoMessage *baseMessage = (DFIndigoMessage *)mouseMessage(&ratioPoint, NULL, DFIndigoTouchTarget, eventType, displaySize, 0);
    if (baseMessage == NULL) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit failed to create a base Indigo HID touch packet."
            );
        }
        return NULL;
    }

    size_t messageSize = sizeof(DFIndigoMessage) + sizeof(DFIndigoPayload);
    DFIndigoMessage *message = calloc(1, messageSize);
    if (message == NULL) {
        free(baseMessage);
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"Unable to allocate the Indigo HID touch packet."
            );
        }
        return NULL;
    }

    message->innerSize = (uint32_t)sizeof(DFIndigoPayload);
    message->eventType = DFIndigoEventTypeTouch;
    message->payload.field1 = DFIndigoTouchEventKind;
    message->payload.timestamp = mach_absolute_time();
    message->payload.event.touch = baseMessage->payload.event.touch;
    message->payload.event.touch.xRatio = ratioPoint.x;
    message->payload.event.touch.yRatio = ratioPoint.y;

    DFIndigoPayload *secondPayload = (DFIndigoPayload *)((uint8_t *)&message->payload + sizeof(DFIndigoPayload));
    memcpy(secondPayload, &message->payload, sizeof(DFIndigoPayload));
    secondPayload->event.touch.field1 = 0x1;
    secondPayload->event.touch.field2 = 0x2;

    free(baseMessage);
    return message;
}

static IndigoHIDMessage *DFCreateKeyboardMessage(uint16_t keyCode, BOOL keyDown, NSError **error) {
    DFIndigoHIDMessageForKeyboardArbitraryFn keyboardMessage = (DFIndigoHIDMessageForKeyboardArbitraryFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardArbitrary");
    if (keyboardMessage == NULL) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not expose IndigoHIDMessageForKeyboardArbitrary."
            );
        }
        return NULL;
    }

    IndigoHIDMessage *message = keyboardMessage((int)keyCode, keyDown ? DFKeyboardDirectionDown : DFKeyboardDirectionUp);
    if (message == NULL && error != NULL) {
        *error = DFMakeError(
            DFPrivateSimulatorErrorCodeTouchDispatchFailed,
            [NSString stringWithFormat:@"SimulatorKit failed to encode keyboard HID for keyCode %u.", keyCode]
        );
    }
    return message;
}

static IndigoHIDMessage *DFCreateKeyboardMessageFromEvent(NSEvent *event, NSError **error) {
    DFIndigoHIDMessageForKeyboardNSEventFn keyboardMessage = (DFIndigoHIDMessageForKeyboardNSEventFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardNSEvent");
    if (keyboardMessage == NULL) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not expose IndigoHIDMessageForKeyboardNSEvent."
            );
        }
        return nil;
    }

    IndigoHIDMessage *message = keyboardMessage(event);
    if (message == NULL && error != NULL) {
        *error = DFMakeError(
            DFPrivateSimulatorErrorCodeTouchDispatchFailed,
            @"SimulatorKit could not construct an NSEvent keyboard HID packet."
        );
    }

    return message;
}

static IndigoHIDMessage *DFCreateButtonMessage(uint32_t buttonCode, uint32_t operation, uint32_t target, NSError **error) {
    DFIndigoHIDMessageForButtonFn buttonMessage = (DFIndigoHIDMessageForButtonFn)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForButton");
    if (buttonMessage == NULL) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not expose IndigoHIDMessageForButton."
            );
        }
        return NULL;
    }

    IndigoHIDMessage *message = buttonMessage(buttonCode, operation, target);
    if (message == NULL && error != NULL) {
        *error = DFMakeError(
            DFPrivateSimulatorErrorCodeTouchDispatchFailed,
            [NSString stringWithFormat:@"SimulatorKit could not construct hardware button HID for code %u.", buttonCode]
        );
    }

    return message;
}

static BOOL DFCallSwiftUnitAngleMeasurementGetter(id selfObject, const char *symbolName, DFUnitAngleMeasurement *measurement) {
    if (selfObject == nil || measurement == NULL) {
        return NO;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return NO;
    }

    DFUnitAngleMeasurement result = { nil, 0 };
    __asm__ volatile(
        "mov x20, %0\n"
        "mov x8, %1\n"
        "blr %2\n"
        :
        : "r" (selfObject), "r" (&result), "r" (function)
        : "x8", "x20", "x30", "memory"
    );

    *measurement = result;
    return YES;
}

static BOOL DFCallSwiftUnitAngleMeasurementSetter(id selfObject, DFUnitAngleMeasurement measurement, const char *symbolName) {
    if (selfObject == nil) {
        return NO;
    }

    void *function = dlsym(RTLD_DEFAULT, symbolName);
    if (function == NULL) {
        return NO;
    }

    DFUnitAngleMeasurement value = measurement;
    __asm__ volatile(
        "mov x20, %0\n"
        "mov x0, %1\n"
        "blr %2\n"
        :
        : "r" (selfObject), "r" (&value), "r" (function)
        : "x0", "x20", "x30", "memory"
    );

    return YES;
}

static double DFNormalizedDegrees(double value) {
    double normalized = fmod(value, 360.0);
    if (normalized < 0) {
        normalized += 360.0;
    }
    return normalized;
}

static NSArray<NSString *> * DFInterestingSelectorsForObject(id object) {
    if (object == nil) {
        return @[];
    }

    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList([object class], &methodCount);
    if (methods == NULL) {
        return @[];
    }

    NSArray<NSString *> *terms = @[@"orient", @"rotate", @"button", @"home", @"display", @"screen", @"face"];
    for (unsigned int index = 0; index < methodCount; index += 1) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        NSString *lowercased = name.lowercaseString;
        for (NSString *term in terms) {
            if ([lowercased containsString:term]) {
                [selectors addObject:name];
                break;
            }
        }
    }
    free(methods);

    return [selectors sortedArrayUsingSelector:@selector(compare:)];
}

static void DFLogRuntimeShape(id object, NSString *label) {
    if (object == nil) {
        DFLog(@"%@ is nil", label);
        return;
    }

    DFLog(@"%@ class=%@", label, NSStringFromClass([object class]));
    NSArray<NSString *> *selectors = DFInterestingSelectorsForObject(object);
    if (selectors.count > 0) {
        DFLog(@"%@ interesting selectors=%@", label, selectors);
    }
}

static NSInteger DFOrientationEquivalentValueForMeasurement(DFUnitAngleMeasurement measurement) {
    double degrees = DFNormalizedDegrees(measurement.value);
    if (fabs(degrees - 0.0) < 0.5 || fabs(degrees - 360.0) < 0.5) {
        return 1;
    }
    if (fabs(degrees - 180.0) < 0.5) {
        return 2;
    }
    if (fabs(degrees - 90.0) < 0.5) {
        return 4;
    }
    if (fabs(degrees - 270.0) < 0.5) {
        return 3;
    }
    return 1;
}

static BOOL DFSendIntegerSelectorIfAvailable(id target, const char *selectorName, NSInteger value) {
    if (target == nil || selectorName == NULL) {
        return NO;
    }

    SEL selector = sel_registerName(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }

    ((void(*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
    return YES;
}

static BOOL DFSendPurpleOrientationEvent(id device, NSInteger orientationValue) {
    if (device == nil) {
        return NO;
    }

    SEL selector = sel_registerName("sendPurpleEvent:");
    if (![device respondsToSelector:selector]) {
        return NO;
    }

    uint8_t purpleEvent[0x50];
    memset(purpleEvent, 0, sizeof(purpleEvent));
    memset(purpleEvent, 0xFF, 16);

    *(uint64_t *)(purpleEvent + 0x10) = 0x7b00000000ULL;
    *(uint32_t *)(purpleEvent + 0x18) = 0x32;
    *(uint32_t *)(purpleEvent + 0x48) = 4;
    *(uint32_t *)(purpleEvent + 0x4C) = (uint32_t)orientationValue;

    ((void(*)(id, SEL, const void *))objc_msgSend)(device, selector, purpleEvent);
    DFLog(@"Sent simulator device orientation %ld via sendPurpleEvent:", (long)orientationValue);
    return YES;
}

static BOOL DFSendDeviceOrientationEvent(id device, NSInteger orientationValue) {
    if (DFSendIntegerSelectorIfAvailable(device, "gsEventsSendOrientation:", orientationValue)) {
        DFLog(@"Sent simulator device orientation %ld via gsEventsSendOrientation:", (long)orientationValue);
        return YES;
    }

    if (DFSendPurpleOrientationEvent(device, orientationValue)) {
        return YES;
    }

    return NO;
}

static BOOL DFSetDisplayRotationMeasurement(id object, DFUnitAngleMeasurement measurement, const char *setterSymbol) {
    if (object == nil || setterSymbol == NULL) {
        return NO;
    }

    return DFCallSwiftUnitAngleMeasurementSetter(object, measurement, setterSymbol);
}

static void DFConfigureDisplayGeometry(id displayView, CGSize displaySize) {
    if (displayView == nil || displaySize.width <= 0 || displaySize.height <= 0) {
        return;
    }

    NSRect frame = NSMakeRect(0, 0, displaySize.width, displaySize.height);
    if ([displayView respondsToSelector:@selector(setFrame:)]) {
        ((void(*)(id, SEL, NSRect))objc_msgSend)(displayView, @selector(setFrame:), frame);
    }

    id chromeView = object_getIvar(displayView, DFGetIvar(displayView, "chromeView"));
    if (chromeView != nil) {
        if ([chromeView respondsToSelector:@selector(setFrame:)]) {
            ((void(*)(id, SEL, NSRect))objc_msgSend)(chromeView, @selector(setFrame:), frame);
        }
        DFSetCGSizeIvar(chromeView, "displaySize", displaySize);

        id chromeRenderView = object_getIvar(chromeView, DFGetIvar(chromeView, "_renderView"));
        if (chromeRenderView != nil) {
            if ([chromeRenderView respondsToSelector:@selector(setFrame:)]) {
                ((void(*)(id, SEL, NSRect))objc_msgSend)(chromeRenderView, @selector(setFrame:), frame);
            }
            DFSetCGSizeIvar(chromeRenderView, "displaySize", displaySize);
        }
    }
}

static BOOL DFSendSingleKeyboardEvent(id hidClient, uint16_t keyCode, BOOL keyDown, NSError **error) {
    IndigoHIDMessage *message = DFCreateKeyboardMessage(keyCode, keyDown, error);
    if (message == NULL) {
        return NO;
    }

    return DFSendHIDMessage(hidClient, message, YES, error);
}

@interface DFPrivateSimulatorDisplayBridge ()

@property (nonatomic, strong) NSView *displayView;

@end

@implementation DFPrivateSimulatorDisplayBridge {
    id _serviceContext;
    id _device;
    id _screenAdapterHost;
    id _screenAdapter;
    id _bootstrapScreen;
    id _activeScreen;
    id _rawScreen;
    id _hidClient;
    id _digitizerInputView;
    dispatch_queue_t _callbackQueue;
    NSUUID *_screenAdapterCallbackUUID;
    NSUUID *_screenCallbackUUID;
    CVPixelBufferRef _latestPixelBuffer;
    NSString *_displayStatusValue;
    uint32_t _activeScreenID;
    CGSize _displayPixelSize;
    CGPoint _lastTouchPoint;
    BOOL _hasLastTouchPoint;
    BOOL _hasLoggedFirstFrame;
    BOOL _isActivatingDisplay;
    BOOL _hasActivatedDisplay;
    BOOL _digitizerInputReady;
}

+ (BOOL)loadPrivateFrameworks:(NSError **)error {
    static dispatch_once_t onceToken;
    static NSError *loadError = nil;

    dispatch_once(&onceToken, ^{
        if (!dlopen(DFCoreSimulatorPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            loadError = DFMakeError(
                DFPrivateSimulatorErrorCodeFrameworkLoadFailed,
                [NSString stringWithFormat:@"Unable to load CoreSimulator from %@.", DFCoreSimulatorPath]
            );
            return;
        }

        if (!dlopen(DFSimulatorKitPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            loadError = DFMakeError(
                DFPrivateSimulatorErrorCodeFrameworkLoadFailed,
                [NSString stringWithFormat:@"Unable to load SimulatorKit from %@.", DFSimulatorKitPath]
            );
        }
    });

    if (error != NULL) {
        *error = loadError;
    }

    return loadError == nil;
}

- (void)updateStatus:(NSString *)status {
    if ([_displayStatusValue isEqualToString:status]) {
        return;
    }
    _displayStatusValue = [status copy];
    DFLog(@"%@", _displayStatusValue);
    [self notifyDelegateOfStatus:_displayStatusValue isReady:_latestPixelBuffer != nil];
}

- (void)notifyDelegateOfStatus:(NSString *)status isReady:(BOOL)isReady {
    id<DFPrivateSimulatorDisplayBridgeDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return;
    }

    NSString *statusCopy = [status copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [delegate privateSimulatorDisplayBridge:strongSelf didChangeDisplayStatus:statusCopy isReady:isReady];
    });
}

- (void)notifyDelegateOfFrame:(CVPixelBufferRef)pixelBuffer {
    id<DFPrivateSimulatorDisplayBridgeDelegate> delegate = self.delegate;
    if (delegate == nil || pixelBuffer == nil) {
        return;
    }

    CVPixelBufferRetain(pixelBuffer);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil) {
            [delegate privateSimulatorDisplayBridge:strongSelf didUpdateFrame:pixelBuffer];
        }
        CVPixelBufferRelease(pixelBuffer);
    });
}

- (nullable instancetype)initWithUDID:(NSString *)udid error:(NSError * _Nullable __autoreleasing *)error {
    if (![DFPrivateSimulatorDisplayBridge loadPrivateFrameworks:error]) {
        return nil;
    }

    self = [super init];
    if (self == nil) {
        return nil;
    }

    _callbackQueue = dispatch_queue_create("com.sigkitten.KittyFarm.private-screen", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_callbackQueue, DFPrivateSimulatorCallbackQueueKey, (void *)DFPrivateSimulatorCallbackQueueKey, NULL);
    [self updateStatus:[NSString stringWithFormat:@"Starting private CoreSimulator attach for %@", udid]];

    Class serviceContextClass = NSClassFromString(@"SimServiceContext");
    if (serviceContextClass == Nil) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeServiceContextFailed,
                @"CoreSimulator did not expose SimServiceContext in this Xcode runtime."
            );
        }
        return nil;
    }

    NSError *serviceError = nil;
    id contextAlloc = ((id(*)(id, SEL))objc_msgSend)(serviceContextClass, sel_registerName("alloc"));
    _serviceContext = ((id(*)(id, SEL, id, long long, NSError **))objc_msgSend)(
        contextAlloc,
        sel_registerName("initWithDeveloperDir:connectionType:error:"),
        nil,
        0LL,
        &serviceError
    );
    if (_serviceContext == nil) {
        if (error != NULL) {
            *error = serviceError ?: DFMakeError(
                DFPrivateSimulatorErrorCodeServiceContextFailed,
                @"Unable to create a CoreSimulator service context."
            );
        }
        return nil;
    }

    NSError *deviceSetError = nil;
    id deviceSet = ((id(*)(id, SEL, NSError **))objc_msgSend)(_serviceContext, sel_registerName("defaultDeviceSetWithError:"), &deviceSetError);
    if (deviceSet == nil) {
        if (error != NULL) {
            *error = deviceSetError ?: DFMakeError(
                DFPrivateSimulatorErrorCodeServiceContextFailed,
                @"Unable to access the default CoreSimulator device set."
            );
        }
        return nil;
    }

    NSArray *devices = DFSendObject(deviceSet, "devices");
    for (id candidate in devices) {
        id deviceUDID = DFSendObject(candidate, "UDID");
        NSString *candidateUDID = [deviceUDID respondsToSelector:sel_registerName("UUIDString")]
            ? DFSendObject(deviceUDID, "UUIDString")
            : [deviceUDID description];
        if ([candidateUDID isEqualToString:udid]) {
            _device = candidate;
            break;
        }
    }

    if (_device == nil) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeDeviceLookupFailed,
                [NSString stringWithFormat:@"Unable to locate simulator %@ inside the CoreSimulator device set.", udid]
            );
        }
        return nil;
    }

    Class legacyHIDClientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    if (legacyHIDClientClass != Nil) {
        NSError *hidClientError = nil;
        id hidClientAlloc = ((id(*)(id, SEL))objc_msgSend)(legacyHIDClientClass, sel_registerName("alloc"));
        _hidClient = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
            hidClientAlloc,
            sel_registerName("initWithDevice:error:"),
            _device,
            &hidClientError
        );

        if (_hidClient != nil) {
            DFLog(@"Created private SimulatorKit HID client for %@", udid);
        } else {
            DFLog(@"Failed to create private SimulatorKit HID client for %@: %@", udid, hidClientError.localizedDescription ?: @"unknown error");
        }
    } else {
        DFLog(@"SimulatorKit legacy HID client class was unavailable.");
    }

    _screenAdapterHost = DFCallSwiftSelfGetter(_device, "$sSo9SimDeviceC12SimulatorKitE13screenAdapterAC0ab6ScreenF0CSgvg");
    if (_screenAdapterHost == nil) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"CoreSimulator did not expose a SimulatorKit screen adapter."
            );
        }
        return nil;
    }

    Class screenClass = NSClassFromString(@"SimulatorKit.SimDeviceScreen");
    if (screenClass == Nil) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"SimulatorKit did not expose SimDeviceScreen."
            );
        }
        return nil;
    }

    _bootstrapScreen = ((id(*)(id, SEL))objc_msgSend)(screenClass, sel_registerName("alloc"));
    _bootstrapScreen = ((id(*)(id, SEL, id, uint32_t))objc_msgSend)(_bootstrapScreen, sel_registerName("initWithDevice:screenID:"), _device, 0);
    [self updateStatus:@"Waiting for CoreSimulator screen adapter"];
    DFSpinRunLoop(0.5);

    _screenAdapter = object_getIvar(_screenAdapterHost, class_getInstanceVariable([_screenAdapterHost class], "_screenAdapter"));
    if (_screenAdapter == nil) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"CoreSimulator did not provide a headless screen adapter proxy."
            );
        }
        return nil;
    }

    _screenAdapterCallbackUUID = [NSUUID UUID];
    __weak typeof(self) weakSelf = self;
    ((void(*)(id, SEL, id, id, id, id))objc_msgSend)(
        _screenAdapter,
        sel_registerName("registerScreenAdapterCallbacksWithUUID:callbackQueue:screenConnectedCallback:screenWillDisconnectCallback:"),
        _screenAdapterCallbackUUID,
        _callbackQueue,
        ^(id simScreen) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf updateStatus:@"CoreSimulator screen proxy connected"];
        },
        ^(id simScreen) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf updateStatus:@"CoreSimulator screen proxy disconnected"];
        }
    );

    [self updateStatus:@"Waiting for headless simulator screens"];
    DFSpinRunLoop(0.5);

    NSDictionary<NSNumber *, id> *screens = DFReadAdapterScreens(_screenAdapterHost);
    if (screens.count == 0) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"The CoreSimulator screen adapter did not expose any live screens."
            );
        }
        return nil;
    }

    NSArray<NSNumber *> *sortedScreenIDs = [[screens allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSNumber *selectedScreenID = nil;
    for (NSNumber *candidate in sortedScreenIDs) {
        if (candidate.unsignedIntValue > 0) {
            selectedScreenID = candidate;
            break;
        }
    }
    if (selectedScreenID == nil) {
        selectedScreenID = sortedScreenIDs.firstObject;
    }
    _activeScreenID = selectedScreenID.unsignedIntValue;
    DFLog(@"Discovered headless screens %@; selecting %@", sortedScreenIDs, selectedScreenID);

    _activeScreen = ((id(*)(id, SEL))objc_msgSend)(screenClass, sel_registerName("alloc"));
    _activeScreen = ((id(*)(id, SEL, id, uint32_t))objc_msgSend)(_activeScreen, sel_registerName("initWithDevice:screenID:"), _device, _activeScreenID);
    _rawScreen = screens[selectedScreenID];
    DFLogRuntimeShape(_activeScreen, @"activeScreen");
    DFLogRuntimeShape(_rawScreen, @"rawScreen");
    DFLogRuntimeShape(_device, @"device");
    DFSpinRunLoop(0.1);

    Class simDisplayViewClass = NSClassFromString(@"SimulatorKit.SimDisplayView");
    if (simDisplayViewClass != Nil) {
        DFRunOnMainSync(^{
            self->_displayView = DFAllocInitRect(simDisplayViewClass, NSMakeRect(0, 0, 1, 1));
            self->_digitizerInputView = self->_displayView != nil ? object_getIvar(self->_displayView, DFGetIvar(self->_displayView, "digitizerView")) : nil;
            if (self->_displayView != nil) {
                DFSetStrongObjectIvar(self->_displayView, "device", self->_device);
                ((void(*)(id, SEL, id))objc_msgSend)(self->_displayView, sel_registerName("setDevice:"), self->_device);
            }
            if (self->_digitizerInputView != nil && self->_hidClient != nil) {
                DFSetStrongObjectIvar(self->_displayView, "_hidClient", self->_hidClient);
                objc_setAssociatedObject(self->_digitizerInputView, DFDigitizerDelegateAssociationKey, self->_hidClient, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self->_digitizerInputView, DFDigitizerWakeDelegateAssociationKey, self->_displayView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                DFStoreWeakObjectIvar(self->_digitizerInputView, "delegate", self->_hidClient);
                DFStoreWeakObjectIvar(self->_digitizerInputView, "wakeOnTouchDelegate", self->_displayView);
                DFSetBoolIvar(self->_digitizerInputView, "isEnabled", YES);
                DFSetBoolIvar(self->_digitizerInputView, "isPaused", NO);
                DFSetBoolIvar(self->_digitizerInputView, "isAsleep", NO);
                DFSetCGFloatIvar(self->_digitizerInputView, "scale", 1.0);
                DFSetNSEdgeInsetsIvar(self->_digitizerInputView, "screenInset", NSEdgeInsetsMake(0, 0, 0, 0));
                self->_digitizerInputReady = YES;
                DFLog(@"Prepared SimDisplayView digitizer bridge for %@", udid);
            }
        });
    } else {
        DFLog(@"SimulatorKit display view class was unavailable.");
    }

    id rawScreen = _rawScreen;
    if (rawScreen == nil || ![rawScreen respondsToSelector:sel_registerName("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")]) {
        if (error != NULL) {
            *error = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"The selected CoreSimulator screen did not expose display callbacks."
            );
        }
        return nil;
    }

    _screenCallbackUUID = [NSUUID UUID];
    ((void(*)(id, SEL, id, id, id, id, id))objc_msgSend)(
        rawScreen,
        sel_registerName("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"),
        _screenCallbackUUID,
        _callbackQueue,
        ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_latestPixelBuffer == nil) {
                return;
            }
            if (!strongSelf->_hasLoggedFirstFrame) {
                strongSelf->_hasLoggedFirstFrame = YES;
                [strongSelf updateStatus:@"Receiving headless screen frames"];
            }
        },
        ^(id surface, id maskedSurface) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }

            CVPixelBufferRef pixelBuffer = DFCreatePixelBufferFromSurface((__bridge IOSurfaceRef)surface);
            if (pixelBuffer == nil) {
                [strongSelf updateStatus:@"Headless screen surfaced an unsupported IOSurface"];
                return;
            }

            if (strongSelf->_latestPixelBuffer != nil) {
                CVPixelBufferRelease(strongSelf->_latestPixelBuffer);
            }
            strongSelf->_latestPixelBuffer = pixelBuffer;
            size_t width = CVPixelBufferGetWidth(pixelBuffer);
            size_t height = CVPixelBufferGetHeight(pixelBuffer);
            strongSelf->_displayPixelSize = CGSizeMake((CGFloat)width, (CGFloat)height);
            [strongSelf notifyDelegateOfFrame:pixelBuffer];
            DFRunOnMainAsync(^{
                DFConfigureDisplayGeometry(strongSelf->_displayView, strongSelf->_displayPixelSize);
                if (strongSelf->_digitizerInputView != nil) {
                    [strongSelf->_digitizerInputView setFrame:NSMakeRect(0, 0, (CGFloat)width, (CGFloat)height)];
                }
            });
            [strongSelf updateStatus:[NSString stringWithFormat:@"Private display ready (%zux%zu)", width, height]];
        },
        ^(id properties) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            DFLog(@"Headless screen properties updated: class=%@", properties != nil ? NSStringFromClass([properties class]) : @"(nil)");
            if (properties != nil && [properties respondsToSelector:sel_registerName("uiOrientation")]) {
                NSInteger uiOrientation = ((NSInteger(*)(id, SEL))objc_msgSend)(properties, sel_registerName("uiOrientation"));
                DFLog(@"Headless screen uiOrientation=%ld", (long)uiOrientation);
            }
            [strongSelf updateStatus:@"Headless screen properties updated"];
        }
    );

    if (_displayView == nil) {
        _displayView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 932)];
        _displayView.wantsLayer = YES;
    }
    [self updateStatus:@"Waiting for IOSurface callback"];

    DFSpinRunLoop(0.25);
    return self;
}

- (void)dealloc {
    if (_latestPixelBuffer != nil) {
        CVPixelBufferRelease(_latestPixelBuffer);
        _latestPixelBuffer = nil;
    }
}

- (void)activateDisplayIfNeeded {
    if (_hasActivatedDisplay || _isActivatingDisplay || _displayView == nil || _activeScreen == nil) {
        return;
    }

    DFRunOnMainSync(^{
        if (self->_hasActivatedDisplay || self->_isActivatingDisplay || self->_displayView == nil || self->_activeScreen == nil) {
            return;
        }

        if (self->_displayView.window == nil) {
            [self updateStatus:@"Waiting for private display host window"];
            return;
        }

        self->_isActivatingDisplay = YES;
        [self updateStatus:@"Attaching private SimulatorKit display"];

        NSError *activationError = nil;
        id renderableView = [self->_displayView respondsToSelector:sel_registerName("renderableView")]
            ? DFSendObject(self->_displayView, "renderableView")
            : nil;

        if (renderableView == nil) {
            activationError = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"SimulatorKit did not expose a renderable view for the private display."
            );
        } else {
            static const char *renderableConnectSymbol = "$s12SimulatorKit24SimDisplayRenderableViewC7connect6screenyAA0C12DeviceScreenC_tFTj";

            if (!DFCallSwiftVoidMethodWithSelfAndObject(renderableView, self->_activeScreen, renderableConnectSymbol)) {
                activationError = DFMakeError(
                    DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                    @"Failed to locate SimulatorKit renderableView.connect(screen:)."
                );
            } else {
                DFLog(@"Activated private renderableView.connect(screen:) without SimDisplayView.connect(screen:inputs:).");
            }
        }

        if (activationError != nil) {
            self->_isActivatingDisplay = NO;
            [self updateStatus:[NSString stringWithFormat:@"Private SimulatorKit attach failed: %@", activationError.localizedDescription ?: @"unknown error"]];
            DFLog(@"Private SimulatorKit display activation failed: %@", activationError);
            return;
        }

        self->_hasActivatedDisplay = YES;
        self->_isActivatingDisplay = NO;
        [self updateStatus:@"Private SimulatorKit display attached"];
        DFLog(@"Activated SimulatorKit private display attach for screen %u", self->_activeScreenID);
    });
}

- (nullable CVPixelBufferRef)copyPixelBuffer {
    __block CVPixelBufferRef pixelBuffer = nil;
    dispatch_block_t work = ^{
        if (self->_latestPixelBuffer != nil) {
            pixelBuffer = CVPixelBufferRetain(self->_latestPixelBuffer);
        }
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    return pixelBuffer;
}

- (BOOL)pressHomeButton:(NSError * _Nullable __autoreleasing *)error {
    __block BOOL success = NO;
    __block NSError *dispatchError = nil;

    dispatch_block_t work = ^{
        if (self->_hidClient == nil || self->_activeScreen == nil) {
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not provide a live hardware button target."
            );
            return;
        }

        uint32_t target = DFCallSwiftSelfGetterU32(self->_activeScreen, "$s12SimulatorKit15SimDeviceScreenC12buttonTargetSo15IndigoHIDTargetVvg");
        if (target == 0) {
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not expose a hardware button target for this screen."
            );
            return;
        }

        NSError *messageError = nil;
        IndigoHIDMessage *buttonDown = DFCreateButtonMessage(DFHomeButtonCode, DFButtonDirectionDown, target, &messageError);
        if (buttonDown == NULL) {
            dispatchError = messageError;
            return;
        }

        if (!DFSendHIDMessage(self->_hidClient, buttonDown, YES, &messageError)) {
            dispatchError = messageError ?: DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit rejected the Home button-down HID packet."
            );
            return;
        }

        IndigoHIDMessage *buttonUp = DFCreateButtonMessage(DFHomeButtonCode, DFButtonDirectionUp, target, &messageError);
        if (buttonUp == NULL) {
            dispatchError = messageError;
            return;
        }

        if (!DFSendHIDMessage(self->_hidClient, buttonUp, YES, &messageError)) {
            dispatchError = messageError ?: DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit rejected the Home button-up HID packet."
            );
            return;
        }

        DFLog(@"Sending Home hardware button HID to target %u", target);
        success = YES;
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    if (!success && error != NULL) {
        *error = dispatchError;
    }

    return success;
}

- (BOOL)rotateRight:(NSError * _Nullable __autoreleasing *)error {
    __block BOOL success = NO;
    __block NSError *dispatchError = nil;

    dispatch_block_t work = ^{
        static const char *displayViewGetter = "$s12SimulatorKit14SimDisplayViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvgTj";
        static const char *displayViewSetter = "$s12SimulatorKit14SimDisplayViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvsTj";
        static const char *chromeGetter = "$s12SimulatorKit20SimDisplayChromeViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvgTj";
        static const char *chromeSetter = "$s12SimulatorKit20SimDisplayChromeViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvsTj";
        static const char *chromeRenderGetter = "$s12SimulatorKit26SimDisplayChromeRenderViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvgTj";
        static const char *chromeRenderSetter = "$s12SimulatorKit26SimDisplayChromeRenderViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvsTj";
        static const char *digitizerGetter = "$s12SimulatorKit21SimDigitizerInputViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvgTj";
        static const char *digitizerSetter = "$s12SimulatorKit21SimDigitizerInputViewC14deviceRotation10Foundation11MeasurementVySo11NSUnitAngleCGvsTj";

        __block DFUnitAngleMeasurement measurement = { [NSUnitAngle degrees], 0 };
        __block BOOL updatedDisplayRotation = NO;
        __block NSInteger orientationValue = 1;
        DFRunOnMainSync(^{
            DFConfigureDisplayGeometry(self->_displayView, self->_displayPixelSize);

            id chromeView = self->_displayView != nil
                ? object_getIvar(self->_displayView, DFGetIvar(self->_displayView, "chromeView"))
                : nil;
            id chromeRenderView = chromeView != nil
                ? object_getIvar(chromeView, DFGetIvar(chromeView, "_renderView"))
                : nil;

            updatedDisplayRotation = DFCallSwiftUnitAngleMeasurementGetter(self->_displayView, displayViewGetter, &measurement);
            if (!updatedDisplayRotation) {
                updatedDisplayRotation = DFCallSwiftUnitAngleMeasurementGetter(chromeView, chromeGetter, &measurement);
            }
            if (!updatedDisplayRotation) {
                updatedDisplayRotation = DFCallSwiftUnitAngleMeasurementGetter(self->_digitizerInputView, digitizerGetter, &measurement);
            }
            if (!updatedDisplayRotation) {
                return;
            }

            if (measurement.unit == nil) {
                measurement.unit = [NSUnitAngle degrees];
            }
            measurement.value = DFNormalizedDegrees(measurement.value + 90.0);
            orientationValue = DFOrientationEquivalentValueForMeasurement(measurement);

            updatedDisplayRotation = NO;
            updatedDisplayRotation |= DFSetDisplayRotationMeasurement(self->_displayView, measurement, displayViewSetter);
            updatedDisplayRotation |= DFSetDisplayRotationMeasurement(chromeView, measurement, chromeSetter);
            updatedDisplayRotation |= DFSetDisplayRotationMeasurement(chromeRenderView, measurement, chromeRenderSetter);
            updatedDisplayRotation |= DFSetDisplayRotationMeasurement(self->_digitizerInputView, measurement, digitizerSetter);
        });

        if (!updatedDisplayRotation) {
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"SimulatorKit did not expose a mutable rotation state on the private display."
            );
            return;
        }

        BOOL propagatedOrientation = DFSendDeviceOrientationEvent(self->_device, orientationValue);

        if (!propagatedOrientation) {
            DFLogRuntimeShape(self->_activeScreen, @"activeScreen");
            DFLogRuntimeShape(self->_rawScreen, @"rawScreen");
            DFLogRuntimeShape(self->_device, @"device");
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeDisplayAttachFailed,
                @"Failed to send the private simulator orientation event to the connected device."
            );
            return;
        }

        DFLog(@"Rotated private SimulatorKit display state to the right and sent orientation %ld", (long)orientationValue);
        success = YES;
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    if (!success && error != NULL) {
        *error = dispatchError;
    }

    return success;
}

- (void)disconnect {
    dispatch_block_t work = ^{
        if (self->_screenAdapter != nil && self->_screenAdapterCallbackUUID != nil) {
            ((void(*)(id, SEL, id))objc_msgSend)(self->_screenAdapter, sel_registerName("unregisterScreenAdapterCallbacksWithUUID:"), self->_screenAdapterCallbackUUID);
        }

        NSDictionary<NSNumber *, id> *screens = DFReadAdapterScreens(self->_screenAdapterHost);
        id rawScreen = screens[@(self->_activeScreenID)];
        if (rawScreen != nil && self->_screenCallbackUUID != nil && [rawScreen respondsToSelector:sel_registerName("unregisterScreenCallbacksWithUUID:")]) {
            ((void(*)(id, SEL, id))objc_msgSend)(rawScreen, sel_registerName("unregisterScreenCallbacksWithUUID:"), self->_screenCallbackUUID);
        }

        if (self->_latestPixelBuffer != nil) {
            CVPixelBufferRelease(self->_latestPixelBuffer);
            self->_latestPixelBuffer = nil;
        }

        [self updateStatus:@"Disconnected"];
        [self.displayView removeFromSuperview];
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }
}

- (BOOL)isDisplayReady {
    __block BOOL ready = NO;
    dispatch_block_t work = ^{
        ready = self->_latestPixelBuffer != nil;
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    return ready;
}

- (NSString *)displayStatus {
    __block NSString *status = @"Starting private CoreSimulator attach";
    dispatch_block_t work = ^{
        status = self->_displayStatusValue ?: @"Starting private CoreSimulator attach";
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    return status;
}

- (BOOL)sendTouchAtNormalizedX:(double)normalizedX
                   normalizedY:(double)normalizedY
                         phase:(DFPrivateSimulatorTouchPhase)phase
                         error:(NSError * _Nullable __autoreleasing *)error {
    __block BOOL success = NO;
    __block NSError *dispatchError = nil;

    dispatch_block_t work = ^{
        if (self->_hidClient == nil) {
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not provide a headless HID client for this simulator."
            );
            return;
        }

        CGFloat clampedX = (CGFloat)fmax(0.0, fmin(1.0, normalizedX));
        CGFloat clampedY = (CGFloat)fmax(0.0, fmin(1.0, normalizedY));
        CGSize displaySize = self->_displayPixelSize;
        if (displaySize.width < 1.0 || displaySize.height < 1.0) {
            displaySize = CGSizeMake(1.0, 1.0);
        }
        CGPoint point = CGPointMake(
            clampedX * fmax(displaySize.width - 1.0, 1.0),
            clampedY * fmax(displaySize.height - 1.0, 1.0)
        );

        NSString *phaseLabel = @"moved";
        switch (phase) {
        case DFPrivateSimulatorTouchPhaseBegan:
            phaseLabel = @"began";
            break;
        case DFPrivateSimulatorTouchPhaseMoved:
            phaseLabel = @"moved";
            break;
        case DFPrivateSimulatorTouchPhaseEnded:
        case DFPrivateSimulatorTouchPhaseCancelled:
            phaseLabel = phase == DFPrivateSimulatorTouchPhaseEnded ? @"ended" : @"cancelled";
            break;
        }
        BOOL touchDown = phase == DFPrivateSimulatorTouchPhaseBegan || phase == DFPrivateSimulatorTouchPhaseMoved;
        DFIndigoMessage *message = DFCreateIndigoTouchMessage(CGPointMake(clampedX, clampedY), displaySize, touchDown, &dispatchError);
        if (message == NULL) {
            return;
        }

        NSError *messageError = nil;
        if (!DFSendHIDMessage(self->_hidClient, (IndigoHIDMessage *)message, YES, &messageError)) {
            dispatchError = messageError ?: DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit rejected the Indigo HID touch packet."
            );
            return;
        }

        if (phase != DFPrivateSimulatorTouchPhaseMoved) {
            DFLog(@"Sending %@ Indigo HID touch at pixel (%.1f, %.1f) ratio (%.4f, %.4f) within %.0fx%.0f", phaseLabel, point.x, point.y, clampedX, clampedY, displaySize.width, displaySize.height);
        }

        self->_lastTouchPoint = point;
        self->_hasLastTouchPoint = YES;
        if (phase == DFPrivateSimulatorTouchPhaseEnded || phase == DFPrivateSimulatorTouchPhaseCancelled) {
            self->_lastTouchPoint = CGPointZero;
            self->_hasLastTouchPoint = NO;
        }

        success = YES;
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    if (!success && error != NULL) {
        *error = dispatchError;
    }

    return success;
}

- (BOOL)sendKeyCode:(uint16_t)keyCode
          modifiers:(NSUInteger)modifiers
              error:(NSError * _Nullable __autoreleasing *)error {
    __block BOOL success = NO;
    __block NSError *dispatchError = nil;

    dispatch_block_t work = ^{
        if (self->_hidClient == nil) {
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not provide a headless HID client for keyboard input."
            );
            return;
        }

        static const struct {
            NSUInteger mask;
            uint16_t keyCode;
        } modifierMap[] = {
            { DFKeyboardModifierCapsLock, 57 },
            { DFKeyboardModifierControl, 59 },
            { DFKeyboardModifierOption, 58 },
            { DFKeyboardModifierShift, 56 },
            { DFKeyboardModifierCommand, 55 },
            { DFKeyboardModifierFunction, 63 },
        };

        NSMutableArray<NSNumber *> *modifierKeyCodes = [NSMutableArray array];
        for (NSUInteger index = 0; index < sizeof(modifierMap) / sizeof(modifierMap[0]); index++) {
            if ((modifiers & modifierMap[index].mask) != 0) {
                [modifierKeyCodes addObject:@(modifierMap[index].keyCode)];
            }
        }

        NSError *messageError = nil;
        for (NSNumber *modifierKeyCode in modifierKeyCodes) {
            if (!DFSendSingleKeyboardEvent(self->_hidClient, modifierKeyCode.unsignedShortValue, YES, &messageError)) {
                dispatchError = messageError;
                return;
            }
        }

        if (!DFSendSingleKeyboardEvent(self->_hidClient, keyCode, YES, &messageError)) {
            dispatchError = messageError;
            return;
        }

        if (!DFSendSingleKeyboardEvent(self->_hidClient, keyCode, NO, &messageError)) {
            dispatchError = messageError;
            return;
        }

        for (NSNumber *modifierKeyCode in [modifierKeyCodes reverseObjectEnumerator]) {
            if (!DFSendSingleKeyboardEvent(self->_hidClient, modifierKeyCode.unsignedShortValue, NO, &messageError)) {
                dispatchError = messageError;
                return;
            }
        }

        DFLog(@"Sending keyboard HID keyCode %u with modifiers 0x%lx", keyCode, (unsigned long)modifiers);
        success = YES;
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    if (!success && error != NULL) {
        *error = dispatchError;
    }

    return success;
}

- (BOOL)sendKeyEvent:(NSEvent *)event
               error:(NSError * _Nullable __autoreleasing *)error {
    __block BOOL success = NO;
    __block NSError *dispatchError = nil;

    dispatch_block_t work = ^{
        if (self->_hidClient == nil) {
            dispatchError = DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit did not provide a headless HID client for keyboard input."
            );
            return;
        }

        NSError *messageError = nil;
        IndigoHIDMessage *message = DFCreateKeyboardMessageFromEvent(event, &messageError);
        if (message == NULL) {
            dispatchError = messageError;
            return;
        }

        if (!DFSendHIDMessage(self->_hidClient, message, NO, &messageError)) {
            dispatchError = messageError ?: DFMakeError(
                DFPrivateSimulatorErrorCodeTouchDispatchFailed,
                @"SimulatorKit rejected the NSEvent keyboard HID packet."
            );
            return;
        }

        DFLog(@"Sending NSEvent keyboard HID type=%ld keyCode=%hu modifiers=0x%llx", (long)event.type, event.keyCode, event.modifierFlags);
        success = YES;
    };

    if (dispatch_get_specific(DFPrivateSimulatorCallbackQueueKey) != NULL) {
        work();
    } else {
        dispatch_sync(_callbackQueue, work);
    }

    if (!success && error != NULL) {
        *error = dispatchError;
    }

    return success;
}

@end
