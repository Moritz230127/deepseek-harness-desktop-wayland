#!/usr/bin/env bash
# Download the newest rolling package into /srv/localrepo and refresh the db.
# Deliberately does NOT install: a bad build must not replace a working desktop.
set -euo pipefail

REPO=${REPO:-Moritz230127/deepseek-harness-desktop-wayland}
PKG=deepseek-harness-desktop-wayland
DB=${DB:-/srv/localrepo/localrepo.db.tar.gz}
REL=rolling

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

gh release download "$REL" -R "$REPO" -D "$tmp" -p latest -p SHA256SUMS
want_pkgver=$(sed -n 's/^pkgver=//p' "$tmp/latest")
want_pkgrel=$(sed -n 's/^pkgrel=//p' "$tmp/latest")
artifact=$(sed -n 's/^artifact=//p' "$tmp/latest")
[[ -n $want_pkgver && -n $want_pkgrel && -n $artifact ]] \
  || { echo "rolling release 的 latest 文件不完整" >&2; exit 1; }

want="$want_pkgver-$want_pkgrel"
have=$(pacman -Q "$PKG" 2>/dev/null | awk '{print $2}' || true)
if [[ -n $have ]] && (( $(vercmp "$want" "$have") <= 0 )); then
  echo "已是最新：$have（rolling=$want）"
  exit 0
fi

gh release download "$REL" -R "$REPO" -D "$tmp" -p "$artifact" --clobber
(
  cd "$tmp"
  grep -F "  $artifact" SHA256SUMS | sha256sum -c -
)

sudo cp "$tmp/$artifact" /srv/localrepo/
sudo repo-add "$DB" "/srv/localrepo/$artifact"
sudo pacman -Sy --noconfirm

if command -v notify-send >/dev/null; then
  notify-send "DSH $want 已入库" "sudo pacman -Syu $PKG"
fi
echo "已入库 $want；安装：sudo pacman -Syu $PKG"
