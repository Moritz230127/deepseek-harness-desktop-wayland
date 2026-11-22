#!/usr/bin/env bash
# 轮询上游 master；head 变化时用 PAT 触发 dsh 构建仓的 repository_dispatch。
#
# 部署位置：VPS 或本机 systemd user timer（建议 5 分钟）。需要 GH_TOKEN：
#   fine-grained PAT，两个仓（构建仓 + Rodriguez）Contents: Read and write。
#
# 环境变量：
#   GH_TOKEN        必填
#   UPSTREAM_REPO   默认 deepseek-ai/deepseek-harness
#   BUILD_REPO      默认 Moritz230127/deepseek-harness-desktop-wayland
#   STATE_DIR       默认 ${XDG_STATE_HOME:-$HOME/.local/state}/dsh-upstream-watch
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN 未设置}"
upstream=${UPSTREAM_REPO:-deepseek-ai/deepseek-harness}
build_repo=${BUILD_REPO:-Moritz230127/deepseek-harness-desktop-wayland}
state_dir=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-upstream-watch}
mkdir -p "$state_dir"

sha=$(git ls-remote "https://github.com/$upstream" refs/heads/master | awk '{print $1}')
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "无法解析上游 head" >&2; exit 1; }

last=$(cat "$state_dir/master.sha" 2>/dev/null || true)
if [[ $sha == "$last" ]]; then
  exit 0
fi

payload=$(printf '{"event_type":"dsh-upstream","client_payload":{"sha":"%s"}}' "$sha")
printf '%s' "$payload" | gh api "repos/$build_repo/dispatches" --input - >/dev/null
printf '%s\n' "$sha" > "$state_dir/master.sha"
echo "dispatched $sha -> $build_repo"
