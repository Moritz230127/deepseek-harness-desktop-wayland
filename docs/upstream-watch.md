# 上游实时触发：一个 PAT + 一个 5 分钟 watcher，替代不可靠的 GitHub schedule

## 背景

GitHub Actions 的 `schedule` 在这个仓库上实测不可靠：

- 旧 6h cron 的 2026-11-22 12:00Z 档到 12:14Z 都没有启动；
- 新 5 分钟 cron / Rodriguez 15 分钟 cron 在部署后 20+ 分钟内也没有出现任何 scheduled run；
- 同仓库的 `push` 触发和手动 dispatch 都正常。

结论：**“上游发版 → 构建 → 镜像”这条关键路径不能只押 GitHub 定时器。**

## 方案：外部 watcher 同时触发两端

```text
VPS / 本机 systemd timer（5 分钟）
  ├─ git ls-remote deepseek-ai/deepseek-harness master
  │     head 变化 → dispatch build 仓（event=dsh-upstream）
  └─ 读 build 仓 rolling release 的 latest
        artifact 变化 → dispatch Rodriguez（event=dsh-published）
              │
              ▼
build-desktop（repository_dispatch）→ resolve → build → rolling release
                                              │
Rodriguez（repository_dispatch）→ 下载/重签/repo-add → pacman 可见
```

关键点：

- **只需要一个 fine-grained PAT**（两个仓 `Contents: Read and write`）；
- **不需要在仓库里配置 secret**：镜像由 watcher 在 `latest` 变化后触发；
- 不再依赖 GitHub 的 `schedule`；
- 两个 dispatch 都是 API 调用，秒级生效；构建约 12 分钟，镜像约 1–2 分钟。

构建仓自己的 `dispatch to Rodriguez` 步骤仍然保留：如果你另外配置了
`RODRIGUEZ_DISPATCH_TOKEN`，构建完成会直接通知 Rodriguez，watcher 的镜像触发是冗余但无害的
（Rodriguez 的 digest 去重会跳过重复）。

## 一次性配置

### 1. 创建 PAT

<https://github.com/settings/personal-access-tokens/new>

- Repository access：只选
  - `Moritz230127/deepseek-harness-desktop-wayland`
  - `Moritz230127/rodriguez`
- Permissions：**Contents: Read and write**（两个仓），其余 No access
- 过期时间按习惯（建议 90 天）

### 2. 部署 watcher

```bash
install -Dm755 ci/upstream-watch.sh ~/.local/bin/upstream-watch.sh

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
ExecStart=%h/.local/bin/upstream-watch.sh
```

```ini
# ~/.config/systemd/user/dsh-upstream-watch.timer
[Unit]
Description=Poll dsh upstream + build latest every 5 minutes

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
journalctl --user -u dsh-upstream-watch.service -n 30
```

VPS 上部署同理（systemd system unit 或 root cron），推荐 VPS，因为本机可能关机。

### 3. 验证

```bash
# 清状态，强制走一遍两个 dispatch
rm -rf ~/.local/state/dsh-upstream-watch
GH_TOKEN=$(sed -n 's/^GH_TOKEN=//p' ~/.config/dsh-upstream-watch/env) \
  ~/.local/bin/upstream-watch.sh

gh run list -R Moritz230127/deepseek-harness-desktop-wayland --limit 3
gh run list -R Moritz230127/rodriguez --limit 3
```

预期：

- 构建仓出现一条 `repository_dispatch` 的 `build-desktop` run（上游 head 与上次构建相同则
  resolve 直接跳过，不会重复构建）；
- `latest` 与上次镜像不同时，Rodriguez 出现一条 `repository_dispatch` 的 `repo` run；
  digest 已存在则镜像步骤会跳过。

## 运行语义

- watcher 每 5 分钟跑一次，`master.sha` / `latest.artifact` 两个状态文件避免重复 dispatch。
- 上游 head 变化但只有 docs/tests 时，build 的 `resolve` 会跳过（不会浪费 12 分钟）。
- 新 tag 在 `resolve` 里绕过 1 小时 cooldown。
- `latest` 变化时才触发镜像；构建失败不会改 `latest`，所以不会镜像坏包。
- 本机 watcher 关机期间不会补跑；开机后下一次 timer 会看到最新状态并 dispatch。
  需要 24/7 就放 VPS。

## 安全

- PAT 只放 watcher 的 600 环境文件；不要提交、不要贴到 issue。
- 只有两个仓的 Contents 写权限；泄漏后立即 revoke 并轮换。
- watcher 只读 `git ls-remote` 和公开的 `latest` 资产，不 clone、不上传源码。

## 维护

- 上游默认分支变化时改脚本里的 `refs/heads/master`。
- PAT 过期会报 401；重新生成并更新环境文件。
- GitHub 定时器恢复后，watcher 可以保留（双保险），也可以只留 watcher 停掉不可靠的 cron。
