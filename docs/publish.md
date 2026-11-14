# 发布流程（本机 localrepo + GitHub）

## 1. 构建

```bash
# 官方归档 + 补丁应用到工作树后
ci/build-wayland.sh <upstream-tree> --dir
# 产物：<upstream-tree>/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked
```

## 2. 打包

```bash
ci/package-wayland.sh <linux-unpacked> <out-dir> 0.2.2rc3
# 产出 deepseek-harness-desktop-wayland-0.2.2rc3-1-x86_64.pkg.tar.zst
```

## 3. 发布到本机 localrepo

```bash
STAGE=~/.local/share/dsh-local-update/staging/wayland-0.2.2rc3
mkdir -p "$STAGE"
cp <out-dir>/deepseek-harness-desktop-wayland-0.2.2rc3-1-x86_64.pkg.tar.zst "$STAGE/"
# 写入 metadata.env（tag/commit/归档 sha256/补丁系列 sha256/构建时间/包 sha256）
(cd "$STAGE" && sha256sum ./*.pkg.tar.zst metadata.env > SHA256SUMS)

# root 窗口内（用户本人开窗；脚本要求 SUDO_USER 且 staging 属于当前用户）
dsh-root run 'env SUDO_USER=Arch /usr/local/bin/dsh-localrepo-publish '"$STAGE"

# 客户端刷新元数据后即可安装
sudo pacman -Sy
sudo pacman -S deepseek-harness-desktop-wayland
```

## 4. 发布到 GitHub

```bash
# 本机 git 全局配置了 gh-proxy 的 insteadOf 重写，直接 push 会走代理并失败；
# 用空全局配置 + gh 凭据 helper 直连（仅影响这条命令）：
GIT_CONFIG_GLOBAL=/dev/null git -c credential.helper='!gh auth git-credential' \
  push origin main
GIT_CONFIG_GLOBAL=/dev/null git -c credential.helper='!gh auth git-credential' \
  push origin v0.2.2rc3-1

gh release create v0.2.2rc3-1 --repo Moritz230127/deepseek-harness-desktop-wayland \
  --title "deepseek-harness-desktop-wayland 0.2.2rc3-1 (Arch Linux / Wayland)" \
  --notes-file release-notes.md

gh release upload v0.2.2rc3-1 --repo Moritz230127/deepseek-harness-desktop-wayland \
  <pkg.tar.zst> <SHA256SUMS> <metadata.env> --clobber
```

仓库默认 **private**（与旧仓库一致）；如需公开：`gh repo edit --visibility public --accept-visibility-change-consequences`。
