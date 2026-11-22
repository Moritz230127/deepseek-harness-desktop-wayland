# 打包最小化与性能审查（2026-11-22）

## 结论

当前包已经接近“最小改动”的合理形态，不需要为了 NVIDIA 显示问题再加源码补丁。
本轮实际改动集中在：

1. 依赖补全（`wayland` / `libdrm` / `mesa`）和 `pkgdesc` 纠正（非官方构建）；
2. `-git` 式跟踪节奏与补丁自动 `pkgrel`；
3. 把 NVIDIA + niri 的稳定性修复放到 **niri 全局配置**
   （`wait-for-frame-completion-before-queueing`），不动 dsh 源码；
   不使用按窗口的 opacity/圆角覆盖（用户要求全局一致外观）。

## 17 个补丁的必要性

| 补丁 | 作用 | 必要性 |
|---|---|---|
| 0001–0006 | Linux 目标模型、electron-builder 配置、`package:linux:*` 脚本、发布设置 | **必需**（上游没有 Linux 发布接线） |
| 0007–0008 | 独立 Node 宿主（避开 Electron 链接 glib 导致 libvips 崩溃）、打包/冒烟链路 | **必需**（否则 Host 不稳定） |
| 0009 | Linux 不嵌入/不轮询强制更新策略 | **必需**（Linux 无更新通道） |
| 0010 | release 源码包无 `.git` 时记录 commit/dirty | **必需**（可复现构建） |
| 0011 | Linux 窗口 `backgroundColor`，防深色主题首帧白闪 | 建议保留（视觉稳定性，~4 行） |
| 0012 | Linux 隐藏应用内更新入口 | 建议保留（pacman 管更新，避免失败路径） |
| 0013 | GPU `launch-failed` 时退出 75，交给 launcher 软件兜底 | 建议保留（NVIDIA 兜底协议） |
| 0016 | 移除 Linux GTK 菜单条，保留 F12 DevTools | 建议保留（去重复 UI） |
| 0014 / 0015 / 0017 | 把 Linux 预期失败/已释放引用/缺失 summary 从 console error 降噪 | **可选**：纯 console 清洁，不影响功能/渲染；若追求“补丁最少”可删 |

运行时补丁合计约 250 行，其中真正影响显示的只有 0011（背景色）；其余是构建接线、更新入口、
GPU 兜底和 console 降噪。**没有为了 NVIDIA 闪烁改 dsh 源码**——那属于合成器同步问题，
见 [nvidia-niri.md](nvidia-niri.md)。

## 依赖

`depends` 补了 `wayland`、`libdrm`、`mesa`：Electron 直接链接 `libwayland-client/egl`、
`libdrm`、`libgbm`（`mesa` 提供），此前靠 `gtk3` 的传递依赖，最小系统上不保险。
`optdepends` 补了 `libva-nvidia-driver`（VA-API/NVDEC 硬解）。

## 构建耗时与缓存

一次构建约 12 分钟：free disk ~2 分钟 + Arch 容器内 `pacman -Syu` / 依赖 / `pnpm install` /
Electron 下载 / `package:linux:x64:dir` ~9 分钟。可行的优化（未在本轮实现）：

- `actions/cache` 缓存 pnpm store（按 `pnpm-lock.yaml` 哈希）和 `apps/desktop/.desktop-build/downloads`；
  需要把 store 指到 workspace 内（例如 `PNPM_STORE_DIR=/w/.pnpm-store`），否则容器销毁后缓存丢失。
- 预构建一个带 `nodejs/pnpm/python/gtk4` 的 Arch 镜像，省掉每次 `pacman -Syu`。
- `free disk space` 只在空间不足时执行；GitHub 标准 runner 通常够用。
- 这些优化不影响正确性，优先级低于“发版延迟”和稳定性。

## 启动器 / desktop entry

- `Exec=/usr/bin/deepseek-harness-wayland %U`、`StartupWMClass=deepseek-harness` 与 niri 的
  app-id 一致；`TryExec`、icon、MIME 均正常。
- launcher 默认只加 `--ozone-platform=wayland`、NVIDIA 下 `--disable-features=Vulkan`、
  VA-API/GPU raster/zero-copy、GPU 崩溃单次软件兜底；没有再堆叠“优化”flag。
- 新增 `/usr/bin/dsh-wayland-doctor`：只读检查 NVIDIA/niri/explicit sync/GPU 日志并给建议；
  PKGBUILD 增加该 source 与校验和。
- **本轮发现并修复了 launcher 源/打包副本漂移**：`packaging/deepseek-harness-wayland` 解析到
  `packaging/launcher/deepseek-harness`，而不是根 `launcher/deepseek-harness`；只改根源会导致
  修复不进包（本轮 `DSH_GPU_COMPOSITING` 就差点漏掉）。已同步副本、更新 PKGBUILD 校验和，
  并在 `ci/ci-build.sh` 加 `diff -q` 守卫，后续漂移会直接失败。
- 不建议默认加 `--disable-gpu-compositing`：它能消除闪烁但把 UI 合成降为软件，
  违背“GPU 硬渲染 + 最高速”。仅在 niri 配置无效时作为排障开关。

## 版本排序

`vercmp` 实测：`0.2.3.alpha.1-1 > 0.2.3-1`（pacman 把预发布后缀当额外段，反而“更新”）。
当前 pkgver 总是带 `.rN.gSHA`，所以正式版会变成 `0.2.3.r0.g<sha>`，仍大于 alpha，不会踩坑；
若未来改成“直接发干净 tag 版本”（`pkgver=0.2.3`），必须加 `epoch=1` 或换版本方案。

## 包名与 `dsh-git`

见 README 的“这是不是 dsh-git”一节：语义是 `-git`，包名保留是为了避免迁移；
若要对齐 AUR，可改 `dsh-git` + `provides/conflicts/replaces`，一次性迁移。

## 风险

- 上游 `master` 变化快，补丁 rebase 仍是唯一需要人介入的步骤；CI 失败会开 issue，不会发坏包。
- 单包 359 MB，cooldown 是带宽/Release 存储的必要保护；新 tag 会绕过 cooldown。
- niri 26.04 无 explicit sync；在 niri 支持 `linux-drm-syncobj-v1` 前，`wait-for-frame-completion-before-queueing`
  是已知最有效的缓解，debug 选项可能随 niri 版本变化。
