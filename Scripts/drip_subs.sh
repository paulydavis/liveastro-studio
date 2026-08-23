#!/usr/bin/env bash
#
# drip_subs.sh — long-run repro harness for the live-watcher stall.
#
# The M8 all-nighter: LiveAstro's native FolderFrameSource quietly stopped detecting new files
# ~2h / 762 frames in (app idle, no data loss). The count-scale cause is ruled out (1500 files stack
# in 1.5s), so the stall is time- or environment-dependent — it needs a REAL long run to surface.
#
# This drips real FITS subs from SOURCE into DEST one at a time, ATOMICALLY (copy to a temp name in
# DEST, then rename into place — the watcher never sees a partial file), cycling the source list until
# COUNT files have been dripped. Point LiveAstro at DEST in "Raw subs (native stacking)" mode (prefix
# Light_) and let it run. The watcher heartbeat in the app log — "watcher alive: N polls, M tracked,
# E emitted" every 60s — localizes any stall:
#   * log stops advancing            -> the WATCHER died
#   * polls climb, emitted flatlines -> detection desynced
#   * emitted climbs, no snapshots   -> the CONSUMER (stacker) stalled
#
# To match the M8 conditions, put DEST on the SAME kind of folder the M8 run used — if that was the
# iCloud-synced Desktop, use a folder under ~/Desktop (the prime environment suspect).
#
# Usage: Scripts/drip_subs.sh <source-folder-of-.fit-subs> <dest-folder> [interval_sec=12] [count=900]
#   e.g. Scripts/drip_subs.sh ~/Desktop/M63-import ~/Desktop/livestack_live_repro 12 900
#   (900 subs x 12s = 3h — comfortably past the ~762-frame M8 stall point.)

set -euo pipefail

SOURCE="${1:?usage: drip_subs.sh <source-folder> <dest-folder> [interval_sec] [count]}"
DEST="${2:?usage: drip_subs.sh <source-folder> <dest-folder> [interval_sec] [count]}"
INTERVAL="${3:-12}"
COUNT="${4:-900}"

mkdir -p "$DEST"

shopt -s nullglob
subs=("$SOURCE"/*.fit "$SOURCE"/*.fits "$SOURCE"/*.FIT "$SOURCE"/*.FITS)
if [ ${#subs[@]} -eq 0 ]; then
    echo "drip_subs: no .fit/.fits subs found in $SOURCE" >&2
    exit 1
fi

echo "drip_subs: ${#subs[@]} source subs -> $DEST  (Light_NNNN.fit, every ${INTERVAL}s, up to $COUNT)"
echo "drip_subs: point LiveAstro at $DEST in 'Raw subs (native stacking)' mode, prefix Light_"

# Disk guard: the DEST folder ACCUMULATES every dripped file (like the real relay did on the M8 night),
# so total ≈ COUNT × sub-size. Warn before a multi-GB run so it can't silently fill the drive.
sub_bytes=$(stat -f%z "${subs[0]}" 2>/dev/null || echo 0)
est_gb=$(( COUNT * sub_bytes / 1024 / 1024 / 1024 ))
if [ "$est_gb" -ge 5 ]; then
    echo "drip_subs: WARNING — this will accumulate ~${est_gb} GB in $DEST ($COUNT × $(( sub_bytes / 1024 / 1024 )) MB subs)."
    echo "drip_subs:   Use smaller subs (e.g. a Seestar 8MP folder) or a lower count if disk is tight. Ctrl-C to abort."
    sleep 5
fi

for (( n = 1; n <= COUNT; n++ )); do
    src="${subs[$(( (n - 1) % ${#subs[@]} ))]}"
    name=$(printf "Light_%04d.fit" "$n")
    tmp="$DEST/.drip-$$-$n.tmp"
    cp "$src" "$tmp"
    mv "$tmp" "$DEST/$name"            # atomic appearance — no partial file for the watcher to trip on
    echo "$(date '+%H:%M:%S')  $name  ($n/$COUNT)"
    if [ "$n" -lt "$COUNT" ]; then sleep "$INTERVAL"; fi
done

echo "drip_subs: done — $COUNT subs dripped over ~$(( COUNT * INTERVAL / 3600 ))h"
