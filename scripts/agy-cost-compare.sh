#!/usr/bin/env bash
#
# agy-cost-compare.sh — run ONE task on agy (Gemini), then show what that same
# token volume would cost on Claude vs on Gemini Flash. A demo aid for the
# "let the cheap model do the bulk tokens" hypothesis.
#
# HONEST SCOPE / CAVEATS:
#   * agy v1.0.x has no token usage API in --print mode, so token counts here are
#     ESTIMATED from character count (chars / CHARS_PER_TOKEN). They are ballpark,
#     not billing-accurate.
#   * This prices the SAME measured volume at both price decks to visualize the
#     per-token price gap. The REAL saving in practice is larger, because Claude
#     as an orchestrator processes far fewer tokens than Claude doing everything.
#   * Prices below are PLACEHOLDERS. Override with the real Vertex rates for your
#     project before quoting numbers to anyone. Per 1M tokens, in USD.
#
# Usage:
#   agy-cost-compare.sh [-t flash|flash-lo|pro] "the task prompt"
#
# Env overrides (USD per 1M tokens):
#   CLAUDE_IN_PER_M  CLAUDE_OUT_PER_M     (default: prices.json claude_opus,
#                                          today 4 / 20 -- VERIFY!)
#   GEMINI_IN_PER_M  GEMINI_OUT_PER_M     (default: prices.json gemini_flash,
#                                          today 0.75 / 3.75 -- VERIFY against
#                                          your own Vertex rates)
#   CHARS_PER_TOKEN                       (default: 4)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/plugin-options.sh
. "$HERE/lib/plugin-options.sh"
load_plugin_options

TIER="flash"

YOLO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tier) TIER="${2:-flash}"; shift 2 ;;
    --yolo)    YOLO="--yolo"; shift ;;   # needed if the task uses tools (web/Vertex search)
    --)        shift; break ;;
    -*)        echo "unknown option: $1" >&2; exit 1 ;;
    *)         break ;;
  esac
done
PROMPT="${*:-}"
[ -n "$PROMPT" ] || { echo "usage: agy-cost-compare.sh [-t tier] [--yolo] \"task\"" >&2; exit 1; }

# Configured pro tier model (pinned against agy-delegate.sh and doctor.sh in run-tests.sh);
# overridden below if agy-delegate reports a different model in AGY_USAGE or a pro fallback.
PRO_MODEL="${CLAUDE_PLUGIN_OPTION_TIER_PRO:-Gemini 4 Argon (High)}"
DEL_ERR="$(mktemp "${TMPDIR:-/tmp}/agy-cc-err.XXXXXX")"
trap 'rm -f "$DEL_ERR" 2>/dev/null' EXIT

echo ">> Delegating to agy (tier=$TIER) ..." >&2
START=$(date +%s 2>/dev/null || echo 0)
# Stream the delegate's stderr live AND keep a copy for the price lookup below. A
# `2> >(tee ...)` process substitution would do both, but a bare `wait` does not wait
# for it on bash < 4.4 (macOS ships 3.2), so python could read $DEL_ERR before tee had
# flushed the AGY_USAGE line and silently price a fallback run at the wrong rate. A
# named pipe gives tee a PID we can wait on explicitly; if mkfifo is unavailable, fall
# back to buffering stderr in the file and replaying it afterwards.
set +e
FIFO="$(mktemp -u "${TMPDIR:-/tmp}/agy-cc-fifo.XXXXXX")"
if mkfifo "$FIFO" 2>/dev/null; then
  trap 'rm -f "$DEL_ERR" "$FIFO" 2>/dev/null' EXIT
  tee "$DEL_ERR" <"$FIFO" >&2 &
  TEE_PID=$!
  OUT="$("$HERE/agy-delegate.sh" --tier "$TIER" ${YOLO:+$YOLO} "$PROMPT" 2>"$FIFO")"
  RC=$?
  wait "$TEE_PID" 2>/dev/null
  rm -f "$FIFO"
else
  OUT="$("$HERE/agy-delegate.sh" --tier "$TIER" ${YOLO:+$YOLO} "$PROMPT" 2>"$DEL_ERR")"
  RC=$?
  [ -s "$DEL_ERR" ] && cat "$DEL_ERR" >&2
fi
set -e
[ "$RC" -eq 0 ] || exit "$RC"
END=$(date +%s 2>/dev/null || echo 0)
ELAPSED=$(( END - START ))

# Default prices from prices.json (env vars still override); Gemini rate by tier and the
# model that actually ran (so a runtime fallback from Argon to Gemini 3.1 Pro is priced
# as gemini_pro rather than gemini_argon).
PRICES="$HERE/../prices.json"
if [ -f "$PRICES" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(python3 - "$PRICES" "$TIER" "$PRO_MODEL" "$DEL_ERR" 2>/dev/null <<'PY'
import json,os,re,sys
try:
    d=json.load(open(sys.argv[1])); t,pm,errf=sys.argv[2],sys.argv[3],sys.argv[4]
    if os.path.isfile(errf):
        for line in open(errf,encoding="utf-8",errors="replace").read().splitlines():
            if line.startswith("AGY_USAGE "):
                try:
                    u=json.loads(line[len("AGY_USAGE "):])
                    if isinstance(u,dict) and u.get("model"): pm=str(u["model"])
                except Exception: pass
            m=re.search(r"pro fell back to ([^(]+)",line)
            if m: pm=m.group(1).strip()
    pk="gemini_argon" if ("argon" in pm.lower() and "gemini_argon" in d) else "gemini_pro"
    g=d[pk] if t=="pro" else d["gemini_flash"]; c=d["claude_opus"]
    print(f'_CIN={c["in"]} _COUT={c["out"]} _GIN={g["in"]} _GOUT={g["out"]}')
except Exception: pass
PY
)"
fi
# Last-resort fallbacks, used only when prices.json or python3 is unavailable. Keep them
# in step with prices.json — a stale hardcoded rate here quotes a wrong number in exactly
# the situation where nobody can see where it came from.
CLAUDE_IN_PER_M="${CLAUDE_IN_PER_M:-${_CIN:-4}}"
CLAUDE_OUT_PER_M="${CLAUDE_OUT_PER_M:-${_COUT:-20}}"
GEMINI_IN_PER_M="${GEMINI_IN_PER_M:-${_GIN:-0.75}}"
GEMINI_OUT_PER_M="${GEMINI_OUT_PER_M:-${_GOUT:-3.75}}"
CPT="${CHARS_PER_TOKEN:-4}"
case "$CPT" in ''|*[!0-9]*) CPT=4 ;; esac   # must be a positive integer (avoid awk div-by-zero)
[ "$CPT" -gt 0 ] || CPT=4

IN_CHARS=${#PROMPT}
OUT_CHARS=${#OUT}

awk -v ic="$IN_CHARS" -v oc="$OUT_CHARS" -v cpt="$CPT" \
    -v cin="$CLAUDE_IN_PER_M" -v cout="$CLAUDE_OUT_PER_M" \
    -v gin="$GEMINI_IN_PER_M" -v gout="$GEMINI_OUT_PER_M" \
    -v el="$ELAPSED" 'BEGIN {
  it = ic / cpt; ot = oc / cpt;
  cc = it*cin/1e6 + ot*cout/1e6;
  gc = it*gin/1e6 + ot*gout/1e6;
  save = cc - gc;
  ratio = (gc > 0) ? cc / gc : 0;
  printf "\n--- estimated (chars/%d), NOT billing-accurate ---\n", cpt;
  printf "input  ~%d tokens (%d chars)\n", it, ic;
  printf "output ~%d tokens (%d chars)\n", ot, oc;
  printf "elapsed: %ds\n\n", el;
  printf "%-14s %12s %12s\n", "deck", "in $/1M", "out $/1M";
  printf "%-14s %12.2f %12.2f\n", "Claude", cin, cout;
  printf "%-14s %12.2f %12.2f\n\n", "Gemini Flash", gin, gout;
  printf "if priced as Claude: $%.6f\n", cc;
  printf "actual on Gemini   : $%.6f\n", gc;
  printf "saved on this task : $%.6f  (%.1fx cheaper)\n", save, ratio;
  printf "NOTE: real saving is larger — orchestrator Claude handles far fewer tokens.\n";
}'

echo ""
echo "----- agy output -----"
printf '%s\n' "$OUT"
