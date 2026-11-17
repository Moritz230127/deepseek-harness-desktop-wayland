# 发布流程

本仓库默认由 GitHub Actions 自动构建并发布，见 [automation.md](automation.md)。
下面的手工命令只用于调试或工作流不可用时。

## 自动（推荐）

```bash
# 默认追 master；也可以 -f ref=<tag|sha>
gh workflow run build-desktop -R Moritz230127/deepseek-harness-desktop-wayland

# 补丁变更、上游 SHA 不变
gh workflow run build-desktop -R ... -f pkgrel=2 -f force=true
```

工作流会：

1. 解析上游 commit 和 `pkgver`；
2. 在 Arch 容器里 `makepkg`；
3. 更新唯一的 `rolling` Release：版本化包、`dsh.db`、`latest`、`SHA256SUMS`、`metadata.env`。

本机入库：

```bash
./ci/sync-localrepo.sh
sudo pacman -Syu deepseek-harness-desktop-wayland
```

## 手工（调试）

```bash
# 1) 在干净的上游 master 树上应用补丁后，或直接用参数化 PKGBUILD：
cd packaging
DSH_PKGVER=0.2.2rc3.r608.g39163dd \
DSH_PKGREL=1 \
DSH_UPSTREAM_REF=<40位sha> \
DSH_UPSTREAM_COMMIT=<40位sha> \
DSH_UPSTREAM_SHA256=<archive sha256> \
makepkg -C -s --nocheck

# 2) 产物
ls -lh deepseek-harness-desktop-wayland-*.pkg.tar.zst
```

## 发布到 GitHub（一个 rolling Release）

追踪 git 时不要为每个 commit 建 release/tag。固定 tag `rolling`，资产用版本化文件名：

```bash
# 在 CI 产出的 out/ 目录：包 + dsh.db + latest + metadata.env + SHA256SUMS
gh release create rolling out/*.pkg.tar.zst out/dsh.db out/latest \
  out/metadata.env out/SHA256SUMS \
  -R Moritz230127/deepseek-harness-desktop-wayland \
  --prerelease \
  --title "rolling: deepseek-harness-desktop-wayland <pkgver>-<pkgrel>" \
  --notes-file release-notes.md
# 已存在时
gh release upload rolling out/*.pkg.tar.zst out/dsh.db out/latest \
  out/metadata.env out/SHA256SUMS -R ... --clobber
```

## 公开仓库：直接把 Release 当 pacman 源

仓库设为 public 后，GitHub Release 资产可以直接作为 pacman 的 `Server`，不需要本机 repo：

```ini
[dsh]
SigLevel = Optional TrustAll
Server = https://github.com/Moritz230127/deepseek-harness-desktop-wayland/releases/download/rolling
```

```bash
sudo pacman -Syy
sudo pacman -S deepseek-harness-desktop-wayland
```

私有仓库不能这样用（pacman 不会带 GitHub token），用 `ci/sync-localrepo.sh` 走 `gh` 下载。

仓库默认 private。公开可获得无限制 Actions 分钟数，但先确认没有个人信息/凭据：

```bash
gh repo edit --visibility public --accept-visibility-change-consequences
```

## 推送到 GitHub 的代理问题

本机 git 全局配置了 `gh-proxy` 的 `insteadOf` 重写；直连推送时用空全局配置 + gh 凭据：

```bash
GIT_CONFIG_GLOBAL=/dev/null git -c credential.helper='!gh auth git-credential' \
  push origin main
```
