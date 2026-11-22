#!/usr/bin/env bash
# 外部触发器：替代不可靠的 GitHub schedule。
#
# 每 5 分钟（systemd timer / cron）做两件事：
#   1) 上游 master head 变化 → 触发构建仓 build-desktop（repository_dispatch）；
#   2) 构建仓 rolling release 的 latest artifact 变化 → 触发 Rodriguez 镜像。
#
# 只需要一个 fine-grained PAT（两个仓 Contents: Read and write）；
# 不依赖 gh CLI，只用 git/curl，适合 VPS 上最小化部署。
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
  local repo=$1 payload=$2
  if ! printf '%s' "$payload" | curl -fsS --max-time 20 -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/$repo/dispatches" \
      --data-binary @- >/dev/null; then
    echo "dispatch failed: $repo" >&2
    return 1
  fi
}

# 1) 上游 master 变化 → 构建
if ! out=$(timeout 20 git ls-remote "https://github.com/$upstream" refs/heads/master 2>/dev/null); then
  echo "上游不可达，跳过本轮" >&2
  exit 0
fi
sha=$(printf '%s\n' "$out" | awk '{print $1}')
if [[ ! $sha =~ ^[0-9a-f]{40}$ ]]; then
  echo "无法解析上游 head：$sha" >&2
  exit 0
fi
last_sha=$(cat "$state_dir/master.sha" 2>/dev/null || true)
if [[ $sha != "$last_sha" ]]; then
  dispatch "$build_repo" \
    "$(printf '{"event_type":"dsh-upstream","client_payload":{"sha":"%s"}}' "$sha")"
  printf '%s\n' "$sha" > "$state_dir/master.sha"
  echo "dispatched build for $sha"
fi

# 2) 构建完成（latest 指针变化）→ 镜像
latest=$(curl -fsSL --max-time 15 --retry 2 --retry-delay 2 "$latest_url" 2>/dev/null || true)
artifact=$(printf '%s\n' "$latest" | sed -n 's/^artifact=//p' | head -1)
upstream_sha=$(printf '%s\n' "$latest" | sed -n 's/^upstream_sha=//p' | head -1)
last_artifact=$(cat "$state_dir/latest.artifact" 2>/dev/null || true)
if [[ -n $artifact && $artifact != "$last_artifact" ]]; then
  dispatch "$rodriguez_repo" \
    "$(printf '{"event_type":"dsh-published","client_payload":{"artifact":"%s","upstream_sha":"%s"}}' "$artifact" "$upstream_sha")"
  printf '%s\n' "$artifact" > "$state_dir/latest.artifact"
  echo "dispatched mirror for $artifact"
fi
