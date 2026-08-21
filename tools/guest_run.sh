#!/bin/bash
# Runs INSIDE the Lima guest. Boots the emulator with its MAC bridged to tap0 and forwards to its HTTP port.
set -eu

EMU=/Users/smetrot/work/duet3/duet3-emulation
BOARD_IP=192.168.100.50
FORWARD_PORT=8080
RENODE_DIR="$HOME/renode-portable"
LAUNCH="$HOME/renode_launch.sh"

# Logs go to $HOME, not /tmp: /tmp is a 2.9GB tmpfs in the Lima guest and an unbounded Renode log
# filled it completely, which then broke every later step with confusing "no space left" errors.

# Kill previous instances properly. This used to be pkill -f 'Renode' with a capital R, which never
# matched "./renode" - so old instances survived, kept tap0 open, and went on answering HTTP with
# stale firmware while the new instance sat there unable to attach. Symptom: served responses
# containing strings that are provably not in the binary you just built.
pkill -f renode_launch 2>/dev/null || true
pkill -x renode 2>/dev/null || true
pkill -f '\./renode' 2>/dev/null || true
pkill -f "socat.*${FORWARD_PORT}" 2>/dev/null || true
sleep 2
if pgrep -x renode >/dev/null 2>&1; then
    echo "WARNING: renode still running after kill:" >&2
    pgrep -a -x renode >&2
    exit 1
fi

# tap0 is created and addressed by setup_guest.sh; make sure the address survived a previous run.
# The SD image must be writable for persistent=true, and Lima mounts the home directory read-only -
# opening it read-write fails and takes Renode down with a fatal I/O error. Work on a guest-local copy.
GUEST_SD="$HOME/sdcard.img"
if [ -f "$EMU/build/sdcard.img" ]; then
    [ -f "$GUEST_SD" ] || cp "$EMU/build/sdcard.img" "$GUEST_SD"
fi

sudo ip addr replace 192.168.100.1/24 dev tap0
sudo ip link set tap0 up

# Lima republishes guest ports bound to 0.0.0.0, so this surfaces as localhost:8080 on the Mac.
setsid nohup socat TCP-LISTEN:${FORWARD_PORT},fork,reuseaddr TCP:${BOARD_IP}:80 >"$HOME/socat.log" 2>&1 </dev/null &

# Generated rather than inlined: the launcher needs ${EMU} expanded now but Renode's own $variables
# left alone, which is fiddly to get right inside nested quoting - this went wrong twice.
cat > "$LAUNCH" <<INNER
#!/bin/sh
cd "$RENODE_DIR"
# stdin must stay open: in --console mode Renode exits on EOF, so a /dev/null redirect makes it boot,
# run, and vanish in a way that looks exactly like a crash.
exec tail -f /dev/null | ./renode --disable-xwt --console \\
    -e "\\\$tcmodel=@${EMU}/peripherals/SAME70_TimerCounter.cs" \\
    -e "\\\$piomodel=@${EMU}/peripherals/SAME70_ParallelIO.cs" \\
    -e "\\\$afecmodel=@${EMU}/peripherals/SAME70_AnalogFrontEnd.cs" \\
    -e "\\\$xdmacmodel=@${EMU}/peripherals/SAME70_Xdmac.cs" \\
    -e "\\\$hsmcimodel=@${EMU}/peripherals/SAME70_Hsmci.cs" \\
    -e "\\\$rstcmodel=@${EMU}/peripherals/SAME70_ResetController.cs" \\
    -e "\\\$sd=@$GUEST_SD" \\
    -e "\\\$fw=@${EMU}/build/firmware_sd.bin" \\
    -e "\\\$elf=@${EMU}/build/firmware_sd.elf" \\
    -e "\\\$plat=@${EMU}/platforms/duet3_mb6hc.repl" \\
    -e "include @${EMU}/scripts/networked.resc"
INNER
chmod +x "$LAUNCH"

# setsid, not just nohup: a process started through "limactl shell" belongs to that SSH session's
# process group and dies when the session ends, which silently took Renode down mid-boot.
setsid nohup "$LAUNCH" >"$HOME/renode.log" 2>&1 </dev/null &
echo "launched"

# Leaving socat up after Renode exits makes port 8080 look open while nothing is behind it, which
# reads as "the board is unreachable" rather than "the board is not running".
( sleep 5
  while pgrep -x renode >/dev/null 2>&1; do sleep 10; done
  pkill -f "socat.*${FORWARD_PORT}" 2>/dev/null || true ) >/dev/null 2>&1 &
