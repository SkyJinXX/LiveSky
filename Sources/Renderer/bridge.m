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
// exported symbol name; every opaque Swift value is checked for size, metadata kind and field
// offsets before it is written. Any mismatch ends the process cleanly with a status line instead
// of touching memory, so an unverified macOS version fails safely.
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
static uint8_t location[160], gradient[104], animation[416], view[48];
static double sunElevation = NAN, moonPhase = NAN;
static const char *locationMeta = "$s11WeatherCore8LocationVMa";
static const char *animationMeta = "$s9WeatherUI23BackgroundAnimationDataO5ModelVMa";
static const char *gradientMeta = "$s9WeatherUI21SkyBackgroundGradientVMa";
static const char *optionsMeta = "$s9WeatherUI0A26ConditionBackgroundOptionsVMa";

enum { KindStruct = 0x200, KindEnum = 0x201, KindOptional = 0x202 };

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
static void check(const char *name, size_t size, const uint32_t *offsets, unsigned count) {
    const uintptr_t *type = metadata(name);
    if (type[0] != KindStruct) failf("KIND MISMATCH", "%s: expected struct metadata, found kind 0x%lx", name, (unsigned long)type[0]);
    size_t expected = size;
    if (simulateIncompatible) { expected += 1; simulateIncompatible = 0; }
    size_t actual = witness(type)[8];
    if (actual != expected) failf("SIZE MISMATCH", "%s: expected %zu bytes, found %zu", name, expected, actual);
    if (count) {
        const uint8_t *descriptor = (void *)type[1];
        if (!descriptor) failf("FIELD MISMATCH", "%s: missing type descriptor", name);
        uint32_t fields = *(const uint32_t *)(descriptor + 20);
        uint32_t vector = *(const uint32_t *)(descriptor + 24);
        if (fields != count || memcmp(type + vector, offsets, count * 4)) {
            char found[256] = "", expectedText[256] = "";
            const uint32_t *actualOffsets = (const uint32_t *)(type + vector);
            for (unsigned i = 0; i < count && i < 24; i++) {
                size_t used = strlen(expectedText);
                snprintf(expectedText + used, sizeof expectedText - used, "%s%u", i ? "," : "", offsets[i]);
            }
            for (unsigned i = 0; fields == count && i < fields && i < 24; i++) {
                size_t used = strlen(found);
                snprintf(found + used, sizeof found - used, "%s%u", i ? "," : "", actualOffsets[i]);
            }
            failf("FIELD MISMATCH", "%s: expected %u fields at [%s], found %u fields%s%s%s", name, count, expectedText,
                  fields, fields == count ? " at [" : "", fields == count ? found : "", fields == count ? "]" : "");
        }
    }
}
static void checkMaximumSize(const char *name, size_t maximum) {
    const uintptr_t *type = metadata(name);
    size_t actual = witness(type)[8];
    if (actual > maximum) failf("SIZE MISMATCH", "%s: %zu bytes exceeds the %zu-byte buffer", name, actual, maximum);
}
static void copyValue(void *dst, const void *src, const char *metaName) {
    const uintptr_t *type = metadata(metaName);
    ((void *(*)(void *, const void *, const void *))witness(type)[2])(dst, src, type);
}
static void none(void *dst, const char *metaName) {
    const uintptr_t *type = metadata(metaName);
    ((void (*)(void *, unsigned, unsigned, const void *))witness(type)[7])(dst, 1, 1, type);
}
static void enumCase(void *dst, const char *metaName, const char *caseName) {
    const uintptr_t *type = metadata(metaName);
    if (type[0] != KindEnum && type[0] != KindOptional)
        failf("KIND MISMATCH", "%s: expected enum metadata, found kind 0x%lx", metaName, (unsigned long)type[0]);
    unsigned tag = *(const unsigned *)symbol(caseName);
    ((void (*)(void *, unsigned, const void *))witness(type)[13])(dst, tag, type);
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

#pragma mark - Rendering

void weather_frame_prepare(uint8_t condition, const void *emptyArray, double date, double cloudCover, double windSpeed, const void *locationValue, double width, double height, double sunrise, double sunset) {
    setbuf(stderr, NULL);
    livesky_stage("loading WeatherUI");
    handle = dlopen("/System/iOSSupport/System/Library/PrivateFrameworks/WeatherUI.framework/WeatherUI", RTLD_NOW | RTLD_GLOBAL);
    if (!handle) failf("DLOPEN", "%s", dlerror());

    livesky_stage("checking WeatherUI layouts");
    check(locationMeta, 144, (uint32_t[]){0,48,64,80,96,112,128}, 7);
    check("$s11WeatherCore8LocationV10IdentifierVMa",48,(uint32_t[]){0,16,32},3);
    check(animationMeta, 410, (uint32_t[]){0,144,152,160,176,184,192,208,288,377,384,400,409}, 13);
    check(gradientMeta, 104, (uint32_t[]){0,32,64,96}, 4);
    check(optionsMeta, 89, (uint32_t[]){0,8,9,16,32,33,34,40,72,80}, 10);
    check("$s9WeatherUI0A7VFXViewVMa", 42, (uint32_t[]){0,16,41}, 3);
    check("$s9WeatherUI0A12VFXViewModelVMa",25,(uint32_t[]){0,8,16,24},4);
    check("$s9WeatherUI14VFXLoadRequestVMa",976,(uint32_t[]){0,8,424,840,944,945,952},7);
    check("$s9WeatherUI9ElevationVMa", 9, (uint32_t[]){0,8}, 2);
    check("$s9WeatherUI0A22ConditionGradientModelVMa", 33, (uint32_t[]){0,8,17,18,24,32}, 6);
    check("$s9WeatherUI18BackgroundMoonDataVMa",80,(uint32_t[]){0,8,24,40,48,56,64},7);
    checkMaximumSize("$s9WeatherUI20CollisionViewMetricsVMa", 63);
    if (simulateCrash) {
        livesky_stage("simulated crash");
        raise(SIGSEGV);
    }

    livesky_stage("locating");
    copyValue(location, locationValue, locationMeta);

    livesky_stage("astronomy");
    uint8_t elevation[16]={0};
    SwiftCall astronomy={.result=elevation,.x={(uintptr_t)location,(uintptr_t)&date}};
    invoke(symbol("$s9WeatherUI10GeoHandlerV12getElevation3for2onAA0F0V0A4Core8LocationV_10Foundation4DateVtFZ"), &astronomy);
    double degrees=0; memcpy(&degrees,elevation,8);
    if (!isfinite(degrees) || degrees < -90.5 || degrees > 90.5) failf("ASTRONOMY", "implausible sun elevation %f", degrees);
    sunElevation = degrees;
    BOOL daytime=degrees > 0;
    fprintf(stderr,"ASTRONOMY sunElevation=%f isPM=%u\n",degrees,elevation[8]);

    livesky_stage("sky gradient");
    void *gm = construct("$s9WeatherUI0A24ConditionGradientManagerCMa", "$s9WeatherUI0A24ConditionGradientManagerCACycfC", NULL, NULL);
    uint8_t gmInput[40] = {0};
    gmInput[0] = condition;
    memcpy(gmInput+8,elevation,9);
    gmInput[17] = daytime;
    putDouble(gmInput,24,cloudCover);
    enumCase(gmInput+18, "$s9WeatherUI0A22ConditionGradientModelV16AnimationContextOMa",
        "$s9WeatherUI0A22ConditionGradientModelV16AnimationContextO3vfxyA2EmFWC");
    enumCase(gmInput+18, "$s9WeatherUI0A22ConditionGradientModelV19PresentationContextOMa",
        "$s9WeatherUI0A22ConditionGradientModelV19PresentationContextO10fullScreenyAeC09AnimationG0OcAEmFWC");
    enumCase(gmInput+32, "$s9WeatherUI17CloudAltitudeKindOMa", "$s9WeatherUI17CloudAltitudeKindO3lowyA2CmFWC");
    SwiftCall gc = {.self=gm, .result=gradient, .x={(uintptr_t)gmInput}};
    invoke(symbol("$s9WeatherUI0A24ConditionGradientManagerC4load3forAA013SkyBackgroundD0VAA0acD5ModelV_tF"), &gc);
    fprintf(stderr, "GRADIENT ready\n");

    livesky_stage("animation model");
    copyValue(animation, location, locationMeta);
    putDouble(animation,144,date);
    animation[152]=condition;
    putPointer(animation,160,(__bridge_retained void *)[NSUnitSpeed metersPerSecond]);
    putDouble(animation,168,windSpeed);
    putDouble(animation,176,cloudCover);
    enumCase(animation+184, "$s9WeatherUI17CloudAltitudeKindOMa", "$s9WeatherUI17CloudAltitudeKindO3lowyA2CmFWC");
    memcpy(animation+192,elevation,9);

    livesky_stage("moon");
    void *moon=construct("$s9WeatherUI16MoonDataProviderCMa","$s9WeatherUI16MoonDataProviderCACycfC",NULL,NULL);
    double latitude=0,longitude=0;
    memcpy(&latitude,location+32,8); memcpy(&longitude,location+40,8);
    SwiftCall lunar={.self=moon,.result=animation+208,.x={(uintptr_t)&date,(uintptr_t)(location+48)},.d={latitude,longitude}};
    invoke(symbol("$s9WeatherUI16MoonDataProviderC017weatherBackgroundcD03for8timeZone10coordinateAA0gcD0VSg10Foundation4DateV_AK04TimeJ0VSo22CLLocationCoordinate2DVtF"),&lunar);
    const uintptr_t *moonType=metadata("$s9WeatherUI18BackgroundMoonDataVMa");
    unsigned moonTag=((unsigned (*)(const void *,unsigned,const void *))witness(moonType)[6])(animation+208,1,moonType);
    double moonElevation=0,moonPhaseAngle=0;
    memcpy(&moonElevation,animation+248,8); memcpy(&moonPhaseAngle,animation+256,8);
    if (moonTag == 0) {
        if (!isfinite(moonElevation) || moonElevation < -90.5 || moonElevation > 90.5 ||
            !isfinite(moonPhaseAngle) || moonPhaseAngle < -360.5 || moonPhaseAngle > 360.5)
            failf("MOON", "implausible moon data: elevation %f, phase angle %f", moonElevation, moonPhaseAngle);
        moonPhase = moonPhaseAngle;
    }
    fprintf(stderr,"MOON optionalTag=%u elevation=%f phaseAngle=%f\n",moonTag,moonElevation,moonPhaseAngle);

    livesky_stage("background options");
    uint8_t *options=animation+288;
    putPointer(options,0,emptyArray);
    enumCase(options+16,"$s9WeatherUI15VFXEffectViewIDOMa","$s9WeatherUI15VFXEffectViewIDO14locationVieweryA2CmFWC");
    enumCase(options+33,"$s9WeatherUI0A25ConditionBackgroundConfigV18CameraPositionTypeOMa","$s9WeatherUI0A25ConditionBackgroundConfigV18CameraPositionTypeO7defaultyA2EmFWC");
    enumCase(options+34,"$s9WeatherUI0A26ConditionBackgroundOptionsV15DisplayLocationOMa","$s9WeatherUI0A26ConditionBackgroundOptionsV15DisplayLocationO14locationVieweryA2EmFWC");
    putDouble(options,56,width); putDouble(options,64,height); putDouble(options,72,1.0);
    options[88]=1;
    animation[377]=daytime;
    if (isfinite(sunrise)) putDouble(animation,384,sunrise);
    else animation[392]=1;
    if (isfinite(sunset)) putDouble(animation,400,sunset);
    else animation[408]=1;

    livesky_stage("background request");
    void *config=construct("$s9WeatherUI0A29ConditionConfigurationManagerCMa","$s9WeatherUI0A29ConditionConfigurationManagerCACycfC",NULL,NULL);
    void *templates=construct("$s9WeatherUI23VFXSceneTemplateManagerCMa","$s9WeatherUI23VFXSceneTemplateManagerCACycfC",NULL,NULL);
    void *ce[5]={config,0,0,(void *)metadata("$s9WeatherUI0A29ConditionConfigurationManagerCMa"),symbol("$s9WeatherUI0A29ConditionConfigurationManagerCAA0acdE4TypeAAWP")};
    void *te[5]={templates,0,0,(void *)metadata("$s9WeatherUI23VFXSceneTemplateManagerCMa"),symbol("$s9WeatherUI23VFXSceneTemplateManagerCAA0cdE4TypeAAWP")};
    manager=construct("$s9WeatherUI0A26ConditionBackgroundManagerCMa","$s9WeatherUI0A26ConditionBackgroundManagerC013configurationE008templateE0AcA0ac13ConfigurationE4Type_p_AA016VFXSceneTemplateeI0_ptcfC",ce,te);
    observer=construct("$s9WeatherUI0A22VFXConditionBackgroundCMa","$s9WeatherUI0A22VFXConditionBackgroundCACycfC",NULL,NULL);

    uint8_t last[416]={0}, collision[64]={0}, request[976]={0}, target[8]={0}, dynamicType[8]={3};
    none(last, animationMeta);
    none(collision,"$s9WeatherUI20CollisionViewMetricsVMa");
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
    uint8_t model[32]={0};
    SwiftCall get={.self=observer,.result=model};
    invoke(symbol("$s9WeatherUI0A22VFXConditionBackgroundC21backgroundEffectModelAA0a7VFXViewG0VSgvg"),&get);
    fprintf(stderr,"VIEW MODEL effect=%p\n",*(void **)model);
    if (!*(void **)model) return NULL;
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
