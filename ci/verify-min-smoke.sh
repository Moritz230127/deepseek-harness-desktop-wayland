#!/usr/bin/env bash
# Minimum post-build smoke gate for the Linux unpacked application.
#
# Preference order:
#   1. tools/verify/smoke-runtime.sh (task-6 verifier deliverable), when present
#   2. the official apps/desktop/scripts/smoke-packaged-runtime.ts through pnpm
#   3. structural checks on linux-unpacked (ELF, resources/app.asar, no updater)
#
# A missing smoke entry point is recorded and skipped; a present entry point that
# fails makes this script fail so the build job cannot publish broken artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/common.sh
source "$SCRIPT_DIR/common.sh"

ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
UNPACKED=${LINUX_UNPACKED:-}
UPSTREAM=${UPSTREAM_DIR:-}
LOG_FILE=${SMOKE_LOG:-}
TIMEOUT=${SMOKE_TIMEOUT:-180}

usage() {
  cat <<'USAGE'
Usage: ci/verify-min-smoke.sh [--unpacked DIR] [--upstream DIR] [--log FILE]

Environment: LINUX_UNPACKED, UPSTREAM_DIR, SMOKE_LOG, SMOKE_TIMEOUT.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unpacked) UNPACKED=${2:?--unpacked needs a value}; shift 2 ;;
    --upstream) UPSTREAM=${2:?--upstream needs a value}; shift 2 ;;
    --log) LOG_FILE=${2:?--log needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n $LOG_FILE ]]; then
  mkdir -p "$(dirname -- "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

log "smoke: unpacked=${UNPACKED:-<unset>} upstream=${UPSTREAM:-<unset>}"

run_smoke_command() {
  local label=$1
  shift
  log "smoke: running $label: $*"
  local status=0
  timeout "$TIMEOUT" "$@" || status=$?
  if (( status != 0 )); then
    err "smoke: $label failed with exit code $status"
    return "$status"
  fi
  log "smoke: $label passed"
}

# 1. Verifier-owned smoke script.
VERIFY_SMOKE="$ROOT/tools/verify/smoke-runtime.sh"
if [[ -f $VERIFY_SMOKE && -z $UPSTREAM ]]; then
  warn "smoke: verifier script present but --upstream missing; trying official smoke/structural checks"
fi
if [[ -f $VERIFY_SMOKE && -n $UPSTREAM ]]; then
  # tools/verify/smoke-runtime.sh expects --root work/verify/official layout and
  # runs the official smoke from that tree. CI builds live in work/ci/<tag>/upstream,
  # so expose the build tree through the path the verifier expects.
  mkdir -p "$UPSTREAM/work/verify"
  ln -sfn "$UPSTREAM" "$UPSTREAM/work/verify/official"
  log "smoke: using verifier script $VERIFY_SMOKE"
  run_smoke_command "tools/verify/smoke-runtime.sh" \
    bash "$VERIFY_SMOKE" --root "$UPSTREAM" --unpacked "$UNPACKED"
  exit 0
fi

# 2. Official packaged-runtime smoke (requires the patched Linux target).
if [[ -n $UPSTREAM && -f $UPSTREAM/apps/desktop/scripts/smoke-packaged-runtime.ts ]] && command -v pnpm >/dev/null 2>&1; then
  log "smoke: using official packaged-runtime smoke in $UPSTREAM"
  smoke_cmd=(pnpm --filter @deepseek-ai/dsh-desktop exec tsx scripts/smoke-packaged-runtime.ts)
  if [[ -z ${DISPLAY:-} ]] && command -v xvfb-run >/dev/null 2>&1; then
    smoke_cmd=(xvfb-run -a "${smoke_cmd[@]}")
  fi
  (
    cd "$UPSTREAM"
    DSH_DESKTOP_TARGET_PLATFORM=linux DSH_DESKTOP_TARGET_ARCH=x64 \
      run_smoke_command "official smoke-packaged-runtime" "${smoke_cmd[@]}"
  )
  exit 0
fi

# 3. Structural fallback: no runtime boot, but reject obviously broken trees.
if [[ -z $UNPACKED ]]; then
  warn "smoke: no runnable smoke entry point and no linux-unpacked directory; skipping smoke (recorded)"
  printf 'TODO(ci): pass --upstream/--unpacked (or run tools/verify/build.sh first) to execute the runtime smoke.\n'
  exit 0
fi
if [[ ! -d $UNPACKED ]]; then
  die "smoke: linux-unpacked directory not found: $UNPACKED"
fi

log "smoke: no runtime smoke entry point; running structural checks"

main_bin=''
while IFS= read -r candidate; do
  if file "$candidate" | grep -q 'ELF'; then
    main_bin=$candidate
    break
  fi
done < <(find "$UNPACKED" -maxdepth 1 -type f -perm -u+x -print)
[[ -n $main_bin ]] || die "smoke: no top-level ELF executable in $UNPACKED"
log "smoke: main executable: $main_bin"

if [[ ! -e $UNPACKED/resources/app.asar ]]; then
  die "smoke: resources/app.asar missing under $UNPACKED"
fi

updater_config=$(find "$UNPACKED" -name 'app-update.yml' -print -quit)
if [[ -n $updater_config ]]; then
  die "smoke: Linux package must not ship app-update.yml (found $updater_config)"
fi

if [[ ! -e $UNPACKED/chrome-sandbox ]]; then
  warn "smoke: chrome-sandbox not found (launcher may use --no-sandbox fallback)"
fi

# Best-effort version probe; a headless Electron app may need a display and is
# allowed to fail here. The real runtime gate is run by the verifier scripts.
if [[ -n ${DISPLAY:-} ]] || command -v xvfb-run >/dev/null 2>&1; then
  probe=(timeout 30 "$main_bin" --version)
  if [[ -z ${DISPLAY:-} ]]; then
    probe=(xvfb-run -a "${probe[@]}")
  fi
  if "${probe[@]}"; then
    log "smoke: version probe returned 0"
  else
    warn "smoke: version probe failed (non-fatal without a runtime smoke script)"
  fi
fi

log "smoke: structural checks passed"
