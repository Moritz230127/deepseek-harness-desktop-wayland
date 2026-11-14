#!/usr/bin/env bash
# Update AUR package metadata (PKGBUILD + regenerated .SRCINFO) from one official
# deepseek-harness tag, optionally pushing the result to AUR over SSH.
#
# Modes:
#   * default        update packaging/aur/{source,-bin} in this repository
#   * --dry-run      work on a temp copy and print unified diffs, never write/push
#   * --pkgbuild F   update a single PKGBUILD in place (used by ci/build-in-arch.sh
#                    on throw-away build copies); no .SRCINFO, no push
#
# Safety rules: --dry-run never touches the repository or AUR; AUR is only pushed
# with --push and a private key; failures leave the last good version untouched.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/common.sh
source "$SCRIPT_DIR/common.sh"

ROOT_DEFAULT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ROOT=${ROOT:-$ROOT_DEFAULT}
PACKAGING_DIR=${PACKAGING_DIR:-$ROOT/packaging/aur}
PATCH_DIR=${PATCH_DIR:-$ROOT/patches}
KNOWN_HOSTS_DEFAULT="$ROOT/ci/aur_known_hosts"
UPSTREAM_REPOSITORY=${UPSTREAM_REPOSITORY:-deepseek-ai/deepseek-harness}

SOURCE_PKG_NAME=deepseek-harness-desktop-linux
BIN_PKG_NAME=deepseek-harness-desktop-linux-bin
GIT_PKG_NAME=deepseek-harness-desktop-linux-git

TAG=''
COMMIT=''
PKGVER=''
PKGREL='1'
SOURCE_URL=''
SOURCE_SHA256=''
BIN_URL=''
BIN_SHA256=''
INCLUDE_GIT=0
DRY_RUN=0
PUSH=0
PUSH_BIN=1
SSH_KEY=''
KNOWN_HOSTS=$KNOWN_HOSTS_DEFAULT
AUR_URL='ssh://aur@aur.archlinux.org'
REPO_OWNER=''
REPO_NAME=''
if [[ -n ${GITHUB_REPOSITORY:-} && ${GITHUB_REPOSITORY} == */* ]]; then
  REPO_OWNER=${GITHUB_REPOSITORY%%/*}
  REPO_NAME=${GITHUB_REPOSITORY#*/}
fi
PKGBUILD_PATH=''
PKG_KIND=''
REWRITE_PATCHES=0
ALLOW_MISSING=0
MESSAGE=''

usage() {
  cat <<'USAGE'
Usage: ci/update-aur.sh [options]

Metadata:
  --tag TAG              upstream tag, e.g. dsh-v0.2.0-rc.2
  --commit SHA           upstream commit (defaults source URL to the commit tarball)
  --pkgver VER           Arch pkgver override (default: tag with '-' -> '_')
  --pkgrel N             Arch pkgrel (default: 1)
  --source-url URL       official source archive URL
  --source-sha256 HASH   sha256 of the official source archive
  --bin-url URL          release asset URL of the source-built package used by the -bin package
  --bin-sha256 HASH      sha256 of that asset
  --include-git          also refresh patch hashes in the -git package
  --source-only          push only the source AUR package (skip -bin)

Actions:
  --dry-run              show diffs on a temp copy; never writes the repo or AUR
  --push                 push the regenerated packages to AUR (requires --ssh-key)
  --ssh-key FILE         private key registered with the AUR account
  --known-hosts FILE     fixed known_hosts file (default ci/aur_known_hosts)
  --repo-owner OWNER     GitHub owner for the -bin release URL (default from GITHUB_REPOSITORY)
  --repo-name NAME       GitHub repository name for the -bin release URL
  --message MSG          AUR commit message (default mentions tag/commit)
  --pkgbuild FILE        single-file mode used by the build job
  --kind source|bin|git  package kind for --pkgbuild mode
  --patch-dir DIR        directory holding the local patch series (default patches/)
  --rewrite-patches      rewrite patch source entries to patches/<basename>
  --allow-missing        skip missing patch files instead of failing
  -h, --help             show this text
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a value}; shift 2 ;;
    --commit) COMMIT=${2:?--commit needs a value}; shift 2 ;;
    --pkgver) PKGVER=${2:?--pkgver needs a value}; shift 2 ;;
    --pkgrel) PKGREL=${2:?--pkgrel needs a value}; shift 2 ;;
    --source-url) SOURCE_URL=${2:?--source-url needs a value}; shift 2 ;;
    --source-sha256) SOURCE_SHA256=${2:?--source-sha256 needs a value}; shift 2 ;;
    --bin-url) BIN_URL=${2:?--bin-url needs a value}; shift 2 ;;
    --bin-sha256) BIN_SHA256=${2:?--bin-sha256 needs a value}; shift 2 ;;
    --include-git) INCLUDE_GIT=1; shift ;;
    --source-only) PUSH_BIN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --push) PUSH=1; shift ;;
    --ssh-key) SSH_KEY=${2:?--ssh-key needs a value}; shift 2 ;;
    --known-hosts) KNOWN_HOSTS=${2:?--known-hosts needs a value}; shift 2 ;;
    --repo-owner) REPO_OWNER=${2:?--repo-owner needs a value}; shift 2 ;;
    --repo-name) REPO_NAME=${2:?--repo-name needs a value}; shift 2 ;;
    --message) MESSAGE=${2:?--message needs a value}; shift 2 ;;
    --pkgbuild) PKGBUILD_PATH=${2:?--pkgbuild needs a value}; shift 2 ;;
    --kind) PKG_KIND=${2:?--kind needs a value}; shift 2 ;;
    --patch-dir) PATCH_DIR=${2:?--patch-dir needs a value}; shift 2 ;;
    --rewrite-patches) REWRITE_PATCHES=1; shift ;;
    --allow-missing) ALLOW_MISSING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

export LC_ALL=C
require_cmd python3

if [[ -n $PKGBUILD_PATH ]]; then
  [[ $PUSH -eq 0 ]] || die "--pkgbuild cannot be combined with --push"
  [[ -n $PKG_KIND ]] || die "--pkgbuild requires --kind source|bin|git"
  case "$PKG_KIND" in
    source|bin|git) ;;
    *) die "--kind must be source, bin or git (got '$PKG_KIND')" ;;
  esac
  [[ -f $PKGBUILD_PATH ]] || die "PKGBUILD not found: $PKGBUILD_PATH"
else
  if [[ -n $PKG_KIND ]]; then
    die "--kind is only valid together with --pkgbuild"
  fi
  if [[ -n $TAG ]]; then
    TAG=$(normalize_tag "$TAG")
  fi
  if [[ -z $PKGVER && -n $TAG ]]; then
    PKGVER=$(aur_pkgver "$TAG")
  fi
  if [[ -z $SOURCE_URL && -n $TAG && -n $COMMIT ]]; then
    SOURCE_URL="https://codeload.github.com/$UPSTREAM_REPOSITORY/tar.gz/$COMMIT"
  fi
fi

TAG_VERSION=''
if [[ -n $TAG ]]; then
  TAG_VERSION=$(tag_version "$TAG")
fi
if [[ -z $MESSAGE ]]; then
  if [[ -n $TAG ]]; then
    MESSAGE="update to $TAG ($COMMIT)"
  else
    MESSAGE='refresh local patch checksums'
  fi
fi

# Update one PKGBUILD through the embedded Python editor. Parameters are passed
# as UPDATE_* environment variables to keep quoting out of the shell layer.
update_single_pkgbuild() {
  local pkgbuild=$1 kind=$2 rewrite=${3:-0} allow_missing=${4:-0}
  UPDATE_PACKAGE_DIR="${UPDATE_PACKAGE_DIR:-$(dirname -- "$pkgbuild")}" \
  UPDATE_KIND="$kind" \
  UPDATE_TAG="${TAG:-}" \
  UPDATE_TAG_VERSION="${TAG_VERSION:-}" \
  UPDATE_COMMIT="${COMMIT:-}" \
  UPDATE_PKGVER="${PKGVER:-}" \
  UPDATE_PKGREL="${PKGREL:-}" \
  UPDATE_SOURCE_URL="${SOURCE_URL:-}" \
  UPDATE_SOURCE_SHA256="${SOURCE_SHA256:-}" \
  UPDATE_BIN_URL="${BIN_URL:-}" \
  UPDATE_BIN_SHA256="${BIN_SHA256:-}" \
  UPDATE_REPO_OWNER="${REPO_OWNER:-}" \
  UPDATE_REPO_NAME="${REPO_NAME:-}" \
  UPDATE_PATCH_DIR="$PATCH_DIR" \
  UPDATE_REWRITE_PATCHES="$rewrite" \
  UPDATE_ALLOW_MISSING="$allow_missing" \
  python3 - "$pkgbuild" <<'PY'
import hashlib
import os
import re
import shlex
import sys
from pathlib import Path


def fail(message):
    print(f"update-aur: {message}", file=sys.stderr)
    raise SystemExit(2)


path = Path(sys.argv[1])
original = path.read_text(encoding="utf-8")
text = original

kind = os.environ.get("UPDATE_KIND", "source")
tag = os.environ.get("UPDATE_TAG", "")
tag_version = os.environ.get("UPDATE_TAG_VERSION", "")
commit = os.environ.get("UPDATE_COMMIT", "")
pkgver = os.environ.get("UPDATE_PKGVER", "")
pkgrel = os.environ.get("UPDATE_PKGREL", "")
source_url = os.environ.get("UPDATE_SOURCE_URL", "")
source_sha = os.environ.get("UPDATE_SOURCE_SHA256", "")
bin_url = os.environ.get("UPDATE_BIN_URL", "")
bin_sha = os.environ.get("UPDATE_BIN_SHA256", "")
repo_owner = os.environ.get("UPDATE_REPO_OWNER", "")
repo_name = os.environ.get("UPDATE_REPO_NAME", "")
patch_dir = Path(os.environ.get("UPDATE_PATCH_DIR", "patches"))
rewrite_patches = os.environ.get("UPDATE_REWRITE_PATCHES", "0") == "1"
allow_missing = os.environ.get("UPDATE_ALLOW_MISSING", "0") == "1"


def sha256_file(file_path):
    return hashlib.sha256(file_path.read_bytes()).hexdigest()


PACKAGE_DIR = Path(os.environ.get("UPDATE_PACKAGE_DIR", str(path.parent)))


def local_file_for(basename):
    """Find a local source file either next to the PKGBUILD or in patches/."""
    for candidate in (PACKAGE_DIR / basename, patch_dir / basename):
        if candidate.is_file():
            return candidate
    return None


def quote_token(value):
    if "$" in value:
        # Shell expansions in preserved entries must stay unquoted.
        return value
    if "'" not in value:
        return "'" + value + "'"
    return "'" + value.replace("'", "'\\''") + "'"


def tokenize(body):
    try:
        return shlex.split(body, comments=True, posix=True)
    except ValueError as exc:
        fail(f"{path}: cannot parse PKGBUILD array body: {exc}")


def render_array(tokens):
    if not tokens:
        return ""
    return "\n" + "\n".join("  " + quote_token(token) for token in tokens) + "\n"


ARRAY_START = re.compile(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)=\(")


def find_arrays(source):
    found = []
    for match in ARRAY_START.finditer(source):
        name = match.group(1)
        if not re.fullmatch(r"(?:source|sha256sums|b2sums)[A-Za-z0-9_]*", name):
            continue
        index = match.end()
        depth = 1
        quote = None
        while index < len(source):
            char = source[index]
            if quote is not None:
                if quote == '"' and char == "\\":
                    index += 2
                    continue
                if char == quote:
                    quote = None
            elif char in ('"', "'"):
                quote = char
            elif char == "#" and (index == 0 or source[index - 1] in " \t\n"):
                # Comments may contain apostrophes; skip them instead of
                # treating the rest of the file as a quoted string.
                newline = source.find("\n", index)
                if newline == -1:
                    index = len(source)
                    break
                index = newline
                continue
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        if index >= len(source):
            fail(f"{path}: unterminated array {name}")
        found.append({"name": name, "start": match.end(), "end": index,
                      "body": source[match.end():index]})
    return found


def classify(url):
    if url.startswith(("git+", "git://", "git=", "ssh://git@")):
        return "git"
    base = Path(url).name
    if base.endswith((".patch", ".diff")):
        return "patch"
    if ".pkg.tar" in base:
        return "bin"
    if re.search(r"\$(\{)?_?(tag|commit|version)\b", url):
        return "archive"
    if base.endswith((".tar.gz", ".tar.xz", ".tar.bz2", ".tgz")):
        return "archive"
    if url.startswith(("http://", "https://")) and (
        "deepseek-harness" in url or "codeload.github.com" in url or "github.com/" in url
    ):
        return "archive"
    return "local"


arrays = find_arrays(text)
by_name = {entry["name"]: entry for entry in arrays}
source_arrays = [entry for entry in arrays if entry["name"].startswith("source")]
if not source_arrays:
    fail(f"{path}: no source=() array found")

edits = []
for source_entry in source_arrays:
    suffix = source_entry["name"][len("source"):]
    sums_name = "sha256sums" + suffix
    sums_entry = by_name.get(sums_name)
    if sums_entry is None:
        fail(f"{path}: {source_entry['name']} has no matching {sums_name} array")
    source_tokens = tokenize(source_entry["body"])
    sum_tokens = tokenize(sums_entry["body"])
    if len(source_tokens) != len(sum_tokens):
        fail(f"{path}: {source_entry['name']} has {len(source_tokens)} entries but "
             f"{sums_name} has {len(sum_tokens)}")
    new_source = []
    new_sums = []
    for index, token in enumerate(source_tokens):
        explicit_name = None
        url = token
        if "::" in token:
            explicit_name, url = token.split("::", 1)
        entry_kind = classify(url)
        # In the -bin PKGBUILD the only remote entry is the GitHub release asset,
        # even though its URL points at github.com and its filename uses variables.
        if kind == "bin" and entry_kind in ("archive", "other"):
            entry_kind = "bin"
        existing_sum = sum_tokens[index]
        if entry_kind == "git":
            new_url = url
            new_sum = existing_sum if existing_sum else "SKIP"
        elif entry_kind == "patch":
            basename = Path(url).name
            local_patch = local_file_for(basename)
            if local_patch is not None:
                new_sum = sha256_file(local_patch)
            elif allow_missing:
                new_sum = existing_sum
            else:
                fail(f"{path}: patch {basename} not found in {PACKAGE_DIR} or {patch_dir}")
            new_url = f"patches/{basename}" if rewrite_patches else url
        elif entry_kind == "archive":
            new_url = source_url or url
            new_sum = source_sha or existing_sum
        elif entry_kind == "bin":
            new_url = bin_url or url
            new_sum = bin_sha or existing_sum
        else:
            basename = Path(url).name
            local_asset = local_file_for(basename)
            if local_asset is not None:
                new_sum = sha256_file(local_asset)
            elif allow_missing:
                new_sum = existing_sum
            else:
                fail(f"{path}: local source {basename} not found in {PACKAGE_DIR}")
            new_url = url
        new_source.append(f"{explicit_name}::{new_url}" if explicit_name else new_url)
        new_sums.append(new_sum)
    edits.append((source_entry["start"], source_entry["end"], render_array(new_source)))
    edits.append((sums_entry["start"], sums_entry["end"], render_array(new_sums)))

for start, end, replacement in sorted(edits, key=lambda item: item[0], reverse=True):
    text = text[:start] + replacement + text[end:]


def set_line(source, key, value):
    pattern = re.compile(r"(?m)^" + re.escape(key) + r"=.*$")
    if not pattern.search(source):
        return source
    return pattern.sub(lambda _match: f"{key}={shlex.quote(value)}", source, count=1)


if kind in ("source", "bin"):
    if pkgver:
        text = set_line(text, "pkgver", pkgver)
    if pkgrel:
        if re.search(r"(?m)^pkgrel=", text):
            text = set_line(text, "pkgrel", pkgrel)
        else:
            text = re.sub(r"(?m)^(pkgver=.*)$", r"\1\npkgrel=" + pkgrel, text, count=1)

if tag:
    for name in ("_tag", "_upstream_tag", "_dsh_tag", "_src_tag", "_release_tag"):
        text = set_line(text, name, tag)
if tag_version:
    for name in ("_version", "_upstream_version", "_dsh_version", "_src_version"):
        text = set_line(text, name, tag_version)
if commit:
    for name in ("_commit", "_upstream_commit", "_dsh_commit", "_src_commit"):
        text = set_line(text, name, commit)
if repo_owner:
    for name in ("_repo_owner",):
        text = set_line(text, name, repo_owner)
if repo_name:
    for name in ("_repo_name",):
        text = set_line(text, name, repo_name)

# Final structural validation: every source entry still has exactly one checksum.
final_arrays = find_arrays(text)
final_by_name = {entry["name"]: entry for entry in final_arrays}
for entry in final_arrays:
    if not entry["name"].startswith("source"):
        continue
    suffix = entry["name"][len("source"):]
    sums = final_by_name.get("sha256sums" + suffix)
    if sums is None or len(tokenize(entry["body"])) != len(tokenize(sums["body"])):
        fail(f"{path}: source/checksum array mismatch after rewrite")

if text != original:
    path.write_text(text, encoding="utf-8")
    print(f"updated {path}")
else:
    print(f"unchanged {path}")
PY
}

# Regenerate .SRCINFO with makepkg in a package directory.
regenerate_srcinfo() {
  local dir=$1 allow_fail=${2:-0}
  if ! command -v makepkg >/dev/null 2>&1; then
    warn "makepkg not found; skipped .SRCINFO regeneration in $dir"
    return 0
  fi
  if (( EUID == 0 )); then
    warn "makepkg refuses to run as root; skipped .SRCINFO regeneration in $dir"
    return 0
  fi
  local tmp="$dir/.SRCINFO.tmp" errors stderr_text
  errors=$(mktemp)
  if ( cd "$dir" && makepkg --printsrcinfo >"$tmp" 2>"$errors" ); then
    mv "$tmp" "$dir/.SRCINFO"
    rm -f "$errors"
    return 0
  fi
  stderr_text=$(head -c 400 "$errors")
  rm -f "$tmp" "$errors"
  if [[ $allow_fail == 1 ]]; then
    warn "makepkg --printsrcinfo failed in $dir (keeping existing .SRCINFO): $stderr_text"
    return 0
  fi
  die "makepkg --printsrcinfo failed in $dir: $stderr_text"
}

print_diff() {
  local left=$1 right=$2 label=$3
  if [[ -f $left && -f $right ]]; then
    printf '=== diff %s ===\n' "$label"
    diff -u "$left" "$right" || true
  elif [[ -f $right ]]; then
    printf '=== new file %s ===\n' "$label"
    sed 's/^/+/' "$right"
  fi
}

prepare_package_copy() {
  # $1=pkgbase $2=kind $3=destination
  local pkgbase=$1 kind=$2 destination=$3
  local src_dir="$PACKAGING_DIR/$pkgbase"
  [[ -f $src_dir/PKGBUILD ]] || return 1
  mkdir -p "$destination"
  # AUR repositories cannot carry symlinks into this monorepo, so dereference
  # every local source while preparing the throw-away package copy. Dangling
  # symlinks (e.g. a patch task that is still in flight) are reported and
  # skipped; --allow-missing decides whether a missing hash is fatal.
  local broken
  broken=$(find "$src_dir" -mindepth 1 -maxdepth 1 -xtype l -print)
  if [[ -n $broken ]]; then
    warn "dangling local source symlink(s) in $src_dir: $(printf '%s' "$broken" | tr '\n' ' ')"
  fi
  find "$src_dir" -mindepth 1 -maxdepth 1 ! -xtype l -exec cp -aL {} "$destination/" \;
  update_single_pkgbuild "$destination/PKGBUILD" "$kind" "$REWRITE_PATCHES" "$ALLOW_MISSING"
  # -git pkgver() needs the cloned upstream tree, which is not available during
  # a metadata refresh; .SRCINFO there is best-effort.
  if [[ $kind == git ]]; then
    regenerate_srcinfo "$destination" 1
  else
    regenerate_srcinfo "$destination" 0
  fi
  return 0
}

aur_push_package() {
  # $1=pkgbase $2=prepared work dir
  local pkgbase=$1 work_dir=$2
  local clone_dir="$TMP_DIR/aur/$pkgbase"
  mkdir -p "$TMP_DIR/aur"
  export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes"

  if ! git clone --quiet "$AUR_URL/$pkgbase.git" "$clone_dir" 2>"$TMP_DIR/clone-$pkgbase.log"; then
    warn "AUR clone failed for $pkgbase; initializing an empty repository (first push creates it)"
    if [[ -s $TMP_DIR/clone-$pkgbase.log ]]; then
      sed -n '1,3p' "$TMP_DIR/clone-$pkgbase.log" >&2 || true
    fi
    rm -rf "$clone_dir"
    mkdir -p "$clone_dir"
    git -C "$clone_dir" init --quiet
    git -C "$clone_dir" remote add origin "$AUR_URL/$pkgbase.git"
    git -C "$clone_dir" checkout --quiet -b master 2>/dev/null || true
  fi

  # The prepared directory contains PKGBUILD, .SRCINFO and every dereferenced
  # local source (patches, launcher, desktop file, service, icons, LICENSE).
  cp -a "$work_dir/." "$clone_dir/"
  git -C "$clone_dir" add -A

  if git -C "$clone_dir" diff --cached --quiet; then
    log "$pkgbase: AUR repository already up to date"
    return 0
  fi
  git -C "$clone_dir" -c user.name='dsh-ci' -c user.email='dsh-ci@users.noreply.github.com' \
    commit --quiet -m "$MESSAGE"

  local attempt
  for attempt in 1 2; do
    if git -C "$clone_dir" push --quiet origin HEAD:master; then
      log "$pkgbase: pushed to AUR ($MESSAGE)"
      return 0
    fi
    warn "$pkgbase: AUR push attempt $attempt failed"
    if (( attempt == 1 )); then
      sleep 5
    fi
  done
  return 1
}

TMP_DIR=''
cleanup() {
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Single-file mode (used on temp build copies by ci/build-in-arch.sh).
# ---------------------------------------------------------------------------
if [[ -n $PKGBUILD_PATH ]]; then
  update_single_pkgbuild "$PKGBUILD_PATH" "$PKG_KIND" "$REWRITE_PATCHES" "$ALLOW_MISSING"
  exit 0
fi

# ---------------------------------------------------------------------------
# Dry-run mode: temp copies only, print diffs, never write the repository.
# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
  TMP_DIR=$(mktemp -d)
  found=0
  for spec in "$SOURCE_PKG_NAME:source" "$BIN_PKG_NAME:bin" "$GIT_PKG_NAME:git"; do
    pkgbase=${spec%%:*}
    kind=${spec##*:}
    if [[ $kind == git && $INCLUDE_GIT -eq 0 ]]; then
      continue
    fi
    src_dir="$PACKAGING_DIR/$pkgbase"
    if [[ ! -f $src_dir/PKGBUILD ]]; then
      warn "dry-run: $src_dir/PKGBUILD not found; skipping $pkgbase"
      continue
    fi
    found=1
    work="$TMP_DIR/$pkgbase"
    prepare_package_copy "$pkgbase" "$kind" "$work"
    print_diff "$src_dir/PKGBUILD" "$work/PKGBUILD" "$pkgbase/PKGBUILD"
    print_diff "$src_dir/.SRCINFO" "$work/.SRCINFO" "$pkgbase/.SRCINFO"
  done
  if (( found == 0 )); then
    warn "no packaging/aur/*/PKGBUILD found; AUR dry-run skipped"
    printf 'TODO(ci): rerun ci/update-aur.sh --dry-run once task-4 packaging PKGBUILDs land.\n'
  fi
  if [[ -n $TAG ]]; then
    log "dry-run for $TAG (pkgver=${PKGVER:-<n/a>}) finished; nothing was written to the repository or AUR"
  else
    log "dry-run finished; nothing was written to the repository or AUR"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Real update: write packaging/aur in this repository, optionally push AUR.
# ---------------------------------------------------------------------------
if [[ -n $TAG ]]; then
  [[ $TAG == dsh-v* ]] || die "tag must look like dsh-v<semver> (got '$TAG')"
fi
if (( PUSH == 0 )); then
  [[ -n $SOURCE_SHA256 ]] || warn "no --source-sha256 given; existing official-archive checksum is kept"
fi

# In real (non-dry-run) mode require the packages that must be published.
for pkgbase in "$SOURCE_PKG_NAME" "$BIN_PKG_NAME"; do
  [[ -f $PACKAGING_DIR/$pkgbase/PKGBUILD ]] ||
    die "missing $PACKAGING_DIR/$pkgbase/PKGBUILD (packaging deliverable not ready?)"
done
if (( INCLUDE_GIT )) && [[ ! -f $PACKAGING_DIR/$GIT_PKG_NAME/PKGBUILD ]]; then
  die "missing $PACKAGING_DIR/$GIT_PKG_NAME/PKGBUILD (needed by --include-git)"
fi
if (( PUSH )); then
  [[ -n $SSH_KEY && -f $SSH_KEY ]] || die "--push requires --ssh-key with an existing private key file"
  [[ -f $KNOWN_HOSTS ]] || die "--push requires --known-hosts (missing $KNOWN_HOSTS)"
  chmod 600 "$SSH_KEY"
  require_cmd git
  require_cmd ssh
fi

TMP_DIR=$(mktemp -d)
PREPARED_SOURCE="$TMP_DIR/$SOURCE_PKG_NAME"
PREPARED_BIN="$TMP_DIR/$BIN_PKG_NAME"
PREPARED_GIT="$TMP_DIR/$GIT_PKG_NAME"

log "preparing $SOURCE_PKG_NAME (pkgver=${PKGVER:-<keep>})"
prepare_package_copy "$SOURCE_PKG_NAME" source "$PREPARED_SOURCE"
log "preparing $BIN_PKG_NAME"
prepare_package_copy "$BIN_PKG_NAME" bin "$PREPARED_BIN"
if (( INCLUDE_GIT )); then
  log "preparing $GIT_PKG_NAME (patch checksums only)"
  prepare_package_copy "$GIT_PKG_NAME" git "$PREPARED_GIT"
fi

# Copy back only the metadata files; never clobber unrelated local assets.
for pair in "$SOURCE_PKG_NAME:$PREPARED_SOURCE" "$BIN_PKG_NAME:$PREPARED_BIN"; do
  pkgbase=${pair%%:*}
  prepared=${pair##*:}
  install -m 0644 "$prepared/PKGBUILD" "$PACKAGING_DIR/$pkgbase/PKGBUILD"
  if [[ -f $prepared/.SRCINFO ]]; then
    install -m 0644 "$prepared/.SRCINFO" "$PACKAGING_DIR/$pkgbase/.SRCINFO"
  fi
done
if (( INCLUDE_GIT )); then
  install -m 0644 "$PREPARED_GIT/PKGBUILD" "$PACKAGING_DIR/$GIT_PKG_NAME/PKGBUILD"
  if [[ -f $PREPARED_GIT/.SRCINFO ]]; then
    install -m 0644 "$PREPARED_GIT/.SRCINFO" "$PACKAGING_DIR/$GIT_PKG_NAME/.SRCINFO"
  fi
fi

if (( PUSH )); then
  aur_push_package "$SOURCE_PKG_NAME" "$PREPARED_SOURCE"
  if (( PUSH_BIN )); then
    aur_push_package "$BIN_PKG_NAME" "$PREPARED_BIN"
  else
    log "AUR: --source-only set; skipping $BIN_PKG_NAME push (GitHub Release asset is still built)"
  fi
  if (( INCLUDE_GIT )); then
    aur_push_package "$GIT_PKG_NAME" "$PREPARED_GIT"
  fi
else
  log "update finished; AUR was not pushed (pass --push to publish)"
fi

