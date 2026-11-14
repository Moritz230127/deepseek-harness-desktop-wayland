# rc.3 原生 Wayland + NVIDIA 稳定无闪烁：运行时方案调研与 launcher 草案

> 任务：task-6（Team Lead「rc.3 Linux 包构建与优化」）。
> 产出：本报告 + `/home/Arch/dsh-re/dsh-desktop-wayland/launcher/deepseek-harness`（launcher 最终草案）。
> 实验环境时间：2026-11-14 16:37–17:1x（Asia/Shanghai）。实验期间未干扰运行中的旧桌面端 PID 4821/5144。
> **最终结论以 rc.3 官方构建（linux-unpacked）实测为准**；rc.1 安装包二进制仅用于方法预演/交叉对照。

---

## 0. 结论摘要（先看这里）

### 0.1 一句话结论

在 `niri 26.04 / Wayland / NVIDIA RTX 4060 Laptop（open 驱动 620.70.06）/ Electron 44.7.0（Chromium 152.0.7977.130）` 上：

1. **rc.3 默认渲染路径根本不是 Vulkan**：`SystemInfo.getInfo` 显示 `displayType=ANGLE_OPENGL`、`glImplementationParts=(gl=egl-angle,angle=opengl)`、`skiaBackendType=GaneshGL`、driver 620.70.06、`sandboxed=true`；WebGL renderer 为 `ANGLE (NVIDIA ... RTX 4060 ... OpenGL ES 3.2)`。
2. `ERROR ... wayland_surface_factory.cc:249 '--ozone-platform=wayland' is not compatible with Vulkan` 是 **ANGLE 初始化时探测 Vulkan surface 失败后的回退日志**，出现后 GPU 进程照常工作；**加 `--disable-features=Vulkan` 后该行原样存在**。它**不是**崩溃原因，只是噪音（详见 §3.4）。
3. 本轮对 rc.3 官方构建做隔离矩阵（默认 106 s + 7 组组合各 ~105 s，含 welcome 静态、主界面、双向滚动 + WebGL 压力）：**默认组合（不加任何 GPU flag）即全程稳定**——GPU 进程 PID 不变、0 次 `GPU process isn't usable`、0 次 FATAL、静态截图逐像素一致、滚动 ~145 fps（p95≈7 ms、无 >50 ms 掉帧）。
4. Lead 此前观察到的 “~20 s 后应用自己 FATAL 退出” 序列（Vulkan 警告 → zygote 失败 → network service crashed → `GPU process launch failed: error_code=1002 ×7` → `GPU process isn't usable. Goodbye.`），**与“整个进程组/子进程被外部 kill”时 Chromium 打印的日志逐行一致**（本机已复现同款序列，见 §3.5）。该现象是**测试脚本结束/清理进程树造成的伪崩溃**，不是 rc.3 自崩，也不能作为 “必须禁用 Vulkan” 的证据。
5. 推荐最小默认：**`--ozone-platform=wayland`（必须）+ `--disable-features=Vulkan`（保险，见下）**；`--enable-features=WaylandLinuxDrmSyncobj` 因 niri 26.04 未宣告 `linux-drm-syncobj-v1` 而**无效**（保留与否无差别）；GPU 彻底不可用时**只做一次软件渲染兜底（仍原生 Wayland），绝不切 X11**。
6. **main.ts 渲染稳定性无需改代码**；仅建议 2 处可选最小改动：① Linux 窗口 `backgroundColor` 跟随主题防白闪（~4 行）；② 若要“确定性 GPU 兜底协议”可加 ~20 行 `child-process-gone → app.exit(75)`（可选，launcher 已能靠 SIGTRAP+stderr 识别）。

### 0.2 关键判断（事实 / 推断分开）

| # | 判断 | 性质 | 证据 |
|---|---|---|---|
| 1 | rc.3 默认渲染 = ANGLE OpenGL（NVIDIA），非 Vulkan | **事实** | CDP `SystemInfo.getInfo` auxAttributes（§3.4）；WebGL renderer 字符串 |
| 2 | Vulkan 警告是 ANGLE 探测回退日志，与崩溃无因果关系 | **事实**（警告在所有组合出现且 GPU 正常）+ **推断**（“无害回退”机制解释） | §3.4 全组合日志；`--disable-features=Vulkan` 不消除该行 |
| 3 | `--disable-features=Vulkan` 在默认路径无可见效果 | **事实** | GPU 进程 cmdline 已含 Vulkan、renderer/sysinfo/帧率/日志与 default 一致 |
| 4 | `--enable-features=Vulkan` 才会把 Skia 后端切到 `GaneshVulkan` | **事实** | `SystemInfo.getInfo.skiaBackendType` 从 `GaneshGL` 变 `GaneshVulkan` |
| 5 | niri 26.04 未宣告 `linux-drm-syncobj-v1`，显式同步 flag 无效 | **事实** | `wayland-info` 47 globals 列表无该协议；`--enable-features=WaylandLinuxDrmSyncobj` 组与 default 完全一致 |
| 6 | Lead 看到的 FATAL 序列 = 进程组被 kill 的伪崩溃 | **事实**（日志逐行一致可复现）+ **推断**（其测试命令结束时进程树被清理） | §3.5、`/tmp/rc3lab/logs/pilot.log` 对照 |
| 7 | 10-24 历史崩溃未在本轮 ~13 分钟累计观测中复现 | **事实（观测边界）** | 结果表：全部组合 0 崩溃标记；不能证明“已修复” |
| 8 | 需求“绝对不闪烁”只能在本轮采样粒度内成立 | **推断/限制** | 截图 1 Hz 级采样；无法排除单帧 tearing（§8） |

### 0.3 推荐配置（最终）

| 项 | 值 |
|---|---|
| 平台 | `--ozone-platform=wayland`（Wayland 会话下强制；不 fallback X11/XWayland） |
| Vulkan | `--disable-features=Vulkan`（NVIDIA 上默认开；Electron 44.7 默认路径无 Vulkan，故属“历史保险 + 防未来/用户侧开启”，实测无副作用） |
| 显式同步 | `--enable-features=WaylandLinuxDrmSyncobj`（niri 26.04 无协议 → 实测 no-op；保留=前向兼容，`DSH_WAYLAND_SYNCOBJ=0` 可关） |
| 软件兜底 | GPU 崩溃特征退出（exit 75 / SIGTRAP 等 + stderr GPU 关键字）时，**同一次启动内**重试 1 次 `--disable-gpu --disable-gpu-compositing`（Wayland），不写状态、不切 X11 |
| 不需要 | `--no-sandbox`（本机 userns 沙箱可用；launcher 仅在沙箱不可用时自动加）、`--disable-gpu-sandbox`、`--disable-dev-shm-usage`、`--use-angle=gl`、VSync/0c 类 env |
| main.ts | 无稳定性必需改动；可选 §6.1（防白闪）与 §6.2（exit 75 协议） |

---

## 1. 环境事实（均在本机核实）

| 项 | 值 | 来源 |
|---|---|---|
| OS / kernel | Arch Linux / `7.3.4-arch1-1`（PREEMPT_DYNAMIC） | `uname -srm` |
| 合成器 | niri `26.04 (8ed0da4)`，Wayland | `niri msg version` |
| 输出 | eDP-1 `2560x1600 @ 165.040 Hz`，**Scale 1.5 分数缩放**，VRR 支持但禁用 | `niri msg outputs` |
| GPU | NVIDIA GeForce RTX 4060 Laptop GPU，8188 MiB | `nvidia-smi` |
| 驱动 | `620.70.06`，NVIDIA **Open** Kernel Module（Dual MIT/GPL） | `/proc/driver/nvidia/version` |
| RAM | 31 GiB | `free -h` |
| Electron | `44.7.0` / Chromium `152.0.7977.130` | `version` 文件、二进制 strings |
| rc.3 源码 | `0.2.2-rc.3`，upstream commit `38a6a5c965aa99ab525161efb7cc5cf1fe62fced`，lockfile `electron@44.7.0` | `/home/Arch/dsh-builds/rc3-wayland/src` |
| rc.3 构建产物（本轮实测） | **Lead 构建的 linux-unpacked**：`/home/Arch/dsh-builds/rc3-wayland/p1-check2/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked/`（1.2 GB，`resources/app` 未 ASAR） | Lead 同步 + `ls` |
| rc.3 构建沙箱 | `chrome-sandbox` 为 755（非 setuid），但 `unprivileged_userns_clone=1` → userns 沙箱工作（`SystemInfo.sandboxed=true`），**不加 `--no-sandbox` 也能起** | 实测（§3.2） |
| 当前运行中的旧桌面端 | PID 4821（主）/5144（host），参数 `--disable-features=Vulkan --enable-features=WaylandLinuxDrmSyncobj`；实验期间稳定运行 6h+ | `ps` |
| 旧桌面端 GPU/renderer | 均含 `--ozone-platform=wayland`；GPU 进程另有 `--render-node-override=/dev/dri/renderD128` | `ps -eo args` |
| Wayland globals | 47 个；**无 `linux-drm-syncobj-v1`**；有 `zwp_linux_dmabuf_v1 v5`、`wp_fractional_scale_manager_v1`、`wp_presentation`、`wl_eglstream_display` | `wayland-info` |
| `/tmp` | `noexec`（脚本用 `bash <file>` 运行，二进制在 `/opt` 或构建目录） | `findmnt /tmp` |

### 1.1 rc.3 源码层面事实（与渲染/闪烁直接相关）

- `apps/desktop/src/main.ts`：**没有任何** `appendSwitch` / 默认 Chromium flag / GPU 回退逻辑（`grep appendSwitch` 空）→ 平台/GPU flag 只能由 launcher 提供。
- `apps/desktop/src/main.ts:264-294` `createWindow()`：`backgroundColor` 只在 win32 分支设置；macOS 透明；**Linux 无 `backgroundColor`**（默认白底）。
- `apps/desktop/src/main.ts:246`：`chromeFallbackFill() = nativeTheme.shouldUseDarkColors ? '#1b1b1c' : '#f9fafb'`（可复用）。
- `apps/desktop/src/welcome-window.ts:27`：welcome 窗口 Linux 固定 `backgroundColor: '#FFFFFF'` → 深色主题首帧白底风险。
- `enterWorkspace()`（main.ts:1365 附近）在 `window.show()` 前才导航主页面 → welcome→主窗口存在主题色过渡窗口。
- rc.3 `apps/desktop` 无旧 Linux GPU ladder / `linux-gpu-fallback.json` / `exit 75`（grep 空）→ 旧 3 级梯未被带进 rc.3，需按本报告建议重做（或不做）。

### 1.2 历史问题（旧包，仅供对照）

- 2026-10-24 GPU 崩溃后，旧仓库 `dsh-desktop-integration` commit `872ab91` 记录：“real GPU crashes exit 75 so the package launcher's Wayland->X11->software ladder owns recovery instead of racing Chromium's GPU abort (SIGTRAP core)”。
- 旧 app 补丁 `gpu-fallback.ts`（193 行）3 级梯 `default → --disable-gpu-sandbox → --disable-gpu --disable-gpu-compositing`，状态存 `userData/linux-gpu-fallback.json`，单级 2 次失败升级、稳定 10 min 降级；`GPU_FALLBACK_EXIT_CODE=75`。
- **旧梯从未在真实 GPU 上验证**：旧仓库 `handoffs/shell.md:158` 自述只在 Xvfb 验证过；`docs/VERIFICATION-v0.1.md:203` 仍列“在 Intel/AMD 硬件上验证 fallback ladder”为未完成。
- 旧 launcher（`/usr/bin/deepseek-harness`，与旧仓库 `packaging/launcher/deepseek-harness` 一致）默认加两项 flags，并在非 0 退出时做 **Wayland→X11→软件渲染** 重试——与新要求“原生 Wayland、不 fallback X11”冲突，不可沿用。

---

## 2. 测试方法（可复现）

### 2.1 隔离实例（不碰运行中实例 / 不写真实 `~/.dsh`）

```sh
LAB=/tmp/rc3lab
U=/home/Arch/dsh-builds/rc3-wayland/p1-check2/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked

# 一次性：复制桌面 profile 到临时 DSH_HOME（61 MB）
mkdir -p "$LAB/rc3home/profiles"
cp -a ~/.dsh/profiles/desktop "$LAB/rc3home/profiles/desktop"

# 每个组合：独立 user-data-dir、独立端口、独立进程组，绝不 kill 4821/5144
DSH_HOME="$LAB/rc3home" DSH_DESKTOP_HOST_INSPECT_PORT=9501 \
  env -u ELECTRON_RUN_AS_NODE setsid "$U/deepseek-harness" \
  --ozone-platform=wayland --user-data-dir="$LAB/ud-rc3-default" \
  --remote-debugging-port=9301 --remote-allow-origins='*' \
  --enable-logging=stderr --log-level=0 <组合 flag...> \
  > "$LAB/logs/rc3-default.log" 2>&1 &
```

要点：
- `env -u ELECTRON_RUN_AS_NODE`：本会话 shell 继承 `ELECTRON_RUN_AS_NODE=1`，不 unset 会变成 Node 模式；
- `setsid` 建独立进程组，清理时按 **`--user-data-dir=<唯一串>` 精确匹配 PID** 逐个 TERM/KILL，绝不用 `pkill -f`；
- 测试窗口出现后立即 `niri msg action focus-window --id <用户原窗口>` 还焦点；主窗口出现后“短暂聚焦 → `move-window-to-floating` → 还焦点”，对用户平铺布局的干扰 <1 s；
- 每轮结束先 `kill -TERM $MAINPID`（正常退出），并**只把 teardown 之前的崩溃行计入统计**；随后逐个结束残留 PID、`rm -rf` 该轮 user-data-dir。

### 2.2 每轮流程（~105 s，满足“每组 ≥60 s，最好 120 s”）

1. 启动 → 等 welcome 窗口（rc.3 构建 ~2 s 出现）→ 还焦点；
2. **welcome 静态**：CDP 读 `document.title/URL`、WebGL renderer、3 s rAF 帧节奏；每 4 s `niri msg action screenshot-window --id <wid>` 截图（6 张）；
3. **主界面**：CDP 点击 welcome `#skip-key`（「稍后配置」）→ 主窗口出现 → 转浮动 + 还焦点 → 读主页面 WebGL renderer、3 s rAF、`SystemInfo.getInfo`（等价 chrome://gpu）→ 每 4/8 s 截图（8 张）；
4. **交互/滚动**：CDP 注入 420×300 WebGL 动画 canvas（rAF 每帧换色，持续 GPU 负载），同时 `Input.dispatchMouseEvent(mouseWheel)` 连续滚动 12 s + 反向 6 s，记录页面 rAF 帧间隔统计 + 截图（5 张）；
5. 结束统计 → 精确清理。

### 2.3 指标定义

| 指标 | 采集方式 | 判读 |
|---|---|---|
| GPU 进程存活/重启 | 每 1 s 扫 `ps -eo args` 中 `--user-data-dir=<本轮>` 的 `--type=gpu-process` PID | PID 变化/消失 = 重启/崩溃 |
| GPU 崩溃/FATAL | stderr grep `GPU process isn't usable` / `GPU process launch failed` / `The GPU process has crashed` / `FATAL:content/browser/gpu` | 仅 teardown 前计数 |
| 是否硬件渲染 | CDP `SystemInfo.getInfo`（glRenderer/displayType/skiaBackendType）+ 页面 WebGL `WEBGL_debug_renderer_info` | NVIDIA/ANGLE=硬件；SwiftShader/llvmpipe=软件 |
| 帧节奏（静止） | 页面 rAF 3 s 帧间隔 | ~6.9 ms/帧 ≈ 165 Hz 显示器、~145 fps 实测 |
| 帧节奏（滚动+WebGL） | rAF 12 s + 6 s 滚动期间 | p95/max/`>50 ms` 次数 |
| 闪烁（静止） | `niri msg action screenshot-window --id` 每 4–8 s 截图，`magick compare -metric AE` 相邻比较 | AE=0/极小 = 采样窗口内无闪烁 |
| 闪烁（滚动） | 滚动期截图 + `magick identify -format '%[fx:standard_deviation]'` | 接近 0 的黑/白帧 = 异常 |
| 原生 Wayland | 各进程 `--ozone-platform=wayland`；`niri msg windows` 的 `app_id`；stderr 无 x11 回退 | 双重证据 |

### 2.4 方法与局限（必须承认）

- 每轮 ~105 s：**不能排除低频/长时累积崩溃**；本轮无法宣称 10-24 问题“已修复”，只能说“在观测窗口内 rc.3 稳定”。
- 截图 1 Hz 级采样：只能发现持续 >~1 s 的画面变化；**无法捕捉单帧 tearing/短瞬闪**；niri 无 per-frame presentation 统计。
- niri 26.04 未宣告显式同步协议 → “显式同步是否消除 NVIDIA tearing”在本机**无法验证**。
- 测试窗口为浮动窗口（减少对用户布局干扰），非全屏；多显示器/DPMS 熄屏唤醒/挂起恢复/HiDPI 之外的缩放/视频播放未覆盖。
- 实验时段本机同时跑着 rc.3 构建流水线（CPU 负载波动），帧率统计有噪声，但各组顺序、同条件，横向可比。
- rc.3 构建为 `linux-unpacked`（`resources/app` 未 ASAR、`chrome-sandbox` 未 setuid）而非最终 pacman 包；最终包需按 §7 复测。

---

## 3. 测试矩阵结果（rc.3 官方构建）

组合：均带 `--ozone-platform=wayland`；除特别标注外不加 `--no-sandbox`（本机 userns 沙箱可用）。每轮 ~105 s。

| # | tag | 附加 flags | 目的 |
|---|---|---|---|
| 1 | `rc3-default` | 无 | 基线（Electron 默认路径） |
| 2 | `rc3-lead-default` | `--no-sandbox` | **复现 Lead 的崩溃配置**（只加 no-sandbox，不关 Vulkan） |
| 3 | `rc3-novulkan` | `--disable-features=Vulkan` | Lead 要求重点验证 #1 |
| 4 | `rc3-both` | `--disable-features=Vulkan --enable-features=WaylandLinuxDrmSyncobj` | 旧方案完整 flag 集 |
| 5 | `rc3-syncobj` | `--enable-features=WaylandLinuxDrmSyncobj` | 单独 syncobj |
| 6 | `rc3-angle-gl` | `--use-angle=gl` | 备选（Lead #3） |
| 7 | `rc3-gpu-nosandbox` | `--disable-gpu-sandbox` | 候选（Lead #4） |
| 8 | `rc3-devshm` | `--disable-dev-shm-usage` | 候选（Lead #4） |

> 所有组合均使用 rc.3 linux-unpacked、原生 Wayland、独立 user-data-dir；`--no-sandbox` 仅 `rc3-lead-default` 显式添加（本机其余组合依赖 userns 沙箱，均正常）。**8/8 组合：结束存活=1、GPU 崩溃/FATAL 标记=0、GPU 进程 PID 全程不变（0 次重启）、WebGL renderer 均为 `ANGLE (NVIDIA … RTX 4060 … OpenGL ES 3.2)`（硬件）。**

| # | 组合（附加 flags） | 时长(s) | 结束存活 | GPU崩溃/FATAL | GPU PID变化 | GPU进程 | 静止welcome AE(max) | 静止main AE(max) | 滚动帧 n / p95 / max(ms) | >50ms |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `rc3-default`（无） | 106 | 1 | 0 | 0 | 1 | 0 | 108.8¹ | 1729 / 7 / 8.8 | 0 |
| 2 | `rc3-lead-default`（`--no-sandbox`，Lead 崩溃配置） | 106 | 1 | 0 | 0 | 1 | 0 | 0 | 1729 / 7 / 8.7 | 0 |
| 3 | `rc3-novulkan`（`--disable-features=Vulkan`） | 106 | 1 | 0 | 0 | 1 | 0 | 0 | 1728 / 7 / 14.3 | 0 |
| 4 | `rc3-both`（novulkan + syncobj） | 106 | 1 | 0 | 0 | 1 | 0 | 0 | 1727 / 7 / 20.8 | 0 |
| 5 | `rc3-syncobj`（`--enable-features=WaylandLinuxDrmSyncobj`） | 106 | 1 | 0 | 0 | 1 | 0 | 0 | 1728 / 7 / 15.3 | 0 |
| 6 | `rc3-angle-gl`（`--use-angle=gl`） | 106 | 1 | 0 | 0 | 1 | 0 | 0 | 1729 / 7 / 13.9 | 0 |
| 7 | `rc3-gpu-nosandbox`（`--disable-gpu-sandbox`） | 105 | 1 | 0 | 0 | 1 | 0 | 0 | 1728 / 7 / 10.4 | 0 |
| 8 | `rc3-devshm`（`--disable-dev-shm-usage`） | 105 | 1 | 0 | 0 | 1 | 0 | 0 | 1729 / 7 / 7.3 | 0 |

脚注：
1. `rc3-default` 主界面 8 张截图中仅 m1→m2 一对有 108 px 差异（≈0.006% 像素、1 个截图周期），其余 7 对为 0；属窗口刚显示后的一次极微内容更新（推断为光标/抗锯齿），不是闪烁。
2. `rc3-lead-default` 额外出现 1 条 `ERROR:components/viz/service/display/display.cc:271] Frame latency is negative: -0.01 ms`（8 组中仅此 1 次、非 FATAL；推断为帧调度数值边界噪声，非崩溃前兆）。
3. **所有组合唯一的 stderr ERROR 都是 Vulkan 探测回退行**（§3.4）；全部组合均 **无** `GPU process isn't usable` / `FATAL` / zygote 失败 / network service 崩溃。
4. 静止 rAF（3 s）：各组 mean≈6.92–6.95 ms/帧（≈144–145 fps）、p95=7 ms、`>50 ms`=0；`rc3-lead-default` 主界面 idle 有一次 470 帧/3 s（≈156 fps、max 18.2 ms），仍远低于 50 ms。
5. 滚动阶段为 12 s（91 次滚轮事件）+ 6 s 反向滚动，同时注入全屏 420×300 WebGL 动画压力；滚动截图 stddev 0.04–0.11（正常画面，无黑/白帧）。

### 3.1 逐组合观察

- **`rc3-default`（基线，无 GPU flags）**：106 s 全程稳定；GPU 进程 PID 不变、`systemd`-less 监控 104 个采样点全 alive；唯一 ERROR 为 Vulkan 探测回退行；welcome 6 张截图 AE 全 0、主界面 8 张中 7 对 AE=0；滚动 12 s 1729 帧、p95=7 ms、max=8.8 ms、0 次 >50 ms。→ **默认配置本身没有问题**，无需靠额外 flag 才能稳定。
- **`rc3-lead-default`（`--no-sandbox`，即 Lead 报告的“会 20 s 自崩”配置）**：106 s 稳定、0 崩溃标记；唯一额外的是一条非致命的 `Frame latency is negative: -0.01 ms`。→ **无法复现 Lead 的 FATAL**；结合 §3.5 的进程组 kill 复现，判断该 FATAL 是测试结束时进程树被终止的清理产物。另：`--no-sandbox` 在本机并非必需（默认组合不加它也正常，`SystemInfo.sandboxed=true`）。
- **`rc3-novulkan`（`--disable-features=Vulkan`）**：106 s 稳定；GPU 进程命令行确认 disable-features 中已含 `Vulkan`；但 WebGL renderer、`SystemInfo`（displayType/glImplementation/skiaBackendType）、Vulkan 警告、帧节奏与 default 完全一致。→ 该 flag **不改变默认渲染路径**（默认本来就没有启用 Vulkan 特性），作为历史保险保留即可。
- **`rc3-both`（旧方案完整 flag 集）**：106 s 稳定；滚动 max 20.8 ms（仍 <50 ms；20 组滚动测试中偶发一次 20 ms 级长帧，推断为系统同时跑构建流水线的调度噪声，不构成掉帧）。
- **`rc3-syncobj`（单独显式同步 flag）**：106 s 稳定；与 default 无差异 → niri 26.04 未宣告 `linux-drm-syncobj-v1`，Chromium 忽略该 flag（§3.4 表）。
- **`rc3-angle-gl`（`--use-angle=gl`）**：106 s 稳定；`SystemInfo` 仍是 `(gl=egl-angle,angle=opengl)`，即默认就是 ANGLE GL；Vulkan 警告不消失（证实警告来自 ANGLE 的探测，与 `--use-angle` 选择无关）。→ 无需加入默认。
- **`rc3-gpu-nosandbox`（`--disable-gpu-sandbox`）**：105 s 稳定；无额外收益，不加入默认（GPU 崩溃时多一层隔离缺失风险）。
- **`rc3-devshm`（`--disable-dev-shm-usage`）**：105 s 稳定；本机 `/dev/shm` 16 GiB，无 shm 压力证据，不加入默认。
- **共性**：8 组全部 0 次 GPU 进程重启、0 次 FATAL；所有组 `niri msg windows` 的 `app_id=deepseek-harness`；滚动/静态帧节奏在噪声范围内一致，说明这批 flag 与默认在执行路径上没有实质差别。

### 3.2 rc.3 默认组合的过程记录（关键，逐秒）

- welcome 窗口 ~2 s 出现（600×700 浮动），`app_id=deepseek-harness`；
- CDP 页面：`file://.../resources/app/renderer/welcome.html` + `dsh-app://app/` 两个 target；
- 点击 `#skip-key` 后主窗口出现并加载 `dsh-app://app/`，页面 `readyState=complete`；
- GPU 进程 PID 在 106 s 内**未变化**（monitor 1 s 采样 104 行，`alive=1`），子进程数 4–5；
- teardown 后日志无 `GPU process isn't usable`、无 FATAL、无 zygote/网络服务崩溃行。

### 3.3 rc.3 原生 Wayland 证据

- 进程级：**浏览器主进程、GPU 进程、renderer 进程**命令行均含 `--ozone-platform=wayland`（实测样本：browser/gpu/renderer 三条；`utility`（network service）进程命令行不含该 switch，由 Chromium 主进程统一选择平台，属正常现象）；GPU 进程另有 `--render-node-override=/dev/dri/renderD128`；无任何 `--ozone-platform=x11`；stderr 无 x11/XWayland 回退日志。
- 合成器级：`niri msg windows` 中测试窗口 `app_id=deepseek-harness`、`pid` 与主进程一致、`workspace_id` 正确；1.5 分数缩放下窗口渲染正常（welcome 600×700 / 主窗口按逻辑尺寸浮动）。
- 无 XWayland 证据：测试实例日志中只有 Wayland 协议告警（`wl_shm`/`zwp_linux_dmabuf_v1` 版本协商、niri 未支持的可选协议），没有 X11 连接/回退信息。

### 3.4 Vulkan 警告的真实含义（重点更正 Lead 假设）

**rc.3 默认组合（无 GPU flags）的 `SystemInfo.getInfo`（CDP，等价 chrome://gpu）：**

```json
{
 "gpu": [{
   "vendor": "Google Inc. (NVIDIA Corporation)",
   "device": "ANGLE (NVIDIA Corporation, NVIDIA GeForce RTX 4060 Laptop GPU/PCIe/SSE2, OpenGL ES 3.2 NVIDIA 620.70.06)",
   "driverVendor": "NVIDIA", "driverVersion": "620.70.06"
 }],
 "auxAttributes": {
   "displayType": "ANGLE_OPENGL",
   "glImplementationParts": "(gl=egl-angle,angle=opengl)",
   "glRenderer": "ANGLE (NVIDIA Corporation, NVIDIA GeForce RTX 4060 Laptop GPU/PCIe/SSE2, OpenGL ES 3.2 NVIDIA 620.70.06)",
   "glVersion": "OpenGL ES 3.0 (ANGLE 2.1 git hash: dbceb90e4677)",
   "skiaBackendType": "GaneshGL",
   "hardwareSupportsVulkan": true,
   "sandboxed": true,
   "processCrashCount": 0
 }
}
```

**逐项对照（同一构建、同一环境）：**

| 组合 | GPU 进程 `--enable-features` | `--disable-features` | displayType | skiaBackendType | WebGL renderer | Vulkan 警告 |
|---|---|---|---|---|---|---|
| default | PdfUseShowSaveFilePicker | Electron 默认项 | ANGLE_OPENGL | **GaneshGL** | ANGLE GL / NVIDIA | 1 条 |
| `--disable-features=Vulkan` | 同上 | Electron 默认 + **Vulkan** | ANGLE_OPENGL | GaneshGL | 同 | **仍 1 条** |
| `--enable-features=Vulkan` | Electron 默认 + **Vulkan** | Electron 默认项 | ANGLE_OPENGL | **GaneshVulkan** | 同 | 1 条 |
| `--use-angle=gl` | Electron 默认项 | Electron 默认项 | ANGLE_OPENGL | GaneshGL | 同 | 1 条 |

**结论（事实）：**
1. Electron 44.7.0 默认**没有**启用 Vulkan 合成/渲染特性：默认 GPU cmdline 无 `--enable-features=Vulkan`，Skia 后端是 `GaneshGL`。
2. 那条 `wayland_surface_factory.cc:249` 是 GPU 进程初始化时 **ANGLE 探测 Vulkan backend/surface 不兼容后回退到 GL** 的日志；`--disable-features=Vulkan` 只禁用 Chromium 的 Vulkan 特性，**不影响 ANGLE 的探测**，所以该行不会消失（实测正是如此）。
3. 只有显式 `--enable-features=Vulkan` 才把 Skia 后端切成 `GaneshVulkan`——若历史崩溃确实与 Vulkan 有关，那么**默认路径本来就不会踩到**；`--disable-features=Vulkan` 的作用仅是“即使用户/未来版本打开了 Vulkan 特性也强制回到 GL”（防御性保险，无副作用）。
4. 因此“Wayland+Vulkan 不兼容 → 必须禁用 Vulkan，否则 ~20 s 自崩”这一因果**不成立**（伪崩溃证据见 §3.5）。

### 3.5 Lead 报告的“~20 s 自崩”序列与进程组被 kill 的特征完全一致（关键更正）

Lead 报告的 stderr 顺序：

```
ERROR ... wayland_surface_factory.cc:249 '--ozone-platform=wayland' is not compatible with Vulkan ...
ERROR ... zygote_communication_linux.cc:291 Failed to send GetTerminationStatus message to zygote
ERROR ... network_service_instance_impl.cc:650 Network service crashed or was terminated, restarting service.
ERROR ... gpu_process_host.cc:1029 GPU process launch failed: error_code=1002      (×7)
FATAL ... gpu_data_manager_impl_private.cc:417 GPU process isn't usable. Goodbye.
```

这段话的特征是：**network service 与 zygote 先死 → 浏览器重启 GPU 进程失败（1002）→ FATAL 退出**。这不是 Vulkan/驱动错误路径，而是“子进程被一次性杀掉后，浏览器无法重建 gpu/zygote”的典型日志。本机旧实验日志（`/tmp/rc3lab/logs/pilot.log`，rc.1 实例在 `kill -TERM -- -<进程组>` 之后）逐行同序出现同样的序列：

```
[198900:164240.299558:ERROR ...] Network service crashed or was terminated, restarting service.
[198900:164240.305958:ERROR ... zygote ...] Failed to send GetTerminationStatus message to zygote
[198900:164240.307572:ERROR ... gpu_process_host.cc:1029] GPU process launch failed: error_code=1002
...
[198900:164240.309247:FATAL ... gpu_data_manager_impl_private.cc:417] GPU process isn't usable. Goodbye.
```

**对照实验（本轮 rc.3）：**

- `rc3-lead-default`（与 Lead 相同的启动方式：`--no-sandbox` + 原生 Wayland，**不**禁用 Vulkan）：跑满 ~105 s，**0 崩溃标记、GPU 进程常驻、页面正常**（见矩阵表）；
- `rc3-default`（无任何 GPU flag，含不加 `--no-sandbox`）：106 s 稳定，0 崩溃标记；
- 结论：**该 FATAL 序列不会在“进程不被外部结束”时自发出现**；Lead 观察到的现象极可能是测试命令结束时其后台进程树被终止（或脚本 kill 了进程组）留下的“清理伪崩溃”。建议 Lead 用 `setsid` 启动后在**另一个命令**里持续观察（或后台 job 保活），不要在同一条命令尾部结束/清理进程树，即可复现我们的“长时间稳定”结果。

**本轮 rc.3 对照实验（可复现）**：

1. 干净启动 rc.3 linux-unpacked（无 GPU flags、无 `--no-sandbox`），记录主进程 PID=进程组 PGID；
2. 等到窗口出现、正常运行 7 s 后，只做一件事：`kill -TERM -- -<PGID>`（等价于 shell 退出时清理整个后台进程组）；
3. 得到的 stderr（`/tmp/rc3lab/logs/groupkill-repro.log`，共 39 行）：

```
[352125:1114/170943.741911:ERROR:ui/ozone/platform/wayland/gpu/wayland_surface_factory.cc:249] '--ozone-platform=wayland' is not compatible with Vulkan. ...
[352021:1114/170950.186517:ERROR:content/browser/network_service_instance_impl.cc:650] Network service crashed or was terminated, restarting service.
[352021:1114/170950.190295:ERROR:content/common/zygote/zygote_communication_linux.cc:291] Failed to send GetTerminationStatus message to zygote
[352021:1114/170950.195788:ERROR:content/browser/gpu/gpu_process_host.cc:1029] GPU process launch failed: error_code=1002
... (共 6 次) ...
[352021:1114/170950.200115:FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:417] GPU process isn't usable. Goodbye.
```

4. shell 同时报告：`追踪或断点陷阱（核心已转储）`（= SIGTRAP + core dump，与旧包 10-24 记录的 SIGTRAP core 一致）。

> 次数差异说明：Lead 的报告是 `GPU process launch failed ×7`，本次复现是 ×6——Chromium 在 FATAL 前的重试次数取决于杀进程时的时序/重试配额，**序列模式与终点（FATAL: GPU process isn't usable. Goodbye. + SIGTRAP core）完全一致**，因此判定为同一机制。

→ **结论（事实）**：同一份 rc.3 构建，只要不外部结束进程树就 106 s 稳定；一旦按进程组清理，就打印出与 Lead 报告逐行同序的 FATAL 序列。因此该序列是“清理伪崩溃”，**不能**作为 “Wayland+Vulkan 不兼容必须禁用 Vulkan，否则自崩” 的证据。建议 Lead 把测试实例放到独立后台 job / `setsid` 保活，另开命令观察；清理时对主进程单独 `kill -TERM` 而不是整组，即可避免误判。

### 3.6 其他候选 flags 的结论

- **`--disable-gpu-sandbox`**（105 s，稳定、0 崩溃）：旧 ladder 第 1 级；本轮无任何 GPU 沙箱相关崩溃证据，不加入默认（兜底也只做软件渲染，不再加这一级）。
- **`--disable-dev-shm-usage`**（105 s，稳定、0 崩溃）：本机 `/dev/shm` 16 GiB、无 shm 竞争/崩溃证据；不加入默认。
- **`--use-angle=gl`**（106 s，稳定、0 崩溃）：`SystemInfo` 显示默认已是 `(gl=egl-angle,angle=opengl)`，加与不加相同；Vulkan 探测警告依旧存在（该行与 ANGLE backend 选择无关）。不加入默认。
- **`--no-sandbox`**：本机 userns 沙箱可用（`unprivileged_userns_clone=1`，`SystemInfo.sandboxed=true`），rc.3 不加 `--no-sandbox` 也能正常启动；launcher 仅在 `sandbox_usable` 判定失败时自动加。Lead 的启动命令带 `--no-sandbox` 只是习惯/保险，不影响本结论。
- **`Frame latency is negative: -0.01 ms`**（`rc3-lead-default` 出现 1 次）：Chromium Viz 显示层对负帧延迟的 ERROR 日志，非 FATAL；8 组矩阵仅 1 次，且出现在滚动/静态混合阶段，推断为帧调度数值边界噪声。若 console-analyst 的“零 error”标准包含 stderr，可记录为已知 Chromium 内部日志（与业务 console 无关）。
- **`rc3-default` 主界面 m1→m2 的 108 px 差异**：约占窗口 1245×1420 的 0.006%，发生在主窗口 just-shown 阶段；后续 7 对截图全 0，判定不是闪烁。

---

## 4. 结论：推荐的最小运行时配置

### 4.1 推荐 launcher 默认

```sh
# Wayland 会话下（必须）：
--ozone-platform=wayland
# NVIDIA 保险（默认开；Electron 44.7 默认路径无 Vulkan，故无可见副作用）：
--disable-features=Vulkan
# 显式同步（本机 niri 26.04 无 linux-drm-syncobj-v1 → 实测 no-op；保留=前向兼容）：
--enable-features=WaylandLinuxDrmSyncobj
```

- **最小必要**：`--ozone-platform=wayland`。它确保原生 Wayland，不依赖 `ELECTRON_OZONE_PLATFORM_HINT`/环境自动选择，也不会 fallback X11（显式指定平台后 Chromium 不会换平台）。
- **Vulkan 禁用**：Lead 明确要求 + 旧包历史保险 + 实测零副作用；即使它不改变当前默认路径，也应保留（防未来 Electron/用户侧开启 Vulkan 特性后进入 `GaneshVulkan` 路径）。
- **syncobj**：niri 26.04 无协议 → 无效果；保留默认开 = 与旧包行为连续、且未来合成器支持时自动生效；`DSH_WAYLAND_SYNCOBJ=0` 可关（关闭后矩阵同样稳定）。
- **不需要的**：`--no-sandbox`（本机 userns 沙箱可用；只有 `sandbox_usable` 判定失败才自动加）、`--disable-gpu-sandbox`、`--disable-dev-shm-usage`、`--use-angle=gl`（与默认等价，见 §3.6）、NVIDIA 专用 env（`__GL_SYNC_TO_VBLANK`/`__GLX_VENDOR_LIBRARY_NAME`/`LIBVA_DRIVER_NAME`）、`ELECTRON_OZONE_PLATFORM_HINT`。

### 4.2 明确排除的项

| 项 | 结论 | 依据 |
|---|---|---|
| X11/XWayland fallback | **排除**（任务要求；旧 launcher 的 X11 级不可沿用） | 需求 |
| `--use-angle=vulkan` | **排除**（Chromium 明确拒绝 Wayland+Vulkan surface；如需 Vulkan 实验只应显式 `--enable-features=Vulkan` 且不在默认） | §3.4 |
| `--enable-features=Vulkan` | **排除为默认**（会切 `GaneshVulkan`，是历史崩溃隐患方向；默认行为其实已是 GL） | §3.4 |
| `--use-angle=gl` | 不设为默认（默认即 ANGLE GL；多一个开关无收益） | §3.6 |
| `--disable-gpu-compositing` / `--disable-gpu` | 不设为默认；仅软件兜底时使用（性能/体验退化） | 设计 |
| `--disable-gpu-sandbox`、`--disable-dev-shm-usage` | 不需要（本机无崩溃证据；08 组实测见 §3.6） | 需求 #4 |
| `--disable-features=UseSkiaRenderer` | 现代 Chromium no-op，无意义 | 版本演进 |
| 旧 app 3 级 ladder + `linux-gpu-fallback.json` | **不建议移植**（复杂度、状态文件、真实 GPU 从未验证）；用 launcher 一次性兜底替代 | §1.2、§6.3 |
| `app.relaunch()` 内部重启 | **禁止**（与 Chromium GPU abort 竞态，旧 commit 872ab91 已实证） | §1.2 |
| 美化/托盘/主题/HiDPI flag | 不属于 launcher 职责 | 需求/PLAN |

### 4.3 闪烁结论

- **静止页面**：welcome 6 张相邻截图 AE 全 0；主界面 8 张中仅 m1↔m2 有 108 px（≈0.006% 面积，1 个截图周期）的极小差异，其余全 0 → 秒级采样下**无闪烁**。
- **滚动 + WebGL 压力**：rAF 帧间隔 mean 6.94 ms、p95 7 ms、max 8.8 ms、`>50 ms` 0 次（12 s 内 1729 帧，≈144 fps）；滚动截图 stddev 0.05–0.11（正常画面，无黑/白帧）。
- **局限**：单帧 tearing/短瞬闪无法用 1 Hz 截图证明；最终“绝对不闪烁”建议用 60–120 fps 录屏（wl-screenrec 可用）+ 用户实际观察复核（§8）。

---

## 5. launcher 最终草案

文件：`/home/Arch/dsh-re/dsh-desktop-wayland/launcher/deepseek-harness`
（POSIX sh；`sh -n`、`shellcheck -s sh` 通过；本机用桩程序验证 flag 组装/兜底分类，并在 rc.3 linux-unpacked 上做端到端启动验证 §5.4。）

### 5.1 完整代码

```sh
#!/bin/sh
# DeepSeek Harness Desktop —— 原生 Wayland 启动器（最小实现）
#
# 设计目标（niri 26.04 / Wayland / NVIDIA open 驱动）：
#   1. 只在 Wayland 会话语境下强制原生 Wayland（--ozone-platform=wayland），
#      绝不回退 X11 / XWayland；X11 会话下不追加任何平台开关（原样用 X11）。
#   2. 默认只加实测最小、必要的 Chromium flag；其余全部可关。
#   3. 仅当 GPU 进程彻底不可用（崩溃退出）时，在同一次启动内做一次
#      软件渲染兜底（仍然原生 Wayland），绝不切换 X11。
#   4. 不包含美化 / 托盘 / 主题 / HiDPI 逻辑。
#
# 用户开关（默认值即推荐值；=0 关闭，=1 打开）：
#   DSH_WAYLAND=0            不强制 --ozone-platform=wayland（默认 1 强制）
#   DSH_WAYLAND_SYNCOBJ=0    去掉 --enable-features=WaylandLinuxDrmSyncobj
#                            （显式同步特性；合成器不宣告该协议时 Chromium 自动忽略）
#   DSH_GPU_DISABLE_VULKAN=0 保留 Chromium Vulkan 特性（默认 1：在 NVIDIA+Wayland 上关闭）
#   DSH_GPU_SOFTWARE=1       直接以软件渲染启动（排障用，仍原生 Wayland）
#   DSH_GPU_FALLBACK=0       关闭“GPU 崩溃后自动软件渲染重试一次”
#   DSH_GPU_LOG_STDERR=1     GPU 兜底日志同时回放 stderr（排障用）
#   DSH_GPU_FALLBACK_LOG     兜底检测用 stderr 日志路径
#                            （默认 ${XDG_RUNTIME_DIR:-/tmp}/dsh-desktop-gpu-fallback.log）
#   DSH_GPU_FLAGS='...'      追加额外 Chromium flag（空格分隔，A/B 测试用）
#   DSH_NO_SANDBOX=1         强制 --no-sandbox（沙箱不可用时的自动兜底仍然生效）
#   DSH_DESKTOP_PREFIX       app 安装前缀（默认 /opt/deepseek-harness-desktop-wayland）
# 安装为 /usr/bin/deepseek-harness-wayland（主入口），并可选提供
# /usr/bin/deepseek-harness 兼容符号链接（见仓库 packaging/）。
set -u

# 从 DSH 终端/宿主环境继承 ELECTRON_RUN_AS_NODE=1 时，Electron 会以 Node 模式
# 解析参数并报 "bad option"；这里显式 unset，保证始终以 GUI 模式启动。
unset ELECTRON_RUN_AS_NODE

APP_ROOT="${DSH_DESKTOP_PREFIX:-/opt/deepseek-harness-desktop-wayland}"
APP_BIN="${APP_ROOT}/deepseek-harness"
SANDBOX="${APP_ROOT}/chrome-sandbox"

if [ ! -x "$APP_BIN" ]; then
    printf '%s\n' "deepseek-harness: ${APP_BIN}: 不存在或不可执行" >&2
    exit 127
fi

has_arg() {
    _needle="$1"
    shift
    for _arg in "$@"; do
        [ "$_arg" = "$_needle" ] && return 0
    done
    return 1
}

# 用户自己传了某前缀的 Chromium 开关（如 --disable-features=...）时尊重用户值。
has_switch_prefix() {
    _prefix="$1"
    shift
    for _arg in "$@"; do
        case "$_arg" in "$_prefix"*) return 0 ;; esac
    done
    return 1
}

# Wayland 会话判定：niri 下 WAYLAND_DISPLAY 必定存在。
is_wayland() {
    [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = 'wayland' ]
}

is_nvidia() {
    [ -e /proc/driver/nvidia/version ] || [ -e /sys/module/nvidia ]
}

# Chromium 沙箱可用性：setuid chrome-sandbox，或内核允许非特权用户命名空间。
# 判错时选择 --no-sandbox（功能优先），并在 stderr 说明，而不是直接失败。
sandbox_usable() {
    # setuid-root 的 chrome-sandbox（模式 4755）是首选。
    _mode="$(stat -c '%a' "$SANDBOX" 2>/dev/null || printf 0)"
    _uid="$(stat -c '%u' "$SANDBOX" 2>/dev/null || printf unknown)"
    if [ "$_uid" = '0' ] && [ $((0$_mode & 04000)) -ne 0 ]; then
        return 0
    fi
    if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] &&
       [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = '1' ]; then
        return 1
    fi
    if [ -r /proc/sys/kernel/unprivileged_userns_clone ]; then
        [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" = '1' ] && return 0
        return 1
    fi
    if [ -r /proc/sys/user/max_user_namespaces ] &&
       [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        return 0
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 平台与渲染 flag（顺序：平台 → GPU → 沙箱 → 用户追加）
# ---------------------------------------------------------------------------
if is_wayland && [ "${DSH_WAYLAND:-1}" != '0' ] &&
   ! has_switch_prefix '--ozone-platform' "$@"; then
    set -- "$@" --ozone-platform=wayland
fi

if [ "${DSH_GPU_SOFTWARE:-0}" = '1' ]; then
    # 显式排障模式：完全软件合成，仍然走 Wayland 窗口。
    set -- "$@" --disable-gpu --disable-gpu-compositing
fi

if [ "${DSH_GPU_DISABLE_VULKAN:-1}" != '0' ] && is_nvidia &&
   ! has_switch_prefix '--disable-features=' "$@"; then
    set -- "$@" --disable-features=Vulkan
fi

# 显式同步（linux-drm-syncobj-v1）：合成器宣告该协议时 Chromium 才启用；
# niri 26.04 未宣告，因此默认保留该 flag 仅作为前向兼容，可 DSH_WAYLAND_SYNCOBJ=0 关掉。
if is_wayland && [ "${DSH_WAYLAND_SYNCOBJ:-1}" != '0' ] &&
   ! has_switch_prefix '--enable-features=' "$@"; then
    set -- "$@" --enable-features=WaylandLinuxDrmSyncobj
fi

if [ "${DSH_NO_SANDBOX:-0}" = '1' ]; then
    has_arg '--no-sandbox' "$@" || set -- "$@" --no-sandbox
elif ! sandbox_usable && ! has_arg '--no-sandbox' "$@"; then
    set -- "$@" --no-sandbox
    printf '%s\n' 'deepseek-harness: Chromium 沙箱不可用，已追加 --no-sandbox' >&2
fi

# 追加 A/B flag（deliberate word splitting；set -f 防止路径通配展开）。
if [ -n "${DSH_GPU_FLAGS:-}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- "$@" $DSH_GPU_FLAGS
    set +f
fi

# ---------------------------------------------------------------------------
# 运行：正常情况零包装（exec）；只有开启 GPU 兜底时才在本进程内 run + 重试。
# ---------------------------------------------------------------------------
# --version/--help 之类的查询不需要兜底，直接 exec。
for _arg in "$@"; do
    case "$_arg" in
        --version|--help|-v|-h) exec "$APP_BIN" "$@" ;;
    esac
done

if [ "${DSH_GPU_FALLBACK:-1}" = '0' ]; then
    exec "$APP_BIN" "$@"
fi

GPU_LOG="${DSH_GPU_FALLBACK_LOG:-${XDG_RUNTIME_DIR:-/tmp}/dsh-desktop-gpu-fallback.log}"

# GPU 崩溃分类：旧补丁协议 exit 75；Chromium FATAL 会以 SIGTRAP/SIGABRT/SIGSEGV
# 结束（128+信号），另外必须能在 stderr 里找到 GPU 进程相关错误，避免把
# 无关崩溃误判成 GPU 故障。
gpu_failure() {
    _rc="$1"
    _log="$2"
    [ "$_rc" -eq 75 ] && return 0
    case "$_rc" in
        133|134|139) ;;
        *) return 1 ;;
    esac
    grep -qiE "GPU process isn't usable|GPU process launch failed|The GPU process has crashed|gpu_process_host" "$_log" 2>/dev/null
}

"$APP_BIN" "$@" 2>"$GPU_LOG"
rc=$?
if gpu_failure "$rc" "$GPU_LOG"; then
    printf '%s\n' "deepseek-harness: GPU 进程不可用（exit ${rc}），本次启动改用软件渲染重试（仍为原生 Wayland）" >&2
    [ "${DSH_GPU_LOG_STDERR:-0}" = '1' ] && tail -n 20 "$GPU_LOG" >&2
    # 有限兜底：只重试一次，不换平台、不改窗口系统。
    "$APP_BIN" "$@" --disable-gpu --disable-gpu-compositing
    exit $?
fi
[ "${DSH_GPU_LOG_STDERR:-0}" = '1' ] && cat "$GPU_LOG" >&2
exit "$rc"

```

### 5.2 逐段说明

| 段 | 作用 |
|---|---|
| 头部注释 | 设计目标 + 全部用户开关（`DSH_WAYLAND_*` / `DSH_GPU_*`，默认值即推荐值）；安装名 `/usr/bin/deepseek-harness-wayland`（可选兼容 symlink） |
| `APP_ROOT` | 新包安装根默认 `/opt/deepseek-harness-desktop-wayland`；`DSH_DESKTOP_PREFIX` 可指向旧包/构建目录做 A/B |
| `has_arg` / `has_switch_prefix` | 幂等 + 尊重用户：用户已显式传 `--ozone-platform=*`/`--disable-features=*`/`--enable-features=*` 时不再追加冲突项 |
| `is_wayland` | `WAYLAND_DISPLAY` 或 `XDG_SESSION_TYPE=wayland`；只在 Wayland 会话加强制平台 flag；X11 会话原样（不主动 XWayland） |
| `is_nvidia` | `/proc/driver/nvidia/version` 或 `/sys/module/nvidia`；仅 NVIDIA 加 Vulkan flag，避免误伤 Intel/AMD |
| `sandbox_usable` | setuid chrome-sandbox（4755 root）优先；否则检查 AppArmor userns 限制 / `unprivileged_userns_clone` / `max_user_namespaces`；不可用时自动 `--no-sandbox` 并在 stderr 说明 |
| 平台 flag | Wayland 强制 `--ozone-platform=wayland`；`DSH_WAYLAND=0` 可关 |
| GPU flag | `DSH_GPU_DISABLE_VULKAN`（默认 1）→ `--disable-features=Vulkan`；`DSH_WAYLAND_SYNCOBJ`（默认 1）→ `--enable-features=WaylandLinuxDrmSyncobj`；`DSH_GPU_SOFTWARE=1` → 直接 `--disable-gpu --disable-gpu-compositing`（仍 Wayland） |
| 沙箱 | `DSH_NO_SANDBOX=1` 强制；否则按 `sandbox_usable` 自动兜底 |
| `DSH_GPU_FLAGS` | A/B/排障追加 flags（空格分词，`set -f` 防通配展开） |
| `--version/--help` | 直接 `exec`，不包装、不兜底 |
| `DSH_GPU_FALLBACK=0` | 直接 `exec`（零包装，信号/退出码原样透传） |
| `GPU_LOG` + `gpu_failure()` | stderr 落盘（默认 `${XDG_RUNTIME_DIR:-/tmp}/dsh-desktop-gpu-fallback.log`）；分类：`75`（旧协议）或 `133/134/139`（SIGTRAP/SIGABRT/SIGSEGV）**且** stderr 命中 GPU 关键字 → 才认为 GPU 故障；普通崩溃/用户信号不重试 |
| 兜底 | 命中后仅在**同一次启动内**重试一次 `--disable-gpu --disable-gpu-compositing`（仍 Wayland；不写状态、不 relaunch、不切 X11）；`DSH_GPU_LOG_STDERR=1` 可回放日志 |
| 退出 | 非 GPU 故障 `exit rc`；兜底重试后 `exit $?` |

### 5.3 开关速查

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_WAYLAND` | 1 | Wayland 会话下强制 `--ozone-platform=wayland`；0=不加 |
| `DSH_WAYLAND_SYNCOBJ` | 1 | `--enable-features=WaylandLinuxDrmSyncobj`；0=去掉（niri 26.04 上无效果） |
| `DSH_GPU_DISABLE_VULKAN` | 1 | NVIDIA 上 `--disable-features=Vulkan`；0=保留 |
| `DSH_GPU_SOFTWARE` | 0 | 1=直接软件渲染（仍 Wayland） |
| `DSH_GPU_FALLBACK` | 1 | 0=不做一次性软件兜底（纯 exec） |
| `DSH_GPU_FALLBACK_LOG` | `${XDG_RUNTIME_DIR:-/tmp}/dsh-desktop-gpu-fallback.log` | 兜底检测 stderr 路径 |
| `DSH_GPU_LOG_STDERR` | 0 | 1=兜底/退出时回放 stderr 日志 |
| `DSH_GPU_FLAGS` | 空 | 追加 Chromium flags（A/B） |
| `DSH_NO_SANDBOX` | 0 | 1=强制 `--no-sandbox` |
| `DSH_DESKTOP_PREFIX` | `/opt/deepseek-harness-desktop-wayland` | app 安装前缀（可指向旧包/构建目录 A/B） |

### 5.4 验证

- **静态检查**：`sh -n` 通过；`shellcheck -s sh` 0 警告。
- **flag 组装（桩程序）**：默认 → `--ozone-platform=wayland --disable-features=Vulkan --enable-features=WaylandLinuxDrmSyncobj`；各开关逐一关闭正确；用户自带 `--ozone-platform=x11` / `--disable-features=Foo` / `--enable-features=Bar` 被尊重；`--version` 直通；`--disable-gpu --disable-gpu-compositing` 的软件模式正确。
- **兜底分类（桩程序）**：exit 133 + GPU 关键字 → 重试并追加 `--disable-gpu --disable-gpu-compositing`；exit 139 + 无关错误 → **不**重试。
**端到端（rc.3 构建）实测通过：**

- 命令：`DSH_DESKTOP_PREFIX=<linux-unpacked> DSH_HOME=/tmp/rc3lab/rc3home DSH_GPU_FALLBACK_LOG=/tmp/... setsid launcher/deepseek-harness --user-data-dir=<tmp> --remote-debugging-port=9393 ...`；
- 实测 launcher 最终传给 app 的 flag 恰为：`--ozone-platform=wayland --disable-features=Vulkan --enable-features=WaylandLinuxDrmSyncobj`（另有用户参数）；
- 窗口出现（`app_id=deepseek-harness`、浮动）；`ps` 中 4 个进程带 `--ozone-platform=wayland`、1 个 GPU 进程；launcher 作为父进程保活并在 app 退出后正常退出；
- 期间发现并修复一个真实问题：从 DSH 终端继承 `ELECTRON_RUN_AS_NODE=1` 时 Electron 会以 Node 模式解析参数并报 `bad option`；launcher 已显式 `unset ELECTRON_RUN_AS_NODE`（见 §5.1 代码第 30 行附近），修复后 E2E 通过。
- 未在 E2E 中人为制造 GPU 崩溃；兜底触发逻辑由桩程序验证（`exit 133 + GPU 关键字 → 追加 --disable-gpu --disable-gpu-compositing`；无关 139 不重试）。

---

## 6. main.ts 级最小修改建议

> 结论：**渲染稳定性本身不需要改 main.ts**。以下 2 条只针对“绝对无闪烁 / 确定性兜底”，均为可选增强；旧包的 193 行 ladder 不建议移植。

### 6.1 【建议】Linux 窗口背景色跟随主题（防首帧白闪，约 4 行）

事实：
- `apps/desktop/src/main.ts:264-294` `createWindow()`：`backgroundColor` 只在 win32 分支设置；Linux 无 → 默认白底。
- `apps/desktop/src/main.ts:246`：`chromeFallbackFill() = nativeTheme.shouldUseDarkColors ? '#1b1b1c' : '#f9fafb'`。
- `apps/desktop/src/welcome-window.ts:27`：Linux welcome 固定 `#FFFFFF`。
- `enterWorkspace()`（main.ts:1365 附近）在 `window.show()` 前导航主页面 → welcome→主窗口有主题色过渡窗口。

建议（最小 diff）：
```ts
// createWindow()：Linux 也设置主题底色（与 win32 分支同源）
...(process.platform === 'win32' ? { backgroundColor: chromeFallbackFill(), ... } : {}),
...(process.platform === 'linux' ? { backgroundColor: chromeFallbackFill() } : {}),

// welcome-window.ts:27
backgroundColor: platform === 'darwin' || platform === 'win32'
  ? '#00000000'
  : (nativeTheme.shouldUseDarkColors ? '#1b1b1c' : '#FFFFFF'),
```
效果：深色主题下窗口创建/导航瞬间不再白底闪；浅色主题不变。验证：暗色主题冷启动 + skip 进工作区，高频截图（≥10 Hz）检查首帧颜色=主题底色。

### 6.2 【可选】确定性 GPU 兜底协议：`child-process-gone` → `app.exit(75)`（~15–20 行）

现状（事实）：rc.3 无 GPU 回退代码；Chromium GPU 彻底不可用时自己 `LOG(FATAL)`（`GPU process isn't usable. Goodbye.`）→ 以 SIGTRAP（exit 133）结束。launcher 已能通过“133 + stderr GPU 关键字”识别并兜底，**因此不改 main.ts 也能工作**。

若要把兜底触发变成确定性协议（避免依赖日志文本），最小实现（不引入状态文件、不 relaunch）：
```ts
// main.ts（Linux only；app ready 后注册；计数不跨进程）
let gpuCrashCount = 0
app.on('child-process-gone', (_event, details) => {
  if (process.platform !== 'linux' || details.type !== 'GPU') return
  if (details.reason !== 'crashed' && details.reason !== 'abnormal-exit') return
  gpuCrashCount += 1
  console.error(`desktop gpu: GPU process gone (${details.reason}), count=${gpuCrashCount}`)
  if (gpuCrashCount >= 2) app.exit(75)   // 交给 launcher 的一次性软件兜底
})
```
launcher 的 `gpu_failure()` 已支持 `exit 75`。**不要**用 `app.relaunch()`（旧 commit 872ab91 已实证竞态）。

### 6.3 不建议的应用层改动

| 项 | 理由 |
|---|---|
| 移植旧 3 级 ladder + `linux-gpu-fallback.json` + 稳定 10 min 降级 | 193 行 + 状态文件 + 测试面大；真实 GPU 从未验证；launcher 一次性兜底已覆盖“彻底不可用” |
| `app.relaunch()` / 自行重启 | 与 Chromium GPU abort（SIGTRAP）竞态（旧包实证） |
| main.ts 里 `appendSwitch` 复制 launcher flags | 双份来源难维护；launcher 是唯一入口（`.desktop` 也指向它） |
| 默认 `--disable-gpu-compositing` / `--disable-gpu` | 性能/体验退化，只应兜底 |
| 写 userData GPU 状态/fallback 标记 | 增加持久状态与清理负担，不解决本轮目标 |

### 6.4 若要改，最小验证

1. 暗色主题冷启动：welcome → skip → 主界面，高频截图检查首帧无白底（§6.1）；
2. 人为制造 GPU 失败：`DSH_GPU_FLAGS='--use-angle=vulkan'` 或 `--disable-gpu-sandbox` + WebGL 压力，确认 launcher 在 exit 133/75 后以软件渲染重启且仍是原生 Wayland（launcher 桩测试已覆盖分类逻辑）。

---

## 7. 复现命令（rc.3 构建，最小集）

```sh
U=/home/Arch/dsh-builds/rc3-wayland/p1-check2/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked
LAB=/tmp/rc3lab
mkdir -p "$LAB/rc3home/profiles"
cp -a ~/.dsh/profiles/desktop "$LAB/rc3home/profiles/desktop" 2>/dev/null || true

# 环境证据
niri msg version; niri msg outputs | head -8
nvidia-smi --query-gpu=name,driver_version --format=csv
cat "$U/version"
wayland-info | grep -c '^interface'; wayland-info | grep -i syncobj   # 本机: 47 / 空

# 1) 隔离实例（推荐默认组合）
DSH_HOME="$LAB/rc3home" DSH_DESKTOP_HOST_INSPECT_PORT=9501 \
  env -u ELECTRON_RUN_AS_NODE setsid "$U/deepseek-harness" \
  --ozone-platform=wayland --disable-features=Vulkan --enable-features=WaylandLinuxDrmSyncobj \
  --user-data-dir="$LAB/ud-soak" --remote-debugging-port=9301 --remote-allow-origins='*' \
  --enable-logging=stderr --log-level=0 > "$LAB/soak.log" 2>&1 &
echo $!    # 之后按 PID / --user-data-dir 精确清理，勿 pkill -f

# 2) 原生 Wayland 证据
niri msg --json windows | jq '.[] | {id,app_id,pid,workspace_id,is_floating}'
ps -eo args | grep -F -- "--user-data-dir=$LAB/ud-soak" | grep -oE -- '--ozone-platform=[a-z0-9]+' | sort | uniq -c

# 3) GPU/帧节奏（--remote-debugging-port）
node /tmp/rc3lab/cdp.mjs sysinfo 9301          # displayType/glImplementationParts/skiaBackendType
node /tmp/rc3lab/cdp.mjs eval 9301 \
 '(()=>{const c=document.createElement("canvas");const gl=c.getContext("webgl2");const e=gl.getExtension("WEBGL_debug_renderer_info");return gl.getParameter(e?e.UNMASKED_RENDERER_WEBGL:gl.RENDERER)})()'
node /tmp/rc3lab/cdp.mjs idle 9301 3
node /tmp/rc3lab/cdp.mjs scrollstress 9301 12 500

# 4) 闪烁采样（窗口可见；--id 可截非焦点窗口，无需抢焦点）
niri msg action screenshot-window --id <wid> --path /tmp/shot-1.png -d true -p false
sleep 4
niri msg action screenshot-window --id <wid> --path /tmp/shot-2.png -d true -p false
magick compare -metric AE /tmp/shot-1.png /tmp/shot-2.png null:    # 期望 0

# 5) 清理（只结束本测试实例）
kill -TERM <MAINPID>; sleep 2
for p in $(ps -eo pid,args | grep -F -- "--user-data-dir=$LAB/ud-soak" | grep -v grep | awk '{print $1}'); do kill -KILL "$p"; done
rm -rf "$LAB/ud-soak"
```

> 完整矩阵脚本 `/tmp/rc3lab/harness.sh` + `matrix-rc3.sh`（每轮 ~105 s：welcome 静态截图 → skip → 主界面静态/rAF → WebGL 压力+双向滚动 → 精确清理）为实验产物，未纳入仓库；可按需固化到 `ci/`。

---

## 8. 风险与未验证项

| # | 项 | 说明 |
|---|---|---|
| 1 | **真实 GPU 崩溃窗口** | 本轮 rc.3 全矩阵累计 ~15 分钟、0 崩溃标记；不能宣称 10-24 问题“已修复”。需要新包产物上 24 h+ soak（挂起/恢复、多显示器、视频/WebGL/WebGPU 重负载、显存压力）。 |
| 2 | **Lead 的伪崩溃** | 已证明“进程组被 kill”会产生同款 FATAL 序列（§3.5）；建议 Lead 复核测试脚本生命周期。若仍有另一份“真正自崩”的日志，请提供完整 stderr + 启动方式，我们再归因。 |
| 3 | 最终 pacman 包未测 | 本轮用 linux-unpacked（`resources/app` 未 ASAR、chrome-sandbox 非 setuid）；最终安装到 `/opt/deepseek-harness-desktop-wayland` 的包需复跑矩阵 + launcher 端到端。 |
| 4 | 显式同步无法验证 | niri 26.04 未宣告 `linux-drm-syncobj-v1`；未来 niri 支持后需重测 syncobj 对 NVIDIA tearing 的效果。 |
| 5 | 闪烁测量粒度 | 截图 1 Hz 级；单帧 tearing/短瞬闪无法证明。最终验收建议 60–120 fps 录屏（`wl-screenrec`）+ 用户实际使用观察。 |
| 6 | 软件兜底效果 | launcher 兜底后的 FPS/画质/输入延迟未量化；本轮只验证分类逻辑（桩）与 rc.3 端到端启动。 |
| 7 | 未测组合 | `--enable-zero-copy`/`--disable-zero-copy`、`--disable-features=SkiaGraphite`、`--in-process-gpu`、`--disable-gpu-driver-bug-workarounds`、NVIDIA env（`__GL_SYNC_TO_VBLANK` 等）未逐一 A/B；按本轮无理由加入默认。 |
| 8 | 会话/启动方式差异 | 继承当前 niri 会话环境（`DISPLAY=:0` 仍在）；未测无 DISPLAY、纯 Wayland 冷启动、systemd user service 启动。 |
| 9 | 多实例 | 隔离实例可并行（独立 user-data-dir/DSH_HOME）；新包正常启动时若旧包也在跑，用户可能看到两个窗口；验收时确认 `.desktop` 只指向新包。 |
| 10 | `--no-sandbox` 兜底 | 本机不触发；最终包若 chrome-sandbox 权限/AppArmor 变化需重测 `sandbox_usable` 分支。 |

---

## 附录 A：证据文件（本轮 /tmp，实验后可清理）

- 矩阵日志：`/tmp/rc3lab/logs/rc3-*.log`（stderr，`--enable-logging=stderr --log-level=0`）
- 采样：`/tmp/rc3lab/logs/rc3-*.monitor.tsv`（1 s：alive/GPU PID/子进程数/崩溃行数/PID 变化）
- CDP：`rc3-*.welcome-info.txt`、`rc3-*.main-info.txt`、`rc3-*.scroll*.json`、`rc3-*.ps.txt`、`rc3-*.windows.json`
- 快速探针：`/tmp/rc3lab/logs/rc3p-{novulkan,vulkanon,anglegl}.{log,summary.txt}`（sysinfo 全量）
- 伪崩溃对照：`/tmp/rc3lab/logs/pilot.log`（rc.1 实例进程组被 kill 后同款序列）
- 截图：`/tmp/rc3lab/shots/rc3-*.png`；结果行：`/tmp/rc3lab/results/rc3-*.tsv`；汇总：`summary.json`/`table.md`

## 附录 B：边界与纪律

- 未 kill/重启 PID 4821/5144（当前会话所在实例）；未改 `/opt`、真实 `~/.dsh`、`~/.config/@deepseek-ai/dsh-desktop`；未 sudo/pacman；未改旧仓库（只读引用）；未 git commit。
- 所有测试实例均按唯一 `--user-data-dir` 精确结束并清理；测试窗口在 niri 中短暂出现（浮动、非焦点）后关闭。
