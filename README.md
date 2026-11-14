# deepseek-harness-desktop-wayland

基于官方 **DeepSeek Harness `dsh-v0.2.2-rc.3`** 源码、面向 Arch Linux / niri(Wayland) / NVIDIA 的全新 Linux 桌面端构建。

- **忠实官方源码**：补丁只做「让官方流水线在 Linux 上工作 + 必要运行时收敛」，不含托盘、主题、磨砂、remote bridge、TUI 等美化/附加功能。
- **原生 Wayland**：不安装、不启动任何 X11/XWayland 回退路径；Wayland 会话下强制 `--ozone-platform=wayland`。
- **GPU 渲染优先**：默认 GPU 合成（ANGLE OpenGL，NVIDIA 硬件）+ VA-API/NVDEC 硬件解码；只有 GPU 进程彻底不可用时才做一次软件渲染兜底（仍原生 Wayland）。
- **零 console 报错**：全新 profile 与「用户 profile（移除实验 Inspector bundle）」下 DevTools console 均 0 error/0 warning（见 `research/rc3-build-verification.md`）。
- **无应用内更新**：pacman 统一管更新；Linux 上隐藏「检查更新」入口。
- **无顶栏菜单**：Linux 上移除上游 GTK「应用/Edit」菜单条（F12 仍可开 DevTools）。

## 产物

| 项 | 值 |
|---|---|
| 包名 | `deepseek-harness-desktop-wayland` |
| 版本 | `0.2.2rc3-1` |
| 安装根 | `/opt/deepseek-harness-desktop-wayland` |
| 启动器 | `/usr/bin/deepseek-harness-wayland`（+ 兼容 symlink `/usr/bin/deepseek-harness`） |
| pacman 包 | `deepseek-harness-desktop-wayland-0.2.2rc3-1-x86_64.pkg.tar.zst`（本地构建，sha256 见 `research/rc3-build-verification.md`） |
| 旧包关系 | `provides/conflicts/replaces`：`deepseek-harness-desktop-linux`（安装时提示替换旧包） |

## 安装 / 回滚

```bash
# 1) 刷新 localrepo 元数据（REPO 在本机 /srv/localrepo）
sudo pacman -Sy

# 2) 安装新包；pacman 会提示替换旧的 deepseek-harness-desktop-linux
sudo pacman -S deepseek-harness-desktop-wayland

# 3) 关闭正在运行的旧桌面端，然后从应用菜单启动 "DeepSeek Harness"
#    （用户级 ~/.local/share/applications/deepseek-harness.desktop 若存在，其 Exec 仍兼容）

# 回滚
sudo pacman -R deepseek-harness-desktop-wayland
sudo pacman -S deepseek-harness-desktop-linux   # 旧包仍在 localrepo
```

## 构建

前置：Arch（`base-devel`）、`nodejs`、`pnpm`、`python`。仓库要求 pnpm 11.x 且入口可被 node 执行；若系统 pnpm 是二进制入口，构建脚本会回退到隔离版：

```bash
npm i --prefix ~/.local/share/dsh-pnpm-11 pnpm@11.28.5
```

构建（从官方 tarball 重建 + 应用 16 个补丁 + electron-builder `linux-x64 --dir`）：

```bash
# 官方归档（sha256 已 pin）放到 CI 缓存目录，或让脚本自动下载
ci/build-wayland.sh <upstream-tree> --dir
# 说明：<upstream-tree> 需为官方 tag 解压后已按序应用 patches/*.patch 的树；
#       也可直接用 packaging/PKGBUILD 全量 makepkg（prepare 自动打补丁 + build）。
```

打包成本地 pacman 包（预构建载荷，快速交付）：

```bash
ci/package-wayland.sh <upstream-tree>/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked <out-dir> 0.2.2rc3
# 或全量源码包：cd packaging && makepkg -C -s --nocheck
```

## 补丁系列（16 个，`patches/`）

**构建启用（0001–0010，43 文件 / +414 −125）**：基于 ffyfox/dsh-desktop-linux 的 Linux 移植经验重写并精简（保留 MIT 归属说明），去掉全部测试/deb/rpm/AppImage/美化 hunk：

| # | 内容 |
|---|---|
| 0001 | desktop target 模型支持 `linux-x64` |
| 0002 | `package-target.ts` 支持 Linux target |
| 0003 | electron-builder Linux 配置（asar 关闭、desktopName、icon、无策略） |
| 0004 | 分发 Electron 二进制（Linux 解压布局） |
| 0005 | `.env.linux` 发布设置 + 工具链探测（Linux） |
| 0006 | Linux 打包 scripts；local profile 也带官方品牌 |
| 0007 | Host 改为 primary-runtime 独立 Node（Linux 上不用 Electron Node 模式） |
| 0008 | 打包/冒烟链路适配 Linux 独立 Node |
| 0009 | Linux 不嵌入/不轮询强制更新策略（policy opt-out） |
| 0010 | release 源码无 `.git` 时从环境录制 build commit |

**运行期收敛（0011–0016，199 行）**：

| # | 内容 |
|---|---|
| 0011 | Linux 主窗口/welcome 首帧背景色跟随主题（消除白闪） |
| 0012 | Linux 隐藏「检查更新…」菜单项（pacman 管更新） |
| 0013 | GPU `launch-failed` 时 `app.exit(75)` 交 launcher 一次性软件渲染兜底 |
| 0014 | account profile 读取失败在 Linux 降级为 info（无账户后端属预期） |
| 0015 | 会话 reference 已释放属正常 teardown，不再打 error |
| 0016 | Linux 移除 GTK 应用菜单条（`Menu.setApplicationMenu(null)`），F12 保留 DevTools |

## 运行期设计

- `packaging/launcher/deepseek-harness`：Wayland 下强制 `--ozone-platform=wayland`；默认 `--disable-features=Vulkan`（NVIDIA+Wayland 保险，实测无副作用）；硬件解码/光栅化 flags 与同机 Google Chrome 153 实测组合一致（`VaapiOnNvidiaGPUs,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,PlatformHEVCDecoderSupport` + `--enable-gpu-rasterization --enable-zero-copy`）；`LIBVA_DRIVER_NAME=nvidia` 仅在缺失且存在 `nvidia_drv_video.so` 时兜底。
- GPU 彻底不可用（exit 75 / SIGTRAP + GPU 关键日志）时**只重试一次** `--disable-gpu --disable-gpu-compositing`，仍是原生 Wayland，不切 X11。
- 可通过 `DSH_GPU_HWDECODE=0`、`DSH_GPU_RASTERIZATION=0`、`DSH_GPU_ZERO_COPY=0`、`DSH_WAYLAND_SYNCOBJ=0`、`DSH_GPU_FALLBACK=0`、`DSH_GPU_SOFTWARE=1` 调整。

## 已知限制

- `video_encode` 在 Chromium/NVIDIA 上为 `disabled_software`：**解码硬解**已启用，**编码**仍走软件（Chromium 的 VA-API encode 在 NVIDIA 路径不暴露）。
- niri 26.04 未宣告 `linux-drm-syncobj-v1`，显式同步 flag 目前为 no-op（保留前向兼容）。
- 稳定性矩阵累计 ~15 min（8 组合）与最终包抽测通过；24 h+ soak、挂起/恢复、多显示器未覆盖。
- 本包为**本地预构建载荷**打包（非 AUR 发布）；可复现性由官方归档 sha256 + 16 补丁 + 构建脚本保证。
- 用户 profile 若保留 `@deepseek-ai/dsh-experimental-inspector-profile` 会出现 19 条 console error（且 9230 为无认证 CDP 调试端口，有安全风险）；零报错验收要求移除该 bundle（见验证报告）。

## 目录

```
ci/          build-wayland.sh（构建） / package-wayland.sh（打包）
patches/     16 个补丁（0001–0016）
packaging/   PKGBUILD（源码包）、PKGBUILD.prebuilt（快速交付）、launcher、desktop、systemd、icons、AppArmor、install
launcher/    launcher 副本（wayland-analyst 交付位置）
reference/   ffyfox-patches 参考（MIT，构建启用补丁的来源基线，未直接复用为运行时补丁）
work/        构建镜像/缓存（gitignore）
```
