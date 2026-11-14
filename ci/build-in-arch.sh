#!/usr/bin/env bash
# Build the Linux x86_64 desktop from the official upstream tag + this repo's
# patch series and turn the result into an AUR source package and a -bin package.
#
# Designed to run as an unprivileged user, either directly on an Arch host or
# inside `archlinux:base-devel` (the GitHub workflow creates a `builder` user).
# Work directories and logs are kept on failure for debugging.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/common.sh
source "$SCRIPT_DIR/common.sh"

ROOT=${ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}
UPSTREAM_REPOSITORY=${UPSTREAM_REPOSITORY:-deepseek-ai/deepseek-harness}
TAG=${TAG:-}
COMMIT=${COMMIT:-}
PKGVER=${PKGVER:-}
PKGREL=${PKGREL:-1}
PACKAGING_DIR=${PACKAGING_DIR:-$ROOT/packaging/aur}
PATCHES_DIR=${PATCHES_DIR:-$ROOT/patches}
WORK_DIR=${WORK_DIR:-}
OUT_DIR=${OUT_DIR:-}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-}
PNPM_STORE_DIR=${PNPM_STORE_DIR:-}
SKIP_DESKTOP_BUILD=${SKIP_DESKTOP_BUILD:-0}
SKIP_ARCH_PACKAGES=${SKIP_ARCH_PACKAGES:-0}
SKIP_SMOKE=${SKIP_SMOKE:-0}
ALLOW_MISSING_PACKAGING=${ALLOW_MISSING_PACKAGING:-0}
EXPECTED_VERSION=${EXPECTED_VERSION:-}
UPSTREAM_ARCHIVE_URL=${UPSTREAM_ARCHIVE_URL:-}

usage() {
  cat <<'USAGE'
Usage: ci/build-in-arch.sh [--tag TAG] [--commit SHA] [--root DIR]
                           [--work-dir DIR] [--out-dir DIR]
                           [--skip-desktop-build] [--skip-arch-packages]
                           [--skip-smoke] [--allow-missing-packaging]

Environment mirrors the options (TAG, COMMIT, ROOT, WORK_DIR, OUT_DIR,
PACKAGING_DIR, PATCHES_DIR, DOWNLOAD_DIR, UPSTREAM_ARCHIVE_URL).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a value}; shift 2 ;;
    --commit) COMMIT=${2:?--commit needs a value}; shift 2 ;;
    --root) ROOT=${2:?--root needs a value}; shift 2 ;;
    --work-dir) WORK_DIR=${2:?--work-dir needs a value}; shift 2 ;;
    --out-dir) OUT_DIR=${2:?--out-dir needs a value}; shift 2 ;;
    --packaging-dir) PACKAGING_DIR=${2:?--packaging-dir needs a value}; shift 2 ;;
    --patches-dir) PATCHES_DIR=${2:?--patches-dir needs a value}; shift 2 ;;
    --skip-desktop-build) SKIP_DESKTOP_BUILD=1; shift ;;
    --skip-arch-packages) SKIP_ARCH_PACKAGES=1; shift ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    --allow-missing-packaging) ALLOW_MISSING_PACKAGING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

export LC_ALL=C
[[ -n $TAG ]] || die "TAG is required (e.g. dsh-v0.2.0-rc.2)"
TAG=$(normalize_tag "$TAG")
[[ -n $PKGVER ]] || PKGVER=$(aur_pkgver "$TAG")
[[ -n $EXPECTED_VERSION ]] || EXPECTED_VERSION=$(tag_version "$TAG")
[[ -n $WORK_DIR ]] || WORK_DIR="$ROOT/work/ci/$TAG"
[[ -n $OUT_DIR ]] || OUT_DIR="$WORK_DIR/artifacts"
[[ -n $DOWNLOAD_DIR ]] || DOWNLOAD_DIR="$WORK_DIR/downloads"
[[ -n $PNPM_STORE_DIR ]] || PNPM_STORE_DIR="$WORK_DIR/pnpm-store"

# Normalize every path up front. `run_logged` is invoked from inside the
# unpacked upstream tree, so a relative WORK_DIR/LOG_DIR would make `tee` fail
# there; absolute paths also make the retained-failure logs predictable.
require_cmd realpath
ROOT=$(realpath -m -- "$ROOT")
PACKAGING_DIR=$(realpath -m -- "$PACKAGING_DIR")
PATCHES_DIR=$(realpath -m -- "$PATCHES_DIR")
WORK_DIR=$(realpath -m -- "$WORK_DIR")
OUT_DIR=$(realpath -m -- "$OUT_DIR")
DOWNLOAD_DIR=$(realpath -m -- "$DOWNLOAD_DIR")
PNPM_STORE_DIR=$(realpath -m -- "$PNPM_STORE_DIR")
LOG_DIR="$WORK_DIR/logs"
UPSTREAM_DIR="$WORK_DIR/upstream"

if (( EUID == 0 )); then
  die "refusing to run as root: makepkg requires an unprivileged user (use sudo -u builder)"
fi

require_cmd curl
require_cmd git
require_cmd node
require_cmd pnpm
require_cmd tar
require_cmd sha256sum
if (( SKIP_ARCH_PACKAGES == 0 )); then
  require_cmd makepkg
fi

if [[ -z $COMMIT ]]; then
  if [[ -d $ROOT/work/official/.git ]] &&
    git -C "$ROOT/work/official" rev-parse --verify --quiet "${TAG}^{commit}" >/dev/null; then
    COMMIT=$(git -C "$ROOT/work/official" rev-parse "${TAG}^{commit}")
  else
    die "COMMIT is required (detect job supplies it)"
  fi
fi
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be a 40-char lowercase SHA (got '$COMMIT')"
if [[ -z $UPSTREAM_ARCHIVE_URL ]]; then
  # Must match the AUR source PKGBUILD convention and its $_upstream_dir:
  # https://github.com/<repo>/archive/<tag>.tar.gz extracts to
  # deepseek-harness-<tag>/.
  UPSTREAM_ARCHIVE_URL="https://github.com/$UPSTREAM_REPOSITORY/archive/$TAG.tar.gz"
fi

PRERELEASE=false
if [[ $EXPECTED_VERSION == *-* ]]; then
  PRERELEASE=true
fi

mkdir -p "$WORK_DIR" "$OUT_DIR" "$LOG_DIR" "$DOWNLOAD_DIR" "$PNPM_STORE_DIR"

# Keep the pnpm store inside the workspace so actions/cache only has to handle
# paths under $GITHUB_WORKSPACE (container job caches).
export npm_config_store_dir="$PNPM_STORE_DIR"

run_logged() {
  local name=$1
  shift
  local log_file="$LOG_DIR/$name.log"
  log "== $name: $*"
  {
    printf '$ %s\n' "$*"
    "$@"
  } 2>&1 | tee -a "$log_file"
}

on_exit() {
  local status=$?
  # Always make the logs part of the uploaded artifact, including on failure.
  if [[ -d $LOG_DIR ]]; then
    mkdir -p "$OUT_DIR/logs" 2>/dev/null || true
    cp -a "$LOG_DIR"/*.log "$OUT_DIR/logs/" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    log "build FAILED (exit $status); work directory kept for debugging: $WORK_DIR"
  fi
}
trap on_exit EXIT

log "tag=$TAG commit=$COMMIT pkgver=$PKGVER work_dir=$WORK_DIR"

# Fail fast on an empty/broken patch directory before downloading hundreds of MB.
# The patch series is required for both the desktop build and the AUR source build.
mapfile -t PATCH_FILES < <(find "$PATCHES_DIR" -maxdepth 1 -type f -name '*.patch' -print | sort)
(( ${#PATCH_FILES[@]} > 0 )) || die "no patch files found under $PATCHES_DIR"

# ---------------------------------------------------------------------------
# 1. Fetch and unpack the official source archive at the exact commit.
# ---------------------------------------------------------------------------
ARCHIVE_FILE="$WORK_DIR/upstream-$COMMIT.tar.gz"
if [[ ! -s $ARCHIVE_FILE ]]; then
  run_logged fetch-upstream curl -fL --retry 3 --retry-delay 3 --connect-timeout 30 \
    -o "$ARCHIVE_FILE.part" "$UPSTREAM_ARCHIVE_URL"
  mv "$ARCHIVE_FILE.part" "$ARCHIVE_FILE"
else
  log "using cached upstream archive $ARCHIVE_FILE"
fi
SOURCE_ARCHIVE_SHA256=$(sha256sum "$ARCHIVE_FILE" | awk '{print $1}')

# Always extract a pristine tree: a previous failed attempt may have already
# applied the patch series, and reusing it makes `git apply` fail on retry.
if [[ -f $UPSTREAM_DIR/package.json ]]; then
  log "resetting upstream tree from a previous attempt for a clean rebuild"
  rm -rf "$UPSTREAM_DIR"
fi
mkdir -p "$UPSTREAM_DIR"
run_logged extract-upstream tar -xzf "$ARCHIVE_FILE" --strip-components=1 -C "$UPSTREAM_DIR"

DETECTED_VERSION=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' \
  "$UPSTREAM_DIR/package.json")
if [[ $DETECTED_VERSION != "$EXPECTED_VERSION" ]]; then
  die "upstream package.json version '$DETECTED_VERSION' does not match tag version '$EXPECTED_VERSION'"
fi
log "verified upstream version $DETECTED_VERSION"

has_desktop_script() {
  node -e '
    const fs = require("fs");
    const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.exit(manifest.scripts && manifest.scripts[process.argv[2]] ? 0 : 1);
  ' "$UPSTREAM_DIR/apps/desktop/package.json" "$1"
}

# ---------------------------------------------------------------------------
# 2. Apply the self-authored patch series in filename order.
# ---------------------------------------------------------------------------
# `$UPSTREAM_DIR` lives below this repository inside the .gitignore'd work/
# tree. Without a ceiling, git discovers the monorepo .git and `git apply`
# silently "skips" the patch with exit 0; setting the ceiling one level above
# the unpacked tree makes git apply run outside any repository and write files.
export GIT_CEILING_DIRECTORIES="$ROOT"

apply_one_patch() {
  local patch=$1
  (
    cd "$UPSTREAM_DIR"
    git apply --check "$patch"
    git apply --verbose "$patch"
    printf 'applied %s\n' "$(basename -- "$patch")"
  )
}
for patch in "${PATCH_FILES[@]}"; do
  run_logged "patch-$(basename -- "$patch")" apply_one_patch "$patch"
done

# Assert the patches actually landed. A silent skip leaves every marker absent.
missing_markers=()
[[ -f "$UPSTREAM_DIR/apps/desktop/.env.linux" ]] || missing_markers+=("apps/desktop/.env.linux")
[[ -f "$UPSTREAM_DIR/apps/desktop/scripts/linux-runtime-adjustments.ts" ]] || missing_markers+=("apps/desktop/scripts/linux-runtime-adjustments.ts")
[[ -f "$UPSTREAM_DIR/apps/desktop/src/gpu-fallback.ts" ]] || missing_markers+=("apps/desktop/src/gpu-fallback.ts (0003)")
if ! has_desktop_script package:linux:x64:dir; then
  missing_markers+=("package.json script package:linux:x64:dir (0001)")
fi
if ! grep -qs 'ozone-platform-hint' "$UPSTREAM_DIR/apps/desktop/src/linux-shell.ts"; then
  missing_markers+=("linux-shell.ts Ozone/HiDPI marker (0003)")
fi
if (( ${#missing_markers[@]} > 0 )); then
  die "patch series did not materialize expected files (silent git apply skip?): ${missing_markers[*]}"
fi
log "patch markers verified after ${#PATCH_FILES[@]} patch(es)"

# ---------------------------------------------------------------------------
# 3. Install dependencies and build linux-unpacked.
# ---------------------------------------------------------------------------
mkdir -p "$UPSTREAM_DIR/apps/desktop/.desktop-build"
ln -sfn "$DOWNLOAD_DIR" "$UPSTREAM_DIR/apps/desktop/.desktop-build/downloads"

export CI=1
export COREPACK_ENABLE_STRICT=0
# The tag tarball has no .git. patch 0001 makes package-target prefer
# DSH_DESKTOP_BUILD_COMMIT over `git rev-parse HEAD`, and the official client
# build already accepts DSH_CLIENT_COMMIT_HASH for metadata without repository
# git. Export both globally so the manual directory build and the later makepkg
# source build both succeed on the clean tarball.
export DSH_DESKTOP_BUILD_COMMIT="$COMMIT"
export DSH_DESKTOP_BUILD_DIRTY=0
export DSH_CLIENT_COMMIT_HASH="$COMMIT"

(
  cd "$UPSTREAM_DIR"
  run_logged pnpm-install pnpm install --frozen-lockfile --prefer-offline \
    --store-dir "$PNPM_STORE_DIR"
)

build_desktop() {
  if has_desktop_script package:linux:x64:dir; then
    run_logged desktop-package env DSH_DESKTOP_TARGET_PLATFORM=linux DSH_DESKTOP_TARGET_ARCH=x64 \
      pnpm --filter @deepseek-ai/dsh-desktop run package:linux:x64:dir
  elif has_desktop_script package:dir; then
    warn "package:linux:x64:dir script not found; falling back to package:dir with Linux target env"
    run_logged desktop-package env DSH_DESKTOP_TARGET_PLATFORM=linux DSH_DESKTOP_TARGET_ARCH=x64 \
      pnpm --filter @deepseek-ai/dsh-desktop run package:dir
  else
    die "apps/desktop/package.json has neither package:linux:x64:dir nor package:dir"
  fi
}

LINUX_UNPACKED=''
find_linux_unpacked() {
  local candidate
  candidate=$(find "$UPSTREAM_DIR/apps/desktop/.desktop-build" -type d -name 'linux-unpacked' -print -quit 2>/dev/null || true)
  if [[ -z $candidate ]]; then
    candidate=$(find "$UPSTREAM_DIR/apps/desktop/.desktop-build" -type d -name 'linux*-unpacked' -print -quit 2>/dev/null || true)
  fi
  printf '%s' "$candidate"
}

if (( SKIP_DESKTOP_BUILD == 0 )); then
  ( cd "$UPSTREAM_DIR" && build_desktop )
  LINUX_UNPACKED=$(find_linux_unpacked)
  [[ -n $LINUX_UNPACKED && -d $LINUX_UNPACKED ]] || die "linux-unpacked directory not found under .desktop-build"
  log "linux-unpacked: $LINUX_UNPACKED"
else
  warn "SKIP_DESKTOP_BUILD=1: desktop package build skipped"
fi

MAIN_EXECUTABLE=''
MAIN_EXECUTABLE_PATH=''
select_main_executable() {
  local directory=$1 candidate base fallback=''
  # Prefer the product executable by name; never mistake Electron's setuid
  # helper or crashpad handler for the application.
  for candidate in "$directory/deepseek-harness" "$directory/deepseek-harness-desktop"; do
    if [[ -f $candidate && -x $candidate ]] && file "$candidate" | grep -q 'ELF'; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  for candidate in "$directory"/*; do
    [[ -f $candidate && -x $candidate ]] || continue
    base=$(basename -- "$candidate")
    case "$base" in
      chrome-sandbox|chrome_crashpad_handler|*.so|*.so.*) continue ;;
    esac
    if file "$candidate" | grep -q 'ELF'; then
      fallback=$candidate
      break
    fi
  done
  if [[ -n $fallback ]]; then
    warn "product-named ELF not found; using first eligible ELF: $fallback"
    printf '%s' "$fallback"
    return 0
  fi
  return 1
}

if [[ -n $LINUX_UNPACKED ]]; then
  MAIN_EXECUTABLE_PATH=$(select_main_executable "$LINUX_UNPACKED") ||
    die "no eligible top-level ELF executable found in $LINUX_UNPACKED"
  MAIN_EXECUTABLE=$(basename -- "$MAIN_EXECUTABLE_PATH")
  [[ $MAIN_EXECUTABLE == deepseek-harness ]] ||
    warn "expected main executable 'deepseek-harness', selected '$MAIN_EXECUTABLE'"
  log "main executable: $MAIN_EXECUTABLE ($MAIN_EXECUTABLE_PATH)"
fi

# ---------------------------------------------------------------------------
# 4. Minimum smoke gate (task-6 script preferred, official smoke fallback).
# ---------------------------------------------------------------------------
if (( SKIP_SMOKE == 0 )) && [[ -f $ROOT/ci/verify-min-smoke.sh ]]; then
  run_logged smoke env \
    LINUX_UNPACKED="$LINUX_UNPACKED" \
    UPSTREAM_DIR="$UPSTREAM_DIR" \
    SMOKE_LOG="$LOG_DIR/verify-smoke.log" \
    SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-2700}" \
    bash "$ROOT/ci/verify-min-smoke.sh"
elif (( SKIP_SMOKE == 0 )); then
  warn "ci/verify-min-smoke.sh missing; smoke gate recorded as skipped"
else
  warn "SKIP_SMOKE=1: smoke gate skipped"
fi

# ---------------------------------------------------------------------------
# 5. Build the AUR source package and repack the -bin package.
# ---------------------------------------------------------------------------
SOURCE_PKG_DIR="$PACKAGING_DIR/deepseek-harness-desktop-linux"
BIN_PKG_DIR="$PACKAGING_DIR/deepseek-harness-desktop-linux-bin"
SOURCE_BUILT_PKG=''
BIN_BUILT_PKG=''

create_source_bundle() {
  local bundle="$OUT_DIR/deepseek-harness-desktop-linux-$PKGVER-source-bundle.tar.gz"
  local staging="$WORK_DIR/source-bundle"
  rm -rf "$staging"
  mkdir -p "$staging"
  if [[ -d $PACKAGING_DIR ]]; then
    cp -a "$PACKAGING_DIR" "$staging/packaging"
  fi
  if [[ -d $PATCHES_DIR ]]; then
    cp -a "$PATCHES_DIR" "$staging/patches"
  fi
  run_logged source-bundle tar -czf "$bundle" -C "$staging" .
  SOURCE_BUILT_PKG=$bundle
}

build_source_package() {
  local build_dir="$WORK_DIR/arch/source"
  local srcdest="$WORK_DIR/arch/srcdest"
  local source_asset_name
  source_asset_name="deepseek-harness-desktop-linux-${PKGVER}-x86_64.pkg.tar.zst"
  rm -rf "$build_dir"
  mkdir -p "$build_dir/pkgdest" "$srcdest"
  # The AUR package keeps local sources as symlinks next to the PKGBUILD (the
  # launcher, desktop file, icons, LICENSE and patch series); dereference them
  # into the throw-away build directory so makepkg can consume plain files.
  cp -aL "$SOURCE_PKG_DIR/." "$build_dir/"

  bash "$ROOT/ci/update-aur.sh" --pkgbuild "$build_dir/PKGBUILD" --kind source \
    --tag "$TAG" --commit "$COMMIT" --pkgver "$PKGVER" --pkgrel "$PKGREL" \
    --source-url "$UPSTREAM_ARCHIVE_URL" --source-sha256 "$SOURCE_ARCHIVE_SHA256" \
    --patch-dir "$PATCHES_DIR"

  # Seed makepkg's SRCDEST with the archive we already checksummed, so the
  # pinned sha256 is guaranteed to match instead of re-downloading the tarball.
  install -m 0644 "$ARCHIVE_FILE" "$srcdest/deepseek-harness-$TAG.tar.gz"

  (
    cd "$build_dir"
    makepkg --printsrcinfo >.SRCINFO
  )
  install -m 0644 "$build_dir/.SRCINFO" "$OUT_DIR/deepseek-harness-desktop-linux.SRCINFO"

  # Phase 1: extract the seeded official archive and apply the patch series
  # exactly as an AUR user's build() would. `--nobuild` stops after prepare().
  (
    cd "$build_dir"
    run_logged makepkg-source-prepare env SRCDEST="$srcdest" \
      makepkg --nodeps --noconfirm --force --cleanbuild --nobuild
  )
  local source_tree="$build_dir/src/deepseek-harness-$TAG"
  [[ -f "$source_tree/apps/desktop/.env.linux" ]] ||
    die "source prepare() did not materialize apps/desktop/.env.linux"
  [[ -f "$source_tree/apps/desktop/scripts/linux-runtime-adjustments.ts" ]] ||
    die "source prepare() did not materialize linux-runtime-adjustments.ts"
  [[ -f "$source_tree/apps/desktop/src/gpu-fallback.ts" ]] ||
    die "source prepare() did not materialize gpu-fallback.ts"

  # Reuse the first desktop build's download cache for the makepkg tree too.
  # Phase 2 then stops before extraction/prepare (patches are already applied),
  # so makepkg never re-fetches Electron/runtime unless a cache entry is missing.
  mkdir -p "$source_tree/apps/desktop/.desktop-build"
  ln -sfn "$DOWNLOAD_DIR" "$source_tree/apps/desktop/.desktop-build/downloads"
  (
    cd "$build_dir"
    run_logged makepkg-source env SRCDEST="$srcdest" PKGDEST="$build_dir/pkgdest" \
      makepkg --nodeps --noconfirm --force --noextract --noprepare --nocheck
  )
  local built
  built=$(find "$build_dir/pkgdest" -maxdepth 1 -type f -name '*.pkg.tar.*' -print -quit)
  [[ -n $built ]] || die "makepkg produced no source package"
  # GitHub release asset name expected by the -bin PKGBUILD ($_asset_name).
  install -m 0644 "$built" "$OUT_DIR/$source_asset_name"
  SOURCE_BUILT_PKG="$OUT_DIR/$source_asset_name"
  log "source package artifact: $source_asset_name (makepkg built $(basename -- "$built"))"
}

build_bin_package() {
  [[ -n $SOURCE_BUILT_PKG ]] || die "source package is required before the -bin package"
  [[ -f $BIN_PKG_DIR/PKGBUILD ]] || die "missing $BIN_PKG_DIR/PKGBUILD"
  local build_dir="$WORK_DIR/arch/bin"
  local asset_name source_sha
  asset_name=$(basename -- "$SOURCE_BUILT_PKG")
  source_sha=$(sha256sum "$SOURCE_BUILT_PKG" | awk '{print $1}')
  rm -rf "$build_dir"
  mkdir -p "$build_dir/pkgdest"
  cp -aL "$BIN_PKG_DIR/." "$build_dir/"
  install -m 0644 "$SOURCE_BUILT_PKG" "$build_dir/$asset_name"

  bash "$ROOT/ci/update-aur.sh" --pkgbuild "$build_dir/PKGBUILD" --kind bin \
    --tag "$TAG" --commit "$COMMIT" --pkgver "$PKGVER" --pkgrel "$PKGREL" \
    --bin-url "$asset_name" --bin-sha256 "$source_sha" \
    --patch-dir "$PATCHES_DIR"

  (
    cd "$build_dir"
    run_logged makepkg-bin env PKGDEST="$build_dir/pkgdest" \
      makepkg --nodeps --noconfirm --force --cleanbuild --nocheck
  )
  local built
  built=$(find "$build_dir/pkgdest" -maxdepth 1 -type f -name '*.pkg.tar.*' -print -quit)
  [[ -n $built ]] || die "makepkg produced no -bin package"
  BIN_BUILT_PKG="$OUT_DIR/$(basename -- "$built")"
  install -m 0644 "$built" "$BIN_BUILT_PKG"

  # The AUR -bin base needs its own .SRCINFO alongside the release metadata.
  (
    cd "$build_dir"
    makepkg --printsrcinfo >.SRCINFO
  )
  install -m 0644 "$build_dir/.SRCINFO" "$OUT_DIR/deepseek-harness-desktop-linux-bin.SRCINFO"
  log "bin package: $(basename -- "$BIN_BUILT_PKG")"
  log "bin .SRCINFO: deepseek-harness-desktop-linux-bin.SRCINFO"
}

if (( SKIP_ARCH_PACKAGES == 1 )); then
  warn "SKIP_ARCH_PACKAGES=1: Arch package generation skipped"
elif [[ ! -f $SOURCE_PKG_DIR/PKGBUILD ]]; then
  if (( ALLOW_MISSING_PACKAGING == 1 )); then
    warn "packaging source PKGBUILD missing; producing a patch/source bundle only"
    create_source_bundle
  else
    die "missing $SOURCE_PKG_DIR/PKGBUILD (packaging deliverable not ready?)"
  fi
else
  build_source_package
  build_bin_package
fi

# ---------------------------------------------------------------------------
# 6. Checksums, metadata and logs for upload/publish.
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR/logs"
if compgen -G "$LOG_DIR/*.log" >/dev/null; then
  cp -a "$LOG_DIR"/*.log "$OUT_DIR/logs/"
fi

{
  printf 'TAG=%s\n' "$TAG"
  printf 'COMMIT=%s\n' "$COMMIT"
  printf 'PKGVER=%s\n' "$PKGVER"
  printf 'PKGREL=%s\n' "$PKGREL"
  printf 'PRERELEASE=%s\n' "$PRERELEASE"
  printf 'UPSTREAM_ARCHIVE_URL=%s\n' "$UPSTREAM_ARCHIVE_URL"
  printf 'UPSTREAM_ARCHIVE_SHA256=%s\n' "$SOURCE_ARCHIVE_SHA256"
  printf 'LINUX_UNPACKED=%s\n' "$LINUX_UNPACKED"
  printf 'MAIN_EXECUTABLE=%s\n' "$MAIN_EXECUTABLE"
  printf 'MAIN_EXECUTABLE_PATH=%s\n' "$MAIN_EXECUTABLE_PATH"
  printf 'PATCHES=%s\n' "$(printf '%s ' "${PATCH_FILES[@]}")"
} >"$OUT_DIR/metadata.env"

# The versioned pipeline always produces exactly two packages and two
# .SRCINFO files; guard against a regression where one silently disappears.
if [[ -n $SOURCE_BUILT_PKG && -n $BIN_BUILT_PKG ]]; then
  pkg_count=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' | wc -l)
  srcinfo_count=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.SRCINFO' | wc -l)
  if (( pkg_count != 2 )); then
    die "expected 2 package artifacts in $OUT_DIR, found $pkg_count"
  fi
  if (( srcinfo_count != 2 )); then
    die "expected 2 .SRCINFO artifacts in $OUT_DIR, found $srcinfo_count"
  fi
fi

(
  cd "$OUT_DIR"
  find . -maxdepth 1 -type f \
    \( -name '*.pkg.tar.*' -o -name '*.SRCINFO' -o -name '*.tar.gz' -o -name 'metadata.env' \) \
    -print0 | sort -z | xargs -0 -r sha256sum >SHA256SUMS
)
log "artifacts in $OUT_DIR:"
( cd "$OUT_DIR" && ls -la )

log "build finished successfully for $TAG"
