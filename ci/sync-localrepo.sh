#!/usr/bin/env bash
# Download the newest rolling release into /srv/localrepo and refresh the db.
# Deliberately does NOT install: a bad build must not replace a working desktop.
set -euo pipefail

REPO=${REPO:-Moritz230127/deepseek-harness-desktop-wayland}
PKG=deepseek-harness-desktop-wayland
DB=${DB:-/srv/localrepo/localrepo.db.tar.gz}

latest=$(gh release view -R "$REPO" --json tagName --jq .tagName)
want=${latest#v}
have=$(pacman -Q "$PKG" 2>/dev/null | awk '{print $2}' || true)

if [[ -n $have ]] && (( $(vercmp "$want" "$have") <= 0 )); then
  echo "已是最新：$have（latest=$latest）"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh release download "$latest" -R "$REPO" -D "$tmp" \
  -p '*.pkg.tar.zst' -p SHA256SUMS -p metadata.env
(cd "$tmp" && sha256sum -c SHA256SUMS)

sudo cp "$tmp"/*.pkg.tar.zst /srv/localrepo/
sudo repo-add "$DB" "$tmp"/*.pkg.tar.zst
sudo pacman -Sy --noconfirm

if command -v notify-send >/dev/null; then
  notify-send "DSH $latest 已入库" "sudo pacman -Syu $PKG"
fi
echo "已入库 $latest；安装：sudo pacman -Syu $PKG"
