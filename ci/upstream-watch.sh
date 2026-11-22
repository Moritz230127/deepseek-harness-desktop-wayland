#!/usr/bin/env bash
# 外部触发器：替代不可靠的 GitHub schedule。
#
# 每 5 分钟（systemd timer / cron）做两件事：
#   1) 上游 master head 变化 → repository_dispatch 到构建仓，触发 build-desktop；
#   2) 构建仓 rolling release 的 latest artifact 变化 → repository_dispatch 到 Rodriguez，
#      触发镜像。
#
# 只需要一个 fine-grained PAT（两个仓 Contents: Read and write），不需要在仓库里配 secret。
#
# 环境变量：
#   GH_TOKEN         必填
#   UPSTREAM_REPO    默认 deepseek-ai/deepseek-harness
#   BUILD_REPO       默认 Moritz230127/deepseek-harness-desktop-wayland
#   RODRIGUEZ_REPO   默认 Moritz230127/rodriguez
#   STATE_DIR        默认 ${XDG_STATE_HOME:-$HOME/.local/state}/dsh-upstream-watch
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN 未设置}"
upstream=${UPSTREAM_REPO:-deepseek-ai/deepseek-harness}
build_repo=${BUILD_REPO:-Moritz230127/deepseek-harness-desktop-wayland}
rodriguez_repo=${RODRIGUEZ_REPO:-Moritz230127/rodriguez}
state_dir=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-upstream-watch}
mkdir -p "$state_dir"

latest_url="https://github.com/$build_repo/releases/download/rolling/latest"

dispatch() {
  local repo=$1 event=$2 payload=$3
  printf '%s' "$payload" | gh api "repos/$repo/dispatches" --input - >/dev/null
}

# 1) 上游 master 变化 → 构建
sha=$(git ls-remote "https://github.com/$upstream" refs/heads/master | awk '{print $1}')
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "无法解析上游 head" >&2; exit 1; }
last_sha=$(cat "$state_dir/master.sha" 2>/dev/null || true)
if [[ $sha != "$last_sha" ]]; then
  dispatch "$build_repo" dsh-upstream \
    "$(printf '{"event_type":"dsh-upstream","client_payload":{"sha":"%s"}}' "$sha")"
  printf '%s\n' "$sha" > "$state_dir/master.sha"
  echo "dispatched build for $sha"
fi

# 2) 构建完成（latest 指针变化）→ 镜像
latest=$(curl -fsSL --retry 3 --retry-delay 2 "$latest_url" 2>/dev/null || true)
artifact=$(printf '%s\n' "$latest" | sed -n 's/^artifact=//p' | head -1)
upstream_sha=$(printf '%s\n' "$latest" | sed -n 's/^upstream_sha=//p' | head -1)
last_artifact=$(cat "$state_dir/latest.artifact" 2>/dev/null || true)
if [[ -n $artifact && $artifact != "$last_artifact" ]]; then
  dispatch "$rodriguez_repo" dsh-published \
    "$(printf '{"event_type":"dsh-published","client_payload":{"artifact":"%s","upstream_sha":"%s"}}' "$artifact" "$upstream_sha")"
  printf '%s\n' "$artifact" > "$state_dir/latest.artifact"
  echo "dispatched mirror for $artifact"
fi
