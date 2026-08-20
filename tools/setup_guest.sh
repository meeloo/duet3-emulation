#!/bin/bash
# Set up the Lima guest to run the emulator with real host-reachable networking.
#
# Renode needs a layer-2 TAP interface to put the emulated board on a network. macOS has no TAP
# (utun is layer 3 and third-party kexts do not load on Apple Silicon), which is the entire reason
# this VM exists. Linux has /dev/net/tun built in.
#
# Topology:
#   board 192.168.100.50  <-- emulated GMAC --> tap0 192.168.100.1 (guest)
#   guest 0.0.0.0:8080 --socat--> 192.168.100.50:80
#   Lima forwards guest 8080 to the host, so the Mac reaches DWC at localhost:8080.
set -euo pipefail

RENODE_VERSION=1.16.1
RENODE_TARBALL="renode-${RENODE_VERSION}.linux-arm64-portable-dotnet.tar.gz"
RENODE_URL="https://github.com/renode/renode/releases/download/v${RENODE_VERSION}/${RENODE_TARBALL}"
RENODE_DIR="$HOME/renode-portable"

echo "== packages"
sudo apt-get update -qq
sudo apt-get install -y -qq socat iproute2 python3 >/dev/null

echo "== renode"
if [ ! -d "$RENODE_DIR" ]; then
    mkdir -p "$RENODE_DIR"
    curl -sSL "$RENODE_URL" | tar xz -C "$RENODE_DIR" --strip-components=1
fi
"$RENODE_DIR/renode" --version

echo "== tap0"
if ! ip link show tap0 >/dev/null 2>&1; then
    sudo ip tuntap add dev tap0 mode tap user "$(id -un)"
fi
sudo ip addr replace 192.168.100.1/24 dev tap0
sudo ip link set tap0 up
ip -brief addr show tap0

echo
echo "tap0 is up. Renode can now attach to it with:"
echo "    emulation CreateTap \"tap0\" \"tap\""
echo "    connector Connect gem tap"
