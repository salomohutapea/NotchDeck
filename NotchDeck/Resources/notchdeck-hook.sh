#!/bin/sh
# NotchDeck hook forwarder. Usage: notchdeck-hook.sh <claude|codex>
# Reads the hook JSON from stdin and forwards it to the NotchDeck app in the
# background. Prints nothing (Claude adds hook stdout to the model context) and
# always exits 0, even when NotchDeck is not running.
agent="${1:-claude}"
payload=$(cat 2>/dev/null)
(
  printf '%s' "$payload" | curl -s -m 1 -X POST --data-binary @- \
    "http://127.0.0.1:${NOTCHDECK_PORT:-47474}/hook?agent=$agent" \
    >/dev/null 2>&1 &
) >/dev/null 2>&1
exit 0
