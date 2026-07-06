#!/bin/bash
# Relays new sub-exposures from the Seestar SMB share to a local folder for
# Siril livestacking. SMB is too unreliable to watch directly; local disk isn't.
# Usage: seestar_relay.sh <seestar_sub_dir> <local_watch_dir> [poll_seconds]
SRC="${1:?seestar sub dir (e.g. /Volumes/Seestar/MyWorks/NGC 7000_sub)}"
DST="${2:?local watch dir (e.g. ~/Desktop/livestack_live)}"
POLL="${3:-5}"
mkdir -p "$DST"
echo "relay: $SRC -> $DST (every ${POLL}s, Ctrl+C to stop)"
while true; do
  rsync -a --ignore-existing --include='*.fit' --exclude='*' "$SRC/" "$DST/" 2>/dev/null
  count=$(ls "$DST"/*.fit 2>/dev/null | wc -l | tr -d ' ')
  printf "\rrelay: %s subs relayed  " "$count"
  sleep "$POLL"
done
