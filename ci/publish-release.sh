#!/usr/bin/env bash
# Publish out/*.pkg.tar.zst + metadata to a GitHub Release.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PKGVER, PKGREL, SHA, REF,
#               ARCHIVE_SHA256, UPSTREAM_DATE, AHEAD, BASE_TAG.
set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
: "${PKGVER:?}"
: "${PKGREL:?}"
: "${SHA:?}"
: "${REF:?}"
: "${ARCHIVE_SHA256:?}"
: "${UPSTREAM_DATE:?}"
: "${AHEAD:?}"
: "${BASE_TAG:?}"

cd "$(dirname "$0")/.."
tag="v${PKGVER}-${PKGREL}"
pkg=$(find out -maxdepth 1 -type f -name '*.pkg.tar.zst' | head -1)
[[ -n $pkg ]] || { echo "找不到 out/*.pkg.tar.zst" >&2; exit 1; }
artifact=$(basename "$pkg")
artifact_sha256=$(sha256sum "$pkg" | awk '{print $1}')

# 补丁系列的内容指纹：补丁变了但上游 SHA 没变时，pkgrel 应加一。
patch_series_sha256=$(find patches -type f -name '*.patch' -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')

cat > out/metadata.env <<EOF
pkgname=deepseek-harness-desktop-wayland
pkgver=$PKGVER
pkgrel=$PKGREL
upstream_repo=https://github.com/deepseek-ai/deepseek-harness
upstream_ref=$REF
upstream_sha=$SHA
upstream_date=$UPSTREAM_DATE
upstream_base_tag=$BASE_TAG
upstream_ahead=$AHEAD
patch_series_sha256=$patch_series_sha256
artifact=$artifact
artifact_sha256=$artifact_sha256
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
builder=github-actions
EOF

(
  cd out
  sha256sum "$artifact" metadata.env > SHA256SUMS
)

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
{
  echo "Rolling build from upstream \`$REF\` at \`$SHA\`."
  echo
  echo "- upstream date: $UPSTREAM_DATE"
  echo "- commits ahead of \`$BASE_TAG\`: $AHEAD"
  echo "- package: \`$PKGVER-$PKGREL\`"
  echo "- patch series: \`$patch_series_sha256\`"
  echo
  echo "### Upstream commits"
  gh api "repos/deepseek-ai/deepseek-harness/compare/$BASE_TAG...$SHA" \
    --jq '.commits[-15:][] | "- `\(.sha[0:7])` \(.commit.message | split("\n")[0])"' 2>/dev/null \
    || echo "(compare unavailable)"
  echo
  echo "Install: \`sudo pacman -Syu deepseek-harness-desktop-wayland\`"
} > "$notes"

if gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "==> 更新已有 release $tag"
  gh release upload "$tag" "$pkg" out/metadata.env out/SHA256SUMS \
    -R "$GITHUB_REPOSITORY" --clobber
  gh release edit "$tag" -R "$GITHUB_REPOSITORY" --notes-file "$notes"
else
  echo "==> 创建 release $tag"
  gh release create "$tag" "$pkg" out/metadata.env out/SHA256SUMS \
    -R "$GITHUB_REPOSITORY" \
    --title "deepseek-harness-desktop-wayland $PKGVER-$PKGREL (rolling)" \
    --notes-file "$notes"
fi

echo "==> release: https://github.com/$GITHUB_REPOSITORY/releases/tag/$tag"
