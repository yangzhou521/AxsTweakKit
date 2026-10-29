---
name: a11-roothide-ondevice
description: 在这台 iPhone10,1（A11 / iOS 16.7.16 / roothide）上做越狱 deb 的现实做法：本机没有可用工具链，所以写完源码走 GitHub Actions 双切片云编译（arm64 + arm64e），再用 irisin-cli 装到本机、重启目标进程读诊断验证；含「一站一槽 / Per-Site Original Slot」钩子修复法、隐根路径、过滤器、日志窗口与故障速查。
---

# A11 / roothide 设备侧工作方式（含云编译闭环）

> 本文件是设备上 `~/Documents/wiki.qaq.apelin/skills/a11-roothide-ondevice/SKILL.md` 的镜像，
> 放在仓库里是为了换设备、换越狱也能带走、能改。两边内容应保持一致；改了一边记得对另一边。

本文件只写**在这台设备上真正成立**的做法：iPhone10,1（iPhone 8，A11，iOS 16.7.16，roothide 隐根）。
插件本身怎么写、字段怎么填，读插件骨架的注释与 Apelin 的内置技能（apelin-tweak-development、apelin-project-description、apelin-bootstrap-paths、apelin-package-dependencies…），这里不复制。

## 0. 一句话闭环

本机没有编译器 → 源码 push 到 GitHub → GitHub Actions 用 clang 直编出 **arm64 + arm64e 双切片**的 deb 并发布成 Release → 用 `irisin-cli` 装到本机（真根路径）→ **重启目标进程** → 读插件自己写的诊断 / 崩溃报告 → 界面行为最后单独确认。
这套叫「A11 双切片云编译闭环」，是这台机器上唯一能走通的交付路径（已在 com.unknown.notesreadonly 上完整跑过两轮）。

## 1. 本机没有编译器，也不要去装

- A11 缺 `FEAT_LRCPC`：Apple 目录里每个 Command Line Tools 都被 `apelin_toolchain_list` 标成 `requires CPU features this device lacks`，`installed` 永远为空。SDK（iphoneos16.4/16.5）已注册也**不是**编译器。
- 不要写、也不要承诺「本机直编闭环」「本机自测通过」；不要反复试装工具链，不要改 flags 绕。工具链状态每次都读 `apelin_toolchain_list` 的实时结果。
- `apelin_project_build` 在这台机器上必然失败（没有匹配的工具链），带编译需求的模板新建时就会被拒，只有 workspace/empty 这类空工程能建。所以「产出 deb」这件事只发生在 CI。

## 2. 云编译的形状（已验证）

- CI 里检出 `roothide/theos`（私有头在 `$THEOS/vendor/include`，预编的 `CydiaSubstrate.framework` 在 `$THEOS/vendor/lib`），SDK 用 `theos/sdks` 的 headerless `iPhoneOS16.5.sdk`，再 `brew install ldid dpkg`。
- **不用 Theos 的构建系统**：一个 `sh scripts/build-dualslice.sh` 里 clang 逐 arch 编译、`lipo -create` 合成、`ldid -S` 签名、`dpkg-deb -b --root-owner-group` 打包。
- 一个产品一个 workflow 文件，`push` 触发 + `paths` 过滤（只列这个产品的源码、构建脚本和该 workflow 自身）。**没有 paths 过滤时，改一次文档也会重建并覆盖 Release 资产**，把已经在设备上验证过的那份 deb 换掉。
- Release 资产**每次运行都重建**：源码没变也会得到不同的体积与 sha256。记录验证结果时写清楚「哪一次 run（head 提交）产的」，不要拿旧 sha256 当"这一份"。
- job 日志要登录才能看，所以把要读的验证信息写成 check-run annotation（`::notice title=…::`），公开仓库的 annotations 匿名可读。
- 构建脚本自己核对：切片是否 arm64 **和** arm64e 都在、substrate 依赖是否为 `.jbroot` 相对形式；缺一片就 exit 非 0，别把坏包发出去。

## 3. 双切片是这台设备的硬要求

| 事实 | 数值 |
|---|---|
| 用户态进程架构 | arm64（SpringBoard 是 `Mach-O 64-bit arm64`） |
| 已装 tweak dylib | 52 fat、6 仅 arm64、**0 仅 arm64e** |
| 包标签 | roothide 写 `Architecture: iphoneos-arm64e`（与 dylib 的真实 slice 无关） |

- 被注入的 dylib **必须含 arm64**；只含 arm64e 的在这个设备上注入不进任何进程，症状是「装上后完全没反应、没有日志」（1.0.7 的包就是这样一直没生效）。
- 包标签保持 `iphoneos-arm64e`，不要改成 `iphoneos-arm64`（那是 rootless 的标签）。
- 看切片：`file <dylib>`；本机没有 `lipo`/`otool`/`nm`/`size`/`python3`，别写依赖它们的排查步骤。

## 4. 链接坑（headerless SDK + vendor 头）

- substrate：`-F$THEOS/vendor/lib -framework CydiaSubstrate`（`-lsubstrate` 解析不了）。
- 该 SDK 的 `UIKit.tbd` **不 reexport CoreGraphics**（Foundation 仍 reexport CoreFoundation）。凡用到 `CGRectZero` / `CGRectGetWidth` 之类，必须显式 `-framework CoreGraphics`。别为了"修"链接把它去掉。
- install_name 与 substrate 依赖都用 `.jbroot` 相对形式（`@loader_path/.jbroot/usr/lib/…`）；构建后 `otool -L` 核对，必要时 `install_name_tool -change` 兜底。
- dylib 不签名不加载：`ldid -S`。

## 5. 装：只有一条路

- 把 deb 弄到本机：`icli probe` 里用 `NSData`/`NSURL` 下载并写文件（本机没有 curl/wget/python3）；`sha256sum` 只有 jbroot 那份可用，路径要加 `/rootfs` 前缀。
- 安装（须 root）：`irisin-cli install --yes --json /rootfs/var/mobile/Documents/<deb>`。**必须真根 `/rootfs` 前缀**，jbroot 拼写找不到文件。
- 不要用 `apt`/`dpkg`；不要拿 `irisin-cli` 去装 Apelin 自己构建出来的包（那是 `apelin_package_install` 的事）。

## 6. 验：顺序不能错

1. **先重启目标进程**：`icli app kill <bundle> --force` → `icli app launch <bundle>`。没重启 dylib 就没被映射，诊断也不会出现——**「装完看起来没生效」几乎总是这个原因**。
2. 读插件加载时写的诊断：`icli prefs read <目标域> <key>`（key 是位置参数，`--key` 会被拒）。第二通道是目标 App 自己容器里的 `Documents/<X>Diagnostics.txt`；第三是 os_log——统一日志在 iOS 上**没有历史**，`apelin_log_read` 只从调用那刻起听最多 10 秒。
3. 崩溃：`apelin_crash_list` → `apelin_crash_read`。本机没有本机构建，`apelin_crash_symbolicate` 用不上；靠报告里的镜像名 + 偏移 + 自己代码里的宏/函数名定位。
4. 界面：`apelin_screen_read_tree` / `capture` / `interact`。**Apelin 在前台时动作会被拒**（"UI actions may not reach wiki.qaq.apelin"），而用户切回 Apelin 看进度就会打断——所以界面验证要设计成一次做完，不要跨多轮；做不到的部分如实写「未测」。
5. 只读/禁用类行为的旁证：`icli input type` 打不进被禁用的文本视图（键盘不出现）——这本身就是"限制生效"的证据。

## 7. 钩子结构：一站一槽（Per-Site Original Slot）

这套命名用来描述这类修复，写文档、写提交信息时照用：

- **R1 一站一槽**：每个 (类, 选择器) 站点各有**自己的静态原 IMP 槽**和自己的包装函数；装钩时把原指针存进这一站，运行时**绝不按 `self` 的类去查一张总表**。
- **R2 声明者才挂**（Declared-Owner Install）：只在类**自己声明**了该方法时才挂站；继承来的不挂，`super` 链路自然落到被钩的父类。

违反 R1 的典型崩溃：`-[子类 setEditable:]` 里 `[super setEditable:]` 进到父类那一站的钩子，而 `self` 仍是子类实例，按 `self` 的类查总表又取回子类那份「原 IMP」→ 钩子→原IMP→super→钩子 无限递归，几帧撑爆栈。

自检方式：诊断里记 hooks 数与装了哪些类。因为 R2，站点数会**少于** `类数 × 方法数`，这是对的，不要当成缺钩。

## 8. 过滤器、隐根、面板

- 在 Apelin 工程里只写 `package.tweakFilter`，别自己 ship 一份 Filter plist；过滤器只列真正要注入的进程。
- 隐根：`@ROOTFS@` 是 `/rootfs`、`@PREFIX@` 为空、不存在 `/var/jb`、jbroot 名每次越狱都变，绝不写死；代码要打开 bootstrap 里的文件用 `ApelinBootstrapPath()`（头要从 apelin-bootstrap-paths 技能拷进 `Sources/`）。
- 面板：「面板能开、开关能拨，但插件没反应」九成是三处不一致——specifier 里的 `defaults`、插件读的偏好域、Darwin 通知名必须是同一个包 id。默认值永远不写盘，关掉就是原行为。
- 偏好域写成目标 App 自己的 bundle id，`icli prefs read` 才读得到（沙箱里跨域写不进去）。

## 9. 故障速查

| 症状 | 先查 |
|---|---|
| 进程里完全没反应、无日志 | dylib 有没有 arm64 slice（`file`）、过滤器 bundle id、`Depends` 里有没有 `mobilesubstrate`、进程是否重启过 |
| 装不上：built for … not this bootstrap | 包是给别的引导构建的；本机要装 roothide 的包 |
| 装完崩溃 | `apelin_crash_list` → `apelin_crash_read`；先看是不是钩子结构违反 R1 |
| 开关/功能不生效 | 偏好域与通知名、目标进程是否重启、站点是否真装上（诊断里的 hooks 数） |
| 设置面板没有入口 | PreferenceLoader 入口路径、bundle 名、`preferenceloader` 依赖；重启 Settings |
| 构建报 environment 错误 | 本机预期永远 unavailable；去 CI，别在本机继续试 |
| 界面动作被拒 | Apelin 在前台；先把目标 App 调到前台，并且一次做完 |

## 10. 说法纪律

- 编译通过 ≠ 装机通过 ≠ 加载生效 ≠ 界面正确。本机能覆盖到「装了 + 进程里生效」，界面部分要么用屏幕工具走通，要么写明未测。
- 本文件里的实测数字只属于这台 A11 / 这次越狱；换设备、换引导要重新实测。
- 「本机直编」这类说法在本机一律是错的，不要出现在文档、技能或承诺里。
