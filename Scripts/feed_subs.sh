#!/bin/bash
# Feeds real sub-exposures into a Siril livestack watch folder, one every N seconds,
# simulating a camera capturing live. Usage: feed_subs.sh <source_dir> <watch_dir> [interval] [count]
SRC="${1:?source dir}"; DST="${2:?watch dir}"; INTERVAL="${3:-8}"; COUNT="${4:-100}"
i=0
find "$SRC" -maxdepth 1 -name '*.fit' | sort | head -n "$COUNT" | while read -r f; do
  i=$((i+1))
  cp "$f" "$DST/"
  echo "feed: $i/$COUNT  $(basename "$f")"
  sleep "$INTERVAL"
done
echo "feed: done"
