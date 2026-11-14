#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the deepseek-harness-desktop-linux CI scripts.
#
# This file is a library: source it, never execute it directly. It defines pure
# functions only and deliberately leaves `set -euo pipefail` to the caller.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'ci/common.sh is a library; source it from a CI script instead\n' >&2
  exit 2
fi

# Log one line to stderr with a UTC timestamp. GitHub renders stderr normally.
log() { printf '[ci %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# GitHub Actions annotations (plain text outside Actions is still readable).
warn() { printf '::warning::%s\n' "$*" >&2; }
err() { printf '::error::%s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Normalize any of "0.2.0-rc.2", "v0.2.0-rc.2", "dsh-v0.2.0-rc.2" to "dsh-v0.2.0-rc.2".
normalize_tag() {
  local value=${1:-}
  value=${value#dsh-v}
  value=${value#v}
  [[ -n "$value" ]] || die "empty version/tag"
  printf 'dsh-v%s' "$value"
}

# Strip the dsh-v prefix: "dsh-v0.2.0-rc.2" -> "0.2.0-rc.2".
tag_version() {
  local tag
  tag=$(normalize_tag "$1")
  printf '%s' "${tag#dsh-v}"
}

# Convert a tag into a valid Arch pkgver (no hyphens allowed) with the same
# convention as packaging/aur: "dsh-v0.2.0-rc.2" -> "0.2.0rc2",
# "dsh-v0.1.7-alpha.2" -> "0.1.7alpha2".
aur_pkgver() {
  local version
  version=$(tag_version "$1")
  version=${version//-/}
  while [[ $version =~ ([A-Za-z])[.]([0-9]) ]]; do
    version=${version//${BASH_REMATCH[1]}.${BASH_REMATCH[2]}/${BASH_REMATCH[1]}${BASH_REMATCH[2]}}
  done
  printf '%s' "$version"
}

# Compare two numeric components without bash octal surprises.
_semver_num_cmp() {
  local a=$1 b=$2
  if (( 10#$a > 10#$b )); then
    printf '1'
  elif (( 10#$a < 10#$b )); then
    printf '%s' '-1'
  else
    printf '0'
  fi
}

# Semantic-version comparison: echo 1 when $1 > $2, -1 when $1 < $2, 0 when equal.
# Handles the dsh-v prefix, missing minor/patch components, pre-release fields and
# semver build metadata (which is ignored, as the specification requires).
semver_compare() {
  local a b a_meta b_meta a_pre='' b_pre=''
  a=$(tag_version "$1")
  b=$(tag_version "$2")
  a_meta=${a%%+*}
  b_meta=${b%%+*}
  a=$a_meta
  b=$b_meta
  if [[ $a == *-* ]]; then
    a_pre=${a#*-}
    a=${a%%-*}
  fi
  if [[ $b == *-* ]]; then
    b_pre=${b#*-}
    b=${b%%-*}
  fi

  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  local part
  for part in "$a1" "$a2" "$a3" "$b1" "$b2" "$b3"; do
    [[ $part =~ ^[0-9]+$ ]] || die "not a numeric semver component: $part"
  done

  local result
  result=$(_semver_num_cmp "$a1" "$b1")
  [[ $result == 0 ]] || { printf '%s' "$result"; return 0; }
  result=$(_semver_num_cmp "$a2" "$b2")
  [[ $result == 0 ]] || { printf '%s' "$result"; return 0; }
  result=$(_semver_num_cmp "$a3" "$b3")
  [[ $result == 0 ]] || { printf '%s' "$result"; return 0; }

  # A release (empty pre-release) sorts above any pre-release of the same core.
  if [[ -z $a_pre && -z $b_pre ]]; then
    printf '0'
    return 0
  elif [[ -z $a_pre ]]; then
    printf '1'
    return 0
  elif [[ -z $b_pre ]]; then
    printf '%s' '-1'
    return 0
  fi

  local -a a_parts b_parts
  IFS=. read -r -a a_parts <<<"$a_pre"
  IFS=. read -r -a b_parts <<<"$b_pre"
  local count=${#a_parts[@]}
  if (( ${#b_parts[@]} < count )); then
    count=${#b_parts[@]}
  fi

  local i x y
  for (( i = 0; i < count; i++ )); do
    x=${a_parts[i]}
    y=${b_parts[i]}
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then
      result=$(_semver_num_cmp "$x" "$y")
    elif [[ $x =~ ^[0-9]+$ ]]; then
      result=-1
    elif [[ $y =~ ^[0-9]+$ ]]; then
      result=1
    elif [[ $x == "$y" ]]; then
      result=0
    elif [[ $x < "$y" ]]; then
      result=-1
    else
      result=1
    fi
    [[ $result == 0 ]] || { printf '%s' "$result"; return 0; }
  done

  if (( ${#a_parts[@]} > ${#b_parts[@]} )); then
    printf '1'
  elif (( ${#a_parts[@]} < ${#b_parts[@]} )); then
    printf '%s' '-1'
  else
    printf '0'
  fi
}
