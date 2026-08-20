# Duet emulation on Renode

Emulating Duet control boards well enough to run real RepRapFirmware images, so that firmware
behaviour — motion above all — can be observed and asserted without hardware.

Target board today is the **Duet 3 Mainboard 6HC (ATSAME70Q20B)**. The structure is meant to extend to
the Mini 5+ (SAME54), MB6XD and Duet 2 (SAM4E) later.

## Status

RepRapFirmware 3.7.0-beta.3 boots and **reaches its main loop**. No CPU faults. The watchdog is fed
about 870 times a second, the ADC task is converting, and the firmware is trying to talk to the SD
card — that is RRF running its normal FreeRTOS workload, not a stuck init.

The step clock runs: `tc0 StepClock` reads 0x30321 (197,409 ticks) after 0.3 emulated seconds. It is
below the 225,000 a full 0.3s at 750kHz would give because the counter only starts when RRF enables
it, roughly 37ms into boot. Being above 0xFFFF is the useful part: it proves the channel 0 to
channel 2 chaining works.

PIO is modelled, so STEP/DIR can now be watched: `pioc` traces the six MB6HC step pins and counts
edges. Booting idle produces zero edges, which is correct — nothing has been commanded. That zero is
trustworthy rather than merely absent: `scripts/selftest_pio.resc` pokes SODR/CODR/ODSR directly and
checks the state and edge count, so an inert model would be caught.

**Still not possible: commanding motion.** There is no console, so no way to send G-code in.

The chain behind that turned out to be longer than it looked. RepRapFirmware's aux G-code channels are
`Aux` on UART2 and `Aux2` on USART2 (`Serial0Params`/`Serial1Params` in `Pins_Duet3_MB6HC.h`).
Renode already models USART2, and `Aux2` needs no checksum
(`commsParams[FirstAuxChannel + 1] = 0`), so it looks like a free console — except `AuxDevice::Init`
only records the baud rate. Nothing calls `SetMode`, and therefore nothing calls `uart->begin()`,
until `M575` runs. `M575` comes from `config.g`, which comes from the SD card. No SD, no console; and
no console, no way to send the `M575` that would open one.

The way out is `USE_EMBEDDED_FILES`, which `Pins_Duet3_MB6HC.h` already supports: it compiles the
filesystem into the image after `_firmware_end` and turns off mass storage entirely. That removes
HSMCI from the critical path. `Makefiles/Duet3_MB6HC_embedded.mk` builds it (that config did not
previously exist, and `USE_EMBEDDED_FILES` did not compile on beta.3 — see the RepRapFirmware
commit).

Getting here needed these, each found by letting the firmware fail and reading the log:

| Symptom | Cause |
|---|---|
| 3-blink loop in `AppMain` | The `.bin` had no firmware CRC. `Makefiles/*.mk` append one only `if command -v CrcAppender`, and it was not installed. See `RepRapFirmware/Scripts/CrcAppender.py`. |
| `CPU abort: MPU: Trying to use non-existent MPU region ... faulting region number: 8` | Renode's `CPU.CortexM` defaults to 8 MPU regions; the SAME70's Cortex-M7 has 16 and RepRapFirmware configures region 8. |
| Boot appeared to work but hid stray accesses | Stock `sam_e70.repl` declares 256MB catch-all memories at 0x0 and 0x20000000. Replaced with the real Q20B map. |
| Spin in `StepTimer::Init` on `TC0:CV0` | No timer model. See `peripherals/SAME70_TimerCounter.cs`. |
| Spin in `dcd_connect` on `USBHS:SR` | TinyUSB waits for UTMI `CLKUSABLE`. Stubbed. |
| Spin in `efc_perform_read_sequence` on `EFC:FSR` | Reading the unique ID waits for `FRDY` to clear and then to set; a constant hangs one of the two. |
| Spin in `CanDevice::Enable` on `MCAN0/1:CCCR` | `CCCR.INIT` is cleared then polled until it reads back clear, so the register needs real storage. |
| Nothing to observe motion with | No PIO model. See `peripherals/SAME70_ParallelIO.cs`. |

## Peripherals the firmware touches

Measured over 0.3 emulated seconds, now that it reaches the main loop:

| Peripheral | Accesses | State |
|---|---|---|
| AFEC0 / AFEC1 | 15103 | SVD stub — ADC conversions, polled hard |
| HSMCI | 2296 | SVD stub — the SD card |
| WDT / RSWDT | 520 | SVD stub; harmless |
| PIOA–E | — | **modelled**; `pioc` traces the step pins |
| PMC | 94 | status register faked |
| XDMAC | 32 | SVD stub |
| MCAN0 / MCAN1 | 44 | only `CCCR` has storage |
| USBHS | 12 | only `SR` is faked — **needed for a console** |
| EFC, MATRIX, RSTC | 20 | reset values plus the `FSR` fake |

## Next

1. **Build the embedded filesystem image.** The format is in `src/Storage/EmbeddedFiles.cpp`: at
   `_firmware_end`, a header of `magic = 0x543C2BEF`, `directoriesOffset`, `numFiles`, then
   `numFiles` × (`nameOffset`, `contentOffset`, `contentLength`), all offsets relative to
   `_firmware_end`. Needs a builder script and a `config.g` whose job is to run
   `M575 P2 S0 B57600` — opening `Aux2` on USART2.
   Note the ordering: append the filesystem *first*, then the CRC, because for embedded builds the
   CRC lives after the files. `Scripts/CrcAppender.py` already asserts this rather than silently
   CRCing the wrong extent.
2. **Send G-code over `usart2`** and confirm RRF answers.
3. Then: drive `M700` and reconstruct the velocity profile from the traced step edges.

## Layout

    platforms/   .repl platform descriptions
    scripts/     .resc run scripts
    peripherals/ C# peripheral models

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
  -e "\$tcmodel=@$EMU/peripherals/SAME70_TimerCounter.cs" \
  -e "\$plat=@$EMU/platforms/duet3_mb6hc.repl" \
  -e "\$logfile=@/tmp/boot.log" \
  -e "include @$EMU/scripts/boot.resc"
```

The image must be the **CRC-appended `.bin`**, not the `.elf` — the firmware checks its own CRC over
the flash image and a raw ELF load fails it. The `.elf` is loaded only for symbols.

`scripts/trace_bin.resc` is the same run with `cpu LogFunctionNames true`, which is how the CRC loop
was identified. It is roughly a hundred times slower; use it on short windows only.
