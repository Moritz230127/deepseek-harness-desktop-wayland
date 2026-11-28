#!/usr/bin/env bash
# Publish the rolling package into ONE GitHub Release (tag: rolling).
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PKGVER, PKGREL, SHA, REF,
#               ARCHIVE_SHA256, UPSTREAM_DATE, AHEAD, BASE_TAG.
#
# Assets:
#   <pkgver>-<pkgrel>-x86_64.pkg.tar.zst  versioned package (rollback by URL)
#   dsh.db                                pacman repo database (current package)
#   latest                                tiny state file for local sync
#   metadata.env                          build provenance
#   SHA256SUMS                            checksums for the above
#
# One stable release avoids creating a git tag/release per commit.
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
tag=rolling
pkg=$(find out -maxdepth 1 -type f -name '*.pkg.tar.zst' | head -1)
[[ -n $pkg ]] || { echo "找不到 out/*.pkg.tar.zst" >&2; exit 1; }
[[ -f out/dsh.db ]] || { echo "找不到 out/dsh.db（ci-build.sh 的 repo-add 阶段失败？）" >&2; exit 1; }

artifact=$(basename "$pkg")
artifact_sha256=$(sha256sum "$pkg" | awk '{print $1}')

# 补丁系列的内容指纹：补丁变了但上游 SHA 没变时，pkgrel 应加一。
patch_series_sha256=$(find patches -type f -name '*.patch' -print0 \
  | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')

cat > out/latest <<EOF
pkgver=$PKGVER
pkgrel=$PKGREL
artifact=$artifact
upstream_sha=$SHA
EOF

cat > out/metadata.env <<EOF
pkgname=deepseek-harness-desktop-wayland
pkgver=$PKGVER
pkgrel=$PKGREL
release_tag=$tag
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
  sha256sum "$artifact" dsh.db metadata.env latest > SHA256SUMS
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
  echo "### Pacman repository (public repo only)"
  echo
  echo '```ini'
  echo '[dsh]'
  echo 'SigLevel = Optional TrustAll'
  echo "Server = https://github.com/$GITHUB_REPOSITORY/releases/download/$tag"
  echo '```'
  echo
  echo "Or install the local copy: \`sudo pacman -Syu deepseek-harness-desktop-wayland\`"
  echo
  echo "### Upstream commits"
  gh api "repos/deepseek-ai/deepseek-harness/compare/$BASE_TAG...$SHA" \
    --jq '.commits[-15:][] | "- `\(.sha[0:7])` \(.commit.message | split("\n")[0])"' 2>/dev/null \
    || echo "(compare unavailable)"
} > "$notes"

# 发布顺序：先传 359 MB 包，再传 db/metadata/SHA256SUMS，最后单独更新 latest。
# latest 是给镜像端读的“指针”，它出现时被引用的包与校验和必须已经存在；
# 旧的写法把所有资产塞进一次 gh release upload，latest 会比包早 10 秒左右可见。
package_assets=("$pkg")
meta_assets=(out/dsh.db out/metadata.env out/SHA256SUMS)

if gh release view "$tag" -R "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "==> 更新 rolling release：先传包"
  gh release upload "$tag" "${package_assets[@]}" -R "$GITHUB_REPOSITORY" --clobber
  echo "==> 更新 rolling release：再传数据库与校验和"
  gh release upload "$tag" "${meta_assets[@]}" -R "$GITHUB_REPOSITORY" --clobber
  echo "==> 更新 rolling release：最后更新 latest 指针"
  gh release upload "$tag" out/latest -R "$GITHUB_REPOSITORY" --clobber
  gh release edit "$tag" -R "$GITHUB_REPOSITORY" \
    --latest \
    --title "rolling: deepseek-harness-desktop-wayland $PKGVER-$PKGREL" \
    --notes-file "$notes"
else
  echo "==> 创建 rolling release（先 draft，传完再公开）"
  extra=()
  if gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" >/dev/null 2>&1; then
    extra+=(--verify-tag)
  fi
  gh release create "$tag" -R "$GITHUB_REPOSITORY" \
    --draft \
    --title "rolling: deepseek-harness-desktop-wayland $PKGVER-$PKGREL" \
    --notes-file "$notes" "${extra[@]}"
  gh release upload "$tag" "${package_assets[@]}" -R "$GITHUB_REPOSITORY"
  gh release upload "$tag" "${meta_assets[@]}" -R "$GITHUB_REPOSITORY"
  gh release upload "$tag" out/latest -R "$GITHUB_REPOSITORY"
  gh release edit "$tag" -R "$GITHUB_REPOSITORY" --draft=false --latest \
    --title "rolling: deepseek-harness-desktop-wayland $PKGVER-$PKGREL" \
    --notes-file "$notes"
fi

# 只保留当前包 + 最近 2 个旧包，避免单个 release 无限膨胀。
mapfile -t stale < <(
  gh release view "$tag" -R "$GITHUB_REPOSITORY" --json assets \
    --jq '.assets[] | select(.name | endswith(".pkg.tar.zst")) | [.createdAt, .name] | @tsv' \
    | sort -r | awk -v current="$artifact" '$2 != current { print $2 }' | tail -n +3
)
for name in "${stale[@]:-}"; do
  [[ -n $name ]] || continue
  echo "==> 删除旧包资产 $name"
  gh release delete-asset "$tag" "$name" -R "$GITHUB_REPOSITORY" --yes
done

echo "==> release: https://github.com/$GITHUB_REPOSITORY/releases/tag/$tag"
