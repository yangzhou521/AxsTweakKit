//
//  AxsDualSliceTweak.m —— 「一站一槽」（Per-Site Original Slot）模板
//
//  这是可复制的最小骨架，演示三件事：
//   1. 站点写法：每个 (类, 选择器) 站点各有自己的静态原 IMP 槽和自己的包装函数
//      （R1 一站一槽），并且只在类「自己声明」了该方法时才挂站
//      （R2 声明者才挂 / Declared-Owner Install）。
//   2. 加载时写一条外部读得到的诊断（版本 / 站点数 / 装了哪些类）：装完靠它判断
//      「是没注入」还是「只是没重启进程」。
//   3. 开关从目标 App 的偏好域读，默认关闭；默认值永不写盘，关掉就是原行为。
//
//  这里示范挂的是 -[UIView setUserInteractionEnabled:]：包装函数原样转发、不改任何行为，
//  它的唯一用处是证明「注入成功、站点装上了」。换成你自己的类和方法即可；多站点的宏表写法
//  照抄 NotesReadOnly/Sources/NotesReadOnly.m 的
//  AXS_FOR_EACH_EDITOR_CLASS / AXS_DEFINE_EDITOR_SITES / AXS_INSTALL_EDITOR_SITES。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>

// ── 改这里 ──────────────────────────────────────────────────────────────
// 目标 App 的 bundle id：必须与 Support/<PRODUCT>.plist 的 Filter/Bundles 一致。
// 它同时是偏好域——沙箱里只有目标 App 自己的域写得进去，`icli prefs read <它> …` 才读得到。
static NSString *const AxsDualSliceTargetBundle = @"com.apple.springboard";
// 与 scripts/build-dualslice.sh 的 VERSION 保持一致。
static NSString *const AxsDualSliceVersion = @"1.0.0";
// ───────────────────────────────────────────────────────────────────────

// 键名：面板（PreferenceLoader 的 defaults 域）与这里必须一致。
static NSString *const AxsDualSliceEnabledKey = @"AxsDualSliceEnabled";
static NSString *const AxsDualSliceDiagnosticsKey = @"AxsDualSliceDiagnostics";

static BOOL sEnabled = NO;
static NSUInteger sSiteCount = 0;
static NSMutableArray<NSString *> *sHookedClasses = nil;

static os_log_t AxsDualSliceLogHandle(void) {
    static os_log_t handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.example.axsdualslice", "tweak");
    });
    return handle;
}

// ── 读开关 ──────────────────────────────────────────────────────────────
// 只读，不写默认值：键不存在 => NO => 原行为。
static BOOL AxsDualSliceReadEnabled(void) {
    Boolean ok = false;
    CFStringRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)AxsDualSliceEnabledKey,
                                                 (__bridge CFStringRef)AxsDualSliceTargetBundle);
    if (value == NULL) {
        return NO;
    }
    BOOL enabled = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
        ok = true;
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        enabled = [(__bridge NSNumber *)value boolValue];
        ok = true;
    } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
        enabled = [(__bridge NSString *)value boolValue];
        ok = true;
    }
    CFRelease(value);
    (void)ok;
    return enabled;
}

// ── 诊断：装完靠它判断有没有注入 ────────────────────────────────────────
static void AxsDualSliceWriteDiagnostics(void) {
    NSString *classes = sHookedClasses.count ? [sHookedClasses componentsJoinedByString:@","] : @"-";
    NSString *text = [NSString stringWithFormat:@"v%@;hooks=%lu;classes=%@;enabled=%d",
                      AxsDualSliceVersion, (unsigned long)sSiteCount, classes, sEnabled ? 1 : 0];

    CFPreferencesSetAppValue((__bridge CFStringRef)AxsDualSliceDiagnosticsKey,
                             (__bridge CFStringRef)text,
                             (__bridge CFStringRef)AxsDualSliceTargetBundle);
    CFPreferencesAppSynchronize((__bridge CFStringRef)AxsDualSliceTargetBundle);

    // 第二通道（尽力而为）：目标进程的 Documents/ 下同名文件。
    // SpringBoard 这类进程的 NSHomeDirectory() 不是自己的容器，写不进去很正常——主通道是上面的偏好域。
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
                      @"Documents/AxsDualSliceDiagnostics.txt"];
    [[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];

    os_log(AxsDualSliceLogHandle(), "AXS_DUALSLICE_LOADED %{public}s", text.UTF8String);
}

// ── R2 声明者才挂：类自己声明了该方法（不是从父类继承来的）才挂站 ────────
static BOOL AxsClassDeclaresMethod(Class cls, SEL sel) {
    if (cls == Nil || sel == NULL) {
        return NO;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    if (methods != NULL) {
        free(methods);
    }
    return found;
}

// ── R1 一站一槽：这一站有自己的静态原 IMP 槽和自己的包装函数 ─────────────
static IMP axsSetUserInteractionEnabledOriginal = NULL;

static void axsSetUserInteractionEnabledHook(id self, SEL _cmd, BOOL enabled) {
    IMP original = axsSetUserInteractionEnabledOriginal;   // 用本槽，绝不按 self 的类去查表
    if (original == NULL) {
        return;                                            // 没拿到原实现就什么都不做，别自己当原实现
    }
    if (sEnabled) {
        // 想要的行为写在这里。模板什么都不做，只做一次记录，证明站点真的被调到。
        os_log(AxsDualSliceLogHandle(), "AXS_DUALSLICE_SITE fired %{public}@", NSStringFromClass([self class]));
    }
    ((void (*)(id, SEL, BOOL))original)(self, _cmd, enabled);   // 原样转发
}

static void AxsDualSliceInstallSites(void) {
    Class cls = NSClassFromString(@"UIView");
    SEL sel = sel_registerName("setUserInteractionEnabled:");
    if (!AxsClassDeclaresMethod(cls, sel)) {
        return;                                            // 没声明就不挂（R2）
    }
    if (axsSetUserInteractionEnabledOriginal != NULL) {
        return;                                            // 已经挂过
    }
    MSHookMessageEx(cls, sel, (IMP)axsSetUserInteractionEnabledHook,
                    &axsSetUserInteractionEnabledOriginal);
    sSiteCount++;
    [sHookedClasses addObject:NSStringFromClass(cls)];
}

__attribute__((constructor))
static void AxsDualSliceInitialize(void) {
    sHookedClasses = [NSMutableArray array];
    sEnabled = AxsDualSliceReadEnabled();
    AxsDualSliceInstallSites();
    AxsDualSliceWriteDiagnostics();
}
