#!/bin/bash
# Build a FAT32 SD card image from files/ for the emulated HSMCI.
#
# Assembled inside the Lima guest: macOS has no mkfs.vfat or mtools by default, and Lima mounts the
# home directory read-only, so the image is built in the guest and copied back out.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$HERE/build/sdcard.img"
GUEST_IMG="/tmp/sdcard.img"
SIZE_MB="${SIZE_MB:-64}"

mkdir -p "$HERE/build"

cat > "$HERE/build/_mksd_guest.sh" <<INNER
#!/bin/bash
set -euo pipefail
command -v mkfs.vfat >/dev/null || sudo apt-get install -y -qq dosfstools mtools >/dev/null
command -v mcopy     >/dev/null || sudo apt-get install -y -qq mtools >/dev/null

rm -f '$GUEST_IMG'
dd if=/dev/zero of='$GUEST_IMG' bs=1M count=${SIZE_MB} status=none
mkfs.vfat -F 32 -n DUET '$GUEST_IMG' >/dev/null

export MTOOLS_SKIP_CHECK=1
cd '$HERE/files'

# Null-delimited: macro names contain spaces, and word splitting silently dropped them.
find . -mindepth 1 -type d -print0 | while IFS= read -r -d '' d; do
    mmd -i '$GUEST_IMG' "::/\${d#./}"
done
find . -type f -print0 | while IFS= read -r -d '' f; do
    mcopy -i '$GUEST_IMG' "\$f" "::/\${f#./}"
done

echo '--- contents:'
mdir -i '$GUEST_IMG' -/ :: | head -25
INNER

limactl shell duet -- bash "$HERE/build/_mksd_guest.sh"
limactl copy "duet:$GUEST_IMG" "$IMG"
echo
echo "ready: $IMG  ($(du -h "$IMG" | cut -f1))"
