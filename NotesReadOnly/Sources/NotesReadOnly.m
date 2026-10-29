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
#import <stdlib.h>
#import <string.h>
#import <substrate.h>

#pragma mark - 常量

static NSString *const AxsNotesReadOnlyVersion = @"1.0.9";
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

#pragma mark - 钩子站点

// 每个 (类, 选择器) 是一“站”，各有独立的包装函数和自己的原 IMP 槽。
//
// 1.0.8 用的是一张 (类, 选择器) → 原 IMP 的总表，1.0.9 把它拆成每站各自的槽，原因就是
// 那个闪退：同一个选择器挂在多个类上时，`-[ICTextView setEditable:]` 里再 `[super
// setEditable:]` 进到父类那一站的钩子，而 self 仍然是 ICTextView 实例，按 self 的类查总表
// 又查到 ICTextView 那一份原 IMP，于是 钩子 → 原 IMP → super → 钩子 … 无限递归，几帧就撑爆
// 栈（崩溃里 AxsNotesReadOnlyHookedSetEditable 与 -[ICTextView setEditable:] 交替上千层，
// 最后在栈保护区写坏）。每站只认自己的原 IMP，super 调用落到父类那一站，链路自然到底。
//
// 另外只挂“自己声明了这个方法”的类：继承来的方法由祖先那一站覆盖，同一个实现不会被挂两次。

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

typedef struct AxsHookSite {
    const char *className;
    const char *selectorName;
    IMP hook;
    IMP *slot;
} AxsHookSite;

// 挂一站。requireDeclared = YES 时只挂类自己实现的方法（多站同选择器必须这样）；
// NO 时连继承来的方法也挂，只用于“同一个选择器全局只有一站”的导航条钩子。
static BOOL AxsInstallSiteOnClass(Class cls, SEL sel, IMP hook, IMP *slot, BOOL requireDeclared) {
    if (cls == Nil || sel == NULL || hook == NULL || slot == NULL) {
        return NO;
    }
    if (*slot != NULL) {
        return NO;  // 这一站已经挂过
    }
    if (requireDeclared && !AxsClassDeclaresMethod(cls, sel)) {
        return NO;
    }

    IMP previous = NULL;
    MSHookMessageEx(cls, sel, hook, &previous);
    if (previous == NULL) {
        return NO;
    }
    *slot = previous;
    sHookCount += 1;
    return YES;
}

// 按类名挂一组站点；类还不存在就跳过，下次（主队列 / 导航条 hook 里）再试。
static BOOL AxsInstallSites(const AxsHookSite *sites, size_t count) {
    BOOL any = NO;
    for (size_t i = 0; i < count; i++) {
        if (sites[i].selectorName == NULL) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:sites[i].className];
        Class cls = name.length > 0 ? NSClassFromString(name) : Nil;
        SEL sel = sel_registerName(sites[i].selectorName);
        if (AxsInstallSiteOnClass(cls, sel, sites[i].hook, sites[i].slot, YES)) {
            any = YES;
        }
    }
    return any;
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

// 这几个选择器全局只有一站（UINavigationItem / UIBarButtonItem 各一个），
// 所以各自一个静态原 IMP 就够，不用查表。
static IMP axsSetRightItemsAnimatedOriginal = NULL;
static IMP axsSetRightItemsOriginal = NULL;
static IMP axsSetRightItemAnimatedOriginal = NULL;
static IMP axsSetRightItemOriginal = NULL;
static IMP axsSetMenuOriginal = NULL;

static void AxsNotesReadOnlyHookedSetRightBarButtonItemsAnimated(id self, SEL _cmd,
                                                                NSArray *items, BOOL animated) {
    if (axsSetRightItemsAnimatedOriginal != NULL) {
        ((void (*)(id, SEL, id, BOOL))axsSetRightItemsAnimatedOriginal)(self, _cmd, items, animated);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

static void AxsNotesReadOnlyHookedSetRightBarButtonItems(id self, SEL _cmd, NSArray *items) {
    if (axsSetRightItemsOriginal != NULL) {
        ((void (*)(id, SEL, id))axsSetRightItemsOriginal)(self, _cmd, items);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

static void AxsNotesReadOnlyHookedSetRightBarButtonItemAnimated(id self, SEL _cmd,
                                                               UIBarButtonItem *item, BOOL animated) {
    if (axsSetRightItemAnimatedOriginal != NULL) {
        ((void (*)(id, SEL, id, BOOL))axsSetRightItemAnimatedOriginal)(self, _cmd, item, animated);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

static void AxsNotesReadOnlyHookedSetRightBarButtonItem(id self, SEL _cmd, UIBarButtonItem *item) {
    if (axsSetRightItemOriginal != NULL) {
        ((void (*)(id, SEL, id))axsSetRightItemOriginal)(self, _cmd, item);
    }
    if (sInjecting) {
        return;
    }
    AxsNotesReadOnlyInjectIntoNavigationItem(self);
}

// 备忘录常常先建按钮、之后才赋菜单：这条路径补上。
static void AxsNotesReadOnlyHookedSetMenu(id self, SEL _cmd, UIMenu *menu) {
    if (axsSetMenuOriginal != NULL) {
        ((void (*)(id, SEL, id))axsSetMenuOriginal)(self, _cmd, menu);
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

    // 只挂一次，所以允许继承来的方法也挂（requireDeclared: NO）。
    AxsInstallSiteOnClass(navigationItem, sel_registerName("setRightBarButtonItems:animated:"),
                          (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItemsAnimated,
                          &axsSetRightItemsAnimatedOriginal, NO);
    AxsInstallSiteOnClass(navigationItem, sel_registerName("setRightBarButtonItems:"),
                          (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItems,
                          &axsSetRightItemsOriginal, NO);
    AxsInstallSiteOnClass(navigationItem, sel_registerName("setRightBarButtonItem:animated:"),
                          (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItemAnimated,
                          &axsSetRightItemAnimatedOriginal, NO);
    AxsInstallSiteOnClass(navigationItem, sel_registerName("setRightBarButtonItem:"),
                          (IMP)AxsNotesReadOnlyHookedSetRightBarButtonItem,
                          &axsSetRightItemOriginal, NO);
    AxsInstallSiteOnClass(barButtonItem, sel_registerName("setMenu:"),
                          (IMP)AxsNotesReadOnlyHookedSetMenu,
                          &axsSetMenuOriginal, NO);
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

// —— 每站一套：自己的包装函数 + 自己的原 IMP 槽 ——
//
// 1.0.8 只有一组包装函数加一张 (类, 选择器) → 原 IMP 的总表。`-[ICTextView setEditable:]` 里再
// `[super setEditable:]` 落到父类那一站的钩子时，self 仍是 ICTextView 实例，按 self 的类查表
// 又取回 ICTextView 自己那份「原 IMP」（其实就是钩子），于是 钩子 → 原 IMP → super → 钩子
// 无尽递归，栈瞬间撑爆（崩溃里 AxsNotesReadOnlyHookedSetEditable 与 -[ICTextView setEditable:]
// 交替上千层）。改成每站独立，谁挂的谁认自己的原 IMP，super 调用顺着父类那一站往下走，链路
// 自然到底。

#define AXS_FOR_EACH_EDITOR_CLASS(X) \
    X(ICTextView) \
    X(ICBaseTextView) \
    X(NoteHTMLEditorView) \
    X(UITextView)

#define AXS_DEFINE_EDITOR_SITES(TOKEN)                                                       \
    static IMP axsSetEditableOriginal_##TOKEN = NULL;                                         \
    static void axsSetEditableHook_##TOKEN(id self, SEL _cmd, BOOL editable) {                \
        IMP original = axsSetEditableOriginal_##TOKEN;                                        \
        if (original == NULL) {                                                               \
            return;                                                                           \
        }                                                                                     \
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, sLocked ? NO : editable);             \
    }                                                                                         \
                                                                                              \
    static IMP axsIsEditableOriginal_##TOKEN = NULL;                                          \
    static BOOL axsIsEditableHook_##TOKEN(id self, SEL _cmd) {                                \
        if (sLocked) {                                                                        \
            return NO;                                                                        \
        }                                                                                     \
        IMP original = axsIsEditableOriginal_##TOKEN;                                         \
        return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;             \
    }                                                                                         \
                                                                                              \
    static IMP axsCanBecomeFirstResponderOriginal_##TOKEN = NULL;                             \
    static BOOL axsCanBecomeFirstResponderHook_##TOKEN(id self, SEL _cmd) {                   \
        if (sLocked) {                                                                        \
            return NO;                                                                        \
        }                                                                                     \
        IMP original = axsCanBecomeFirstResponderOriginal_##TOKEN;                            \
        return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;             \
    }                                                                                         \
                                                                                              \
    static IMP axsBecomeFirstResponderOriginal_##TOKEN = NULL;                                \
    static BOOL axsBecomeFirstResponderHook_##TOKEN(id self, SEL _cmd) {                      \
        if (sLocked) {                                                                        \
            return NO;                                                                        \
        }                                                                                     \
        IMP original = axsBecomeFirstResponderOriginal_##TOKEN;                               \
        return original != NULL ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;             \
    }                                                                                         \
                                                                                              \
    static IMP axsCanPerformActionOriginal_##TOKEN = NULL;                                    \
    static BOOL axsCanPerformActionHook_##TOKEN(id self, SEL _cmd, SEL action, id sender) {   \
        if (sLocked && !AxsNotesReadOnlyIsReadOnlySelector(action)) {                         \
            return NO;                                                                        \
        }                                                                                     \
        IMP original = axsCanPerformActionOriginal_##TOKEN;                                   \
        return original != NULL                                                               \
            ? ((BOOL (*)(id, SEL, SEL, id))original)(self, _cmd, action, sender) : YES;       \
    }                                                                                         \
                                                                                              \
    static const AxsHookSite axsEditorSites_##TOKEN[] = {                                     \
        { #TOKEN, "setEditable:", (IMP)axsSetEditableHook_##TOKEN,                            \
          &axsSetEditableOriginal_##TOKEN },                                                  \
        { #TOKEN, "isEditable", (IMP)axsIsEditableHook_##TOKEN,                               \
          &axsIsEditableOriginal_##TOKEN },                                                   \
        { #TOKEN, "canBecomeFirstResponder", (IMP)axsCanBecomeFirstResponderHook_##TOKEN,     \
          &axsCanBecomeFirstResponderOriginal_##TOKEN },                                      \
        { #TOKEN, "becomeFirstResponder", (IMP)axsBecomeFirstResponderHook_##TOKEN,           \
          &axsBecomeFirstResponderOriginal_##TOKEN },                                         \
        { #TOKEN, "canPerformAction:withSender:", (IMP)axsCanPerformActionHook_##TOKEN,       \
          &axsCanPerformActionOriginal_##TOKEN },                                             \
    };

// 头三个是备忘录自己的编辑器类（版本不同类名不同，谁在就挂谁）；UITextView 兜底。
AXS_FOR_EACH_EDITOR_CLASS(AXS_DEFINE_EDITOR_SITES)

// 幂等：类还不存在就跳过，下次（主队列 / 导航条 hook 里）再试。
static void AxsNotesReadOnlyInstallEditorHooks(void) {
    if (sEditorClasses == nil) {
        sEditorClasses = [NSMutableArray array];
    }

#define AXS_INSTALL_EDITOR_SITES(TOKEN)                                                      \
    if (![sEditorClasses containsObject:@#TOKEN] && NSClassFromString(@#TOKEN) != Nil) {     \
        if (AxsInstallSites(axsEditorSites_##TOKEN,                                           \
                            sizeof(axsEditorSites_##TOKEN)                                    \
                                / sizeof(axsEditorSites_##TOKEN[0]))) {                       \
            [sEditorClasses addObject:@#TOKEN];                                              \
        }                                                                                    \
    }

    AXS_FOR_EACH_EDITOR_CLASS(AXS_INSTALL_EDITOR_SITES)

#undef AXS_INSTALL_EDITOR_SITES
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
