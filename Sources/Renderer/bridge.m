#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>
#import "bridge.h"

// Ported from the live-sky research bridge (verified on macOS 15.7.7, 24G720, Apple Silicon).
// The renderer and its resources are Apple's WeatherUI. Function addresses are resolved by
// exported symbol name. No opaque Swift value is laid out by hand: WeatherCore builds the Location
// itself, buffers are sized from type metadata, and every stored property the bridge writes is
// found by name in the reflection metadata and checked for its type before it is written. Any
// mismatch ends the process cleanly with a status line instead of touching memory, so an
// unverified macOS version fails safely.
typedef struct {
    uintptr_t x[8]; double d[8]; void *result; void *self;
    uintptr_t returned[4]; double returnedD[4];
} SwiftCall;

__attribute__((naked)) static void invoke(void *fn, SwiftCall *call) {
    __asm__(
        "stp x19, x20, [sp, #-32]!\n"
        "stp x29, x30, [sp, #16]\n"
        "mov x19, x1\nmov x9, x0\n"
        "ldr x8, [x19, #128]\nldr x20, [x19, #136]\n"
        "ldp d0, d1, [x19, #64]\nldp d2, d3, [x19, #80]\n"
        "ldp d4, d5, [x19, #96]\nldp d6, d7, [x19, #112]\n"
        "ldp x0, x1, [x19]\nldp x2, x3, [x19, #16]\n"
        "ldp x4, x5, [x19, #32]\nldp x6, x7, [x19, #48]\n"
        "blr x9\n"
        "stp x0, x1, [x19, #144]\nstp x2, x3, [x19, #160]\n"
        "stp d0, d1, [x19, #176]\nstp d2, d3, [x19, #192]\n"
        "ldp x29, x30, [sp, #16]\nldp x19, x20, [sp], #32\nret\n"
    );
}

#pragma mark - Status reporting

static const char *volatile currentStage = "launch";
static int simulateIncompatible, simulateCrash;

static void writeAll(int fd, const char *text) {
    size_t length = 0;
    while (text[length]) length++;
    while (length > 0) {
        ssize_t written = write(fd, text, length);
        if (written <= 0) return;
        text += written; length -= (size_t)written;
    }
}

// Async-signal-safe: a crash inside WeatherUI must not produce a crash report or a
// "quit unexpectedly" dialog, so the handler only writes the status line and exits.
static void crashHandler(int signalNumber) {
    char digits[12], reversed[12];
    int value = signalNumber, count = 0, index = 0;
    do { reversed[count++] = (char)('0' + value % 10); value /= 10; } while (value && count < 11);
    while (count) digits[index++] = reversed[--count];
    digits[index] = 0;
    const char *stage = currentStage;
    writeAll(STDOUT_FILENO, "\nLIVESKY_STATUS {\"status\":\"crash\",\"signal\":");
    writeAll(STDOUT_FILENO, digits);
    writeAll(STDOUT_FILENO, ",\"stage\":\"");
    writeAll(STDOUT_FILENO, stage);
    writeAll(STDOUT_FILENO, "\"}\n");
    writeAll(STDERR_FILENO, "CRASH signal ");
    writeAll(STDERR_FILENO, digits);
    writeAll(STDERR_FILENO, " during ");
    writeAll(STDERR_FILENO, stage);
    writeAll(STDERR_FILENO, "\n");
    _exit(70);
}

void livesky_install_crash_handlers(void) {
    static char alternateStack[128 * 1024];
    stack_t stack = {.ss_sp = alternateStack, .ss_size = sizeof alternateStack, .ss_flags = 0};
    sigaltstack(&stack, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = crashHandler;
    action.sa_flags = SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGSYS};
    for (unsigned i = 0; i < sizeof signals / sizeof signals[0]; i++) sigaction(signals[i], &action, NULL);
}

void livesky_stage(const char *stage) {
    currentStage = stage;
    fprintf(stderr, "STAGE %s\n", stage);
}

void livesky_simulate(int incompatible, int crash) {
    simulateIncompatible = incompatible;
    simulateCrash = crash;
}

static NSString *text(const char *value) {
    return (value ? [NSString stringWithUTF8String:value] : nil) ?: @"";
}

void livesky_fail(const char *check, const char *detail) {
    NSDictionary *status = @{@"status": @"fail", @"check": text(check), @"detail": text(detail),
                             @"stage": text(currentStage)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
    fprintf(stderr, "FAIL %s: %s (stage %s)\n", check, detail, currentStage);
    fprintf(stdout, "\nLIVESKY_STATUS %.*s\n", (int)json.length, (const char *)json.bytes);
    fflush(stdout);
    fflush(stderr);
    _exit(20);
}

static void failf(const char *check, const char *format, ...) __attribute__((noreturn, format(printf, 2, 3)));
static void failf(const char *check, const char *format, ...) {
    char detail[1024];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(detail, sizeof detail, format, arguments);
    va_end(arguments);
    livesky_fail(check, detail);
}

#pragma mark - Invisible host window

// Mac Catalyst backs the UIWindow with an ordinary titled NSWindow. A transparent UIWindow alone
// still leaves that NSWindow (title bar, grey background) on screen while the sky renders, so the
// AppKit window is made fully transparent and click-through before it is first ordered in. It
// floats above normal windows so it is never occluded (occluded windows stop rendering), joins
// every Space so nothing switches Spaces, and stays out of Mission Control and window cycling.
static int concealWindows = 1;

static void conceal(id window) {
    if (!concealWindows || !window || ![window respondsToSelector:sel_registerName("setAlphaValue:")]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(window, sel_registerName("setAlphaValue:"), 0.0);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setIgnoresMouseEvents:"), YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setHasShadow:"), NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setExcludedFromWindowsMenu:"), YES);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(window, sel_registerName("setLevel:"), 3); // NSFloatingWindowLevel
    // canJoinAllSpaces | transient | ignoresCycle | fullScreenAuxiliary
    NSUInteger behavior = (1u << 0) | (1u << 3) | (1u << 6) | (1u << 8);
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(window, sel_registerName("setCollectionBehavior:"), behavior);
}

static IMP originalOrderWindow, originalOrderFront, originalMakeKeyAndOrderFront, originalOrderFrontRegardless;
static void concealedOrderWindow(id self, SEL _cmd, NSInteger place, NSInteger relativeTo) {
    conceal(self);
    ((void (*)(id, SEL, NSInteger, NSInteger))originalOrderWindow)(self, _cmd, place, relativeTo);
}
static void concealedOrderFront(id self, SEL _cmd, id sender) {
    conceal(self);
    ((void (*)(id, SEL, id))originalOrderFront)(self, _cmd, sender);
}
static void concealedMakeKeyAndOrderFront(id self, SEL _cmd, id sender) {
    conceal(self);
    ((void (*)(id, SEL, id))originalMakeKeyAndOrderFront)(self, _cmd, sender);
}
static void concealedOrderFrontRegardless(id self, SEL _cmd) {
    conceal(self);
    ((void (*)(id, SEL))originalOrderFrontRegardless)(self, _cmd);
}
static IMP hook(Class cls, const char *name, IMP replacement) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    return method ? method_setImplementation(method, replacement) : NULL;
}

int livesky_conceal_windows(int enabled) {
    concealWindows = enabled;
    Class windowClass = NSClassFromString(@"NSWindow");
    if (!enabled || !windowClass || originalOrderWindow) return windowClass != Nil;
    originalOrderWindow = hook(windowClass, "orderWindow:relativeTo:", (IMP)concealedOrderWindow);
    originalOrderFront = hook(windowClass, "orderFront:", (IMP)concealedOrderFront);
    originalMakeKeyAndOrderFront = hook(windowClass, "makeKeyAndOrderFront:", (IMP)concealedMakeKeyAndOrderFront);
    originalOrderFrontRegardless = hook(windowClass, "orderFrontRegardless", (IMP)concealedOrderFrontRegardless);
    return originalOrderWindow && originalOrderFront && originalMakeKeyAndOrderFront && originalOrderFrontRegardless;
}

void livesky_conceal_existing_windows(const char *moment) {
    Class applicationClass = NSClassFromString(@"NSApplication");
    if (!applicationClass) return;
    id application = ((id (*)(id, SEL))objc_msgSend)(applicationClass, sel_registerName("sharedApplication"));
    NSArray *windows = ((id (*)(id, SEL))objc_msgSend)(application, sel_registerName("windows"));
    for (id window in windows) {
        conceal(window);
        double alpha = ((double (*)(id, SEL))objc_msgSend)(window, sel_registerName("alphaValue"));
        BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("isVisible"));
        NSInteger level = ((NSInteger (*)(id, SEL))objc_msgSend)(window, sel_registerName("level"));
        fprintf(stderr, "HOST WINDOW %s: %s alpha=%.2f visible=%d level=%ld\n", moment,
                class_getName(object_getClass(window)), alpha, visible, (long)level);
    }
}

#pragma mark - Swift runtime helpers

static void *handle, *manager, *observer;
static uint8_t *gradient, *animation, *view;
static const uintptr_t *optionalDate, *optionalOrientation;
static double sunElevation = NAN, moonPhase = NAN;
static const char *locationMeta = "$s11WeatherCore8LocationVMa";
static const char *animationMeta = "$s9WeatherUI23BackgroundAnimationDataO5ModelVMa";
static const char *gradientMeta = "$s9WeatherUI21SkyBackgroundGradientVMa";
static const char *gradientModelMeta = "$s9WeatherUI0A22ConditionGradientModelVMa";
static const char *elevationMeta = "$s9WeatherUI9ElevationVMa";
static const char *moonMeta = "$s9WeatherUI18BackgroundMoonDataVMa";
static const char *viewMeta = "$s9WeatherUI0A7VFXViewVMa";
static const char *viewModelMeta = "$s9WeatherUI0A12VFXViewModelVMa";
static const char *requestMeta = "$s9WeatherUI14VFXLoadRequestVMa";
static const char *collisionMeta = "$s9WeatherUI20CollisionViewMetricsVMa";
// Location.init(id:name:timeZone:coordinate:lastRefreshDate:searchTitle:searchSubtitle:preciseName:secondaryName:)
static const char *locationInit = "$s11WeatherCore8LocationV2id4name8timeZone10coordinate15lastRefreshDate11searchTitle0L8Subtitle11preciseName09secondaryP0ACSS_SS10Foundation04TimeG0VSo22CLLocationCoordinate2DVAM0K0VSgSSSgA3UtcfC";

enum { KindStruct = 0x200, KindEnum = 0x201, KindOptional = 0x202 };

typedef struct { const char *data; uintptr_t length; } TypeName;
extern TypeName swift_getTypeName(const void *type, bool qualified) __attribute__((swiftcall));
extern const uintptr_t *swift_getTypeByMangledNameInContext(const char *name, size_t length, const void *context,
                                                           const void *const *arguments) __attribute__((swiftcall));

static void *symbol(const char *name) {
    void *p = dlsym(handle, name);
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    if (!p) failf("MISSING SYMBOL", "%s", name);
    return p;
}
static const uintptr_t *metadata(const char *name) {
    const uintptr_t *type = ((const uintptr_t *(*)(uintptr_t))symbol(name))(0);
    if (!type) failf("METADATA", "%s returned no type metadata", name);
    return type;
}
static const uintptr_t *witness(const uintptr_t *type) { return (const uintptr_t *)type[-1]; }
static size_t sizeOf(const uintptr_t *type) { return witness(type)[8]; }
// Zeroed storage for one value, with room to spare for an Optional's extra tag byte.
static uint8_t *allocate(const uintptr_t *type) {
    uint8_t *storage = calloc(1, witness(type)[9] + 16);
    if (!storage) failf("MEMORY", "could not allocate %zu bytes", (size_t)witness(type)[9] + 16);
    return storage;
}
static void copyValue(void *dst, const void *src, const uintptr_t *type) {
    ((void *(*)(void *, const void *, const void *))witness(type)[2])(dst, src, type);
}
static void none(void *dst, const uintptr_t *type) {
    ((void (*)(void *, unsigned, unsigned, const void *))witness(type)[7])(dst, 1, 1, type);
}
static void inject(void *dst, const uintptr_t *type, unsigned tag) {
    ((void (*)(void *, unsigned, const void *))witness(type)[13])(dst, tag, type);
}
static void enumCase(void *dst, const char *metaName, const char *caseName) {
    const uintptr_t *type = metadata(metaName);
    if (type[0] != KindEnum && type[0] != KindOptional)
        failf("KIND MISMATCH", "%s: expected enum metadata, found kind 0x%lx", metaName, (unsigned long)type[0]);
    inject(dst, type, *(const unsigned *)symbol(caseName));
}
static void *construct(const char *metaName, const char *initName, void *a, void *b) {
    SwiftCall c = {.self=(void *)metadata(metaName), .x={(uintptr_t)a, (uintptr_t)b}};
    invoke(symbol(initName), &c);
    fprintf(stderr, "INIT %s -> %p\n", metaName, (void *)c.returned[0]);
    if (!c.returned[0]) failf("CONSTRUCTOR", "%s returned nil", initName);
    return (void *)c.returned[0];
}
static void putDouble(void *p, size_t offset, double value) { memcpy((char *)p + offset, &value, 8); }
static void putPointer(void *p, size_t offset, const void *value) { memcpy((char *)p + offset, &value, 8); }
// A Date? written through the Optional's own value witnesses; NaN stands for nil.
static void putOptionalDate(void *p, size_t offset, double value) {
    if (isfinite(value)) putDouble(p, offset, value);
    inject((char *)p + offset, optionalDate, isfinite(value) ? 0 : 1);
}

#pragma mark - Layouts

// Stored properties the bridge writes or reads, found by name in WeatherUI's reflection metadata
// when it loads. Their offsets differ between systems: macOS 26 grew WeatherCore.Location by 32
// bytes, which moved every Model property after it.
static struct {
    struct { size_t location, date, conditionKind, windUnit, windValue, cloudCover, cloudKind, elevation, moonData,
                    options, isDayTime, sunrise, sunset; } model;
    struct { size_t locationIDs, effectViewID, cameraPositionType, displayLocation, windowBounds, displayScale,
                    orientation; } options;
    struct { size_t conditionKind, elevation, isDaylight, presentation, cloudCover, cloudKind; } gradientModel;
    struct { size_t degrees, isPM; } elevation;
    struct { size_t elevation, phaseAngle; } moonData;
    size_t effect;
} at;

typedef struct { size_t offset; const uintptr_t *type; } Field;

static const void *relative(const void *pointer) {
    int32_t offset = *(const int32_t *)pointer;
    return offset ? (const char *)pointer + offset : NULL;
}
// Mangled names in reflection metadata can embed symbolic references with 4- or 8-byte operands.
static size_t mangledLength(const char *name) {
    size_t length = 0;
    for (unsigned char c; (c = (unsigned char)name[length]);) length += c <= 0x17 ? 5 : c <= 0x1F ? 9 : 1;
    return length;
}
// Struct metadata whose stored properties are reached by name. With a count, the struct must have
// exactly that many, so every property the bridge leaves zeroed is one it has looked up and checked.
static const uintptr_t *structure(const uintptr_t *type, unsigned count) {
    TypeName name = swift_getTypeName(type, true);
    if (type[0] != KindStruct)
        failf("KIND MISMATCH", "%.*s: expected struct metadata, found kind 0x%lx", (int)name.length, name.data, (unsigned long)type[0]);
    unsigned fields = *(const uint32_t *)((const uint8_t *)type[1] + 20);
    if (count && simulateIncompatible) { count += 1; simulateIncompatible = 0; }
    if (count && fields != count)
        failf("FIELD MISMATCH", "%.*s: expected %u stored properties, found %u", (int)name.length, name.data, count, fields);
    return type;
}
// Offset and type of the stored property `name`, which must have the type `typeName` (NULL accepts any).
static Field field(const uintptr_t *type, const char *name, const char *typeName) {
    TypeName owner = swift_getTypeName(type, true);
    const uint8_t *descriptor = (const void *)type[1];
    const uint8_t *records = relative(descriptor + 16);
    uint32_t count = *(const uint32_t *)(descriptor + 20), vector = *(const uint32_t *)(descriptor + 24);
    if (!records) failf("FIELD MISMATCH", "%.*s has no reflection metadata", (int)owner.length, owner.data);
    uint16_t recordSize = *(const uint16_t *)(records + 10);
    for (uint32_t i = 0; i < count && i < *(const uint32_t *)(records + 12); i++) {
        const uint8_t *record = records + 16 + i * recordSize;
        const char *recordName = relative(record + 8), *mangled = relative(record + 4);
        if (!recordName || strcmp(recordName, name)) continue;
        // A generic struct such as Measurement<NSUnitSpeed> resolves its parameters from its metadata.
        const void *const *arguments = descriptor[0] & 0x80 ? (const void *const *)(type + 2) : NULL;
        const uintptr_t *found = mangled ? swift_getTypeByMangledNameInContext(mangled, mangledLength(mangled), descriptor, arguments) : NULL;
        TypeName actual = found ? swift_getTypeName(found, true) : (TypeName){"an unresolvable type", 20};
        if (!found || (typeName && (actual.length != strlen(typeName) || memcmp(actual.data, typeName, actual.length))))
            failf("FIELD MISMATCH", "%.*s.%s: expected %s, found %.*s", (int)owner.length, owner.data, name,
                  typeName ? typeName : "a resolvable type", (int)actual.length, actual.data);
        return (Field){((const uint32_t *)(type + vector))[i], found};
    }
    failf("FIELD MISMATCH", "%.*s has no stored property %s", (int)owner.length, owner.data, name);
}

const void *weather_frame_load(size_t locationCapacity) {
    setbuf(stderr, NULL);
    livesky_stage("loading WeatherUI");
    handle = dlopen("/System/iOSSupport/System/Library/PrivateFrameworks/WeatherUI.framework/WeatherUI", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) failf("DLOPEN", "%s", dlerror());

    livesky_stage("checking WeatherUI layouts");
    // WeatherCore's own initializer builds the Location, so only its size matters here.
    void *makeLocation = symbol(locationInit);
    const uintptr_t *location = structure(metadata(locationMeta), 0);
    if (sizeOf(location) > locationCapacity)
        failf("SIZE MISMATCH", "%s: %zu bytes exceeds the %zu-byte buffer", locationMeta, sizeOf(location), locationCapacity);

    const uintptr_t *model = structure(metadata(animationMeta), 13);
    at.model.location = field(model, "location", "WeatherCore.Location").offset;
    Field date = field(model, "date", "Foundation.Date");
    if (sizeOf(date.type) != 8) failf("SIZE MISMATCH", "Foundation.Date: expected 8 bytes, found %zu", sizeOf(date.type));
    at.model.date = date.offset;
    at.model.conditionKind = field(model, "conditionKind", "WeatherKit.WeatherCondition").offset;
    Field wind = field(model, "windSpeed", "Foundation.Measurement<__C.NSUnitSpeed>");
    const uintptr_t *measurement = structure(wind.type, 2);
    // `unit` has the generic parameter's type, which the check above already pinned to NSUnitSpeed.
    at.model.windUnit = wind.offset + field(measurement, "unit", NULL).offset;
    at.model.windValue = wind.offset + field(measurement, "value", "Swift.Double").offset;
    at.model.cloudCover = field(model, "cloudCover", "Swift.Double").offset;
    at.model.cloudKind = field(model, "cloudKind", "WeatherUI.CloudAltitudeKind").offset;
    at.model.elevation = field(model, "elevation", "WeatherUI.Elevation").offset;
    at.model.moonData = field(model, "moonData", "Swift.Optional<WeatherUI.BackgroundMoonData>").offset;
    Field options = field(model, "options", "WeatherUI.WeatherConditionBackgroundOptions");
    at.model.options = options.offset;
    at.model.isDayTime = field(model, "isDayTime", "Swift.Bool").offset;
    Field sunrise = field(model, "sunrise", "Swift.Optional<Foundation.Date>");
    at.model.sunrise = sunrise.offset;
    optionalDate = sunrise.type;
    at.model.sunset = field(model, "sunset", "Swift.Optional<Foundation.Date>").offset;
    field(model, "isReduceMotionEnabled", "Swift.Bool");

    const uintptr_t *background = structure(options.type, 10);
    at.options.locationIDs = field(background, "locationIDs", "Swift.Array<Swift.String>").offset;
    field(background, "applyMask", "Swift.Bool");
    field(background, "applyLegibilityScrim", "Swift.Bool");
    at.options.effectViewID = field(background, "effectViewID", "WeatherUI.VFXEffectViewID").offset;
    field(background, "canShowCollisionLayer", "Swift.Bool");
    at.options.cameraPositionType = field(background, "cameraPositionType", "WeatherUI.WeatherConditionBackgroundConfig.CameraPositionType").offset;
    at.options.displayLocation = field(background, "displayLocation", "WeatherUI.WeatherConditionBackgroundOptions.DisplayLocation").offset;
    at.options.windowBounds = field(background, "windowBounds", "__C.CGRect").offset;
    at.options.displayScale = field(background, "displayScale", "CoreGraphics.CGFloat").offset;
    Field orientation = field(background, "locationViewerOrientation", "Swift.Optional<__C.UIInterfaceOrientation>");
    at.options.orientation = orientation.offset;
    optionalOrientation = orientation.type;

    const uintptr_t *gradientModel = structure(metadata(gradientModelMeta), 6);
    at.gradientModel.conditionKind = field(gradientModel, "conditionKind", "WeatherKit.WeatherCondition").offset;
    at.gradientModel.elevation = field(gradientModel, "elevation", "WeatherUI.Elevation").offset;
    at.gradientModel.isDaylight = field(gradientModel, "isDaylight", "Swift.Bool").offset;
    at.gradientModel.presentation = field(gradientModel, "presentation", "WeatherUI.WeatherConditionGradientModel.PresentationContext").offset;
    at.gradientModel.cloudCover = field(gradientModel, "cloudCover", "Swift.Double").offset;
    at.gradientModel.cloudKind = field(gradientModel, "cloudKind", "WeatherUI.CloudAltitudeKind").offset;

    const uintptr_t *elevation = structure(metadata(elevationMeta), 2);
    at.elevation.degrees = field(elevation, "degrees", "CoreGraphics.CGFloat").offset;
    at.elevation.isPM = field(elevation, "isPM", "Swift.Bool").offset;

    // WeatherUI fills in the rest itself; the bridge only reads a few of their properties.
    const uintptr_t *moon = structure(metadata(moonMeta), 0);
    at.moonData.elevation = field(moon, "elevation", "Swift.Double").offset;
    at.moonData.phaseAngle = field(moon, "phaseAngle", "Swift.Double").offset;
    at.effect = field(structure(metadata(viewModelMeta), 0), "effect", "Swift.Optional<VFX.VFXEffect>").offset;
    structure(metadata(requestMeta), 0);
    structure(metadata(collisionMeta), 0);
    gradient = allocate(structure(metadata(gradientMeta), 0));
    view = allocate(structure(metadata(viewMeta), 0));
    animation = allocate(model);
    if (simulateCrash) {
        livesky_stage("simulated crash");
        raise(SIGSEGV);
    }
    return makeLocation;
}

#pragma mark - Rendering

void weather_frame_prepare(uint8_t condition, const void *emptyArray, double date, double cloudCover, double windSpeed,
                           const void *location, const void *timeZone, double latitude, double longitude,
                           double width, double height, double sunrise, double sunset) {
    livesky_stage("astronomy");
    const uintptr_t *elevationType = metadata(elevationMeta);
    uint8_t *elevation = allocate(elevationType);
    SwiftCall astronomy={.result=elevation,.x={(uintptr_t)location,(uintptr_t)&date}};
    invoke(symbol("$s9WeatherUI10GeoHandlerV12getElevation3for2onAA0F0V0A4Core8LocationV_10Foundation4DateVtFZ"), &astronomy);
    double degrees=0; memcpy(&degrees,elevation+at.elevation.degrees,8);
    if (!isfinite(degrees) || degrees < -90.5 || degrees > 90.5) failf("ASTRONOMY", "implausible sun elevation %f", degrees);
    sunElevation = degrees;
    BOOL daytime=degrees > 0;
    fprintf(stderr,"ASTRONOMY sunElevation=%f isPM=%u\n",degrees,elevation[at.elevation.isPM]);

    livesky_stage("sky gradient");
    void *gm = construct("$s9WeatherUI0A24ConditionGradientManagerCMa", "$s9WeatherUI0A24ConditionGradientManagerCACycfC", NULL, NULL);
    uint8_t *gmInput = allocate(metadata(gradientModelMeta));
    gmInput[at.gradientModel.conditionKind] = condition;
    copyValue(gmInput+at.gradientModel.elevation,elevation,elevationType);
    gmInput[at.gradientModel.isDaylight] = daytime;
    putDouble(gmInput,at.gradientModel.cloudCover,cloudCover);
    enumCase(gmInput+at.gradientModel.presentation, "$s9WeatherUI0A22ConditionGradientModelV16AnimationContextOMa",
        "$s9WeatherUI0A22ConditionGradientModelV16AnimationContextO3vfxyA2EmFWC");
    enumCase(gmInput+at.gradientModel.presentation, "$s9WeatherUI0A22ConditionGradientModelV19PresentationContextOMa",
        "$s9WeatherUI0A22ConditionGradientModelV19PresentationContextO10fullScreenyAeC09AnimationG0OcAEmFWC");
    enumCase(gmInput+at.gradientModel.cloudKind, "$s9WeatherUI17CloudAltitudeKindOMa", "$s9WeatherUI17CloudAltitudeKindO3lowyA2CmFWC");
    SwiftCall gc = {.self=gm, .result=gradient, .x={(uintptr_t)gmInput}};
    invoke(symbol("$s9WeatherUI0A24ConditionGradientManagerC4load3forAA013SkyBackgroundD0VAA0acD5ModelV_tF"), &gc);
    fprintf(stderr, "GRADIENT ready\n");

    livesky_stage("animation model");
    copyValue(animation+at.model.location, location, metadata(locationMeta));
    putDouble(animation,at.model.date,date);
    animation[at.model.conditionKind]=condition;
    putPointer(animation,at.model.windUnit,(__bridge_retained void *)[NSUnitSpeed metersPerSecond]);
    putDouble(animation,at.model.windValue,windSpeed);
    putDouble(animation,at.model.cloudCover,cloudCover);
    enumCase(animation+at.model.cloudKind, "$s9WeatherUI17CloudAltitudeKindOMa", "$s9WeatherUI17CloudAltitudeKindO3lowyA2CmFWC");
    copyValue(animation+at.model.elevation,elevation,elevationType);

    livesky_stage("moon");
    void *moon=construct("$s9WeatherUI16MoonDataProviderCMa","$s9WeatherUI16MoonDataProviderCACycfC",NULL,NULL);
    uint8_t *moonData=animation+at.model.moonData;
    SwiftCall lunar={.self=moon,.result=moonData,.x={(uintptr_t)&date,(uintptr_t)timeZone},.d={latitude,longitude}};
    invoke(symbol("$s9WeatherUI16MoonDataProviderC017weatherBackgroundcD03for8timeZone10coordinateAA0gcD0VSg10Foundation4DateV_AK04TimeJ0VSo22CLLocationCoordinate2DVtF"),&lunar);
    const uintptr_t *moonType=metadata(moonMeta);
    unsigned moonTag=((unsigned (*)(const void *,unsigned,const void *))witness(moonType)[6])(moonData,1,moonType);
    double moonElevation=0,moonPhaseAngle=0;
    memcpy(&moonElevation,moonData+at.moonData.elevation,8); memcpy(&moonPhaseAngle,moonData+at.moonData.phaseAngle,8);
    if (moonTag == 0) {
        if (!isfinite(moonElevation) || moonElevation < -90.5 || moonElevation > 90.5 ||
            !isfinite(moonPhaseAngle) || moonPhaseAngle < -360.5 || moonPhaseAngle > 360.5)
            failf("MOON", "implausible moon data: elevation %f, phase angle %f", moonElevation, moonPhaseAngle);
        moonPhase = moonPhaseAngle;
    }
    fprintf(stderr,"MOON optionalTag=%u elevation=%f phaseAngle=%f\n",moonTag,moonElevation,moonPhaseAngle);

    livesky_stage("background options");
    uint8_t *options=animation+at.model.options;
    putPointer(options,at.options.locationIDs,emptyArray);
    enumCase(options+at.options.effectViewID,"$s9WeatherUI15VFXEffectViewIDOMa","$s9WeatherUI15VFXEffectViewIDO14locationVieweryA2CmFWC");
    enumCase(options+at.options.cameraPositionType,"$s9WeatherUI0A25ConditionBackgroundConfigV18CameraPositionTypeOMa","$s9WeatherUI0A25ConditionBackgroundConfigV18CameraPositionTypeO7defaultyA2EmFWC");
    enumCase(options+at.options.displayLocation,"$s9WeatherUI0A26ConditionBackgroundOptionsV15DisplayLocationOMa","$s9WeatherUI0A26ConditionBackgroundOptionsV15DisplayLocationO14locationVieweryA2EmFWC");
    // windowBounds is a CGRect at the origin; only its size is set.
    putDouble(options,at.options.windowBounds+16,width); putDouble(options,at.options.windowBounds+24,height);
    putDouble(options,at.options.displayScale,1.0);
    inject(options+at.options.orientation,optionalOrientation,1);
    animation[at.model.isDayTime]=daytime;
    putOptionalDate(animation,at.model.sunrise,sunrise);
    putOptionalDate(animation,at.model.sunset,sunset);

    livesky_stage("background request");
    void *config=construct("$s9WeatherUI0A29ConditionConfigurationManagerCMa","$s9WeatherUI0A29ConditionConfigurationManagerCACycfC",NULL,NULL);
    void *templates=construct("$s9WeatherUI23VFXSceneTemplateManagerCMa","$s9WeatherUI23VFXSceneTemplateManagerCACycfC",NULL,NULL);
    void *ce[5]={config,0,0,(void *)metadata("$s9WeatherUI0A29ConditionConfigurationManagerCMa"),symbol("$s9WeatherUI0A29ConditionConfigurationManagerCAA0acdE4TypeAAWP")};
    void *te[5]={templates,0,0,(void *)metadata("$s9WeatherUI23VFXSceneTemplateManagerCMa"),symbol("$s9WeatherUI23VFXSceneTemplateManagerCAA0cdE4TypeAAWP")};
    manager=construct("$s9WeatherUI0A26ConditionBackgroundManagerCMa","$s9WeatherUI0A26ConditionBackgroundManagerC013configurationE008templateE0AcA0ac13ConfigurationE4Type_p_AA016VFXSceneTemplateeI0_ptcfC",ce,te);
    observer=construct("$s9WeatherUI0A22VFXConditionBackgroundCMa","$s9WeatherUI0A22VFXConditionBackgroundCACycfC",NULL,NULL);

    const uintptr_t *modelType=metadata(animationMeta), *collisionType=metadata(collisionMeta);
    uint8_t *last=allocate(modelType), *collision=allocate(collisionType), *request=allocate(metadata(requestMeta));
    uint8_t target[8]={0}, dynamicType[8]={3};
    none(last, modelType);
    none(collision, collisionType);
    enumCase(target,"$s9WeatherUI21TargetWindowSizeClassOMa","$s9WeatherUI21TargetWindowSizeClassO16landscapeRegularyA2CmFWC");
    SwiftCall load={.result=request,.x={(uintptr_t)observer,(uintptr_t)last,(uintptr_t)animation,(uintptr_t)gradient,(uintptr_t)dynamicType,(uintptr_t)target,(uintptr_t)collision}};
    invoke(symbol("$s9WeatherUI14VFXLoadRequestV18backgroundObserver9lastModel5model8gradient15dynamicTypeSize012targetWindowM5Class20collisionViewMetricsAcA0A22VFXConditionBackgroundC_AA0U13AnimationDataO0H0VSgApA03SkyU8GradientV05SwiftB007DynamiclM0OAA06TargetomP0OAA09CollisionrS0VSgtcfC"),&load);
    SwiftCall foreground={.self=manager};
    invoke(symbol("$s9WeatherUI0A26ConditionBackgroundManagerC24sceneWillEnterForegroundyyF"),&foreground);
    SwiftCall add={.self=manager,.x={(uintptr_t)request}};
    invoke(symbol("$s9WeatherUI0A26ConditionBackgroundManagerC14addLoadRequestyyAA07VFXLoadH0VF"),&add);
    SwiftCall execute={.self=manager,.x={1}};
    invoke(symbol("$s9WeatherUI0A26ConditionBackgroundManagerC15executeRequests12forcePrepareySb_tF"),&execute);
    fprintf(stderr,"LOAD requested\n");
    livesky_stage("waiting for WeatherUI background");
}

int weather_frame_loaded(void) {
    SwiftCall c={.self=observer};
    invoke(symbol("$s9WeatherUI0A22VFXConditionBackgroundC8isLoadedSbvg"),&c);
    return c.returned[0] & 1;
}
const void *weather_frame_view(void) {
    livesky_stage("creating WeatherVFXView");
    uint8_t *model=allocate(metadata(viewModelMeta));
    SwiftCall get={.self=observer,.result=model};
    invoke(symbol("$s9WeatherUI0A22VFXConditionBackgroundC21backgroundEffectModelAA0a7VFXViewG0VSgvg"),&get);
    void *effect=*(void **)(model+at.effect);
    fprintf(stderr,"VIEW MODEL effect=%p\n",effect);
    if (!effect) return NULL;
    SwiftCall init={.result=view,.x={(uintptr_t)model,1}};
    invoke(symbol("$s9WeatherUI0A7VFXViewV5model24foregroundEffectsEnabledAcA0aC5ModelV_SbtcfC"),&init);
    SwiftCall play={.self=manager,.x={1}};
    invoke(symbol("$s9WeatherUI0A26ConditionBackgroundManagerC4playyySbF"),&play);
    return view;
}
const void *weather_frame_gradient(void) {
    static uintptr_t result;
    SwiftCall c={.self=gradient};
    invoke(symbol("$s9WeatherUI21SkyBackgroundGradientV8gradient05SwiftB00E0VyF"),&c);
    result=c.returned[0];
    return &result;
}
double weather_frame_sun_elevation(void) { return sunElevation; }
double weather_frame_moon_phase(void) { return moonPhase; }
