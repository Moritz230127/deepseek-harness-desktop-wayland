# NVIDIA + niri + Wayland 显示稳定性设计

本文解释 dsh 在 NVIDIA + niri 下出现黑块、错位、频闪的原因，以及当前采用的最小缓解方案。
结论先行：**这不是 dsh 源码或 launcher flag 能单独修好的问题，主因在合成器缺少显式同步；
dsh 侧保持 GPU 硬渲染，niri 侧加一行 `wait-for-frame-completion-before-queueing`。**

## 症状

- 只在 Chromium / Electron 系应用出现（Chrome、VS Code、dsh 等）；其他 GTK/Qt 应用正常。
- 滚动、缩放窗口、页面动画时偶发黑块、局部错位、频闪；静止时也可能偶发。
- 高频偶发，短时间连拍/截图很难稳定复现。
- 关掉 GPU 合成（`--disable-gpu-compositing`）或开始录屏后消失/明显减轻。

## 根因

1. **niri 26.04 尚未实现 `linux-drm-syncobj-v1`（explicit sync）。**
   - niri issue #843 仍在跟踪；`wayland-info` 的 globals 里没有该协议。
   - 因此 Chromium 的 GPU 合成结果与 niri 的 DRM 提交之间只能靠**隐式同步**（dma-buf fence）。
   - NVIDIA 驱动在 Wayland 下的隐式同步/缓冲区生命周期是已知薄弱点；niri 把帧交给 DRM 时，
     GPU 可能还没写完，于是出现黑块/错位/频闪。
2. **niri 的直接扫描（direct scanout）与离屏效果会放大竞态。**
   - 平铺到整屏的 dsh 窗口可能被直接扫描到 primary plane；滚动/重绘时在
     “合成 ↔ 直接扫描”之间切换，格式/带宽变化会放大闪烁。
   - 全局阴影、20px 圆角、`clip-to-geometry` 等离屏效果也会让窗口走额外的合成路径。
3. **多显示器混合刷新率/缩放是触发器，不是根因。**
   - 本机：eDP-1 2560x1600@165Hz scale 1.5 + HDMI-A-1 2560x1440@144Hz scale 1.0。
   - 社区报告过类似组合（165/180Hz + 不同 scale）下 Chromium 闪烁；降低刷新率或改 scale
     对部分人有效，但会牺牲体验，不作为首选。
4. **dsh 侧能做的很有限。**
   - `--disable-gpu-compositing` 能消除，但把 UI 合成降为软件，违背“GPU 硬渲染 + 最高速”。
   - `--enable-features=WaylandLinuxDrmSyncobj` 在 niri 26.04 是 no-op（协议未宣告）。
   - 改 dsh 源码无法修复合成器与 DRM 之间的同步。

## 先跑诊断

```bash
dsh-wayland-doctor
```

它只读检查：会话/合成器、NVIDIA 驱动、niri 是否宣告 `linux-drm-syncobj-v1`、
`wait-for-frame-completion-before-queueing` 是否启用、dsh 的 GPU 进程与 flags、GPU 日志计数，
并按结果打印下一步。没有这个命令时说明包还没升级到包含它的版本。

## 推荐配置（niri 侧，最小改动）

在 `~/.config/niri/config.kdl` 的 `debug {}` 中加：

```kdl
debug {
    wait-for-frame-completion-before-queueing
}
```

原理：niri 在把一帧交给 DRM 前，先等待这一帧的 GPU 渲染完成（`res.sync.wait()`），
把“隐式同步是否及时”变成确定性的等待，从而消除竞态。

代价：

- 合成器线程每帧多等一次渲染完成；UI 场景通常 <1ms，165Hz 下无感。
- 游戏/高负载 3D 可能少几帧（每帧串行化 GPU 完成与提交）；可随时注释回退。
- 这是 niri 的 debug 选项，不承诺长期兼容；niri 实现 explicit sync 后应移除。

应用与回退：

```bash
cp ~/.config/niri/config.kdl ~/.config/niri/config.kdl.bak
# 编辑加入上面一行
niri validate
niri msg action load-config-file
```

回退：注释该行，再 `niri msg action load-config-file`。

## 如果仍然偶发：按代价从低到高

1. **`restrict-primary-scanout-to-matching-format`**（niri debug）
   - 只限制格式不匹配时的直接扫描，代价小于完全禁用扫描。
2. **`disable-direct-scanout`**（niri debug）
   - 完全禁用直接扫描；最稳，但全屏视频/游戏会多一点合成功耗。
> **不使用按窗口覆盖 opacity / 圆角 / clip**：用户要求所有窗口保持同一套全局外观，
> 不接受 dsh 的窗口特殊配置。需要更强措施时用下面的**全局**选项，不要对单个窗口做特殊规则。

3. **Chromium 侧兜底**（会损失性能，不设为默认）
   ```bash
   DSH_GPU_COMPOSITING=software deepseek-harness-wayland   # 只关 UI 合成，保留 GPU 光栅/WebGL/视频
   # 或更彻底
   DSH_GPU_FLAGS="--disable-gpu-compositing" deepseek-harness-wayland
   # 或减少零拷贝/光栅路径
   DSH_GPU_ZERO_COPY=0 deepseek-harness-wayland
   DSH_GPU_RASTERIZATION=0 deepseek-harness-wayland
   ```
   - `--disable-gpu-compositing` 是社区确认能消除闪烁的开关，但 UI 合成变软件；
     只作为排障/临时方案，不作为默认。
   - `DSH_GPU_COMPOSITING=software` 是 launcher 提供的折中开关：只关浏览器合成器，
     GPU 光栅、WebGL、视频解码仍是硬渲染；比 `DSH_GPU_SOFTWARE=1` 损失小。

## 分辨率/缩放说明

eDP-1 在 scale 1.5 下逻辑尺寸是 1706.67×1066.67；Chromium 会把窗口缓冲区向上取整到
2561×1601，而输出是 2560×1600，存在 1px 的裁剪/取整差。它通常只影响最右/最下一列像素，
不是“错位频闪”的主因；如果视觉上确实有 1px 偏移，可试验：

```bash
niri msg output eDP-1 scale 1.6   # 2560/1.6=1600 整数，缓冲区正好 2560x1600
```

这是临时输出配置（不写入文件），重启/配置变更后恢复；确认有效再改 `monitor.kdl`。

## 验证与观测

- `niri validate` + `niri msg action load-config-file` 必须无报错。
- 运行日志：`${XDG_RUNTIME_DIR}/dsh-desktop-gpu-fallback.log`。
  - 出现 `Frame latency is negative` 说明帧时序异常，可作为辅助指标，但不是充分条件。
  - 出现 `GPU process isn't usable` / `launch-failed` 才是 GPU 进程级故障，launcher 会兜底。
- 因为问题是高频偶发，**不要用短时截图连拍下结论**；以“长时间实际使用 + 设计上消除竞态”为准。

## 未来

- niri 实现 `linux-drm-syncobj-v1` 后，`--enable-features=WaylandLinuxDrmSyncobj` 会真正生效，
  届时可移除 `wait-for-frame-completion-before-queueing`。
- 跟踪：niri issue #843（explicit sync）、niri discussion #3777（Electron flicker）、
  niri wiki Nvidia / Debug Options。

## 参考

- <https://github.com/niri-wm/niri/discussions/3777>
- <https://github.com/YaLTeR/niri/issues/843>
- <https://github.com/niri-wm/niri/wiki/Nvidia>
- <https://github.com/niri-wm/niri/wiki/Configuration:-Debug-Options>
- <https://forum.archlinuxcn.org/t/topic/17094>
