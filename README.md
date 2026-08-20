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

**Not yet possible: observing motion.** There is no console to send G-code to, and the PIO model
needed to watch STEP/DIR does not exist yet. Those are the next two pieces.

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

## Peripherals the firmware touches

Measured over 0.3 emulated seconds, now that it reaches the main loop:

| Peripheral | Accesses | State |
|---|---|---|
| AFEC0 / AFEC1 | 15103 | SVD stub — ADC conversions, polled hard |
| HSMCI | 2296 | SVD stub — the SD card |
| WDT / RSWDT | 520 | SVD stub; harmless |
| PIOA–E | 545 | SVD stub — **needed to observe STEP/DIR** |
| PMC | 94 | status register faked |
| XDMAC | 32 | SVD stub |
| MCAN0 / MCAN1 | 44 | only `CCCR` has storage |
| USBHS | 12 | only `SR` is faked — **needed for a console** |
| EFC, MATRIX, RSTC | 20 | reset values plus the `FSR` fake |

## Next

1. **PIO model** — without it there is nothing to watch. This is what turns the emulator into a motion oracle.
2. **A console** — either USBHS properly, or the PanelDue UART, so G-code can be sent in.
3. **HSMCI**, or an embedded-files build, so a real `config.g` is read.

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
