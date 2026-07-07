#!/bin/bash
# Relays new sub-exposures from the Seestar SMB share to a local folder for
# Siril livestacking.
#
# Delivery pattern proven on the 2026-07-06 NGC 7000 night:
#   1. Slow SMB pull into a staging dir OUTSIDE the watch folder, then a fast
#      local cp into it. Siril reacts to create events; a local-SSD cp
#      completes before Siril starts reading, so it never sees a partial file.
#      (Copying straight from SMB into the watch folder made Siril read
#      truncated FITS; rsync temp+rename delivery was invisible to it; mv was
#      rejected outright.)
#   2. Optional MARKER: only relay files whose names sort AFTER it. Lets you
#      skip an earlier part of the night (e.g. foggy subs before you reseeded).
#
# Usage: seestar_relay.sh <seestar_sub_dir> <local_watch_dir> [poll_seconds] [marker]
#   marker: a filename (or any prefix); only names sorting strictly after it relay.
SRC="${1:?seestar sub dir (e.g. ~/seestar_mnt/MyWorks/NGC 7000_sub)}"
DST="${2:?local watch dir (e.g. ~/Desktop/livestack_live)}"
POLL="${3:-5}"
MARKER="${4:-}"

mkdir -p "$DST"
STAGE=$(mktemp -d /tmp/seestar_relay.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
count=0
echo "relay: $SRC -> $DST via $STAGE (every ${POLL}s, Ctrl+C to stop)"
[ -n "$MARKER" ] && echo "relay: skipping names <= $MARKER"
while true; do
  for f in "$SRC"/*.fit; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    [[ -z "$MARKER" || "$name" > "$MARKER" ]] || continue
    if [ ! -e "$DST/$name" ]; then
      if cp "$f" "$STAGE/$name" && cp "$STAGE/$name" "$DST/$name"; then
        rm -f "$STAGE/$name"
        count=$((count + 1))
        echo "relayed: $name ($count total)"
      else
        rm -f "$STAGE/$name" "$DST/$name"
        echo "retry next poll: $name (partial SMB read?)"
      fi
    fi
  done
  sleep "$POLL"
done
