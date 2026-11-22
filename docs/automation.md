# 自动构建与滚动发布（追踪上游 git）

本仓库现在默认追踪 `deepseek-ai/deepseek-harness` 的 **`master` 分支**，而不是只追 release tag。
上游的 Linux 桌面支持仍在演进，`master` 比 tag 更早包含构建脚本、Host runtime、客户端 UI 的修复；
代价是补丁需要跟随 `master` rebase。

## 版本规则

一次构建对应一个不可变的上游 commit：

```
pkgver = <上游 package.json 版本>.r<相对最近 tag 的提交数>.g<短 SHA>
例：0.2.2rc4.r1407.gca33fd6-1
```

- `pkgver` 里的 SHA 是 40 位 commit；`source=` 直接指向
  `https://github.com/deepseek-ai/deepseek-harness/archive/<sha>.tar.gz`，构建可复现。
- 同一上游 SHA 下 `patches/` 变化时，CI 自动 `pkgrel+1` 重建；新 SHA 从 1 开始。
- 每 **5 分钟**检查一次 `master` 的当前 head；master 构建至少间隔 1 小时（可用 `min_interval` 调），新 tag 绕过 cooldown；只有代码路径变化才真正构建，docs/tests 变更跳过。

## 发布模型：一个 rolling Release

追踪 git 时**不能**给每个 commit 建 release/tag：一年会有上千个 tag，`latest` 失去意义，
341 MB 的包也会把 release 列表撑爆。本仓库只保留**一个固定 tag 的 release**：

```
tag: rolling
assets:
  deepseek-harness-desktop-wayland-<pkgver>-<pkgrel>-x86_64.pkg.tar.zst
  dsh.db          # pacman repo 数据库（repo-add 生成，只指向当前包）
  latest          # pkgver/pkgrel/artifact/upstream_sha，供本机同步读取
  metadata.env
  SHA256SUMS
```

- 包文件名带版本；旧包资产保留最近 3 个，回滚可按 URL 直接 `pacman -U`。
- `dsh.db` 每次构建覆盖；`repo-add` 在 CI 的 Arch 容器里执行。
- 公开仓库用独立的 `[dsh]` 段 + `dsh.db`（见 `docs/publish.md`）；`[localrepo]` 保持给其他自维护项目，
  避免一个 db 把后续项目全绑在 DSH 的发布节奏上。
- 需要离线兜底时用 `ci/sync-dsh-repo.sh` 拉到 `/srv/dshrepo`（DSH 专用），不碰 `localrepo`。

## 工作流

`.github/workflows/build.yml`：

1. **resolve**（几秒）
   - `gh api commits/<ref>` 解析 SHA、提交时间；
   - 以最近一次上游 release tag 为基线，`compare` 得到 `ahead_by`；
   - 读取 `apps/desktop/package.json` 的版本，生成 `pkgver`；
   - 读取 `rolling` release 的 `metadata.env`；上游 SHA 与上次构建相同则跳过；
   - 若 `compare` 显示只改了文档/测试（且文件数 < 300），跳过；
   - 下载上游 archive，算 `sha256`。
2. **build**（约 25–50 分钟）
   - 在 `archlinux:base-devel` 容器里跑 `makepkg`，保证 glibc 与 Arch 一致；
   - `prepare()` 按序应用 `patches/0001..0017`，任何一个失败都会在 1 分钟内中止，
     不会浪费后面的构建时间；
   - `build()` 跑上游的 `package:linux:x64:dir`。
3. **publish**
   - 更新唯一的 `rolling` release：上传版本化包、`dsh.db`、`latest`、`SHA256SUMS`、`metadata.env`；
   - release notes 带上游 commit 列表、补丁指纹和 pacman `Server` 示例；
   - 只保留最近 3 个 `.pkg.tar.zst` 资产。

手动触发：

```bash
# 追 master（默认）
gh workflow run build-desktop -R Moritz230127/deepseek-harness-desktop-wayland

# 固定到某个 commit / tag
gh workflow run build-desktop -R ... -f ref=<sha|tag>

# 补丁变了但上游 SHA 没变：CI 会自动 pkgrel+1；手动触发时留空 pkgrel 即可
gh workflow run build-desktop -R ...
```

## 可选：本机兜底

云端 `[dsh]` 源正常时不需要这一步。只有 GitHub 下载慢、或想留离线副本时：

```bash
# 只下载、校验、repo-add 到 /srv/dshrepo，不自动安装
./ci/sync-dsh-repo.sh

# 确认后安装
sudo pacman -Syu deepseek-harness-desktop-wayland
```

`/srv/dshrepo` 是 DSH 专用兜底仓库；`/srv/localrepo` 不受影响，继续给其他自维护项目用。

```ini
# ~/.config/systemd/user/dsh-sync.service
[Service]
Type=oneshot
ExecStart=%h/dsh-re/dsh-desktop-wayland/ci/sync-dsh-repo.sh
```

```ini
# ~/.config/systemd/user/dsh-sync.timer
[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
```

`sync-dsh-repo.sh` 里的 `sudo repo-add` 需要一次密码；如果不想每次输，只给这一条命令加
NOPASSWD，不要把整个脚本放进 sudoers。

## 失败通知（已启用）

构建或发布失败时，`.github/workflows/build.yml` 的 `notify` job 会：

- 创建/更新带 `ci-failure` label 的 issue；
- 附上 run URL、上游 ref/SHA、`pkgver`；
- 附上失败日志的最后 60 行，以及本机复现命令。

这样 DSH 不需要一直开着：失败先落在 GitHub issue 里，你看到再处理。
同一 SHA 的重复失败会追加评论，不会刷一堆 issue。

## 后续自动修复（按需再上）

1. 失败频率低（每月 0–2 次）：保持手动，issue 只是提醒。
2. 失败变频繁：加一个 DSH 定时任务，轮询 `ci-failure` issue，开修复 session；
   仍然只提 PR，不直接改 `main`。
3. 需要工单、审计、并发控制：部署官方
   [`dsh-superagent-prototype`](https://github.com/deepseek-ai/dsh-superagent-prototype)。
   它把 GitHub CI 作为 Source，Policy 的 accept mode 设为 `auto`、加一条
   “修复补丁失效”规则，worker 会拉 master、修 patch、跑 `makepkg --nobuild`、提 PR；
   默认不自动 merge。

无论哪一级，**CI 通过 + 人 merge** 是最后一道闸门。

## 补丁 rebase（唯一需要人做的一步）

CI 报 `补丁失败：00xx-...` 时：

```bash
cd ~/dsh-re/dsh-desktop-wayland

# 1) 取新 master 的干净树
mkdir -p /tmp/dsh-rebase && cd /tmp/dsh-rebase
curl -fL -o master.tar.gz \
  https://github.com/deepseek-ai/deepseek-harness/archive/master.tar.gz
rm -rf tree && mkdir tree && tar -xzf master.tar.gz -C tree --strip-components=1

# 2) 按序应用，定位失败的补丁
cd tree
for p in ~/dsh-re/dsh-desktop-wayland/patches/0*.patch; do
  echo "== $(basename "$p")"
  patch -Np1 --no-backup-if-mismatch -i "$p" || break
done

# 3) 修 .rej / 手工改上下文，重新生成该补丁的 hunk
#    常见情况：上游把文件搬了（改 diff 路径）、插入了 import（补上下文行）、
#    删除了旧文件（删掉对应 diff 段）。
```

修完后在干净树上做一次只到 prepare 的验证：

```bash
cd /home/Arch/dsh-re/dsh-desktop-wayland
rm -rf /tmp/pkgtest && mkdir /tmp/pkgtest && cp -aL packaging/. /tmp/pkgtest/
cd /tmp/pkgtest && makepkg --nobuild --nocheck --nodeps
```

通过后提交补丁；CI 会在下一个 5 分钟窗口自动 `pkgrel+1` 重建（也可手动 dispatch，留空 pkgrel）。

## 回滚

- `rolling` release 保留最近 3 个版本化包；`/srv/dshrepo` 里的旧 `.pkg.tar.zst` 不会因 `repo-add` 消失。
- 公开仓库的旧包可直接 `sudo pacman -U https://github.com/<owner>/<repo>/releases/download/rolling/<旧文件名>`。
- 回滚到上一版：

```bash
sudo pacman -U /srv/dshrepo/deepseek-harness-desktop-wayland-<旧版本>-x86_64.pkg.tar.zst
```

- 若新版启动失败，先回滚包，再在 issue 里附 `metadata.env` 的上游 SHA。

## 成本与限制

- 公开仓库：Actions 分钟数免费；私有仓库：Free 计划 2,000 分钟/月。
  一次实际构建约 12 分钟（2026-11-17 实测）；5 分钟检查约 288 次/天、每次 resolve 约 10–15 秒，约 48 分钟/天；master 构建最多 24 次/天（1 小时 cooldown），新 tag 额外触发。公开仓库 Actions 免费；私有仓库 Free 额度 2,000 分钟/月，按 24 次构建/天估算约 8,600 分钟/月，**会超**——私有仓库请把 cooldown 调大（例如 6 小时）或改用公开仓库。
- 单个 release 持有多个版本化包，每个约 341 MB；工作流只保留最近 3 个。
- CI 不保存 YubiKey 私钥，也不签名 pacman 包；本机 `[localrepo]` 是 `SigLevel = Optional TrustAll`，
  依赖 HTTPS + `SHA256SUMS` 校验。需要签名时在本机入库阶段用 `repo-add -s`。
- `master` 可能短暂不可构建；工作流失败不会产生新 Release，本机继续用上一版。
