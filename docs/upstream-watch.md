# 上游实时触发：PAT watcher（替代不可靠的 GitHub schedule）

## 背景

GitHub Actions 的 `schedule` 在这个仓库上实测不可靠：

- 旧 6h cron 的 2026-11-22 12:00Z 档到 12:14Z 都没有启动；
- 新 5 分钟 cron / Rodriguez 15 分钟 cron 在部署后 20 分钟内也没有出现任何 scheduled run；
- 同仓库的 `push` 触发（12:14Z）和手动 dispatch 都正常。

结论：**不能把“上游发版 → 构建”这个关键路径只押在 GitHub 的定时器上**。
本文件给出一个 5 分钟的外部 watcher：轮询上游 `master`，head 变化时用 PAT 触发
`repository_dispatch`，由构建仓的 `build-desktop` 接住。

## 架构

```text
VPS / 本机 systemd timer（5 分钟）
  git ls-remote deepseek-ai/deepseek-harness master
        │ head 变化
        ▼
  gh api repos/Moritz230127/deepseek-harness-desktop-wayland/dispatches
        event_type=dsh-upstream
        │
        ▼
build-desktop（repository_dispatch）
  resolve → build（约 12 分钟）→ rolling release
        │ 发布后 dispatch（需要 RODRIGUEZ_DISPATCH_TOKEN）
        ▼
Rodriguez 立即镜像 → pacman 可见
```

没有 PAT 时，构建仓仍有 5 分钟 cron、Rodriguez 仍有 15 分钟 cron + push 触发；
watcher 是**在 GitHub 定时器不工作时仍然可靠**的那条路。

## 一次性配置

### 1. 创建 fine-grained PAT

访问 <https://github.com/settings/personal-access-tokens/new>：

- Repository access：只选
  - `Moritz230127/deepseek-harness-desktop-wayland`
  - `Moritz230127/rodriguez`
- Permissions：
  - **Contents: Read and write**（`repository_dispatch` 需要）
  - 其余全部 No access
- 过期时间按自己习惯（建议 90 天）。

### 2. 设置构建仓 secret（让构建完成后能立即通知 Rodriguez）

```bash
gh secret set RODRIGUEZ_DISPATCH_TOKEN \
  -R Moritz230127/deepseek-harness-desktop-wayland
# 粘贴同一个 PAT
```

### 3. 部署 watcher

把 `ci/upstream-watch.sh` 放到 VPS 或本机（例如 `~/bin/upstream-watch.sh`），
token 放到权限 600 的文件：

```bash
install -d -m700 ~/.config/dsh-upstream-watch
printf 'GH_TOKEN=%s\n' 'github_pat_xxx' > ~/.config/dsh-upstream-watch/env
chmod 600 ~/.config/dsh-upstream-watch/env
```

systemd user timer：

```ini
# ~/.config/systemd/user/dsh-upstream-watch.service
[Unit]
Description=DeepSeek Harness upstream watcher

[Service]
Type=oneshot
EnvironmentFile=%h/.config/dsh-upstream-watch/env
ExecStart=%h/bin/upstream-watch.sh
```

```ini
# ~/.config/systemd/user/dsh-upstream-watch.timer
[Unit]
Description=Poll dsh upstream master every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now dsh-upstream-watch.timer
systemctl --user list-timers dsh-upstream-watch.timer
journalctl --user -u dsh-upstream-watch.service -n 20
```

### 4. 验证

```bash
# 手动跑一次（head 未变时会静默退出）
GH_TOKEN=$(sed -n 's/^GH_TOKEN=//p' ~/.config/dsh-upstream-watch/env) \
  ~/bin/upstream-watch.sh

# 强制验证 dispatch：把 state 删掉再跑
rm -f ~/.local/state/dsh-upstream-watch/master.sha
GH_TOKEN=... ~/bin/upstream-watch.sh
gh run list -R Moritz230127/deepseek-harness-desktop-wayland --limit 3
```

预期：出现一条 `repository_dispatch` 的 `build-desktop` run；如果上游 head 与上次构建
相同，resolve 会跳过（不会重复构建）。

## 安全

- PAT 只放 watcher 的 600 环境文件与 GitHub secret；**不要提交到仓库**。
- PAT 只有两个仓的 Contents 写权限；泄漏后立即在 GitHub 设置里 revoke 并轮换。
- watcher 只读 `git ls-remote`，不 clone、不上传源码。

## 维护

- 上游换了默认分支（不是 `master`）时，改 `ci/upstream-watch.sh` 的 `refs/heads/master`。
- PAT 过期后 watcher 会报 401；重新生成并更新环境文件 + secret。
- GitHub 定时器恢复后，watcher 可以保留（双保险），也可以停掉 timer 只留 5 分钟 cron。
