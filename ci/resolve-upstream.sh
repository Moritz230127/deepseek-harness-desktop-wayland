#!/usr/bin/env bash
# Resolve one upstream ref into a reproducible package version.
#
# Reads INPUT_REF / INPUT_PKGREL / INPUT_FORCE from the workflow; writes
# build/sha/pkgver/pkgrel/archive_sha256/ref/base_tag/ahead/upstream_date/
# patch_series_sha256/last_version to $GITHUB_OUTPUT.
#
# Tracking model (AUR `-git` semantics):
#   * 永远构建 master 的当前 head，pkgver = <上游版本>.r<相对最近 tag 的提交数>.g<短 SHA>；
#   * 上游 SHA 变化且改到代码路径 → 构建，pkgrel 从 1 开始；
#   * 上游 SHA 不变、只有 patches/ 变化 → 自动 pkgrel+1 重建（不再需要手动 force）；
#   * 上游 SHA 与补丁都没变 → 跳过，不制造空跑。
set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_OUTPUT:?}"

upstream=deepseek-ai/deepseek-harness
ref=${INPUT_REF:-master}
force=${INPUT_FORCE:-false}
pkgrel_input=${INPUT_PKGREL:-}
min_interval=${INPUT_MIN_INTERVAL:-3600}

if [[ -n $pkgrel_input && ! $pkgrel_input =~ ^[0-9]+$ ]]; then
  echo "pkgrel 必须是整数：$pkgrel_input" >&2
  exit 2
fi
if [[ ! $min_interval =~ ^[0-9]+$ ]]; then
  echo "min_interval 必须是整数秒：$min_interval" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 补丁系列指纹，必须与 ci/publish-release.sh 的算法保持一致。
patch_sha=$(find patches -type f -name '*.patch' -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
echo "==> patch series: $patch_sha"

echo "==> upstream ref: $ref"
sha=$(gh api "repos/$upstream/commits/$ref" --jq .sha)
upstream_date=$(gh api "repos/$upstream/commits/$ref" --jq .commit.committer.date)
echo "    sha=$sha date=$upstream_date"

# 以最近一次上游 release tag 作为版本基线（master 可能领先 tag 数百个提交）。
base_tag=$(gh api "repos/$upstream/releases" \
  --jq '[.[] | select(.draft == false)][0].tag_name // empty')
if [[ -z $base_tag ]]; then
  base_tag=$(gh api "repos/$upstream/tags" --jq '.[0].name')
fi
echo "    base_tag=$base_tag"

ahead=0
if [[ -n $base_tag ]]; then
  ahead=$(gh api "repos/$upstream/compare/$base_tag...$sha" --jq .ahead_by 2>/dev/null || echo 0)
fi
[[ $ahead =~ ^[0-9]+$ ]] || ahead=0

base_version=$(gh api "repos/$upstream/contents/apps/desktop/package.json?ref=$sha" \
  --jq .content 2>/dev/null | base64 -d 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).version??"")}catch{console.log("")}})' \
  || true)

# 0.2.2-rc.3 -> 0.2.2rc3（pacman 不允许 '-'）；0.0.0/dev 版本回退到 tag。
base=$(printf '%s' "$base_version" | sed -E 's/-rc\./rc/; s/-/./g; s/[^0-9A-Za-z._+]/./g')
if [[ -z $base || $base == 0.0.0* ]]; then
  base=$(printf '%s' "$base_tag" | sed -E 's/^dsh-v//; s/-rc\./rc/; s/-/./g')
fi
base=${base%.}
[[ -n $base ]] || { echo "无法解析上游版本（package.json=$base_version tag=$base_tag）" >&2; exit 3; }

short=${sha:0:7}
pkgver="${base}.r${ahead}.g${short}"
echo "    base=$base ahead=$ahead pkgver=$pkgver"

rolling=rolling
last_sha=''
last_pkgver=''
last_pkgrel=''
last_patch_sha=''
last_base_tag=''
last_build_date=''
if gh release view "$rolling" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  mkdir -p "$tmp/last"
  gh release download "$rolling" -R "$GITHUB_REPOSITORY" \
    -p metadata.env -p latest -D "$tmp/last" 2>/dev/null || true
  if [[ -f $tmp/last/metadata.env ]]; then
    last_sha=$(sed -n 's/^upstream_sha=//p' "$tmp/last/metadata.env" | head -1)
    last_pkgrel=$(sed -n 's/^pkgrel=//p' "$tmp/last/metadata.env" | head -1)
    last_patch_sha=$(sed -n 's/^patch_series_sha256=//p' "$tmp/last/metadata.env" | head -1)
    last_base_tag=$(sed -n 's/^upstream_base_tag=//p' "$tmp/last/metadata.env" | head -1)
    last_build_date=$(sed -n 's/^build_date=//p' "$tmp/last/metadata.env" | head -1)
  fi
  if [[ -f $tmp/last/latest ]]; then
    last_pkgver=$(sed -n 's/^pkgver=//p' "$tmp/last/latest" | head -1)
    echo "    last_pkgver=$last_pkgver"
  fi
fi

same_sha=false
if [[ -n $last_sha && $last_sha == "$sha" ]]; then
  same_sha=true
fi

build=true
if $same_sha && [[ $force != true && -z $pkgrel_input ]]; then
  if [[ -n $last_patch_sha && $patch_sha != "$last_patch_sha" ]]; then
    echo "==> 上游 SHA 未变，但补丁系列变化，自动重建"
  else
    echo "==> 上游 SHA 与补丁系列均未变（$sha），跳过"
    build=false
  fi
fi

# 上游 SHA 变化时，只有文档/测试变更才跳过（AUR -git 的“跟踪最新提交”仍以最新 head 为准）。
if $build && ! $same_sha && [[ -n $last_sha && $force != true ]]; then
  files=$(gh api "repos/$upstream/compare/$last_sha...$sha" --jq '.files[].filename' 2>/dev/null || true)
  count=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l)
  if [[ $count -gt 0 && $count -lt 300 ]] \
    && ! printf '%s\n' "$files" | grep -qE '^(apps/desktop|apps/desktop-host|apps/desktop-publisher|packages/|pnpm-lock\.yaml|package\.json|pnpm-workspace\.yaml|scripts/)'; then
    echo "==> 只有文档/测试变更，跳过构建"
    build=false
  fi
fi

# 构建节流：master 最多每 min_interval 秒构建一次，避免 359MB 包连续刷屏；
# 上游新 tag（base_tag 变化）或补丁变化时绕过节流，优先保证发版/修复及时。
patch_changed=false
if [[ -n $last_patch_sha && $patch_sha != "$last_patch_sha" ]]; then
  patch_changed=true
fi
release_bypass=false
if [[ -n $last_base_tag && $base_tag != "$last_base_tag" ]]; then
  release_bypass=true
fi

if $build && [[ $force != true && $patch_changed != true && $release_bypass != true && -z $pkgrel_input ]]; then
  now_epoch=$(date -u +%s)
  last_build_epoch=0
  if [[ -n $last_build_date ]]; then
    last_build_epoch=$(date -u -d "$last_build_date" +%s 2>/dev/null || echo 0)
  fi
  if (( last_build_epoch > 0 )); then
    elapsed=$(( now_epoch - last_build_epoch ))
    if (( elapsed < min_interval )); then
      echo "==> 距上次构建 ${elapsed}s < ${min_interval}s，本轮只检查不构建（新 tag / 补丁变化会绕过）"
      build=false
    fi
  fi
fi

# pkgrel：手动输入优先；同一上游 SHA 重建必须递增；新 SHA 从 1 开始。
if [[ -n $pkgrel_input ]]; then
  pkgrel=$pkgrel_input
elif $same_sha; then
  pkgrel=$(( ${last_pkgrel:-1} + 1 ))
else
  pkgrel=1
fi

last_version=''
if [[ -n $last_pkgver ]]; then
  last_version="$last_pkgver-${last_pkgrel:-1}"
fi
echo "    pkgrel=$pkgrel last_version=${last_version:-<none>}"

# 上游 archive 的 sha256 在这里算一次，构建与发布共用。
archive_sha256=''
if [[ $build == true ]]; then
  archive="$tmp/upstream.tar.gz"
  echo "==> 下载上游 archive ..."
  curl -fL --retry 3 --retry-delay 2 -o "$archive" \
    "https://github.com/$upstream/archive/$sha.tar.gz"
  archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
  echo "    archive_sha256=$archive_sha256"
fi

{
  echo "build=$build"
  echo "sha=$sha"
  echo "ref=$ref"
  echo "pkgver=$pkgver"
  echo "pkgrel=$pkgrel"
  echo "archive_sha256=$archive_sha256"
  echo "base_tag=$base_tag"
  echo "ahead=$ahead"
  echo "upstream_date=$upstream_date"
  echo "patch_series_sha256=$patch_sha"
  echo "last_version=$last_version"
} >> "$GITHUB_OUTPUT"
