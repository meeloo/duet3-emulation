#!/bin/bash
# Runs INSIDE the Lima guest. Boots the emulator with its MAC bridged to tap0 and forwards to its HTTP port.
set -eu

EMU=/Users/smetrot/work/duet3/duet3-emulation
BOARD_IP=192.168.100.50
FORWARD_PORT=8080
RENODE_DIR="$HOME/renode-portable"
LAUNCH=/tmp/renode_launch.sh

pkill -f renode_launch 2>/dev/null || true
pkill -f 'Renode' 2>/dev/null || true
pkill -f "socat.*${FORWARD_PORT}" 2>/dev/null || true
sleep 1

# tap0 is created and addressed by setup_guest.sh; make sure the address survived a previous run.
sudo ip addr replace 192.168.100.1/24 dev tap0
sudo ip link set tap0 up

# Lima republishes guest ports bound to 0.0.0.0, so this surfaces as localhost:8080 on the Mac.
setsid nohup socat TCP-LISTEN:${FORWARD_PORT},fork,reuseaddr TCP:${BOARD_IP}:80 >/tmp/socat.log 2>&1 </dev/null &

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
    -e "\\\$fw=@${EMU}/build/firmware.bin" \\
    -e "\\\$elf=@${EMU}/build/firmware.elf" \\
    -e "\\\$plat=@${EMU}/platforms/duet3_mb6hc.repl" \\
    -e "include @${EMU}/scripts/networked.resc"
INNER
chmod +x "$LAUNCH"

# setsid, not just nohup: a process started through "limactl shell" belongs to that SSH session's
# process group and dies when the session ends, which silently took Renode down mid-boot.
setsid nohup "$LAUNCH" >/tmp/renode.log 2>&1 </dev/null &
echo "launched"
