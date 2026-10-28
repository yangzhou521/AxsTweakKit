# AxsTweakKit

Axs 命名约定 + Apelin 工程形态的插件脚手架：SpringBoard 注入的 dylib、只读配置快照、
设置面板（开关 + 自定义滑条）、PreferenceLoader 入口。**只有源码，未编译、未验证。**

- 包 id / 偏好域：`com.axs.axstweakkit`
- 版本：`1.0.0`
- 过滤器：仅 `com.apple.springboard`
- 配置通知：`com.axs.axstweakkit.preferences-changed`（面板发，Tweak 收）

## 本机为何不能编译

这台设备是 iPhone10,1（A11，iOS 16.7.16，roothide）。A11 缺 `FEAT_LRCPC`，Apple 目录里
每个 Command Line Tools 版本都要求该特性，`apelin_toolchain_list` 一律标为不可安装，
可用工具链为空。没有工具链就没有 `clang`/`ldid`，`apelin_project_build` 必然失败，
也就没有 `build_id`，`apelin_package_confirm_loaded` 在本机无法用于本工程。

因此本工程只交付源码与构建描述：没有执行过编译、链接、打包、安装、respring 或加载确认，
文中任何"应该"都不是实测结论。

## 为什么没有把构建描述写进 apelin-project.json

`apelin-project.json` 是 **Apelin 自己的工程清单**，本工程 `kind` 是 `workspace`、
`buildSystem` 是 `external`：它严格校验成员，`products`/`package`/`build` 属于 tweak 工程的
描述，写进工作区的清单会被判为未知成员，而且 Apelin 对工作区只运行一个
`external.script`，不会读 tweak 的 products。

所以构建描述放在 `Docs/apelin-project.tweak.json`：一份可直接粘贴进 **tweak 工程** 的
`apelin-project.json` 的成员片段（`kind` 到 `package`），并且 `scripts/build.sh` 把同样的
步骤写成了脚本。两条路都写在下面。

## 换到有工具链的设备或环境之后

### A. 走 Apelin 构建（推荐）

1. 在目标设备/环境里装好工具链并导入 SDK：`apelin_toolchain_list` → `apelin_toolchain_setup`，
   `apelin_sdk_list` → 需要时 `apelin_sdk_import`，然后用 `apelin_project_set_environment`
   把工程绑定到这一对。
2. 新建一个 **tweak** 工程（模板 `wiki.qaq.apelin.dev.tweak/tweak`），把本工程的 `Sources/`、
   `Prefs/`、`Shared/` 拷进去。
3. 打开新工程的 `apelin-project.json`，保留 Apelin 写的 `schemaVersion`、`projectID`、
   `template`、`environment`、`displayName`、`autoName`，把 `Docs/apelin-project.tweak.json`
   里的成员（`kind`、`language`、`deploymentTarget`、`architectures`、`configurations`、
   `products`、`build`、`package`）合并进去。
4. `apelin_project_build` → 看诊断按文件行修；`apelin_package_install`；SpringBoard 插件用
   `apelin_package_confirm_loaded(target: "SpringBoard", respring: true)`，它会边听边 respring，
   抓构造里那一行 `ApelinLoaded <build_id>`。
5. 发布前 `apelin_project_check_distribution`，再对 `roothide` 与 `rootless` 各出一次
   release 构建并分别验证；两个包不改名、只改目标。

片段里刻意写了这些：

- `products` 两个：`tweak`（dylib，`substrate` 扩展 + `mobilesubstrate` 依赖）与 `prefs`
  （bundle，`preferences` 扩展 + `Preferences` framework + `preferenceloader` 依赖），
  都带 `extensionSupport`。
- `build.steps` 按 product 分组，`prefs` 带 `bundle-resources`，每个 product 以
  `{"type": "sign", "identity": "adhoc"}` 结束。
- `layout` 只用逻辑路径（`/Library/…`），没有 `/var/jb`、没有 jbroot、没有 jbroot 前缀。
- `tweakFilter.bundles` 只有 `com.apple.springboard`，plist 由打包器写在 dylib 旁；
  这时**不要**再把 `Support/AxsTweakKit.plist` 打进包里。
- `architectures.roothide` 写成 `["arm64", "arm64e"]`，不是常见的只 `arm64e`：A11 及更早的
  用户态是 arm64，只有 arm64e slice 的 dylib 在这类机器上注入不进任何进程。包标签仍是
  `iphoneos-arm64e`（roothide 的安装标签，与真实 slice 无关）。

### B. 走脚本（工作区自己的构建）

`scripts/build.sh` 把上面同样的步骤写成 sh：按 `APELIN_BOOTSTRAP` 选切片、`clang` 编 dylib
与 bundle、`ldid -S` 签名、按 `$APELIN_PREFIX` 落包、`dpkg-deb` 出一个 deb。它需要的环境变量
在文件头列了（`SDKROOT`、`SUBSTRATE_CFLAGS`/`SUBSTRATE_LDFLAGS`、`PREFS_LDFLAGS`）。

要用 `apelin_project_build` 驱动它，需要往本工程的 `apelin-project.json` 加一行（本次没改
那份清单）：

```json
"external": {"script": "scripts/build.sh", "interpreter": "sh", "arguments": []}
```

然后用 `APELIN_BOOTSTRAP` 对应的构建目标跑一次；本机没有工具链，所以这一步只在别的机器上成立。

### C. 走 GitHub Actions（云编译，本机就能发起）

`.github/workflows/build.yml` 把上面的脚本放到 GitHub 上跑：macOS runner 上装
Xcode 15.4、检出 roothide/theos（提供 `substrate.h`、iOS 头文件与 `libsubstrate`）、
拉取 theos/sdks 的 `iPhoneOS16.5.sdk`（只有 tbd，面板的 Preferences 私有头来自
theos 的 include 树，Xcode SDK 不提供），然后以 release 配置对 **roothide** 与
**rootless** 各跑一次 `scripts/build.sh`。推送到 `main`/`master` 或手动触发都会
构建并上传 artifacts；手动触发时再把两个 deb 挂到 v1.0.0 的 Release。

- 版本仍是静态 `1.0.0`（脚本与 `Docs/apelin-project.tweak.json` 同值）；重发
  Release 前把三处（`scripts/build.sh` 的 `VERSION`、tweak.json 的 `package.version`、
  工作流里的 `tag_name`/标题）一起升。
- 产物：`com.axs.axstweakkit_1.0.0_iphoneos-arm64e.deb`（roothide，含 arm64+arm64e
  双切片，装这台 A11）与 `…_iphoneos-arm64.deb`（rootless）。
- 工作流与脚本一样**未在真实 runner 上验证过**；第一次跑先看构建日志里的切片与
  `dpkg-deb -I` 输出（工作流里有对应步骤）。

## 安装之后怎么验证

1. `apelin_package_install` 装包 → `apelin_package_confirm_loaded(target:"SpringBoard", respring:true)`：
   标记行是构造里的 `os_log(AxsTweakKitLog(), "ApelinLoaded " APELIN_BUILD_ID)`，subsystem 就是
   包 id，所以确认工具能听到它。
2. 设置里出现 **AxsTweakKit** 入口（PreferenceLoader 读
   `/Library/PreferenceLoader/Preferences/AxsTweakKitPrefs.plist`），打开有"启用插件"和"强度"。
3. 日志：`apelin_log_read(process:"SpringBoard", subsystem:"com.axs.axstweakkit")`，10 秒窗口内
   操作。开关打开后每次进 SpringBoard 会有一行 launch hook 的日志；开关关闭时那一行不出现，
   这就是"enabled 关闭保持原行为"的可观测面。
4. 改滑条 → 面板 `setPreferenceValue:` 写文件 → 发 Darwin 通知 → Tweak 串行队列重读快照。
   只是重读，不改界面；要重进 SpringBoard 才看到下一次启动的行为。

排查口径：面板能开、开关能拨但 tweak 没反应，先看三处是否同为 `com.axs.axstweakkit`
（行上的 `defaults`、Tweak 读的域、通知名）；再看 dylib 里有没有 arm64 slice（`file`）。

## 从 Theos 版技能迁移的约定 vs 重写

**迁移（语义不变）**

- 命名空间：类/文件前缀 `AxsTweakKit`，函数与新增 selector 前缀 `axsTweakKit_`，
  不使用 `AxsConfig`、`AxsSliderCell`、`axs_reload` 这类通用名；新增 selector 只挂在自己的类上，
  系统方法名（`readPreferenceValue:`、`setPreferenceValue:specifier:`）保持原样。
- 配置层单一职责：`AxsTweakKitConfig` 持不可变快照，读一次 + 收到通知后重读，
  高频 hook 只读内存；Tweak 从不写默认值，`enabled` 默认关闭，关闭即保持原行为。
- 面板是唯一写入方：文件不存在时只从自己的偏好域取兼容初始值，坏文件不覆盖，
  先原子写文件再镜像 `NSUserDefaults`，最后发插件专属 Darwin 通知；写失败弹窗并回滚界面。
- 滑条交互：拖动只刷新数值、松手才提交；VoiceOver 调整直接提交；handler 弱引用、
  复用时清空、显示时重新挂接并读取配置；存储值在面板与消费端都做夹紧。
- 过滤器只覆盖需要的进程：只 SpringBoard。
- 首版本 `1.0.0`（技能的 `5.2.0-$run` 属于其 CI 口径，这里按本工程要求）。

**重写（因为 Apelin 不是 Theos）**

- 没有 Logos：`%hook`/`%orig`/`%ctor` 换成 `static` 函数 + `MSHookMessageEx` +
  `__attribute__((constructor))`，保存的 original 与全局量全部 `static`。
- 没有 Makefile / `build.sh`（Theos 版）/ Logos 的 GitHub Actions：换成
  `apelin-project.json` 的两个 product 与 `build.steps`、一份等价的 `scripts/build.sh`，
  以及驱动它出两个引导包的 `.github/workflows/build.yml`（见「C. 走 GitHub Actions」）。
- 路径：Theos 版的 `jbroot()` / `ROOT_PATH_NS()` 换成 `Shared/ApelinBootstrap.h` 的
  `ApelinBootstrapPath()`；包内路径只写逻辑路径，plist 用 `@PREFIX@`/`@ROOTFS@`。
- 面板存储路径：Theos 版在 roothide 上把 `/var/mobile/Library/Preferences/…plist` 也套
  `jbroot()`。这里默认按"系统路径原样使用"处理，两侧读同一个文件；若某套越狱里 Settings
  写不到系统目录，把 `AXS_TWEAKKIT_PREFS_IN_JBROOT` 设为 1，且两个 product 必须一起设。
- 滑条 cell：技能示例就是 `PSTableCell` 子类，这里沿用；没有用私有的 `PSSliderTableCell`，
  它的布局会和标题/滑条/数值三段打架，init 也不在任何受支持的声明里。
- 面板少了技能默认的"关于我们"（Sileo/TG/QQ）：没有拿到真实链接，不编造 URL；
  需要时在控制器 `-specifiers` 里按同一模式补按钮。
- 公共头文件放 `Shared/`（两个 product 共用），用 `headerSearchPaths: ["Shared"]` 引入，
  而不是复制两份。

## 文件

```
Shared/ApelinBootstrap.h                      bootstrap 路径助手（roothide jbroot / rootless /var/jb）
Shared/AxsTweakKitPreferences.h               包 id、通知名、配置文件路径、文件读取
Sources/AxsTweakKitLog.h                      os_log（subsystem = 包 id）与启动标记行
Sources/AxsTweakKitConfig.h/.m                只读配置快照 + Darwin 通知重读
Sources/AxsTweakKitHooks.m                    MSHookMessageEx 骨架、过滤器说明、constructor
Prefs/AxsTweakKitPrefsStore.h/.m              唯一写入方：原子写、镜像、发通知
Prefs/AxsTweakKitSliderCell.h/.m              自定义滑条 cell（主线程、松手提交、VoiceOver）
Prefs/AxsTweakKitPrefsRootListController.h/.m PSListController 子类，读写都走 store
Prefs/Resources/AxsTweakKitRoot.plist         开关 + 滑条两行
Prefs/Resources/Info.plist                    NSPrincipalClass / BNDL / 1.0.0
Prefs/Resources/AxsTweakKitPrefs.plist        PreferenceLoader 入口
Support/AxsTweakKit.plist                     仅 scripts/build.sh 用的过滤 plist（Apelin 路径用 tweakFilter）
Docs/apelin-project.tweak.json                可粘贴的构建描述片段
scripts/build.sh                              等价构建脚本（未验证）
.github/workflows/build.yml                   GitHub Actions 云编译（roothide + rootless，未跑过）
```

## 状态

**未编译、未验证。** 没有运行过 `clang`、`ldid`、`dpkg-deb`，没有安装、没有 respring、
没有确认加载。本机不具备编译条件，这一点不会因为工程写得更完整而改变。
`.github/workflows/build.yml` 已提交，但从未在 GitHub runner 上执行过；第一次跑通前，
一切构建相关结论都仍是假设。