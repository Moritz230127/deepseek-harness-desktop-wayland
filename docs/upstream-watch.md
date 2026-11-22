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

- **只需要一个 fine-grained PAT**（两个仓 `Contents: Read and write`）；
- **不需要在仓库里配置 secret**：镜像由 watcher 在 `latest` 变化后触发；
- 不依赖 GitHub 的 `schedule`；
- 只用 `git` + `curl`，不需要 `gh`；
- 5 分钟一次，两次很小的 HTTPS 请求；正常时零输出，对 VPS 负载可忽略。

## 推荐：部署到 VPS（systemd system service）

`ci/systemd/` 里有现成的 unit。一次性的安装步骤：

```bash
# 1) 专用用户（无 shell、无 home）
sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin dsh-watch

# 2) 脚本与 unit
sudo install -Dm755 ci/upstream-watch.sh /usr/local/bin/upstream-watch.sh
sudo install -Dm644 ci/systemd/dsh-upstream-watch.service /etc/systemd/system/
sudo install -Dm644 ci/systemd/dsh-upstream-watch.timer   /etc/systemd/system/

# 3) token（640，仅 root 与 dsh-watch 可读）
sudo install -d -m755 /etc
sudo touch /etc/dsh-upstream-watch.env
sudo chown root:dsh-watch /etc/dsh-upstream-watch.env
sudo chmod 640 /etc/dsh-upstream-watch.env
sudoedit /etc/dsh-upstream-watch.env   # 写入 GH_TOKEN=github_pat_xxx

# 4) 启动
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-upstream-watch.timer
sudo systemctl start dsh-upstream-watch.service
sudo journalctl -u dsh-upstream-watch.service -n 30
sudo systemctl list-timers dsh-upstream-watch.timer
```

unit 的关键点：

- `User=dsh-watch`，最小权限；
- `StateDirectory=dsh-upstream-watch` → `/var/lib/dsh-upstream-watch` 存两个状态文件；
- `Nice=10`、`IOSchedulingClass=idle`，对 VPS 其他服务让路；
- `TimeoutStartSec=90`，不会挂死；
- `RandomizedDelaySec=15`，避免整点拥塞。

### 负载评估

每 5 分钟：

- 1 次 `git ls-remote`（几十 KB 内）；
- 1 次 `latest` 下载（185 B）；
- 只有上游 head 或 `latest` 变化时才各发 1 次 GitHub API dispatch；
- 一次进程存活几秒、内存 ~10–20 MB，`oneshot` 随即退出；
- 不构建、不装包、不 clone 源码。

对一台正常 VPS 的影响可以忽略，不会威胁其他服务稳定性。

## 本机部署（可选）

本机也可以跑同样的脚本（systemd user timer），但**只在本机开机时工作**；要 24/7 还是放 VPS。

## 验证

```bash
# 清状态，强制走一遍两个 dispatch
sudo rm -rf /var/lib/dsh-upstream-watch
sudo systemctl start dsh-upstream-watch.service
sudo journalctl -u dsh-upstream-watch.service -n 20

gh run list -R Moritz230127/deepseek-harness-desktop-wayland --limit 3
gh run list -R Moritz230127/rodriguez --limit 3
```

预期：

- 构建仓出现一条 `repository_dispatch` 的 `build-desktop` run（上游 head 与上次构建相同则
  resolve 跳过，不会重复构建）；
- `latest` 与上次镜像不同时，Rodriguez 出现一条 `repository_dispatch` 的 `repo` run；
  digest 已存在则镜像步骤跳过。

## 运行语义

- `master.sha` / `latest.artifact` 两个状态文件避免重复 dispatch。
- 上游 head 变化但只有 docs/tests 时，build 的 `resolve` 会跳过。
- 新 tag 在 `resolve` 里绕过 1 小时 cooldown。
- `latest` 变化时才触发镜像；构建失败不改 `latest`，不会镜像坏包。
- 上游网络暂时不可达时脚本退出 0（只记一行日志），不会让 timer 反复报失败。

## 安全

- PAT 只放 `/etc/dsh-upstream-watch.env`（640 root:dsh-watch），不要提交、不要贴到 issue。
- 只有两个仓的 Contents 写权限；泄漏后立即 revoke 并轮换。
- watcher 只读 `git ls-remote` 和公开的 `latest` 资产，不 clone、不上传源码。

## 维护

- 上游默认分支变化时改脚本里的 `refs/heads/master`。
- PAT 过期会报 401；重新生成并更新 `/etc/dsh-upstream-watch.env`，`systemctl restart` 不需要，
  下一次 timer 会读到新值。
- GitHub 定时器恢复后，watcher 可以保留（双保险），也可以停掉不可靠的 schedule。
