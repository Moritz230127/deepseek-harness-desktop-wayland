# rc.3 Wayland 桌面包：最小 Linux 补丁系列与打包骨架设计

> 版本：2026-11-14 16:58（Asia/Shanghai）· 作者：patch-designer（Team Lead 的调研/补丁工程师）
> 基线：`dsh-v0.2.2-rc.3` / commit `38a6a5c965aa99ab525161efb7cc5cf1fe62fced` /
> 官方 archive sha256 `bf6d668e52a26edf98aa2ef7960e240c8d9afcefbad2b09887a2cb1e14001dd5`
> 参考实现：社区 `ffyfox/dsh-desktop-linux`（MIT）的 12 个 build-enablement 补丁（只读，
> 已由 Lead 移到 `reference/ffyfox-patches/`）。**本仓库复用其思路与 hunk，但重新编号、精简、
> 去掉 deb/rpm/AppImage 元数据与纯测试 hunk，并补上 rc.3 适配说明。**

## 0. 一句话结论

- 新补丁系列 **14 个补丁 / 48 个文件条目（去重 45 个）/ +442 −129 行（补丁文件 1639 行）**，
  全部相对同一 pristine rc.3 基线、互相独立；**14/14 单独 `git apply --check` 通过，14/14
  按序 `git apply` 与 `patch -Np1` 通过**，`makepkg --nobuild`（含官方 archive 与本地资产
  sha256 校验 + prepare() 依次应用 14 个补丁）实测通过。
  - **0001–0010**（43 文件 / +414 −125）是本工程师负责的 **P1 构建启用最小集**；
  - **0011–0014**（5 文件 / +28 −4）是**并行作者**（console/wayland 收敛）在 16:56–16:57 新增的
    运行期补丁，本工程师只做了**补丁格式修复**（hunk 行数、去掉 `git format-patch` 尾签名），
    语义内容未改，并复核为可单独/按序 apply（见附录 A）。
- 相对 ffyfox 12 补丁（56 文件 / +866 −141）：删掉 2 个补丁（纯测试、deb/rpm 元数据）并精简
  3 个补丁；**没有为了“少文件”删任何构建必需逻辑**。
- 与旧仓库 3437 行 / 48 文件补丁相比：所有美化类（托盘/主题/磨砂/locale/remote bridge/TUI）
  全部不进新系列；旧补丁里真的还在生效的两类问题已被上游或新方案覆盖：
  1. **鉴权 cookie 累积**——rc.3 上游已修复（`web-document.ts::removeLegacyHostCookies`），
     旧补丁的 `host-auth-cookies.ts` + `webserver` 64 KiB 头上限**不再需要**；
  2. **Linux 上 sharp/libvips 与 Electron glib 冲突（electron#46323）**——不再重建 sharp，
     改为 **Host 跑在 primary-runtime 自带的独立 Node**（新 0007/0008），从根上绕开；
     LibreOfficeKit 的 ASAR 探测问题在 `asar:false` + 独立 Node 下不复现（待实测确认）。
- P4「禁用应用内更新」**不需要补丁**：上游 `update-coordinator.ts` 的 `enabled` 已经是
  `app.isPackaged && existsSync(resources/app-update.yml)`；Linux 的 electron-builder 配置
  不写 publish feed，因此不存在 `app-update.yml`，updater 自然禁用；强制更新策略由新 0009
  在编译进产物前剔除。

## 1. 事实基础与证据来源

| 项 | 事实 | 来源/证据 |
|---|---|---|
| 上游基线 | tag `dsh-v0.2.2-rc.3`，commit `38a6a5c9…fced` | Lead 已解压的 pristine 树 + 官方 tarball sha256 |
| 可行性 | Lead 已用 ffyfox 12 补丁在 rc.3 上**完整构建成功**：`linux-unpacked` 1.2 GB，能启动、CDP 可连、Host 跑独立 Node | Lead 里程碑通报（2026-11-14） |
| pnpm 卡点 | 本机 `npm_execpath` 指向 `@pnpm/exe` 的 **ELF**（实测 `/home/Arch/.local/share/pnpm/package-manager-store/.../node_modules/@pnpm/exe/pnpm`），上游 `package-target.ts::runPnpm()` 用 `node $npm_execpath` 启动它 → `SyntaxError` | 实测：`pnpm exec node -p process.env.npm_execpath` |
| 卡点处置 | **Lead 决定用隔离的官方 pnpm 11.28.5（JS 入口）解决，不再写 0013 pnpm-invocation 补丁** | Lead 第二条修正指令；`ci/build-wayland.sh` 已用 `/home/Arch/.local/share/dsh-pnpm-11/node_modules/.bin/pnpm` |
| 构建形态 | 只出 `--unsigned --dir`（`linux-unpacked`），由 PKGBUILD 直接装 `/opt`；不产 AppImage/deb/rpm | PLAN.md + Lead 要求 |
| 网络 | GitHub 直连超时（rc.1 归档下载失败）；npm registry 可达；本机有 Electron 镜像 `http://127.0.0.1:8899/` | 实测（本会话 `curl` 结果） |

> 说明：本会话**无法下载 rc.1 归档**（GitHub 直连超时），因此「rc.1→rc.3 差异」用
> *旧补丁对 rc.3 的 `git apply` 逐文件命中率 + rc.3 源码语义核对* 完成，而不是逐行 diff。

## 2. 旧补丁（rc.1 时代，3437 行/48 文件）逐文件去留

旧补丁文件级在 rc.3 上独立 `git apply`：**42/48 干净应用**，6 个失败点全部集中在
`main.ts`（大改 + 与 rc.3 不兼容）、`locale.ts`、`desktop-package-environment.mjs`（上游重构
成 `desktop-file-settings.mjs`）、`retain-desktop-ci.ts`、两个测试文件。失败点恰好说明
「旧补丁的大部分目录仍可套用，但新系列不复用旧写法」。

| 旧补丁文件（组） | 去留 | 理由 |
|---|---|---|
| `.gitignore`、`apps/desktop/.env.linux` | **重写** | rc.3 `.gitignore` 已含 `apps/desktop/.desktop-build/`，只需 `.env.linux` 忽略（新 0005）；`.env.linux` 改为 `.env.linux.example` + 构建脚本生成（新 0005，PKGBUILD/build 脚本写实际文件） |
| `apps/desktop/package.json` | **重写** | 新 0006 只加 4 行 `package:linux:*`；旧补丁的 `desktopName` 字段不再需要（新 0003 用 electron-builder `extraMetadata.desktopName`） |
| `apps/desktop/cli/dsh-linux`、`scripts/prepare-cli.ts` | **删除** | 新方案 Linux 不安装 `runtime/cli`（ffyfox 0004 的 `prepare-runtime` 直接跳过）；终端入口由 `/usr/bin/deepseek-harness-wayland` 承担，不需要 macOS 式 CLI 脚本 |
| `scripts/desktop-build-paths.{mjs,d.mts}` | **重写（新 0001）** | 复用：目标模型加 `linux-x64/linux-arm64`、`desktopElectronExecutablePath()`；去掉旧补丁的按平台三元表达式重写（更小） |
| `scripts/desktop-auto-update-environment.{mjs,d.mts}`、`desktop-release-store.ts` | **重写（新 0001）** | 让 `DesktopAutoUpdateTarget` 联合类型包含 Linux，避免全仓库类型收窄改造（ffyfox 方案；比旧补丁“到处传 `DesktopTargetName`”改动小） |
| `scripts/desktop-build-version-discovery.ts`、`edgeone.ts`、`upload-target.ts` | **删除** | ffyfox 方案下这些文件不再有类型冲突（`--dir --unsigned` 不走 `--build-version auto`，也不上传），旧补丁 hunk 不需要 |
| `scripts/package-target.ts`、`desktop-upload-plan.ts` | **重写（新 0002）** | 复用：Linux 目标选择器、宿主守卫、上传计划类型；**p2p 的 `pnpmInvocation` 改写不要**（Lead 用隔离 pnpm 解决）；不需要旧补丁的 release-record 大改（ffyfox 只改类型/守卫） |
| `scripts/electron-builder-config.mjs` | **重写（新 0003，精简）** | 只保留：Linux `asar:false`（独立 Node 宿主）、`desktopName`（app_id）、`executableName`、原图 icon、Linux 不嵌强制更新策略。**去掉 deb/rpm/fpm/AppImage/toolset/synopsis/maintainer/format 选择**（我们只 `--dir`） |
| `scripts/prepare-dsh.ts`、`prepare-runtime.ts` | **重写（新 0004）** | 按目标平台定位 Electron 可执行文件（Linux 为根目录 `electron`）、smoke 用目标 Node 运行时 |
| `scripts/prepare-runtime.ts` 里的 chmod / unzip 兼容 | **删除** | `extract-zip` 在 rc.3 保留可执行位（ffyfox 构建成功未报此问题）；`desktopElectronExecutablePath` + 首次执行探测已覆盖 |
| `scripts/linux-runtime-adjustments.ts`（sharp 重建 + LibreOfficeKit 文本修补，147 行） | **删除** | 被新 0007/0008「Host 用独立 Node」从根上取代：Host 不再注入 Electron 的 glib，sharp/libvips 不再跨库 unref；LibreOfficeKit 的 `!== undefined` 探测在 `asar:false` 下不经过 ASAR fs（详见 §5 P2 分析，待实测） |
| `scripts/desktop-toolchain-preflight.ts` | **重写（新 0005，2 行）** | 只放宽 `platform` 类型到 `'linux'`；旧补丁的 pnpm/git/python 探测整段不要 |
| `scripts/dev.ts`、`flock-entry.ts`、`development-project.ts`、`retain-desktop-ci.ts`、`smoke-packaged-runtime.ts` | **部分重写** | `dev.ts`/`smoke-packaged-runtime.ts` 由新 0008 覆盖；`flock-entry`、`development-project` 不需要（类型不再冲突）；`retain-desktop-ci` 只要新 0001 的类型放宽（CI 保留逻辑不用于 Linux 发布） |
| `scripts/desktop-upload-plan.ts`、`upload-target.ts`、`edgeone.ts` 的旧 hunk | **删除** | 同上，无类型冲突 |
| `src/main.ts`（旧补丁 +420 行：托盘/图标主题/壳层探测/locale/窗口控制/GPU 梯子/cookie 清理） | **删除，仅保留 11 行** | 新 0007 只加「Host Node 运行时选择」相关的最小改动；其余全部是美化/可选功能，需求明确不要 |
| `src/tray.ts`、`src/locale.ts`、`src/bounded-restart.ts`、`src/gpu-fallback.ts`、`src/linux-shell.ts` | **删除** | 托盘/主题/locale 属美化；GPU 兜底移到 launcher（wayland-analyst 的 `launcher/deepseek-harness`）；Wayland flag 全部在 launcher 里，不进应用源码（P3 收敛后也不改 main.ts） |
| `src/host-auth-cookies.ts`（新文件，51 行） | **删除** | **rc.3 上游已修复**：`apps/desktop/src/web-document.ts` 新增 `removeLegacyHostCookies()`，`main.ts:551` 每次启动清理 `dsh-auth-*` |
| `packages/host/webserver/src/index.ts`（+15：64 KiB `maxHeaderSize`） | **删除** | 上游已在源头清 cookie，header 不会再无限累积；64 KiB 上限属防御性可选项，不先验添加 |
| `packages/client/ui-theme/src/client/styles.ts`、`styles/frosted.css` | **删除** | 磨砂美化，明确不要 |
| `package.json`（根，+2 Linux scripts） | **删除** | 构建脚本直接 `pnpm --dir apps/desktop run package:linux:x64:dir`；根 scripts 非必需（少一个文件） |
| `tests/*.spec.ts`（旧补丁 14 个测试文件，约 +640 行） | **删除** | 新系列只保留 rd.3/ffyfox 中与**签名/类型变更强相关**的测试 hunk（0007/0008 内），其余纯行为测试不复用；本仓库当前不跑 vitest |

## 3. rc.1→rc.3 已修复/已变化（新补丁因此可删内容）

| 旧补丁内容 | rc.3 现状 | 结论 |
|---|---|---|
| 鉴权 cookie 累积（`host-auth-cookies.ts` + webserver 头限制） | `apps/desktop/src/web-document.ts::removeLegacyHostCookies()` 新增；`main.ts:551` 每次鉴权后清理该 origin 的全部 `dsh-auth-*` | 删除，无需补丁 |
| Linux 会话性能/长期后台进程 | 未在本仓库证明与桌面补丁相关；`apps/desktop` 无对应旧 hunk | 无补丁 |
| Electron glib vs sharp/libvips 段错误（electron#46323） | 上游未修（sharp 仍是 registry 版）；但 Host 改为独立 Node 后不共享 Electron 进程 | 用 0007/0008 解决，不重建 sharp |
| LibreOfficeKit ASAR 探测（`lstatSync(...) !== undefined`） | rc.3 `packages/document/office-kit/src/locate.ts:64` 仍是原写法 | 在 `asar:false` + 独立 Node 下不再经过 ASAR 文件系统 → 预期不复现；**列为待实测**（冒烟已做 Office 转换，见 0008） |
| `apps/desktop` packaging 脚本（Linux target） | rc.3 仍只有 mac/win 脚本；primary-runtime lock 已含 `linux-x64/linux-arm64`、`prepare.ts` 已处理 `target.startsWith('linux-')` | 确认 P1 只需要“接线”，不需要改 runtime 下载逻辑 |
| `.desktop-build/` 忽略 | rc.3 `.gitignore` 已含 | 省一条 |
| 应用内更新 | 上游已有 `enabled = app.isPackaged && existsSync(resources/app-update.yml)`；Linux config 不写 publish | **P4 不需要补丁** |

## 4. 新补丁系列（14 个，可独立 + 可顺序 apply；0001–0010 为本系列，0011–0014 为并行收敛）

前缀说明：每个补丁文件首行是 `# 目的：…` 中文注释；`git apply` / GNU `patch` 都接受该
preamble（已实测）。文件名连续 `0001`–`0010`，顺序即应用顺序。

| # | 文件 | 目的 | 文件数 | +/− | 相对 ffyfox 的精简 |
|---|---|---|---:|---|---|
| 0001 | `0001-desktop-target-model-linux-x64.patch` | 目标模型加 `linux-x64/linux-arm64`；新增 `desktopElectronExecutablePath()`；update/release-store 类型放宽 | 6 | +39/−15 | 与 ffyfox 0001 相同（未精简） |
| 0002 | `0002-package-target-linux-x64.patch` | `package-target.ts` 支持 Linux 目标（builder `--linux`、宿主/架构守卫）；upload-plan 类型收窄 | 2 | +25/−3 | 同 ffyfox 0002 |
| 0003 | `0003-electron-builder-linux-configuration.patch` | Linux electron-builder：`asar:false`、`executableName: deepseek-harness`、`extraMetadata.desktopName`、`syncDesktopName`、原图 icon、Linux 不嵌强制更新策略 | 1 | +19/−4 | **去** ffyfox 0003 的 deb/rpm/fpm/AppImage/format/synopsis/maintainer 与 `.d.mts`；去 installer-packaging 测试 |
| 0004 | `0004-prepare-target-electron-distribution.patch` | 按目标平台定位 Electron 可执行文件；运行时准备/冒烟使用目标 Node 运行时；Linux 不准备 `runtime/cli` | 2 | +44/−20 | 同 ffyfox 0004 |
| 0005 | `0005-desktop-linux-release-settings.patch` | `.env.linux` 加载/校验（无 preset、无签名、无策略）、`.env.linux.example`、`.gitignore`、工具链预检放宽 | 5 | +36/−10 | **去** ffyfox 0005 的 deb/rpm maintainer/homepage 元数据与 rpmbuild 探测、新增测试；精简 `.env.linux.example` 到 APP_ID+说明 |
| 0006 | `0006-desktop-package-linux-scripts.patch` | `package:linux:*` 脚本；`--unsigned` 的 local client profile 保留官方品牌/标题 | 3 | +11/−1 | **去** ffyfox 0006 两个测试文件 |
| 0007 | `0007-desktop-host-runtime-standalone-node.patch` | Linux 用 primary-runtime 自带独立 Node 承载 Host（避开 electron#46323）；`desktopNodeRuntime()`/`node-bin/node`/host-process/main.ts 适配 | 12 | +148/−40 | 同 ffyfox 0008（测试 hunk 保留：构造函数签名变了，不保留会破坏 `tsc -p tsconfig.host.json` 聚合检查） |
| 0008 | `0008-desktop-packaging-host-runtime.patch` | 打包/冒烟链路适配独立 Node 宿主：Linux 产物按未打包资源树校验；dev/smoke 复用同一运行时选择 | 8 | +53/−29 | 同 ffyfox 0009 |
| 0009 | `0009-desktop-linux-policy-opt-out.patch` | `desktopPlatformEmbedsPolicy()`：Linux 不嵌、不轮询强制更新策略 | 2 | +18/−0 | **去** ffyfox 0010 的测试 hunk |
| 0010 | `0010-desktop-build-commit-release-archive.patch` | release 归档无 `.git`：打包 commit/dirty 由环境变量录制优先，缺失时给明确报错 | 2 | +21/−3 | **去** ffyfox 0012 的测试 hunk |
| 0011 | `0011-desktop-linux-window-background.patch` | Linux 主窗口用 `chromeFallbackFill()` 画首帧底色、欢迎窗口按系统明暗取底色，消除暗色桌面白闪 | 2 | +6/−2 | **并行作者产出**（非本系列 P1）；仅修复 hunk 行数 |
| 0012 | `0012-desktop-linux-hide-update-entry.patch` | Linux 隐藏应用内「检查更新」菜单项（无更新源 + pacman 管更新，入口只会失败） | 1 | +5/−1 | 同上；与 P4 结论一致 |
| 0013 | `0013-desktop-linux-gpu-launch-failure.patch` | `child-process-gone` 的 GPU `launch-failed` 时 `app.exit(75)`，交给 launcher 软件渲染重试一次 | 1 | +11/−0 | 同上；与 launcher 的 75 约定配套 |
| 0014 | `0014-account-expected-linux-failure.patch` | Linux 无 Desktop account backend，账户读取失败是预期能力缺口，从 `console.error` 降到 `console.info` | 1 | +6/−1 | 同上；console 零报错用 |
| **合计** | | | **48 条目 / 45 去重** | **+442/−129** | 补丁文件总共 **1639 行**（含 preamble/description 与 diff 头） |

> 其中 **0001–0010 合计 43 文件 / +414/−125 / 1514 行** 为 P1 最小系列（可与 ffyfox 12 补丁对比：
> 56 文件 / +866/−141）。

### 附录 A：并行补丁 0011–0014 的格式修复（内容未改）

这 4 个补丁由并行 analyst 以 `git format-patch` 风格落盘，但 hunk 头里的行数统计与实际
hunk 体不一致，且末尾带 `-- \n2.51.0` 签名，导致 `git apply` 报「补丁损坏 / 未应用」。
本工程师做了**纯机械修复**：按 hunk 体实际行数重写 `@@ -a,b +c,d @@`、删除尾签名；
并逐个复核：

```text
PASS 0011-desktop-linux-window-background.patch     （独立 vs pristine）
PASS 0012-desktop-linux-hide-update-entry.patch
PASS 0013-desktop-linux-gpu-launch-failure.patch
PASS 0014-account-expected-linux-failure.patch
按序 0001…0014：14/14 APPLIED（git apply）
```

内容语义仍需原作者/Lead 复核（尤其 0012 的更新入口隐藏、0013 的 exit 75 约定要与 launcher 对齐）。

被**整包删掉**的 ffyfox 补丁：`0007-tests-linux-x64-supported`（纯测试，3 文件 +31/−6）、
`0011-desktop-linux-package-metadata`（deb/rpm 才需要的 formats/maintainer/homepage，3 文件 +178）。
被删的 `0013/0016/0017/0018/0019`（托盘/标题栏/glass/frameless/resources-path）本来就不在采纳范围。

### 4.1 为什么这是最小（逐项论证）

- **只接线，不改架构**：Linux target 全部复用上游已有的 `PrimaryRuntimeTarget`（lock 已含
  `linux-x64/linux-arm64`）、`officePackageDirectories()`、`runtime-file-policy`、原生模块预编译；
  补丁只补「平台守卫/类型/路径/CLI 入口」。
- **不重建 sharp、不做文本级 node_modules 修补**：独立 Node 宿主（0007）从根上解决
  electron#46323，替换掉旧补丁 147 行 + 一个 0.35.4 rebuild tarball 的依赖（rc.3 的 sharp 已是
  0.35.5，旧 rebuild 版本还不匹配）。
- **不加更新 UI/策略代码**：只加一个 2 行的 `desktopPlatformEmbedsPolicy()` 并在两处调用点使用。
- **测试 hunk 只在“不保留就破坏聚合类型检查”时保留**（0007/0008）；其余测试全部不加。
- **不引入 pnpm-invocation 补丁**：Lead 用隔离 pnpm 11（JS 入口）把 `npm_execpath` 变成可被
  node 执行的入口，补丁数 -1、更忠实上游。

## 5. P2/P4 分析（本轮不写补丁，供 Lead 实测后决定）

### P2 运行时兼容

1. **sharp/libvips（electron#46323）**：已由 0007/0008 解决——Linux Host 进程不再由 Electron
   的 Node 模式承载，而是 primary-runtime 的独立 Node，因此 libvips 不会从 Electron 的 glib
   解析符号。**不需要**旧补丁的 `@janhapke/sharp-electron` 重建（且该 rebuild 只有
   `0.35.4-electron.1`，rc.3 pin 的是 sharp `0.35.5`）。
2. **LibreOfficeKit ASAR 探测**：rc.3 `locate.ts` 的 `lstatSync(...) !== undefined` 仍在；但
   Linux 构建 `asar:false`（0003），payload 是物理文件树，探测路径不经过 ASAR。ffyfox 的冒烟
   流程包含 Office 转换（PDF/PNG/ODF/XLSX 重算），Lead 的完整构建已通过该冒烟 → **预期无需
   补丁**；建议在最终包里再点一次“Office 转换”做运行期确认。
3. **64 KiB header 上限**：源头（每次启动清 `dsh-auth-*`）已由上游修复，不需要。
4. **其它**：无已知 Linux 运行时兼容补丁需求；若 console-analyst 发现官方代码在 Linux 的
   console error，再单独加 P2 补丁（届时遵循“只改最小处”）。

### P4 无应用内更新

- 上游 `apps/desktop/src/update-coordinator.ts:64`：
  `enabled = () => app.isPackaged && existsSync(join(process.resourcesPath, 'app-update.yml'))`。
- Linux 的 electron-builder 配置 `publish: null`（`update === undefined`）→ 产物无
  `app-update.yml` → `DesktopUpdateCoordinator` 永远 disabled；`DesktopUpdateSchedule` 只读
  渠道配置，不发起网络检查。**结论：不需要补丁**；待实测项 = DevTools/console 无 updater 报错。
- 强制更新策略（Windows/macOS 专有）由 0009 从产物 `extraMetadata` 中剔除，启动时
  `resolveDesktopPolicyConfig(undefined)` 走“无策略”分支，不产生控制台报错。

## 6. `git apply` 证据（2026-11-14 实测）

pristine 树 = 官方 tarball 重新解压（sha256 与上表一致），验证命令：

```bash
# [1] 每个补丁单独 vs pristine（14/14 PASS）
export GIT_CEILING_DIRECTORIES=/tmp/pd-rc3   # 让 git 不误认宿主仓库
for p in /home/Arch/dsh-re/dsh-desktop-wayland/patches/*.patch; do git apply --check "$p"; done
#   PASS 0001 … PASS 0014（14/14）

# [2] 按序 git apply（模拟 prepare 顺序，14/14 APPLIED）
for p in .../patches/*.patch; do git apply "$p"; done

# [3] GNU patch -Np1（makepkg 使用的实现），按序 10/10 APPLIED（0001–0010 阶段）；0011–0014 在 makepkg 中一并通过
for p in .../patches/*.patch; do patch -Np1 -s -i "$p"; done

# [4] 与「精简后目标树」逐字节一致：补丁涉及 43 个文件，全部一致（0 差异）
```

额外实测（**强证据**，2026-11-14 16:56，使用最终版 `packaging/PKGBUILD`）：把官方 tarball
临时硬链接为本地 source 后运行

```bash
cd packaging && BUILDDIR=/tmp/pd-rc3/mkbuild5 makepkg --nodeps --nobuild
# 结果：官方 archive sha256 校验通过；本地 source（launcher/desktop/service/install/svg/apparmor）
#       校验通过；补丁 source 为 SKIP；prepare() 依次 apply 0001–0014，输出“源代码已就绪”；exit 0
# 生成树检查：apps/desktop/package.json 含 package:linux:x64:dir（--unsigned --dir），
#             apps/desktop/.env.linux.example 就位，desktop-build-paths.mjs 含 7 处 linux-x64。
```

其他静态校验：`bash -n PKGBUILD`、`bash -n deepseek-harness.install` 通过；
`makepkg --printsrcinfo` 输出正常（见 §7）。
（未运行完整 `pnpm build`/`makepkg`，按分工由 Lead 执行。）

## 7. 打包骨架（`packaging/`）

### 7.1 文件清单

| 文件 | 说明 |
|---|---|
| `PKGBUILD`（源码包） | pkgname `deepseek-harness-desktop-wayland`、pkgver `0.2.2rc3`、`arch=('x86_64')`、安装根 `/opt/deepseek-harness-desktop-wayland`；source = 官方 tag 归档（sha256 已 pin）+ 14 补丁 + 本地资产（平铺符号链接）；`prepare()` 重建工作树并按文件名顺序 `patch -Np1` 全部 14 个补丁；`build()` 隔离 pnpm 11 + `.env.linux` + electron 预热 + `package:linux:x64:dir`；`package()` 把 `linux-unpacked` 直接装 `/opt`。可完整复现构建 |
| `PKGBUILD.prebuilt`（预构建包） | 配合 Lead 的 `ci/package-wayland.sh`：source 只有 payload `dsh-payload.tar.zst`，资产从 `$startdir/{launcher,desktop,systemd,icons}` 安装；不重跑 pnpm/electron-builder，只做本地快速交付/验证 |
| `desktop/deepseek-harness.desktop` | `Name=DeepSeek Harness`；`Exec=/usr/bin/deepseek-harness-wayland %U`；`Icon=deepseek-harness`；`StartupWMClass=deepseek-harness`；`MimeType=x-scheme-handler/dsh` |
| `launcher/deepseek-harness`（经平铺符号链接 `deepseek-harness-wayland`） | wayland-analyst **已定稿**（7018B，sha256 `41c768d7…`；原生 Wayland + NVIDIA `--disable-features=Vulkan` + GPU 崩溃软件渲染重试一次 + `/tmp` noexec 的原生缓存目录兜底）。安装到 `/usr/bin/deepseek-harness-wayland`。若 launcher 再改动，需 `updpkgsums` 重算 PKGBUILD 校验和 |
| `icons/deepseek-harness.svg` | 上游 `apps/desktop/resources/icon-macos.svg`（原图，装 `hicolor/scalable/apps`） |
| `deepseek-harness.install` | pacman 脚本：按内核 userns 能力决定 `chrome-sandbox` 0755/4755；AppArmor 存在时加载 profile（Arch 默认不启用，惰性） |
| `deepseek-harness.apparmor` | 上游 AppArmor 模板，路径改为新安装根；装到 `/etc/apparmor.d/deepseek-harness` |
| `systemd/deepseek-harness-desktop.service` | 可选用户单元，**只安装不 enable** |
| `0001…0010*.patch`（符号链接） | 指向 `../patches/`，让 makepkg 能按扁平 source 名读取（makepkg 不支持本地 source 子目录，实测） |

### 7.2 PKGBUILD 关键决策

- **只跑 `--dir`**：`package:linux:x64:dir`（新 0006 提供，内部带 `--unsigned`）→
  `apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked`；
  package() 直接 `cp -a` 到 `/opt`，不打包 AppImage/deb/rpm。
- **`.env.linux` 由 build() 生成**（不入 source）：`DSH_DESKTOP_APP_ID=com.deepseek.dsh`
  （与 Lead `ci/build-wayland.sh` 一致），可选 `DSH_DESKTOP_NPM_REGISTRY`（打包期内部 pnpm）。
- **提交信息显式注入**（补丁 0010 依赖）：`DSH_DESKTOP_BUILD_COMMIT=<commit>`、
  `DSH_DESKTOP_BUILD_DIRTY=1`、`DSH_CLIENT_COMMIT_HASH=<commit>`。tarball 无 `.git`，不注入则
  0010 会明确报错（见 §8 第 1 条）。
- **pnpm 选择**：`DSH_PNPM` → `~/.local/share/dsh-pnpm-11/node_modules/.bin/pnpm` →
  系统 `pnpm`，且必须 `11.*`；pnpm 12 会把入口换成 `@pnpm/exe`(ELF) 导致
  `node $npm_execpath` 崩溃（已实测）。
- **依赖**：`gtk3 nss libnotify libxtst xdg-utils at-spi2-core libsecret alsa-lib dbus
  libxcrypt-compat`（libxcrypt-compat 供捆绑 Python 的 `_crypt`）；**不再需要
  libdbusmenu-glib**（无托盘）；`makedepends: nodejs pnpm python`；其余 base-devel。
- **包关系**：`provides=('deepseek-harness-desktop')`；
  `conflicts=('deepseek-harness-desktop-linux' 'deepseek-harness-desktop-linux-bin'
  'dsh-desktop-linux' 'deepseek-harness-desktop')`；
  `replaces=('deepseek-harness-desktop-linux' 'deepseek-harness-desktop-linux-bin')`。
- **入口**：`/usr/bin/deepseek-harness-wayland`（脚本）+ 兼容 symlink
  `/usr/bin/deepseek-harness`（→ 前者）。
- **可选本地构建环境变量**：`DSH_DESKTOP_LINUX_DOWNLOAD_CACHE`（复用 Electron/primary-runtime
  下载缓存）、`ELECTRON_MIRROR`（本机镜像 `http://127.0.0.1:8899/`）、`DSH_DESKTOP_NPM_REGISTRY`。
- **扁平 source 限制**：`packaging/` 根下的 `0001…0010*.patch`、`deepseek-harness-wayland`、
  `deepseek-harness.desktop`、`deepseek-harness.svg`、`deepseek-harness-desktop.service`、
  `deepseek-harness.install`、`deepseek-harness.apparmor` 是**平铺符号链接**（单一来源分别是
  `../patches/`、`launcher/`、`desktop/`、`icons/`、`systemd/`）。makepkg 不支持本地 source
  子目录（实测），因此不能用 `launcher/deepseek-harness` 这种 source 名；复制本目录去别处请
  `cp -aL`（PKGBUILD 头注释已写明）。`makepkg --printsrcinfo` 已通过。
- **`prepare()` 可重复**：失败重跑时 makepkg 会重新解包（覆盖已改文件）但保留补丁新增文件，
  会造成补丁“半应用”；因此 `prepare()` 先从 `$srcdir/$_srcdirname.tar.gz` 重建工作树再打补丁。
- **`package()` 补丁**：`chrome-sandbox` 在包内给 0755，setuid 位由 `.install`
  （`unshare --user true` 成功 → 0755，否则 4755）在安装/升级时决定，与上游 deb/rpm postinst 一致。

## 8. 给 Lead 的 build 脚本修改清单

1. **`ci/build-wayland.sh` 的 3 个 export 已由 Lead 补齐（16:54 版本已含 `COMMIT` +
   `DSH_CLIENT_COMMIT_HASH` + `DSH_DESKTOP_BUILD_COMMIT` + `DSH_DESKTOP_BUILD_DIRTY`）**，
   只需保持：tarball 树无 `.git`，缺这些变量时 0010（`readDesktopBuildCommit`）会明确报
   “is not a Git checkout”，client 构建环境也会走 git 探测。
2. `ci/build-wayland.sh` 当前**不 apply 补丁**（注释：由调用方预 apply）——CI 全流程建议加：
   `for p in patches/*.patch; do (cd "$TREE" && git apply "$p"); done`（或 `patch -Np1`），
   并在 apply 后断言 `apps/desktop/package.json` 里有 `package:linux:x64:dir`、
   `scripts/desktop-build-paths.mjs` 里有 `linux-x64`。
3. 旧的 `ci/build-in-arch.sh`（从旧仓库复制）若继续用，需改：
   - `PACKAGING_DIR` 指向 `packaging/`（不再有 `aur/<pkgname>` 子目录、不再有 `-bin` 包）；
   - 包名/目录名：`deepseek-harness-desktop-linux{,-bin}` → `deepseek-harness-desktop-wayland`；
   - 删除对 `apps/desktop/scripts/linux-runtime-adjustments.ts`、`apps/desktop/src/gpu-fallback.ts`、
     `linux-shell.ts` ozone marker 的断言；`.env.linux` 与 `package:linux:x64:dir` 两个 marker 保留；
   - `prepare()` 用 `patch -Np1`（或 git apply）按文件名顺序应用 10 个补丁；
   - 不再做 AUR source/.SRCINFO 产物的假设。
4. `ci/package-wayland.sh`（Lead 已写）与 `packaging/PKGBUILD.prebuilt` 配套：它把
   `linux-unpacked` 压成 `dsh-payload.tar.zst`，再平铺 `launcher/ desktop/ systemd/ icons/`
   与 `.apparmor`/`.install` 到临时 makepkg 目录后 `makepkg --skipinteg`。本仓库已提供
   `PKGBUILD.prebuilt`（payload 从 `$srcdir` 解包、资产从 `$startdir` 安装）——**Lead 此前
   引用的 `packaging/PKGBUILD.prebuilt` 现已就位**。正式交付前建议把上游 `LICENSE` 也平铺进去。
5. Electron 下载：源码包 `PKGBUILD` 用 `node apps/desktop/node_modules/electron/install.js`
   预热，支持 `ELECTRON_MIRROR`；Lead 的 build 脚本已经用本机镜像。

## 9. 待 Lead 实测 / 待实测确认项（事实 vs 推断已分开）

**已证实（本会话证据）**：10 补丁 apply/顺序/内容一致；`makepkg --nobuild` 源码校验 +
prepare 通过；PKGBUILD/install 语法与 printsrcinfo 通过；pnpm 12→`@pnpm/exe` 卡点机制。

**待实测（推断，按当前证据高置信）**：
1. 完整 `makepkg -C -s --nocheck`（不含 pnpm build 之外的未验证步骤）能否一次通过；
   特别是 `node electron/install.js` 在镜像/缓存命中时的行为。
2. 安装后的 `.desktop` 与 Wayland `app_id` 是否匹配（StartupWMClass + 0003 的
   `desktopName`/`syncDesktopName`）；Wayland 下 `wl_display` 原生窗口证据由
   wayland-analyst 给。
3. Launcher 已在 16:55 定稿（`packaging/launcher/deepseek-harness`，sha256 `41c768d7…`，
   与 `launcher/deepseek-harness` 同一内容）；**若 wayland-analyst 再次改动，务必
   `cd packaging && updpkgsums` 重算**，否则 makepkg 校验失败（已实测该失败模式）。
4. Office 转换路径（LibreOfficeKit ASAR 探测）在安装包里跑一次真实转换（预期正常）。
5. console 零 error（console-analyst 结论）；updater 无初始化报错（预期：无 `app-update.yml`
   → disabled）。
6. `arch=('x86_64')`：aarch64 需在原生 arm64 机器构建（ffyfox 用 GitHub ARM runner），
   当前不承诺；补丁的 arm64 逻辑已保留但因宿主守卫不会启用。
7. 与旧包并存/替换：`conflicts/replaces` 是否按用户预期的本地旧包名生效（旧包
   `deepseek-harness-desktop-linux`）。
8. **`ci/build-wayland.sh` 是否已有上述 3 个 export**（已由 Lead 在 16:54 版本补齐；见 §8-1）。
9. **0011–0014 的内容归属**：格式已修复且可 apply，但语义（首帧底色、隐藏更新入口、GPU
   launch-failed 退出码 75、account 错误降级）应由原并行作者 / Lead 复核后再定稿；本工程师
   未修改其内容。若其中任何一条被否决，从 `patches/` 删除并同步删除 `packaging/` 的平铺符号链接
   与 PKGBUILD `source` 行即可（prepare 用 `0*.patch` 通配）。

## 10. 复现与校验命令（Lead 可直接用）

```bash
# 补丁静态校验（不修改 pristine 树）
export GIT_CEILING_DIRECTORIES=/home/Arch/dsh-builds/rc3-wayland
cd /home/Arch/dsh-builds/rc3-wayland/src
for p in /home/Arch/dsh-re/dsh-desktop-wayland/patches/*.patch; do
  git apply --check "$p" || { echo "FAIL $p"; break; }
done && echo "all patches apply --check OK"

# 顺序 apply（在一次性副本上）
rsync -a /home/Arch/dsh-builds/rc3-wayland/src/ /tmp/rc3-verify/
cd /tmp/rc3-verify && for p in /home/Arch/dsh-re/dsh-desktop-wayland/patches/*.patch; do git apply "$p"; done

# PKGBUILD 静态校验
cd /home/Arch/dsh-re/dsh-desktop-wayland/packaging
bash -n PKGBUILD && bash -n deepseek-harness.install
makepkg --printsrcinfo >/dev/null && echo "PKGBUILD OK"

# （Lead 执行）完整构建 + 打包
cd /home/Arch/dsh-re/dsh-desktop-wayland
ci/build-wayland.sh /home/Arch/dsh-builds/rc3-wayland/src --dir   # 需先补 §8-1 的 export 并预 apply 补丁
# 然后把 patches/ + packaging/ 平铺到暂存目录后 makepkg
```
