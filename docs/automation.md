# 自动构建与滚动发布（追踪上游 git）

本仓库现在默认追踪 `deepseek-ai/deepseek-harness` 的 **`master` 分支**，而不是只追 release tag。
上游的 Linux 桌面支持仍在演进，`master` 比 tag 更早包含构建脚本、Host runtime、客户端 UI 的修复；
代价是补丁需要跟随 `master` rebase。

## 版本规则

一次构建对应一个不可变的上游 commit：

```
pkgver = <上游 package.json 版本>.r<相对最近 tag 的提交数>.g<短 SHA>
例：0.2.2rc3.r608.g39163dd-1
```

- `pkgver` 里的 SHA 是 40 位 commit；`source=` 直接指向
  `https://github.com/deepseek-ai/deepseek-harness/archive/<sha>.tar.gz`，构建可复现。
- 同一个上游 SHA、同一套补丁重复构建时，把 `pkgrel` 加一。
- 不追每个 commit：工作流每天检查一次，只有相关路径变化且 SHA 与上一次发布不同才构建。

## 工作流

`.github/workflows/build.yml`：

1. **resolve**（几秒）
   - `gh api commits/<ref>` 解析 SHA、提交时间；
   - 以最近一次上游 release tag 为基线，`compare` 得到 `ahead_by`；
   - 读取 `apps/desktop/package.json` 的版本，生成 `pkgver`；
   - 若同 `pkgver-pkgrel` 的 release 已存在，或上游 SHA 与上次发布相同，跳过；
   - 若 `compare` 显示只改了文档/测试（且文件数 < 300），跳过；
   - 下载上游 archive，算 `sha256`。
2. **build**（约 25–50 分钟）
   - 在 `archlinux:base-devel` 容器里跑 `makepkg`，保证 glibc 与 Arch 一致；
   - `prepare()` 按序应用 `patches/0001..0017`，任何一个失败都会在 1 分钟内中止，
     不会浪费后面的构建时间；
   - `build()` 跑上游的 `package:linux:x64:dir`。
3. **publish**
   - 上传 `.pkg.tar.zst`、`SHA256SUMS`、`metadata.env` 到 GitHub Release；
   - release notes 带上游 commit 列表和补丁指纹。

手动触发：

```bash
# 追 master（默认）
gh workflow run build-desktop -R Moritz230127/deepseek-harness-desktop-wayland

# 固定到某个 commit / tag
gh workflow run build-desktop -R ... -f ref=<sha|tag>

# 补丁变了但上游 SHA 没变：加 pkgrel 并强制重建
gh workflow run build-desktop -R ... -f pkgrel=2 -f force=true
```

## 本机入库

```bash
# 只下载、校验、repo-add，不自动安装
./ci/sync-localrepo.sh

# 确认后安装
sudo pacman -Syu deepseek-harness-desktop-wayland
```

建议用 systemd user timer 每 6 小时跑一次 `sync-localrepo.sh`。它**不会**自动 `pacman -S`：
滚动包可能坏，保留上一版用于回滚比省一次点击重要。

```ini
# ~/.config/systemd/user/dsh-sync.service
[Service]
Type=oneshot
ExecStart=%h/dsh-re/dsh-desktop-wayland/ci/sync-localrepo.sh
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

`sync-localrepo.sh` 里的 `sudo repo-add` 需要一次密码；如果不想每次输，只给这一条命令加
NOPASSWD，不要把整个脚本放进 sudoers。

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

通过后提交补丁，再 `gh workflow run ... -f pkgrel=<n> -f force=true`。

## 回滚

- GitHub Release 保留历史包；`/srv/localrepo` 里的旧 `.pkg.tar.zst` 不会因 `repo-add` 消失。
- 回滚到上一版：

```bash
sudo pacman -U /srv/localrepo/deepseek-harness-desktop-wayland-<旧版本>-x86_64.pkg.tar.zst
```

- 若新版启动失败，先回滚包，再在 issue 里附 `metadata.env` 的上游 SHA。

## 成本与限制

- 公开仓库：Actions 分钟数免费；私有仓库：Free 计划 2,000 分钟/月。
  一次冷构建约 30–50 分钟，热缓存约 20–30 分钟；每天最多一次，通常远低于额度。
- Release 资产每个约 341 MB；建议只保留最近 3–5 个版本。
- CI 不保存 YubiKey 私钥，也不签名 pacman 包；本机 `[localrepo]` 是 `SigLevel = Optional TrustAll`，
  依赖 HTTPS + `SHA256SUMS` 校验。需要签名时在本机入库阶段用 `repo-add -s`。
- `master` 可能短暂不可构建；工作流失败不会产生新 Release，本机继续用上一版。
