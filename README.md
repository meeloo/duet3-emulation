# Duet emulation on Renode

Emulating Duet control boards well enough to run real RepRapFirmware images, so that firmware
behaviour — motion above all — can be observed and asserted without hardware.

Target board today is the **Duet 3 Mainboard 6HC (ATSAME70Q20B)**. The structure is meant to extend to
the Mini 5+ (SAME54), MB6XD and Duet 2 (SAM4E) later.

## Status

RepRapFirmware 3.7.0-beta.3 boots, initialises FreeRTOS, and reaches `StepTimer::Init()`.

It stops there, spinning on `TC0:CV0`: the timer/counter is not modelled, so the step clock never
advances and the firmware waits forever for time to pass. **Writing the SAME70 TC model is the next
step**, and it is also the highest-value one — the step clock is what motion is measured against.

Getting this far needed three fixes, each found by letting the firmware fail and reading the log:

| Symptom | Cause |
|---|---|
| 3-blink loop in `AppMain` | The `.bin` had no firmware CRC. `Makefiles/*.mk` append one only `if command -v CrcAppender`, and it was not installed. See `RepRapFirmware/Scripts/CrcAppender.py`. |
| `CPU abort: MPU: Trying to use non-existent MPU region ... faulting region number: 8` | Renode's `CPU.CortexM` defaults to 8 MPU regions; the SAME70's Cortex-M7 has 16 and RepRapFirmware configures region 8. |
| Boot appeared to work but hid stray accesses | Stock `sam_e70.repl` declares 256MB catch-all memories at 0x0 and 0x20000000. Replaced with the real Q20B map. |

## Peripherals the firmware actually touches

Measured, not guessed — from `boot.log` over 0.3 emulated seconds:

| Peripheral | Accesses | State |
|---|---|---|
| TC0 | 892 | **stub — the current blocker** |
| PMC | 44 | status register faked by an inline Python flipflop |
| PIOA / PIOD / PIOB / PIOC | 121 | SVD stub; needed to observe STEP/DIR |
| XDMAC | 10 | SVD stub |
| AFEC0 / AFEC1 | 16 | SVD stub |
| EFC, MATRIX, RSTC | 11 | SVD stub; reset values appear to be enough |

Anything not listed is not reached yet, so it does not need writing yet.

## Layout

    platforms/   .repl platform descriptions
    scripts/     .resc run scripts
    peripherals/ C# peripheral models (empty until the TC model lands)

## Running

Renode is not installed system-wide; the portable macOS build is unpacked in the session scratchpad.
To install it properly: `brew install --cask renode`.

`.repl` and `.resc` paths inside Renode resolve relative to the Renode directory, hence the `cd`:

```sh
RENODE=/path/to/Renode.app/Contents/MacOS
EMU=/Users/smetrot/work/duet3/duet3-emulation
FW=/Users/smetrot/work/duet3/RepRapFirmware/Duet3_MB6HC

cp $FW/Duet3Firmware_MB6HC.bin /tmp/fw_crc.bin
python3 /Users/smetrot/work/duet3/RepRapFirmware/Scripts/CrcAppender.py /tmp/fw_crc.bin

cd $RENODE && ./renode --disable-xwt --console \
  -e "\$fw=@/tmp/fw_crc.bin" \
  -e "\$elf=@$FW/Duet3Firmware_MB6HC.elf" \
  -e "\$plat=@$EMU/platforms/duet3_mb6hc.repl" \
  -e "\$logfile=@/tmp/boot.log" \
  -e "include @$EMU/scripts/boot.resc"
```

The image must be the **CRC-appended `.bin`**, not the `.elf` — the firmware checks its own CRC over
the flash image and a raw ELF load fails it. The `.elf` is loaded only for symbols.

`scripts/trace_bin.resc` is the same run with `cpu LogFunctionNames true`, which is how the CRC loop
was identified. It is roughly a hundred times slower; use it on short windows only.
