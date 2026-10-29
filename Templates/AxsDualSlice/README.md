# AxsDualSlice —— 双切片（arm64 + arm64e）deb 模板

给「以后还要修同类问题」用的一份可改脚手架：一个最小插件 + 一条云编译 + 一套验证命令。
形状和 `NotesReadOnly` 完全一样，那套已经在 iPhone10,1（A11 / iOS 16.7.16 / roothide）上
完整跑通过两轮（1.0.8、1.0.9），所以这里只留**已验证成立**的东西。

## 它解决什么

1. **本机没有编译器**：A11 缺 `FEAT_LRCPC`，装不了任何 Command Line Tools，`apelin_project_build`
   在这台机器上必然失败。所以产包只能走 GitHub Actions，本模板就带那条 workflow。
2. **只出 arm64e 的包在这个设备上永远不会生效**：用户态是 arm64，dylib 必须带 arm64 切片
   （`scripts/build-dualslice.sh` 会强制核对，缺一片直接构建失败）。
3. **钩子写错结构会闪退**：模板里的站点用**「一站一槽 / Per-Site Original Slot」**写法
   （见下），这是 1.0.8 崩溃的根因修法。
4. **「装完了却好像没生效」**：模板在加载时写一条可外部读到的诊断，装机后一条命令就能判断
   是没注入还是没重启进程。

## 怎么用

1. 把本目录内容当成新仓库的根：
   ```
   Sources/AxsDualSliceTweak.m          # 插件源码（改这里）
   Support/AxsDualSliceTweak.plist      # 过滤器（改这里）
   scripts/build-dualslice.sh           # 构建脚本（改"包身份"一段）
   .github/workflows/dual-slice.yml     # 从本目录的 ci/dual-slice.yml 拷过去
   ```
2. 改 **四处**，改成同一个产品（改完搜一遍 `AxsDualSliceTweak` / `com.example.axsdualslice`）：
   - `scripts/build-dualslice.sh` 顶部「包身份」：`PRODUCT` / `PACKAGE_ID` / `VERSION` / `NAME_ZH` / `MAINTAINER`；
   - `Sources/AxsDualSliceTweak.m` 的 `AxsDualSliceTargetBundle`（目标 App 的 bundle id）
     与 `AxsDualSliceVersion`；
   - `Support/AxsDualSliceTweak.plist` 的 `Filter/Bundles`（必须是同一个 bundle id）；
   - `ci/dual-slice.yml` 的 `env.VERSION` 与 Release 的 `tag_name`（静态版本，改版本时两处一起改）。
3. push 到 `master`：workflow 自动编译，并在**同一次运行里**把 deb 发成 Release
   （公开仓库匿名可下）。`paths` 过滤只列了本产品的文件——改文档不会重建、不会覆盖已验证的那份 deb。
4. 装到设备验（见下）。

在 Apelin 工程里用同一份源码时，不要再 ship 一份 Filter plist：过滤器写进
`apelin-project.json` 的 `package.tweakFilter`，构建交给云端的 `scripts/build.sh`。

## 站点的写法：「一站一槽 / Per-Site Original Slot」

- **R1 一站一槽**：每个 (类, 选择器) 站点各有**自己的静态原 IMP 槽**和自己的包装函数，
  装钩时把原指针存进这一站；运行时**绝不按 `self` 的类去查一张总表**。
- **R2 声明者才挂**（Declared-Owner Install）：只在类**自己声明**了该方法时才挂站；继承来的
  不挂，`super` 链路自然落到被钩的父类。

违反 R1 会这样炸：`-[子类 setEditable:]` 里 `[super setEditable:]` 进到父类那一站的钩子，
而 `self` 仍是子类实例，按 `self` 的类查总表又取回子类那份「原 IMP」→ 钩子 → 原 IMP → super
→ 钩子，上千帧递归把栈撑爆（1.0.8 就是这么闪退的）。
因为 R2，站点数会**少于** `类数 × 方法数`，这是对的，别当成缺钩。

模板里只有一个示范站点（`-[UIView setUserInteractionEnabled:]`，原样转发、不改行为，用来证明
注入和站点安装成功）。多站点写法照抄 `NotesReadOnly/Sources/NotesReadOnly.m` 里的
`AXS_FOR_EACH_EDITOR_CLASS` / `AXS_DEFINE_EDITOR_SITES` 宏表。

## 装机与验证（这台 A11 / roothide）

```sh
# 1) 下载 deb 到本机（本机没有 curl/wget/python3，用 icli probe + NSData）
#    并核对 sha256（只有 jbroot 那份 sha256sum 可用，路径加 /rootfs 前缀）

# 2) 装（须 root；路径必须是真根 /rootfs 前缀）
irisin-cli install --yes --json /rootfs/var/mobile/Documents/<deb>

# 3) 重启目标进程 —— 不重启 dylib 就没被映射，"看起来没生效"几乎总是这个原因
icli app kill <目标 bundle> --force
icli app launch <目标 bundle>

# 4) 读诊断（key 是位置参数，--key 会被拒）
icli prefs read <目标 bundle> AxsDualSliceDiagnostics
#   期望： v1.0.0;hooks=1;classes=UIView;enabled=0
#   第二通道：目标 App 容器里的 Documents/AxsDualSliceDiagnostics.txt
#   第三通道：os_log（统一日志没有历史，只能边开 App 边听）

# 5) 崩溃：Apelin 的 crash_list / crash_read；本机没有本机构建的 dSYM，用不上符号化工具
```

## 没验证的部分

- **rootless 腿**（`sh scripts/build-dualslice.sh rootless`）在脚本里保留但**没有在任何设备上跑过**：
  这台设备是 roothide，验不了。脚本会在开始前打印警告。
- 模板本身**没有在设备上装过**：它就是 `NotesReadOnly` 已验证结构的抽版，站点数、install_name、
  打包路径都照抄那份，但作为独立包没人装过；第一次用请按上面第 3–5 步自己验一遍再改功能。
- 默认目标 `com.apple.springboard` 只是占位过滤器，不是给 SpringBoard 写的真功能。
