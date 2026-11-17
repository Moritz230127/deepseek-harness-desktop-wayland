#!/usr/bin/env bash
# Build the pacman package inside an Arch container (invoked by GitHub Actions).
#
# Required env: SHA, PKGVER, PKGREL, ARCHIVE_SHA256.
# Optional: HOST_UID, HOST_GID (default 1000).
set -euo pipefail

: "${SHA:?}"
: "${PKGVER:?}"
: "${PKGREL:?}"
: "${ARCHIVE_SHA256:?}"

HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}

echo "==> pacman bootstrap"
pacman -Syu --noconfirm --needed
pacman -S --noconfirm --needed git nodejs npm python zstd sudo

if ! id builder >/dev/null 2>&1; then
  useradd -m -u "$HOST_UID" builder
fi
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

# The PKGBUILD requires pnpm 11.x; Arch's pnpm can lag behind, so keep an isolated copy.
su builder -c 'npm i --prefix "$HOME/.local/share/dsh-pnpm-11" pnpm@11.28.5'

mkdir -p /w/out
chown -R builder:builder /w

echo "==> makepkg as builder (pkgver=$PKGVER pkgrel=$PKGREL sha=$SHA)"
su builder -c "cd /w && \
  DSH_PKGVER='$PKGVER' \
  DSH_PKGREL='$PKGREL' \
  DSH_UPSTREAM_REF='$SHA' \
  DSH_UPSTREAM_COMMIT='$SHA' \
  DSH_UPSTREAM_SHA256='$ARCHIVE_SHA256' \
  DSH_DESKTOP_NPM_REGISTRY='https://registry.npmjs.org' \
  PKGDEST='/w/out' \
  ./ci/makepkg.sh"

echo "==> pacman repo db"
cd /w/out
repo-add --quiet dsh.db.tar.gz ./*.pkg.tar.zst
# repo-add 留下 dsh.db -> dsh.db.tar.gz 的符号链接；Release 资产需要普通文件。
cp --dereference dsh.db dsh.db.file
mv dsh.db.file dsh.db
ls -lh
