#!/usr/bin/env bash
# 在指定的 upstream 工作树里构建 Linux 桌面端（仅供 Lead 本地验证/打包使用）。
#
# 用法：
#   ci/build-wayland.sh <upstream-tree> [--dir|--appimage]
#
# 环境变量：
#   DSH_DESKTOP_LINUX_HOME  隔离的 DSH 数据目录（默认 /tmp/dsh-desktop-build-home）
#   ELECTRON_MIRROR         本地 Electron 镜像（默认 http://127.0.0.1:8899/）
#   PNPM_STORE_DIR          pnpm content-addressable store（默认 ~/.local/share/pnpm/store）
#   DOWNLOAD_CACHE          构建下载缓存（默认 /home/Arch/dsh-builds/downloads-cache）
#
# 说明：本脚本只做「官方流水线 + 本地环境」编排；补丁由调用方预先 apply。
set -euo pipefail

TREE=${1:?usage: build-wayland.sh <upstream-tree> [--dir|--appimage]}
MODE=${2:---dir}
export DSH_HOME=${DSH_DESKTOP_LINUX_HOME:-/tmp/dsh-desktop-build-home}
export ELECTRON_MIRROR=${ELECTRON_MIRROR:-http://127.0.0.1:8899/}
export npm_config_store_dir=${PNPM_STORE_DIR:-$HOME/.local/share/pnpm/store}
export COREPACK_ENABLE_STRICT=0
export CI=1
# release 源码包没有 .git：显式给出上游提交与 dirty（补丁 0010 让环境变量优先于 git 探测）。
TAG=${TAG:-dsh-v0.2.2-rc.3}
COMMIT=${COMMIT:-38a6a5c965aa99ab525161efb7cc5cf1fe62fced}
export DSH_CLIENT_COMMIT_HASH="$COMMIT"
export DSH_DESKTOP_BUILD_COMMIT="$COMMIT"
export DSH_DESKTOP_BUILD_DIRTY=${DSH_DESKTOP_BUILD_DIRTY:-1}
export TMPDIR=${TMPDIR:-/home/Arch/dsh-builds/rc3-wayland/tmp}
mkdir -p "$TMPDIR"
PNPM=${PNPM_BIN:-/home/Arch/.local/share/dsh-pnpm-11/node_modules/.bin/pnpm}
[[ -x $PNPM ]] || { echo "错误：找不到隔离 pnpm 11：$PNPM（npm i --prefix ~/.local/share/dsh-pnpm-11 pnpm@11.28.5）" >&2; exit 1; }

[[ -d $TREE/apps/desktop ]] || { echo "错误：$TREE 不是 upstream 工作树" >&2; exit 1; }
[[ $DSH_HOME != "$HOME/.dsh" ]] || { echo "错误：DSH_HOME 不能指向正在使用的 ~/.dsh" >&2; exit 1; }
mkdir -p "$DSH_HOME"

cd "$TREE"

# Linux 发布设置文件（git 忽略）。由构建脚本确定性地生成，避免残留/缺项：
# - APP_ID 用官方 com.deepseek.dsh（窗口 app_id 由 desktopName 决定，这里是包身份）
# - 打包期内部 pnpm（prepare:dsh 的 payload 安装）走镜像源，否则 registry.npmjs.org 单请求超时
cat > apps/desktop/.env.linux <<'ENVEOF'
DSH_DESKTOP_APP_ID=com.deepseek.dsh
DSH_DESKTOP_NPM_REGISTRY=https://registry.npmmirror.com
ENVEOF

# 复用下载缓存（@electron/get 与打包阶段都从这里取）。
mkdir -p apps/desktop/.desktop-build
ln -sfn "${DOWNLOAD_CACHE:-/home/Arch/dsh-builds/downloads-cache}" apps/desktop/.desktop-build/downloads

echo "==> pnpm $("$PNPM" --version) install (store: $npm_config_store_dir)" >&2
"$PNPM" install --frozen-lockfile --prefer-offline

case "$MODE" in
  --dir)      SCRIPT='package:linux:x64:dir' ;;
  --appimage) SCRIPT='package:linux:x64' ;;
  *) echo "未知模式：$MODE" >&2; exit 2 ;;
esac

echo "==> package target: $SCRIPT (DSH_HOME=$DSH_HOME)" >&2
"$PNPM" --dir apps/desktop run "$SCRIPT"

echo "==> 产物目录：" >&2
find apps/desktop/.desktop-build/targets -maxdepth 2 -type d -name '*unpacked*' -o -maxdepth 2 -type d -name 'unsigned-artifacts' 2>/dev/null | tee /dev/stderr
