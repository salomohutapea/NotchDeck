#!/bin/sh
# NotchDeck build wrapper (ndrun) v1
# Usage: ndrun <command> [args...]      e.g. ndrun xcodebuild -scheme App build
# Runs the command unchanged (live output, exit code preserved) and reports start/finish
# to the NotchDeck app through JSON records in the spool directory.
# Override the spool dir with NOTCHDECK_SPOOL.

if [ $# -eq 0 ]; then
  echo "usage: ndrun <command> [args...]" >&2
  exit 2
fi

SPOOL="${NOTCHDECK_SPOOL:-$HOME/Library/Application Support/NotchDeck/builds}"
mkdir -p "$SPOOL" 2>/dev/null
ESC=$(printf '\033')

now() {
  perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null || date +%s
}

# stdin -> JSON string body (no surrounding quotes), ANSI/control chars stripped.
json_str() {
  { iconv -c -f UTF-8 -t UTF-8 2>/dev/null || cat; } \
    | sed -e "s/${ESC}\[[0-9;?]*[ -\/]*[@-~]//g" -e "s/${ESC}[()][A-Za-z0-9]//g" \
    | tr -d '\000-\010\013-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
    | awk 'BEGIN{ORS=""} {if(NR>1)printf "\\n"; print}'
}

jstr() { printf '%s' "$1" | json_str; }

# write_record <file name> <json>  (atomic: temp file then rename)
write_record() {
  [ -d "$SPOOL" ] || return 0
  printf '%s\n' "$2" > "$SPOOL/.$1.tmp" 2>/dev/null && mv "$SPOOL/.$1.tmp" "$SPOOL/$1" 2>/dev/null
  return 0
}

id="$(date +%s)-$$"
cwd=$(pwd)
project=$(basename "$cwd")
title="$*"
[ ${#title} -gt 160 ] && title="$(printf '%s' "$title" | cut -c1-160)..."
started=$(now)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ndrun.XXXXXX" 2>/dev/null)
if [ -z "$tmp" ]; then
  tmp="${TMPDIR:-/tmp}/ndrun.$$"
  mkdir -p "$tmp"
fi
log="$tmp/log"
: > "$log"

common="\"v\":1,\"id\":\"$(jstr "$id")\",\"startId\":\"$(jstr "$id")\",\"source\":\"cli\",\"project\":\"$(jstr "$project")\",\"title\":\"$(jstr "$title")\",\"cwd\":\"$(jstr "$cwd")\",\"startedAt\":$started"
write_record "$id.start.json" "{$common,\"kind\":\"start\",\"pid\":$$}"

# Ctrl-C reaches the child too; keep the wrapper alive to report the result.
trap : INT

if [ -t 0 ] && [ -t 1 ] && command -v script >/dev/null 2>&1; then
  # Run inside a pty so the tool keeps its colours/progress UI.
  script -q "$log" "$@"
  rc=$?
else
  mkfifo "$tmp/out" "$tmp/err"
  tee -a "$log" < "$tmp/out" &
  p1=$!
  tee -a "$log" < "$tmp/err" >&2 &
  p2=$!
  "$@" > "$tmp/out" 2> "$tmp/err"
  rc=$?
  # Don't hang if the command left a background process holding the pipes.
  i=0
  while [ $i -lt 20 ] && { kill -0 $p1 2>/dev/null || kill -0 $p2 2>/dev/null; }; do
    sleep 0.1
    i=$((i + 1))
  done
  kill $p1 $p2 2>/dev/null
  wait $p1 $p2 2>/dev/null
fi

ended=$(now)
tailjson=""
if [ "$rc" -ne 0 ]; then
  tailjson=",\"tail\":\"$(tail -n 20 "$log" | json_str)\""
fi
write_record "$id.done.json" "{$common,\"kind\":\"done\",\"endedAt\":$ended,\"exit\":$rc$tailjson}"
rm -f "$tmp/out" "$tmp/err" "$log"
rmdir "$tmp" 2>/dev/null
exit "$rc"
