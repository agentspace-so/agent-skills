#!/usr/bin/env bash
# Generate an image via Codex CLI's imagegen extension, reusing the user's
# ChatGPT subscription session. Supports text-to-image and image-to-image.
#
# Works with modern codex-cli (0.14x). The `image_gen.imagegen` tool is a
# namespaced extension tool that requires:
#   - [features] image_generation = true in ~/.codex/config.toml
#   - a non-code-mode model (e.g. gpt-5.4). Code-mode-only models
#     (gpt-5.6-sol / terra / luna) do NOT expose image_gen.
# The generated image is saved by codex under
#   $CODEX_HOME/generated_images/<session-id>/call_*.png
# and copied to the requested --out path.
#
# Usage:
#   gen.sh --prompt "<text>" --out <path.png> [--ref <image>]... [--timeout-sec N] [--model gpt-5.4]
#
# Exit codes:
#   0 success (path printed on stdout)
#   2 bad args
#   3 required CLI missing (codex / python3)
#   4 reference image not found
#   5 codex exec failed
#   6 no new session file detected
#   7 no image payload found (imagegen likely did not run)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

PROMPT=""
OUT=""
REF_IMAGES=()
TIMEOUT_SEC=600
MODEL="gpt-5.4"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)      PROMPT="$2"; shift 2 ;;
    --out)         OUT="$2"; shift 2 ;;
    --ref)         REF_IMAGES+=("$2"); shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    -h|--help)     sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$PROMPT" ]] && { echo "Missing --prompt" >&2; exit 2; }
[[ -z "$OUT" ]]    && { echo "Missing --out" >&2; exit 2; }

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found. Install Codex CLI and run 'codex login' first." >&2
  exit 3
}
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 3; }

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_ROOT="$CODEX_HOME/sessions"
GEN_ROOT="$CODEX_HOME/generated_images"
mkdir -p "$SESSIONS_ROOT"

before="$(mktemp)"; after="$(mktemp)"
stdout_log="$(mktemp)"; stderr_log="$(mktemp)"
trap 'rm -f "$before" "$after" "$stdout_log" "$stderr_log"' EXIT

find "$SESSIONS_ROOT" -type f -name 'rollout-*.jsonl' -print 2>/dev/null | sort > "$before" || true

# Intentionally NOT using --ephemeral: we need the session rollout on disk.
# -m <non-code-mode-model> is required: code-mode-only models don't expose
# image_gen. --enable image_generation is belt-and-suspenders for configs
# that don't have [features] image_generation = true set.
args=(exec -m "$MODEL" --skip-git-repo-check --sandbox read-only --color never --enable image_generation)
if [[ ${#REF_IMAGES[@]} -gt 0 ]]; then
  for img in "${REF_IMAGES[@]}"; do
    [[ -f "$img" ]] || { echo "Reference image not found: $img" >&2; exit 4; }
    args+=(-i "$img")
  done
fi

instruction="Use the image_gen.imagegen tool to generate the image for the following request."
if [[ ${#REF_IMAGES[@]} -gt 0 ]]; then
  instruction+=" Use the attached image(s) as visual reference / input for image-to-image."
fi
instruction+=$'\nRequirements: generate the image directly, return only the image, no explanation.\n\nRequest:\n'"$PROMPT"

TO=""
if   command -v timeout  >/dev/null 2>&1; then TO="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout"
fi

set +e
if [[ -n "$TO" ]]; then
  printf '%s' "$instruction" | "$TO" "$TIMEOUT_SEC" codex "${args[@]}" >"$stdout_log" 2>"$stderr_log"
else
  printf '%s' "$instruction" | codex "${args[@]}" >"$stdout_log" 2>"$stderr_log"
fi
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "codex exec failed (exit=$rc). stderr tail:" >&2
  tail -n 40 "$stderr_log" >&2 || true
  exit 5
fi

find "$SESSIONS_ROOT" -type f -name 'rollout-*.jsonl' -print 2>/dev/null | sort > "$after" || true

# Collect ALL new session files. A single `codex exec` call can spawn more
# than one session rollout, so scan every new one.
new_sessions_file="$(mktemp)"
trap 'rm -f "$before" "$after" "$stdout_log" "$stderr_log" "$new_sessions_file"' EXIT
comm -13 "$before" "$after" > "$new_sessions_file" || true

if [[ ! -s "$new_sessions_file" ]]; then
  echo "No new session rollout file under $SESSIONS_ROOT" >&2
  tail -n 40 "$stderr_log" >&2 || true
  exit 6
fi

# New codex (0.14x): image saved to $CODEX_HOME/generated_images/<session-id>/call_*.png
session_ids="$(sed -E 's/.*rollout-[0-9T-]+-([0-9a-f-]+)\.jsonl/\1/' "$new_sessions_file")"
newest_gen=""
while IFS= read -r sid; do
  [[ -z "$sid" ]] && continue
  if [[ -d "$GEN_ROOT/$sid" ]]; then
    found="$(find "$GEN_ROOT/$sid" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) -print 2>/dev/null | sort | tail -1)"
    if [[ -n "$found" ]]; then
      newest_gen="$found"
    fi
  fi
done <<< "$session_ids"

if [[ -n "$newest_gen" ]]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$newest_gen" "$OUT"
  echo "$OUT"
  exit 0
fi

# Older codex (0.111-era): image embedded as base64 in the session rollout.
set +e
python3 "$SCRIPT_DIR/extract_image.py" "$OUT" "$new_sessions_file"
py_rc=$?
set -e

if [[ $py_rc -ne 0 ]]; then
  echo "No generated image found in $GEN_ROOT or in session rollouts" >&2
  echo "(imagegen likely did not run; stderr tail:)" >&2
  tail -n 30 "$stderr_log" >&2 || true
  exit 7
fi
