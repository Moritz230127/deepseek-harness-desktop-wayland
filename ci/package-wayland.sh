#!/usr/bin/env bash
# 把 ci/build-wayland.sh 产出的 linux-unpacked 打成 pacman 包（本地交付用）。
#
# 用法：ci/package-wayland.sh <linux-unpacked> <out-dir> [pkgver]
# 产物：<out-dir>/deepseek-harness-desktop-wayland-<pkgver>-1-x86_64.pkg.tar.zst
set -euo pipefail

UNPACKED=${1:?usage: package-wayland.sh <linux-unpacked> <out-dir> [pkgver] [pkgrel]}
OUT=${2:?usage: package-wayland.sh <linux-unpacked> <out-dir> [pkgver] [pkgrel]}
PKGVER=${3:-0.2.2rc3}
PKGREL=${4:-1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/home/Arch/dsh-builds/rc3-wayland/package-work}
PKGNAME=deepseek-harness-desktop-wayland

[[ -d $UNPACKED ]] || { echo "错误：找不到 linux-unpacked：$UNPACKED" >&2; exit 1; }
mkdir -p "$OUT"

# 1) 载荷压缩（payload 顶层 = linux-unpacked 内容）
echo "==> 压缩载荷 ..." >&2
mkdir -p "$WORK"
rm -f "$WORK/dsh-payload.tar.zst"
bsdtar --zstd -cf "$WORK/dsh-payload.tar.zst" -C "$UNPACKED" .

# 2) 装配 makepkg 目录（预构建 PKGBUILD + 打包资产）
echo "==> 装配 makepkg 目录 ..." >&2
BD="$WORK/makepkg"
rm -rf "$BD"
mkdir -p "$BD"
cp "$ROOT/packaging/PKGBUILD.prebuilt" "$BD/PKGBUILD"
cp -a "$ROOT/packaging/launcher" "$ROOT/packaging/desktop" "$ROOT/packaging/systemd" \
      "$ROOT/packaging/icons" "$ROOT/packaging/deepseek-harness.apparmor" \
      "$ROOT/packaging/deepseek-harness.install" "$BD/" 2>/dev/null || {
  # 资产可能尚在调整：逐个报错更清晰
  for f in packaging/launcher/deepseek-harness packaging/desktop/deepseek-harness.desktop \
           packaging/systemd/deepseek-harness-desktop.service packaging/icons/deepseek-harness.svg \
           packaging/deepseek-harness.apparmor packaging/deepseek-harness.install; do
    [[ -e $ROOT/$f ]] || { echo "错误：缺少打包资产 $f" >&2; exit 1; }
  done
  mkdir -p "$BD/launcher" "$BD/desktop" "$BD/systemd" "$BD/icons"
  cp "$ROOT/packaging/launcher/deepseek-harness" "$BD/launcher/"
  cp "$ROOT/packaging/desktop/deepseek-harness.desktop" "$BD/desktop/"
  cp "$ROOT/packaging/systemd/deepseek-harness-desktop.service" "$BD/systemd/"
  cp "$ROOT/packaging/icons/deepseek-harness.svg" "$BD/icons/"
  cp "$ROOT/packaging/deepseek-harness.apparmor" "$ROOT/packaging/deepseek-harness.install" "$BD/"
}
chmod +x "$BD/launcher/deepseek-harness" 2>/dev/null || true
sed -i -e "s/^pkgver=.*/pkgver=$PKGVER/" -e "s/^pkgrel=.*/pkgrel=$PKGREL/" "$BD/PKGBUILD"
cp "$WORK/dsh-payload.tar.zst" "$BD/"

# 3) makepkg（只打包，不重建）
echo "==> makepkg ..." >&2
( cd "$BD" && PKGDEST="$OUT" makepkg --nodeps --noconfirm --nocheck --skipinteg )
echo "==> 完成：" >&2
ls -lh "$OUT"/*"$PKGNAME"* 2>/dev/null || ls -lh "$OUT"
