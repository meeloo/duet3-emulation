#!/bin/bash
# Boot the emulator inside the Lima guest with host-reachable networking. Run this from macOS.
set -euo pipefail
limactl shell duet -- bash /Users/smetrot/work/duet3/duet3-emulation/tools/guest_run.sh
echo "board 192.168.100.50; from macOS try: curl -s http://localhost:8080/rr_connect?password="
