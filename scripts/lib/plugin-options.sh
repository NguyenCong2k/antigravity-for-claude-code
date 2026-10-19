#!/usr/bin/env bash
# Shared loader for Claude Code plugin options (#101).
#
# Claude Code injects userConfig options as CLAUDE_PLUGIN_OPTION_* into HOOKS only,
# never into Bash-tool subshells. Sourced by scripts/agy-delegate.sh, scripts/doctor.sh,
# and scripts/agy-cost-compare.sh so options set under:
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
#     -> .pluginConfigs["antigravity@antigravity-for-claude-code"].options
# work everywhere without a duplicate env block. Explicit CLAUDE_PLUGIN_OPTION_*
# environment variables always win.
#
# IMPORTANT: Do NOT put single quotes or apostrophes inside the python3 -c block
# below — tests/check-embedded-python.py enforces that single-quoted python3 -c
# strings are never prematurely terminated by an apostrophe in code or comments.

load_plugin_options() {
  local cfg="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json" out
  if [ ! -f "$cfg" ] || ! command -v python3 >/dev/null 2>&1; then return 0; fi
  out="$(python3 -c '
import json, os, re, shlex, sys
try:
    pc = (json.load(open(sys.argv[1], encoding="utf-8")) or {}).get("pluginConfigs") or {}
except Exception:
    sys.exit(0)
if not isinstance(pc, dict):
    sys.exit(0)
entry = pc.get("antigravity@antigravity-for-claude-code") or pc.get("antigravity")
if not isinstance(entry, dict):
    for k, v in pc.items():
        if isinstance(k, str) and k.startswith("antigravity@") and isinstance(v, dict):
            entry = v
            break
opts = (entry or {}).get("options") if isinstance(entry, dict) else None
if not isinstance(opts, dict):
    sys.exit(0)
for k, v in opts.items():
    if not isinstance(k, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
        continue
    if v is None or isinstance(v, (dict, list)):
        continue
    s = ("true" if v else "false") if isinstance(v, bool) else str(v)
    if s == "":
        continue
    var = "CLAUDE_PLUGIN_OPTION_" + k.upper()
    if not os.environ.get(var):
        print("export %s=%s" % (var, shlex.quote(s)))
' "$cfg" 2>/dev/null || true)"
  if [ -n "$out" ]; then eval "$out"; fi
}
