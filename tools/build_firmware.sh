#!/bin/bash
# Build the emulator's firmware image: compile, embed the filesystem, append the CRC.
#
# The order matters and is not interchangeable. A USE_EMBEDDED_FILES image links with
# _firmware_crc == _firmware_end, so vector slot 7 initially points at where the filesystem is about
# to go; BuildEmbeddedFiles.py appends the files and moves that slot past them, and only then can
# CrcAppender.py checksum the right extent. Both refuse to run if the slot is not where they expect.
#
# Output goes under the project rather than /tmp so that a Lima guest, which mounts the home
# directory, can read it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RRF="$(cd "$HERE/../RepRapFirmware" && pwd)"
TOOLCHAIN="${TOOLCHAIN:-/Applications/ArmGNUToolchain/15.3.rel1/arm-none-eabi/bin/arm-none-eabi-}"
OUT="$HERE/build"

mkdir -p "$OUT"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "== compiling"
    make -C "$RRF" Duet3_MB6HC_embedded CROSS_COMPILE="$TOOLCHAIN" -j8 | tail -3
fi

cp "$RRF/Duet3_MB6HC_embedded/Duet3Firmware_MB6HC_embedded.bin" "$OUT/firmware.bin"
cp "$RRF/Duet3_MB6HC_embedded/Duet3Firmware_MB6HC_embedded.elf" "$OUT/firmware.elf"

echo "== embedding $HERE/files"
python3 "$RRF/Scripts/BuildEmbeddedFiles.py" "$OUT/firmware.bin" "$HERE/files"
echo "== crc"
python3 "$RRF/Scripts/CrcAppender.py" "$OUT/firmware.bin"

echo
echo "ready: $OUT/firmware.bin"
