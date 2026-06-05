#!/usr/bin/env bash
# Shared setup for all export-scripts/*.sh files.
# Usage in each script: source "$(dirname "$0")/_common.sh" && setup_common "$@"
#
# After setup_common, the following are available:
#   PROFILE  REGION  SKIP_GLOBALS  WITH_SECRET_VALUES
#   BASE_AWS_ARGS  AWS_ARGS  _TIMEOUT_CMD
#   safe_aws_json()  chunk_lines_file()

PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
SKIP_GLOBALS="false"
WITH_SECRET_VALUES="false"

setup_common() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region)             REGION="$2";              shift 2 ;;
      --profile)            PROFILE="$2";             shift 2 ;;
      --skip-globals)       SKIP_GLOBALS="true";       shift   ;;
      --with-secret-values) WITH_SECRET_VALUES="true"; shift   ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "${OUT_DIR:-}" ]]; then
    echo "ERROR: OUT_DIR is not set. Example:" >&2
    echo "  OUT_DIR=snapshots/2026-... ./export-scripts/${0##*/}" >&2
    exit 1
  fi
  if [[ ! -d "$OUT_DIR/raw" ]]; then
    echo "ERROR: $OUT_DIR/raw does not exist — invalid snapshot folder." >&2
    exit 1
  fi

  BASE_AWS_ARGS=(--output json)
  [[ -n "$PROFILE" ]] && BASE_AWS_ARGS+=(--profile "$PROFILE")

  if [[ -z "$REGION" && -f "$OUT_DIR/manifest.json" ]]; then
    REGION="$(jq -r '.region // empty' "$OUT_DIR/manifest.json" 2>/dev/null || true)"
  fi
  AWS_ARGS=("${BASE_AWS_ARGS[@]}")
  [[ -n "$REGION" ]] && AWS_ARGS+=(--region "$REGION")

  _TIMEOUT_CMD=""
  if command -v gtimeout >/dev/null 2>&1; then _TIMEOUT_CMD="gtimeout 90"
  elif command -v timeout  >/dev/null 2>&1; then _TIMEOUT_CMD="timeout 90"
  fi
}

safe_aws_json() {
  local outfile="$1"; shift
  echo "→ $outfile"
  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" "$@" > "$outfile" 2>"${outfile}.stderr"; then
    rm -f "${outfile}.stderr"
  else
    local _exit=$?; rm -f "${outfile}.stderr"; echo '{}' > "$outfile"
    if [[ $_exit -eq 124 ]]; then echo "WARN: timed out: aws $*" >&2
    else echo "WARN: failed: aws $*" >&2; fi
  fi
}

chunk_lines_file() {
  local size="$1" infile="$2"
  awk -v size="$size" '
    NF {
      if (count > 0) printf " "
      printf "%s", $0
      count++
      if (count >= size) { printf "\n"; count = 0 }
    }
    END { if (count > 0) printf "\n" }
  ' "$infile"
}
