#!/usr/bin/env bash
# Resolve one upstream ref into a reproducible package version.
#
# Reads INPUT_REF / INPUT_PKGREL / INPUT_FORCE from the workflow; writes
# build/sha/pkgver/pkgrel/archive_sha256/ref/base_tag/ahead/upstream_date
# to $GITHUB_OUTPUT.
set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_OUTPUT:?}"

upstream=deepseek-ai/deepseek-harness
ref=${INPUT_REF:-master}
pkgrel=${INPUT_PKGREL:-1}
force=${INPUT_FORCE:-false}

[[ $pkgrel =~ ^[0-9]+$ ]] || { echo "pkgrel 必须是整数：$pkgrel" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

build=true
rolling=rolling
last_sha=''
last_pkgver=''
if gh release view "$rolling" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  mkdir -p "$tmp/last"
  gh release download "$rolling" -R "$GITHUB_REPOSITORY" \
    -p metadata.env -p latest -D "$tmp/last" 2>/dev/null || true
  if [[ -f $tmp/last/metadata.env ]]; then
    last_sha=$(sed -n 's/^upstream_sha=//p' "$tmp/last/metadata.env" | head -1)
  fi
  if [[ -f $tmp/last/latest ]]; then
    last_pkgver=$(sed -n 's/^pkgver=//p' "$tmp/last/latest" | head -1)
    echo "    last_pkgver=$last_pkgver"
  fi
fi

if [[ $build == true && $last_sha == "$sha" && $force != true ]]; then
  echo "==> 上游 SHA 未变（$sha），跳过"
  build=false
fi

if [[ $build == true && -n $last_sha && $last_sha != "$sha" && $force != true ]]; then
  files=$(gh api "repos/$upstream/compare/$last_sha...$sha" --jq '.files[].filename' 2>/dev/null || true)
  count=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l)
  if [[ $count -gt 0 && $count -lt 300 ]] \
    && ! printf '%s\n' "$files" | grep -qE '^(apps/desktop|apps/desktop-host|apps/desktop-publisher|packages/|pnpm-lock\.yaml|package\.json|pnpm-workspace\.yaml|scripts/)'; then
    echo "==> 只有文档/测试变更，跳过构建"
    build=false
  fi
fi

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
} >> "$GITHUB_OUTPUT"
