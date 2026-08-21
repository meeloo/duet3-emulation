#!/bin/bash
# Fetch the SAME70 SVD that the platform description applies.
#
# Not committed: it is Microchip's register description, redistributed by Antmicro for Renode's use,
# and this project has no clear right to redistribute it. Renode can also pull it from the URL at run
# time, but that re-downloads ~6MB on every fresh start and killed the emulator mid-boot once, so a
# local copy is worth it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/platforms/ATSAME70Q21.svd"
if [ -f "$DEST" ]; then
    echo "already present: $DEST"
    exit 0
fi
curl -sSL -o "$DEST" "https://dl.antmicro.com/projects/renode/svd/ATSAME70Q21.svd"
echo "fetched: $DEST"
