#!/usr/bin/env bash
#
# agy-job.sh — background-job layer over agy-delegate.sh, à la `codex --background`.
# For INTERACTIVE Claude Code sessions: fire a long delegation, keep working, then
# poll :status / fetch :result. (Headless `claude -p` is one-shot — use the wrapper
# synchronously there instead; there is no later turn to collect the result.)
#
# Usage:
#   agy-job.sh start  [agy-delegate options] "task"   # -> prints a JOB_ID, returns now
#   agy-job.sh list                                    # jobs started from this dir
#   agy-job.sh status <id>                             # running | done(rc) | failed
#   agy-job.sh result <id>                             # print stdout (+rc) when finished
#   agy-job.sh cancel <id>                             # terminate a running job
#
# Jobs live under ${ANTIGRAVITY_JOBS:-~/.antigravity-jobs}/<id>/ (out, err, rc, meta).
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DELEGATE="${AGY_DELEGATE:-$HERE/agy-delegate.sh}"
REG="${ANTIGRAVITY_JOBS:-$HOME/.antigravity-jobs}"

die() { echo "agy-job: $*" >&2; exit 1; }

# True on native Windows (Git Bash / MSYS / Cygwin). Mirrors agy-delegate.sh.
on_windows_native() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

# MSYS/Cygwin pids are NOT Windows pids: `taskkill /PID` cannot use the number in
# $jd/pid. `ps -l` exposes the native pid in its WINPID column.
winpid() {
  ps -p "$1" -l 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4; exit }'
}

# resolve a (possibly abbreviated) id to a job dir.
# Callers run this inside `$(...)`, so `die` only leaves the SUBSHELL: the parent kept
# going with jd="" and job_state "" rendered `state=failed` for an id that never existed
# (#96). Every call site therefore reads `jd="$(jobdir ...)" || exit 1`.
jobdir() {
  [ -n "${1:-}" ] || die "need a job id"
  if [ -d "$REG/$1" ]; then echo "$REG/$1"; return; fi
  local hits; hits=$(ls -d "$REG/$1"* 2>/dev/null)
  [ -n "$hits" ] || die "no such job: $1"
  [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || die "ambiguous id '$1'"
  echo "$hits"
}

# `kill -0` succeeds on a ZOMBIE too. A cancelled job's runner is reparented to PID 1, and
# where PID 1 does not reap (a container without an init, e.g. `docker run` without
# --init) it stays a zombie for good — so `status` said `running` forever after a cancel.
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in *Z*) return 1 ;; esac
  return 0
}

# Every descendant of pid $1, one per line. Collected from ONE `ps` snapshot BEFORE
# anything is killed: once a parent dies its children are reparented to PID 1 and can no
# longer be found from the job's pid.
descendants() {
  { ps -A -o pid= -o ppid= 2>/dev/null || ps -l 2>/dev/null | awk 'NR>1 {print $1, $2}'; } | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      q = root
      while (q != "") {
        n = split(q, cur, " "); q = ""
        for (i = 1; i <= n; i++) {
          m = split(kids[cur[i]], k, " ")
          for (j = 1; j <= m; j++) { print k[j]; q = q " " k[j] }
        }
      }
    }'
}

# Kill a job's whole tree. On Windows, MSYS `ps` only lists MSYS processes, so the native
# agy/conhost children were invisible and survived cancel. `taskkill /T` walks the native
# process tree from the wrapper's WINPID; POSIX keeps the snapshot-then-kill approach.
kill_tree() { # $1 = job pid (MSYS pid on Windows)
  local pid="$1" wpid
  [ -n "$pid" ] || return 0
  if on_windows_native && command -v taskkill >/dev/null 2>&1; then
    wpid="$(winpid "$pid")"
    if [ -n "$wpid" ]; then
      # Snapshot first: taskkill can take the wrapper down before we look for MSYS kids.
      local msys_kids
      msys_kids="$(descendants "$pid")"
      # MSYS path conversion would turn /F into F:\; disable it for taskkill only.
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
        taskkill /F /T /PID "$wpid" >/dev/null 2>&1 || true
      # taskkill sees only native parent links. MSYS processes it missed are still
      # visible to `ps`, so send them the old POSIX signal too.
      # shellcheck disable=SC2086  # one pid per word is the point
      kill $msys_kids 2>/dev/null || true
      return 0
    fi
  fi
  # shellcheck disable=SC2046  # one pid per word is the point
  kill "$pid" $(descendants "$pid") 2>/dev/null || true
}

# echoes running | done | failed. (rc is read directly from the file by callers —
# a global set here would NOT survive the `$(job_state ...)` command-substitution subshell.)
job_state() {
  local jd="$1" rc started now age
  if [ -f "$jd/rc" ]; then
    rc="$(cat "$jd/rc")"
    if [ "$rc" = "0" ]; then echo "done"; else echo "failed"; fi
  elif [ -f "$jd/pid" ] && alive "$(cat "$jd/pid")"; then
    echo running
  elif [ ! -f "$jd/pid" ] && [ -f "$jd/meta" ]; then
    # `start` spawns the runner and only then can it write $! — a status call landing in
    # that window found neither rc nor pid and called a live job "failed". The meta file
    # records when the job started; a pid-less job younger than the grace period is still
    # starting. After that it really did crash before recording anything.
    started="$(sed -n 's/^started_epoch=//p' "$jd/meta" 2>/dev/null | head -1)"
    case "$started" in *[!0-9]*|'') started="" ;; esac
    if [ -n "$started" ]; then
      now="$(date +%s 2>/dev/null || echo 0)"
      age=$(( now - started ))
      if [ "$age" -ge 0 ] && [ "$age" -lt 10 ]; then echo running; return 0; fi
    fi
    echo failed
  else
    echo failed   # pid gone, no rc recorded = crashed/killed
  fi
}

# Human label for a delegate / hand-off exit code (mirrors agy-delegate.sh / agy-handoff.sh codes).
rc_label() {
  case "$1" in
    0)  echo 'ok' ;;
    2)  echo 'agy failed' ;;
    3)  echo 'empty output' ;;
    4)  echo 'VERIFY failed — tests still red after the allowed fix-ups (agy-handoff)' ;;
    6)  echo 'TESTS modified — a protected --tests file was edited by the executor (agy-handoff)' ;;
    10) echo 'QUOTA — retry later with --continue' ;;
    11) echo 'AUTH required — run `agy` once interactively' ;;
    12) echo 'TIMEOUT — raise --timeout or narrow scope (agy 1.1.28+: the PARTIAL reply is in the output; --continue resumes the conversation)' ;;
    13) echo 'agy MISSING — install the Antigravity CLI' ;;
    14) echo 'MODEL unavailable — check `agy models` / tier remap' ;;
    # Both denial shapes: the soft deny (agy 1.1.3+, and again from 1.1.20) and 1.1.13's hard error.
    15) echo 'PERMISSION denied (soft on 1.1.3+, a hard error by 1.1.13, soft again from 1.1.20; named in denied_actions since 1.1.27) — add a permissions.allow rule, or --yolo' ;;
    *)  echo 'error' ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  start)
    [ $# -ge 1 ] || die "start needs delegate args, e.g.  start --tier pro \"task\""
    [ -x "$DELEGATE" ] || die "delegate not executable: $DELEGATE"
    id="$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"
    jd="$REG/$id"; mkdir -p "$jd"
    if [ "${!#:-}" = "-" ]; then
      cat > "$jd/prompt"
      task_desc="$(head -n 5 "$jd/prompt" | tr '\n' ' ' | cut -c1-200)"
      { echo "id=$id"; echo "cwd=$PWD"; echo "started=$(date -u +%FT%TZ 2>/dev/null || date)";
        echo "started_epoch=$(date +%s 2>/dev/null || echo 0)";
        echo "task=${task_desc:-stdin}"; } > "$jd/meta"
      ( nohup "$DELEGATE" "$@" < "$jd/prompt" >"$jd/out" 2>"$jd/err"; echo $? >"$jd/rc"; rm -f "$jd/prompt" ) >/dev/null 2>&1 &
      job_pid=$!
    else
      { echo "id=$id"; echo "cwd=$PWD"; echo "started=$(date -u +%FT%TZ 2>/dev/null || date)";
        echo "started_epoch=$(date +%s 2>/dev/null || echo 0)";
        echo "task=$(printf '%s' "${!#}" | tr '\n' ' ' | cut -c1-200)"; } > "$jd/meta"
      ( nohup "$DELEGATE" "$@" >"$jd/out" 2>"$jd/err"; echo $? >"$jd/rc" ) >/dev/null 2>&1 &
      job_pid=$!
    fi
    # Atomic replace: a reader never sees a half-written pid, and job_state's grace
    # window covers the instant between spawn and this write.
    printf '%s\n' "$job_pid" > "$jd/pid.tmp" && mv -f "$jd/pid.tmp" "$jd/pid"
    disown 2>/dev/null || true
    echo "$id"
    ;;
  list)
    [ -d "$REG" ] || { echo "(no jobs)"; exit 0; }
    found=0
    for jd in "$REG"/*/; do
      [ -d "$jd" ] || continue
      cwd="$(sed -n 's/^cwd=//p' "$jd/meta" 2>/dev/null)"
      [ "${ALL:-0}" = "1" ] || [ "$cwd" = "$PWD" ] || continue
      found=1
      st="$(job_state "$jd")"
      printf '%-32s %-8s %s\n' "$(basename "$jd")" "$st" \
        "$(sed -n 's/^task=//p' "$jd/meta" 2>/dev/null)"
    done
    [ "$found" = "1" ] || echo "(no jobs for $PWD — set ALL=1 to see all)"
    ;;
  status)
    jd="$(jobdir "${1:-}")" || exit 1; st="$(job_state "$jd")"
    rc="$(cat "$jd/rc" 2>/dev/null || true)"
    pid="$(cat "$jd/pid" 2>/dev/null || echo '')"
    last_output=""
    if [ -f "$jd/out" ]; then
      last_output="$(date -u -r "$jd/out" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || stat -c %y "$jd/out" 2>/dev/null || echo '')"
    fi
    [ -z "$last_output" ] && last_output="$(sed -n 's/^started=//p' "$jd/meta" 2>/dev/null || echo 'unknown')"
    echo "status:      $st"
    [ -n "$pid" ] && echo "pid:         $pid"
    echo "last_output: $last_output"
    echo "job:    $(basename "$jd")"
    sed 's/^/  /' "$jd/meta" 2>/dev/null
    if [ -n "$rc" ]; then echo "  state=$st (rc=$rc: $(rc_label "$rc"))"; else echo "  state=$st"; fi
    sig="$(grep -m1 '^AGY_SIGNAL ' "$jd/err" 2>/dev/null || true)"
    if [ -n "$sig" ]; then echo "  signal=${sig#AGY_SIGNAL }"; fi
    ;;
  result)
    jd="$(jobdir "${1:-}")" || exit 1; st="$(job_state "$jd")"
    if [ "$st" = "running" ]; then echo "still running — try again later"; exit 2; fi
    rc="$(cat "$jd/rc" 2>/dev/null || true)"
    [ -s "$jd/err" ] && { echo "----- stderr -----" >&2; cat "$jd/err" >&2; }
    cat "$jd/out" 2>/dev/null
    echo "[exit rc=${rc:-?}${rc:+: $(rc_label "$rc")}]" >&2
    ;;
  cancel)
    jd="$(jobdir "${1:-}")" || exit 1
    pid="$(cat "$jd/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && alive "$pid"; then
      # The WHOLE tree, not just direct children: `pkill -P` reached the wrapper but not
      # `timeout` and agy under it — GNU timeout puts itself in its own process group, so
      # they kept running (a hand-off's --yolo executor kept editing the repository).
      # On Windows that tree also crosses into native processes MSYS `ps` cannot see, so
      # kill_tree escalates to taskkill /T using the wrapper's WINPID.
      kill_tree "$pid"
      ilog="${INCIDENT_LOG:-${CLAUDE_PLUGIN_OPTION_INCIDENT_LOG:-}}"
      if [ "${2:-}" = "--incident-log" ] && [ -n "${3:-}" ]; then
        ilog="$3"
      fi
      if [ -n "$ilog" ]; then
        utctime="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u)"
        mkdir -p "$(dirname "$ilog")" 2>/dev/null || true
        cat >> "$ilog" <<EOF

## $utctime — agy — agy-job cancel $1
- Loại: killed_process
- Đã làm: agy-job cancel $1
- Kết quả: process $pid killed
- Xử lý: terminated process tree
- Gợi ý sửa: job cancelled by caller
EOF
      fi
      echo "cancelled $(basename "$jd")"
    else
      echo "not running"
    fi
    ;;
  ""|-h|--help|help)
    sed -n '/^# Usage:/,/^# Jobs live/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$cmd' (start|list|status|result|cancel)" ;;
esac
