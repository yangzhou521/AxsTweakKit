//
//  NotesReadOnly.m — 「备忘录只读」注入插件
//
//  纯 Objective-C + MSHookMessageEx（没有 Logos / Theos 语法），由
//  scripts/build-notesreadonly.sh 在 GitHub Actions 上编成 arm64 + arm64e 双切片。
//  只注入 com.apple.mobilenotes 进程（见 NotesReadOnly/Support/NotesReadOnly.plist）。
//
//  行为：
//   * 右上角「•••」菜单里插一项「只读模式」（带勾选）；拿不到菜单时兜底加一个「只读」按钮。
//   * 开关存 com.apple.mobilenotes 域的 NotesReadOnlyEnabled（默认 NO：装完行为不变）。
//   * 锁定期间编辑器文本视图不可编辑，cut:/paste:/delete: 等编辑动作被挡，copy:/选择仍然可用。
//   * 每处状态变化写一条诊断到 NotesReadOnlyDiagnostics（外加备忘录容器里的一个文本文件和
//     os_log），这样从备忘录外面也能读到它是怎么工作的。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <string.h>
#import <substrate.h>

#pragma mark - 常量

static NSString *const AxsNotesReadOnlyVersion = @"1.0.8";
// 开关与诊断都写在 com.apple.mobilenotes 域（备忘录进程自己的域，icli prefs read 也能读）。
static NSString *const AxsNotesReadOnlyEnabledKey = @"NotesReadOnlyEnabled";
static NSString *const AxsNotesReadOnlyDiagnosticsKey = @"NotesReadOnlyDiagnostics";
static NSString *const AxsNotesReadOnlyActionIdentifier = @"com.unknown.notesreadonly.toggle";
static NSString *const AxsNotesReadOnlyActionTitle = @"只读模式";
static NSString *const AxsNotesReadOnlyBarTitle = @"只读";
static const NSInteger AxsNotesReadOnlyBarTag = 7411;

static os_log_t AxsNotesReadOnlyLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.unknown.notesreadonly", "tweak");
    });
    return log;
}

#pragma mark - 状态

static BOOL sLocked = NO;                 // = NotesReadOnlyEnabled
static NSString *sMenuPath = nil;          // none / item（注入「•••」菜单）/ bar（兜底按钮）
static NSString *sBarSummary = nil;        // 走兜底时记录的导航条实况
static NSString *sLastDiagnostics = nil;   // 诊断字符串去重
static NSUInteger sHookCount = 0;
static NSMutableArray<NSString *> *sEditorClasses = nil;
static BOOL sInjecting = NO;               // 菜单注入重入保护

static void AxsNotesReadOnlySetLocked(BOOL locked);
static void AxsNotesReadOnlyInstallEditorHooks(void);
static void AxsNotesReadOnlyWriteDiagnostics(void);
static void AxsNotesReadOnlyRefreshMenus(void);
static void AxsNotesReadOnlyApplyLock(void);

#pragma mark - 原 IMP 表

// 同一个选择器会挂在多个类上（ICTextView / NoteHTMLEditorView / UITextView…），
// 每个类被 MSHookMessageEx 换下来的原 IMP 都不同，调用原实现前要按 (类, 选择器) 找回来。
#define AxsNotesReadOnlyMaxOriginals 64

typedef struct AxsNotesReadOnlyOriginal {
    Class cls;
    SEL sel;
    IMP imp;
} AxsNotesReadOnlyOriginal;

static AxsNotesReadOnlyOriginal sOriginals[AxsNotesReadOnlyMaxOriginals];
static size_t sOriginalCount = 0;
static os_unfair_lock sOriginalsLock = OS_UNFAIR_LOCK_INIT;

static IMP AxsNotesReadOnlyOriginalIMP(id self, SEL cmd) {
    if (self == nil || cmd == NULL) {
        return NULL;
    }

    AxsNotesReadOnlyOriginal snapshot[AxsNotesReadOnlyMaxOriginals];
    size_t count = 0;
    os_unfair_lock_lock(&sOriginalsLock);
    count = sOriginalCount;
    if (count > 0) {
        memcpy(snapshot, sOriginals, count * sizeof(snapshot[0]));
    }
    os_unfair_lock_unlock(&sOriginalsLock);

    // 精确到类，再沿父类链找（挂的是父类时子类实例也会走到这里）。
    for (Class cls = object_getClass(self); cls != Nil; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; i < count; i++) {
            if (snapshot[i].sel == cmd && snapshot[i].cls == cls) {
                return snapshot[i].imp;
            }
        }
    }
    // 同选择器在别处的原 IMP（正常情况下几个类共用同一个实现）。
    for (size_t i = 0; i < count; i++) {
        if (snapshot[i].sel == cmd) {
            return snapshot[i].imp;
        }
    }
    return NULL;
}

static BOOL AxsNotesReadOnlyHook(Class cls, SEL sel, IMP hook) {
    if (cls == Nil || sel == NULL || hook == NULL) {
        return NO;
    }

    os_unfair_lock_lock(&sOriginalsLock);
    for (size_t i = 0; i < sOriginalCount; i++) {
        if (sOriginals[i].cls == cls && sOriginals[i].sel == sel) {
            os_unfair_lock_unlock(&sOriginalsLock);
            return NO;  // 已经挂过，不重复挂
        }
    }
    os_unfair_lock_unlock(&sOriginalsLock);

    if (class_getInstanceMethod(cls, sel) == NULL) {
        return NO;  // 这个类没有这个方法
    }

    IMP previous = NULL;
    MSHookMessageEx(cls, sel, hook, &previous);
    if (previous == NULL) {
        return NO;
    }

    os_unfair_lock_lock(&sOriginalsLock);
    if (sOriginalCount < AxsNotesReadOnlyMaxOriginals) {
        sOriginals[sOriginalCount++] = (AxsNotesReadOnlyOriginal){ cls, sel, previous };
    }
    os_unfair_lock_unlock(&sOriginalsLock);

    sHookCount += 1;
    return YES;
}

#pragma mark - 诊断

static NSString *AxsNotesReadOnlyDiagnosticsString(void) {
    NSString *classes = sEditorClasses.count > 0
        ? [sEditorClasses componentsJoinedByString:@","]
        : @"none";
    NSString *value = [NSString stringWithFormat:@"v%@;hooks=%lu;classes=%@;menu=%@;locked=%d",
                       AxsNotesReadOnlyVersion, (unsigned long)sHookCount, classes,
                       sMenuPath ?: @"none", sLocked ? 1 : 0];
    if (sBarSummary != nil) {
        value = [value stringByAppendingFormat:@";bar=%@", sBarSummary];
    }
    return value;
}

static void AxsNotesReadOnlyWriteDiagnostics(void) {
    NSString *value = AxsNotesReadOnlyDiagnosticsString();
    if ([value isEqualToString:sLastDiagnostics]) {
        return;  // 没变化就不写
    }
    sLastDiagnostics = value;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:value forKey:AxsNotesReadOnlyDiagnosticsKey];
    [defaults synchronize];

    // 第二条通道：备忘录自己的容器（沙盒内，不需要额外权限），路径也打进日志。
    NSString *path = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/NotesReadOnlyDiagnostics.txt"];
    [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    os_log(AxsNotesReadOnlyLog(), "diagnostics %{public}@ file=%{public}@", value, path);
}

static void AxsNotesReadOnlySetMenuPath(NSString *path) {
    if (path == nil || [path isEqualToString:sMenuPath ?: @""]) {
        return;
    }
    sMenuPath = path;
    os_log(AxsNotesReadOnlyLog(), "menu path=%{public}@ bar=%{public}@",
           path, sBarSummary ?: @"none");
}

#pragma mark - 窗口 / 视图

// 只在主线程用：拿所有窗口。
static NSArray<UIWindow *> *AxsNotesReadOnlyWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (![NSThread isMainThread]) {
        return windows;
    }

    UIApplication *application = [UIApplication sharedApplication];
    if (application == nil) {
        return windows;
    }

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [windows addObject:window];
        }
    }

    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in application.windows) {
            [windows addObject:window];
        }
#pragma clang diagnostic pop
    }
    return windows;
}

static BOOL AxsNotesReadOnlyIsEditorView(UIView *view) {
    if ([view isKindOfClass:[UITextView class]]) {
        return YES;
    }
    for (NSString *name in sEditorClasses) {
        Class cls = NSClassFromString(name);
        if (cls != Nil && [view isKindOfClass:cls]) {
            return YES;
        }
    }
    return NO;
}

static void AxsNotesReadOnlyApplyLockToView(UIView *view) {
    if (AxsNotesReadOnlyIsEditorView(view) &&
        [view respondsToSelector:@selector(setEditable:)]) {
        if (sLocked) {
            // 正在编辑就先让它交出第一响应者，再把可编辑性关掉。
            if ([view isFirstResponder]) {
                [view resignFirstResponder];
            }
            ((void (*)(id, SEL, BOOL))objc_msgSend)(view, @selector(setEditable:), NO);
        } else {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(view, @selector(setEditable:), YES);
        }
    }
    for (UIView *subview in view.subviews) {
        AxsNotesReadOnlyApplyLockToView(subview);
    }
}

static void AxsNotesReadOnlyApplyLock(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AxsNotesReadOnlyApplyLock();
        });
        return;
    }
    for (UIWindow *window in AxsNotesReadOnlyWindows()) {
        AxsNotesReadOnlyApplyLockToView(window);
    }
}

static BOOL AxsNotesReadOnlyViewContainsRightItem(UIView *view, UIBarButtonItem *item) {
    if ([view isKindOfClass:[UINavigationBar class]]) {
        UINavigationItem *topItem = ((UINavigationBar *)view).topItem;
        if (topItem != nil) {
            if (topItem.rightBarButtonItem == item) {
                return YES;
            }
            if ([topItem.rightBarButtonItems containsObject:item]) {
                return YES;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        if (AxsNotesReadOnlyViewContainsRightItem(subview, item)) {
            return YES;
        }
    }
    return NO;
}

// 这个 UIBarButtonItem 现在是不是某个导航条右上角那一项。
static BOOL AxsNotesReadOnlyIsRightBarButtonItem(UIBarButtonItem *item) {
    if (item == nil || ![NSThread isMainThread]) {
        return NO;
    }
    for (UIWindow *window in AxsNotesReadOnlyWindows()) {
        if (AxsNotesReadOnlyViewContainsRightItem(window, item)) {
            return YES;
        }
    }
    return NO;
}

static UINavigationBar *AxsNotesReadOnlyBarForItem(UIView *view, UINavigationItem *item) {
    if ([view isKindOfClass:[UINavigationBar class]] && ((UINavigationBar *)view).topItem == item) {
        return (UINavigationBar *)view;
    }
    for (UIView *subview in view.subviews) {
        UINavigationBar *found = AxsNotesReadOnlyBarForItem(subview, item);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static void AxsNotesReadOnlyCollectButtons(UIView *view, NSMutableArray<UIButton *> *buttons) {
    if ([view isKindOfClass:[UIButton class]]) {
        [buttons addObject:(UIButton *)view];
    }
    for (UIView *subview in view.subviews) {
        AxsNotesReadOnlyCollectButtons(subview, buttons);
    }
}

// 兜底路径的记录：导航条里每个 UIButton 的标题与 menu 情况。
static NSString *AxsNotesReadOnlyDescribeBar(UINavigationBar *bar) {
    if (bar == nil) {
        return @"none";
    }
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    AxsNotesReadOnlyCollectButtons(bar, buttons);

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIButton *button in buttons) {
        NSString *title = button.currentTitle;
        if (title.length == 0) {
            title = button.accessibilityLabel;
        }
        UIMenu *menu = button.menu;
        NSString *menuPart = menu != nil
            ? [NSString stringWithFormat:@"menu(%lu)", (unsigned long)menu.children.count]
            : @"nomenu";
        [parts addObject:[NSString stringWithFormat:@"%@=%@",
                          title.length > 0 ? title : @"?", menuPart]];
    }
    return [NSString stringWithFormat:@"%lu[%@]",
            (unsigned long)buttons.count, [parts componentsJoinedByString:@"|"]];
}

static void AxsNotesReadOnlyCollectRightItems(UIView *view, NSMutableArray<UIBarButtonItem *> *items) {
    if ([view isKindOfClass:[UINavigationBar class]]) {
        UINavigationItem *topItem = ((UINavigationBar *)view).topItem;
        if (topItem.rightBarButtonItem != nil) {
            [items addObject:topItem.rightBarButtonItem];
        }
        NSArray<UIBarButtonItem *> *rightItems = topItem.rightBarButtonItems;
        if (rightItems.count > 0) {
            [items addObjectsFromArray:rightItems];
        }
    }
    for (UIView *subview in view.subviews) {
        AxsNotesReadOnlyCollectRightItems(subview, items);
    }
}

#pragma mark - 菜单

static UIAction *AxsNotesReadOnlyMakeAction(void) {
    UIAction *action = [UIAction actionWithTitle:AxsNotesReadOnlyActionTitle
                                          image:nil
                                     identifier:AxsNotesReadOnlyActionIdentifier
                                        handler:^(UIAction *sender) {
        AxsNotesReadOnlySetLocked(!sLocked);
    }];
    action.state = sLocked ? UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

// 把我们的 UIAction 放进菜单末尾；已经插过就替换那一项（顺带刷新勾选状态），不重复叠加。
static UIMenu *AxsNotesReadOnlyInjectActionIntoMenu(UIMenu *menu) {
    if (menu == nil) {
        return nil;
    }
    NSArray<UIMenuElement *> *children = menu.children;
    if (children == nil) {
        children = @[];
    }

    NSMutableArray<UIMenuElement *> *updated =
        [NSMutableArray arrayWithCapacity:children.count + 1];
    BOOL replaced = NO;
    for (UIMenuElement *child in children) {
        // theos 的 UIKit 头里 UIMenuElement.identifier 没声明（运行时真的有），走运行时取值。
        NSString *identifier = nil;
        SEL identifierSelector = @selector(identifier);
        if ([child respondsToSelector:identifierSelector]) {
            identifier = ((id (*)(id, SEL))objc_msgSend)(child, identifierSelector);
        }
        if ([identifier isKindOfClass:[NSString class]] &&
            [identifier isEqualToString:AxsNotesReadOnlyActionIdentifier]) {
            if (!replaced) {
                [updated addObject:AxsNotesReadOnlyMakeAction()];
                replaced = YES;
            }
            continue;
        }
        [updated addObject:child];
    }
    if (!replaced) {
        [updated addObject:AxsNotesReadOnlyMakeAction()];
    }
    return [menu menuByReplacingChildren:updated];
}

static UIBarButtonItem *AxsNotesReadOnlyMakeBarButtonItem(void) {
    UIBarButtonItem *item =
        [[UIBarButtonItem alloc] initWithTitle:AxsNotesReadOnlyBarTitle
                                        style:UIBarButtonItemStylePlain
                                       target:nil
                                       action:nil];
    item.tag = AxsNotesReadOnlyBarTag;
    // 点「只读」弹一个只含我们那一项的菜单，勾选状态看得见。
    item.menu = [UIMenu menuWithTitle:@"" children:@[AxsNotesReadOnlyMakeAction()]];
    return item;
}

static BOOL AxsNotesReadOnlyContainsOwnBarItem(NSArray<UIBarButtonItem *> *items) {
    for (UIBarButtonItem *item in items) {
        if (item.tag == AxsNotesReadOnlyBarTag) {
            return YES;
        }
    }
    return NO;
}

// 设置导航项之后：把「只读模式」塞进右上角「•••」的菜单；塞不进去就自己加一个按钮。
static void AxsNotesReadOnlyInjectIntoNavigationItem(UINavigationItem *navItem) {
    if (navItem == nil || sInjecting) {
        return;
    }
    sInjecting = YES;

    // 走到这里说明 App 的 UI 已经起来，私有框架肯定加载完了，补挂编辑器钩子。
    AxsNotesReadOnlyInstallEditorHooks();

    NSArray<UIBarButtonItem *> *items = navItem.rightBarButtonItems;
    NSString *path = nil;

    if (items.count > 0) {
        UIBarButtonItem *menuItem = nil;
        for (UIBarButtonItem *item in items) {
            if (item.menu != nil) {
                menuItem = item;  // 最后一个带 menu 的：右上角「•••」
            }
        }

        if (menuItem != nil) {
            UIMenu *injected = AxsNotesReadOnlyInjectActionIntoMenu(menuItem.menu);
            if (injected != nil) {
                menuItem.menu = injected;
                path = @"item";
            }
        }

        if (path == nil) {
            // 兜底：右侧有按钮却没有 menu，就自己往右端加一个「只读」。
            if (!AxsNotesReadOnlyContainsOwnBarItem(items)) {
                NSMutableArray<UIBarButtonItem *> *newItems = [items mutableCopy];
                [newItems addObject:AxsNotesReadOnlyMakeBarButtonItem()];
                navItem.rightBarButtonItems = newItems;  // 走我们自己的 setter hook，重入被挡住
            }
            UINavigationBar *bar = nil;
            for (UIWindow *window in AxsNotesReadOnlyWindows()) {
                bar = AxsNotesReadOnlyBarForItem(window, navItem);
                if (bar != nil) {
                    break;
                }
            }
            sBarSummary = AxsNotesReadOnlyDescribeBar(bar);
            path = @"bar";
        }
    }

    sInjecting = NO;
    AxsNotesReadOnlySetMenuPath(path);
    AxsNotesReadOnlyWriteDiagnostics();
}

// 切换开关后把当前显示的菜单重建一遍，勾选状态立刻跟上。
static void AxsNotesReadOnlyRefreshMenus(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AxsNotesReadOnlyRefreshMenus();
        });
        return;
    }

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    for (UIWindow *window in AxsNotesReadOnlyWindows()) {
        AxsNotesReadOnlyCollectRightItems(window, items);
    }

    sInjecting = YES;
    for (UIBarButtonItem *item in items) {
        if (item.menu != nil) {
            item.menu = AxsNotesReadOnlyInjectActionIntoMenu(item.menu);
        }
    }
    sInjecting = NO;
}

#pragma mark - 导航条 hook

static void AxsNotesReadOnlyHookedSetRightBarButtonItemsAnimated(id self, SEL _cmd,
                                                                NSArray *items, BOOL animated) {
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, id, BOOL))original)(self, _cmd, items, animated);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

static void AxsNotesReadOnlyHookedSetRightBarButtonItems(id self, SEL _cmd, NSArray *items) {
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(self, _cmd, items);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

static void AxsNotesReadOnlyHookedSetRightBarButtonItemAnimated(id self, SEL _cmd,
                                                               UIBarButtonItem *item, BOOL animated) {
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, id, BOOL))original)(self, _cmd, item, animated);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

static void AxsNotesReadOnlyHookedSetRightBarButtonItem(id self, SEL _cmd, UIBarButtonItem *item) {
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(self, _cmd, item);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

// 备忘录常常先建按钮、之后才赋菜单：这条路径补上。
static void AxsNotesReadOnlyHookedSetMenu(id self, SEL _cmd, UIMenu *menu) {
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(self, _cmd, menu);
    }
    if (sInjecting) {
        return;
    }

    UIBarButtonItem *item = (UIBarButtonItem *)self;
    if (![item isKindOfClass:[UIBarButtonItem class]] || !AxsNotesReadOnlyIsRightBarButtonItem(item)) {
        return;  // 只补右上角那一项，别乱动别人的菜单
    }

    UIMenu *current = item.menu;
    if (current == nil) {
        return;
    }

    sInjecting = YES;
    item.menu = AxsNotesReadOnlyInjectActionIntoMenu(current);
    sInjecting = NO;

    AxsNotesReadOnlySetMenuPath(@"item");
    AxsNotesReadOnlyWriteDiagnostics();
}

static void AxsNotesReadOnlyInstallNavigationHooks(void) {
    Class navigationItem = NSClassFromString(@"UINavigationItem");
    Class barButtonItem = NSClassFromString(@"UIBarButtonItem");
    if (navigationItem == Nil || barButtonItem == Nil) {
        os_log_error(AxsNotesReadOnlyLog(), "UINavigationItem/UIBarButtonItem missing, menu injection skipped");
        return;
    }

    AxsNotesReadOnlyHook(navigationItem, sel_registerName("setRightBarButtonItems:animated:"),
                         (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItemsAnimated);
    AxsNotesReadOnlyHook(navigationItem, sel_registerName("setRightBarButtonItems:"),
                         (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItems);
    AxsNotesReadOnlyHook(navigationItem, sel_registerName("setRightBarButtonItem:animated:"),
                         (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItemAnimated);
    AxsNotesReadOnlyHook(navigationItem, sel_registerName("setRightBarButtonItem:"),
                         (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItem);
    AxsNotesReadOnlyHook(barButtonItem, sel_registerName("setMenu:"),
                         (IMP)AxsNotesReadOnlyHookedSetMenu);
}

#pragma mark - 只读执行 hook

// 只读期间仍然放行的动作（阅读相关）：复制、全选、查询、翻译、朗读。
static BOOL AxsNotesReadOnlyIsReadOnlySelector(SEL action) {
    if (action == NULL) {
        return NO;
    }
    const char *name = sel_getName(action);
    if (name == NULL) {
        return NO;
    }
    static const char *allowed[] = {
        "copy", "select", "lookup", "define", "translate", "share", "speak", "accessibility",
    };
    for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
        if (strncmp(name, allowed[i], strlen(allowed[i])) == 0) {
            return YES;
        }
    }
    return NO;
}

static void AxsNotesReadOnlyHookedSetEditable(id self, SEL _cmd, BOOL editable) {
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    if (original == NULL) {
        return;
    }
    ((void (*)(id, SEL, BOOL))original)(self, _cmd, sLocked ? NO : editable);
}

static BOOL AxsNotesReadOnlyHookedIsEditable(id self, SEL _cmd) {
    if (sLocked) {
        return NO;
    }
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;
}

static BOOL AxsNotesReadOnlyHookedCanBecomeFirstResponder(id self, SEL _cmd) {
    if (sLocked) {
        return NO;
    }
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;
}

static BOOL AxsNotesReadOnlyHookedBecomeFirstResponder(id self, SEL _cmd) {
    if (sLocked) {
        return NO;
    }
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;
}

static BOOL AxsNotesReadOnlyHookedCanPerformAction(id self, SEL _cmd, SEL action, id sender) {
    if (sLocked && !AxsNotesReadOnlyIsReadOnlySelector(action)) {
        return NO;
    }
    IMP original = AxsNotesReadOnlyOriginalIMP(self, _cmd);
    return original != NULL ? ((BOOL (*)(id, SEL, SEL, id))original)(self, _cmd, action, sender) : YES;
}

static NSArray<NSString *> *AxsNotesReadOnlyEditorClassNames(void) {
    // 头三个是备忘录自己的编辑器类（版本不同类名不同，谁在就挂谁）；
    // UITextView 兜底，保证任何版本的备忘录都能真的挡住输入。
    return @[ @"ICTextView", @"ICBaseTextView", @"NoteHTMLEditorView", @"UITextView" ];
}

// 幂等：类还不存在就跳过，下次（主队列 / 导航条 hook 里）再试。
static void AxsNotesReadOnlyInstallEditorHooks(void) {
    if (sEditorClasses == nil) {
        sEditorClasses = [NSMutableArray array];
    }

    for (NSString *name in AxsNotesReadOnlyEditorClassNames()) {
        if ([sEditorClasses containsObject:name]) {
            continue;
        }
        Class cls = NSClassFromString(name);
        if (cls == Nil) {
            continue;
        }

        BOOL any = NO;
        any |= AxsNotesReadOnlyHook(cls, @selector(setEditable:),
                                   (IMP)AxsNotesReadOnlyHookedSetEditable);
        any |= AxsNotesReadOnlyHook(cls, @selector(isEditable),
                                   (IMP)AxsNotesReadOnlyHookedIsEditable);
        any |= AxsNotesReadOnlyHook(cls, @selector(canBecomeFirstResponder),
                                   (IMP)AxsNotesReadOnlyHookedCanBecomeFirstResponder);
        any |= AxsNotesReadOnlyHook(cls, @selector(becomeFirstResponder),
                                   (IMP)AxsNotesReadOnlyHookedBecomeFirstResponder);
        any |= AxsNotesReadOnlyHook(cls, @selector(canPerformAction:withSender:),
                                   (IMP)AxsNotesReadOnlyHookedCanPerformAction);
        if (any) {
            [sEditorClasses addObject:name];
        }
    }
}

#pragma mark - 开关

static void AxsNotesReadOnlySetLocked(BOOL locked) {
    sLocked = locked;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:locked forKey:AxsNotesReadOnlyEnabledKey];
    [defaults synchronize];

    os_log(AxsNotesReadOnlyLog(), "toggled locked=%d", locked ? 1 : 0);

    if ([NSThread isMainThread]) {
        AxsNotesReadOnlyApplyLock();
        AxsNotesReadOnlyRefreshMenus();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            AxsNotesReadOnlyApplyLock();
            AxsNotesReadOnlyRefreshMenus();
        });
    }

    AxsNotesReadOnlyWriteDiagnostics();
}

#pragma mark - 启动

__attribute__((constructor)) static void AxsNotesReadOnlyInitialize(void) {
    @autoreleasepool {
        // 装完默认 NO：先读一次，钩子从第一帧起就按这个值工作。
        sLocked = [[NSUserDefaults standardUserDefaults] boolForKey:AxsNotesReadOnlyEnabledKey];

        AxsNotesReadOnlyInstallNavigationHooks();
        AxsNotesReadOnlyInstallEditorHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                // 这时候备忘录自己的框架肯定加载完了，补齐第一轮没找到的编辑器类。
                AxsNotesReadOnlyInstallEditorHooks();
                AxsNotesReadOnlyWriteDiagnostics();

                os_log(AxsNotesReadOnlyLog(),
                       "NotesReadOnly ready, version %{public}@, hooks %lu, menu=%{public}@",
                       AxsNotesReadOnlyVersion, (unsigned long)sHookCount,
                       sMenuPath ?: @"none");

                if (sLocked) {
                    AxsNotesReadOnlyApplyLock();
                }
            }
        });
    }
}
