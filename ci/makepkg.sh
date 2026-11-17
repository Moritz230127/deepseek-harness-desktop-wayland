#!/usr/bin/env bash
# Copy packaging/ into a clean makepkg directory and build the source package.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# packaging/ 里的补丁和资源是符号链接；makepkg 不支持本地 source 的子目录，
# 必须用 cp -aL 解引用后平铺在一个目录里。
cp -aL "$root/packaging/." "$work/"

cd "$work"
echo "==> PKGBUILD: $work/PKGBUILD"
makepkg -s --nocheck --noconfirm
