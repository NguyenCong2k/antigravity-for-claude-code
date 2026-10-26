#!/usr/bin/env bash
#
# SessionStart hook: inject this plugin's COST-AWARE routing policy as session
# context, so the discipline (delegate above the break-even, keep Claude's context
# lean, always verify agy's output) applies even when the `antigravity` skill isn't
# explicitly invoked. Prints the hookSpecificOutput JSON on stdout.
#
# Toggle off via plugin userConfig `inject_policy` (or legacy `coding_policy`;
# env CLAUDE_PLUGIN_OPTION_INJECT_POLICY / CLAUDE_PLUGIN_OPTION_CODING_POLICY:
# off / false / 0 / no / disabled). Default: on. Re-injected on compact if enabled.
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

opt="${CLAUDE_PLUGIN_OPTION_INJECT_POLICY:-${CLAUDE_PLUGIN_OPTION_CODING_POLICY:-on}}"
raw="$(printf '%s' "$opt" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$raw" in
  off|false|0|no|disabled) exit 0 ;;
esac

cat "$HERE/policy-context.json"
exit 0
