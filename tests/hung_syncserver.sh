#!/bin/sh
# A stand-in for /app/bin/syncserver whose graceful shutdown never ends, as syncstorage-rs's
# sometimes does: it answers /__heartbeat__ and ignores SIGTERM (tests/e2e.sh, the migrations
# step must still end, killing it)
trap '' TERM
cd "$(mktemp -d)" && touch __heartbeat__ && exec python3 -m http.server 8000 > /dev/null 2>&1
