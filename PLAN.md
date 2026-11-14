# DSH-Desktop-Wayland（rc.3 全新构建）计划与决策记录

> 创建：2026-11-14 16:40（Asia/Shanghai）。目标：基于官方 `dsh-v0.2.2-rc.3` 源码，构建**全新的**、忠实上游、原生 Wayland、渲染稳定无闪烁、DevTools console 零报错的 Linux 桌面发行包。
> 本仓库**不复用**旧 `dsh-desktop-integration` 的补丁系列（旧 3437 行/48 文件补丁只作为"官方为 mac/win 构建，Linux 需要哪些接线"的参考），重新设计最小补丁。

## 1. 固定事实（2026-11-14）

| 项 | 值 |
|---|---|
| 上游 tag | `dsh-v0.2.2-rc.3` |
| 上游 commit | `38a6a5c965aa99ab525161efb7cc5cf1fe62fced` |
| 官方 archive | `https://github.com/deepseek-ai/deepseek-harness/archive/dsh-v0.2.2-rc.3.tar.gz`（实测 41 MB） |
| archive sha256 | `bf6d668e52a26edf98aa2ef7960e240c8d9afcefbad2b09887a2cb1e14001dd5` |
| Electron | 44.7.0（rc.3 lockfile，`electron@44.7.0`） |
| 本机 | Arch Linux / niri 26.04 / NVIDIA 620.70.06 open / 31 GiB RAM |
| 构建工具链 | 系统 node v26.13.1、pnpm 12.19.0；仓库要求 engines 见 package.json（构建需 Node ≥ 22/24，实测旧构建用系统 node） |
| 本地 Electron 镜像 | `http://127.0.0.1:8899/`（systemd unit `dsh-electron-mirror`，指向 `work/local-electron-mirror/v44.7.0`，zip 来自 `~/dsh-builds/downloads-cache/5a625dfd…`） |
| 工作目录 | `/home/Arch/dsh-builds/rc3-wayland/`（`src/` 官方 pristine、`warm/` 已 pnpm install、`ref-rc1/` rc.1 对照） |

## 2. 新包设计决策

| 项 | 决定 | 理由 |
|---|---|---|
| pkgname | `deepseek-harness-desktop-wayland` | 全新包，不与旧包混淆 |
| 安装根 | `/opt/deepseek-harness-desktop-wayland` | 与旧包 `/opt/deepseek-harness-desktop` 可并存/对比，回滚只需重装旧包 |
| launcher | `/usr/bin/deepseek-harness-wayland`（主）+ `/usr/bin/deepseek-harness`（兼容 symlink） | 兼容用户已有的 `~/.local/bin/deepseek-harness` shim 与用户级 `.desktop` 入口 |
| desktop entry | `/usr/share/applications/deepseek-harness.desktop`（Name 与官方一致） | 保持系统级入口不变 |
| 包关系 | `provides=('deepseek-harness-desktop')`；`conflicts=('deepseek-harness-desktop-linux' …)`；`replaces=('deepseek-harness-desktop-linux')` | 安装前可显式替换旧包；卸载旧包后无残留 |
| 美化 | **无**：不加托盘、无顶栏菜单、无磨砂、无主题图标、无 remote bridge、无 TUI、无 locale 扩展 | 用户要求「原汁原味」，减少补丁面 |
| Wayland | 原生 Wayland 优先，不主动 XWayland；launcher 强制 `--ozone-platform=wayland`（Wayland 会话下） | 用户要求 |
| GPU/渲染 | 由 launcher 默认最小 flag 集 + 仅 GPU 彻底不可用时软件渲染兜底（不切 X11） | 稳定性优先 |
| 更新 | Linux 禁用应用内更新/更新菜单（pacman 管更新）；最小补丁 | 避免 Linux 上 updater 报错 |
| 交付 | 源码树 + 补丁 + 构建脚本 + pacman 包（localrepo 发布）+ 验证报告 | 用户可安装、可回滚、可复现 |

## 3. 目录

```
ci/            build/verify 脚本（Lead 负责 build-wayland.sh）
patches/       新补丁系列（P1 构建启用 / P2 运行时兼容 / P3 稳定性 / P4 无更新）
packaging/     PKGBUILD、launcher、desktop entry、systemd unit、icon
launcher/      Wayland launcher 草案（wayland-analyst 产出）
work/          本地构建镜像/临时（gitignore）
```

## 4. 阶段

1. **P1 构建启用**（patch-designer）：让 rc.3 在 Linux 上产出 `linux-unpacked`；目标文件数 < 旧补丁一半。
2. **P2 运行时兼容**（Lead/patch-designer）：sharp/Electron、LibreOfficeKit ASAR 等经实测仍需的最小兼容；不先验添加。
3. **P3 稳定性**（wayland-analyst + Lead）：launcher flags/env、GPU 失败策略；先实测后写码。
4. **P4 无应用内更新**（Lead）：最小 gating（menu/自动检查/policy），不改 UI 外观。
5. **构建 + 冒烟**（Lead）：`ci/build-wayland.sh`，warm pnpm store + 本地 Electron 镜像；产物 `linux-unpacked` + pacman 包 + 元数据。
6. **零 console 报错验证**（console-analyst）：新包测试实例 CDP 全量捕获，error 清零/归因。
7. **Wayland 稳定性验证**（wayland-analyst）：原生 Wayland 证据、GPU 进程稳定、静止画面无闪烁。
8. **独立审计 + 交付**（verifier）：报告、命令、风险；用户安装由用户执行（重启桌面端）。

## 5. 纪律/边界

- 不 kill/重启当前运行的旧 Desktop（PID 4821/5144，当前会话在其中）；测试实例必须隔离并清理。
- 不修改 `/opt`、旧仓库、真实 `~/.dsh`；测试 profile 用 /tmp 副本。
- 包发布走 `dsh-root` 窗口 + `/usr/local/bin/dsh-localrepo-publish`；安装由用户执行 `sudo pacman -Syu`。
- 安全红线：不提交任何凭据；测试实例用完即清理。

## 6. 验收（最终）

- [ ] 新包可从官方 rc.3 源码一次性重建（脚本 + 补丁 + pinned sha256）
- [ ] 新包在新 profile 下 DevTools console 无 error；用户 profile 下错误逐条归因（官方/插件/数据），官方的修掉
- [ ] 原生 Wayland：进程无 XWayland 回退；窗口 app_id 正确
- [ ] 稳定性：GPU 进程不崩溃、无 `GPU process isn't usable`、静止画面截图无闪烁；长时间 soak 通过
- [ ] 无应用内更新入口；无美化补丁
- [ ] 审查通过（独立 verifier），产物 + 安装/回滚命令交付
