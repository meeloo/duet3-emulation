# Duet emulation on Renode

Emulating Duet control boards well enough to run real RepRapFirmware images, so that firmware
behaviour — motion above all — can be observed and asserted without hardware.

Target board today is the **Duet 3 Mainboard 6HC (ATSAME70Q20B)**. The structure is meant to extend to
the Mini 5+ (SAME54), MB6XD and Duet 2 (SAM4E) later.

## Status

**The emulator can command and measure motion.** RepRapFirmware 3.7.0-beta.3 boots from a
`USE_EMBEDDED_FILES` image, runs `config.g`, opens a G-code console, executes moves, and the resulting
step pulses are counted on PIOC.

```
$ tools/run_gcode.py --after 2.0 "G91" "G1 X10 F600" "M114"
>>> M114
    X:10.000 Y:0.000 Z:0.000 E:0.000 Count 800 0 0 Machine 10.000 0.000 0.000
--- step edges: 1600
```

800 counts is 10mm at the `M92 X80` in `files/sys/config.g`, and 1600 edges is 800 steps with a rising
and a falling edge each. The numbers agree, which is the point: this is a measurement, not a vibe.

`M700` velocity jogging works too:

```
$ tools/run_gcode.py --after 2.0 "M700" "M700 X10" "M114"
>>> M700
    Jogging inactive, chunk 50ms, timeout 250ms, queue 3
>>> M700 X10
>>> M114
    X:3.000 ... Count 240
```

X ran at the commanded 10mm/s and then stopped on its own, because only one `M700` was sent and the
250ms watchdog fired — the deceleration-on-loss-of-input behaviour the jog design claims, observed
rather than asserted.

### It has already caught a real bug

Driving a realistic 20Hz stream and reconstructing the velocity profile from timestamped step edges
found that `M700` stuttered badly at its original default queue depth of 3:

```
$ tools/analyse_edges.py jog_d3.txt        $ tools/analyse_edges.py jog_d4.txt
711 steps = 8.888mm                        767 steps = 9.588mm
   t (ms)   mean mm/s      min                 t (ms)   mean mm/s      min
       50       10.00     9.98                     50       10.00     9.98
      150        9.34     2.50   <--               150       10.00     9.98
      250        9.11     2.50   <--               250       10.00     9.99
```

Velocity collapsed to 2.5mm/s at chunk boundaries and 7% of the commanded distance was lost. It looks
like a blending failure and is not: it is starvation. `JogController::Spin` adds at most one chunk per
pass, so when the ring runs down to a single move, lookahead correctly plans that move to stop at its
end. The default is now 5 (RepRapFirmware commit `924ac78`), and the documented latency went from a
wrong 150-200ms to a measured 300ms.

This is the kind of thing that on real hardware shows up as "jogging feels notchy" and gets argued
about. Here it is a table of numbers.

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

1. Drive a realistic `M700` stream (repeated commands at 20-50Hz) and reconstruct the velocity profile
   from the timestamped edge log, to check the claims the jog commit makes: junction blending, the
   `v <= 2.a.P` ceiling, and per-axis limit clamping.
2. AFEC is polled ~15000 times per 0.3s against an SVD stub, which is wasteful and means temperature
   and voltage readings are meaningless. Worth a model eventually.
3. HSMCI, if a real SD card is ever wanted rather than embedded files.

### Done

1. ~~**Build the embedded filesystem image.**~~ The format is in `src/Storage/EmbeddedFiles.cpp`: at
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

Normal use is through the driver, which boots the machine, sends G-code and decodes the replies:

```sh
cd RepRapFirmware
make Duet3_MB6HC_embedded CROSS_COMPILE=/Applications/ArmGNUToolchain/15.3.rel1/arm-none-eabi/bin/arm-none-eabi- -j8
cp Duet3_MB6HC_embedded/Duet3Firmware_MB6HC_embedded.bin /tmp/fw.bin
python3 Scripts/BuildEmbeddedFiles.py /tmp/fw.bin ../duet3-emulation/files   # filesystem first...
python3 Scripts/CrcAppender.py /tmp/fw.bin                                   # ...then the CRC

cd ../duet3-emulation
DUET_FW=/tmp/fw.bin DUET_ELF=../RepRapFirmware/Duet3_MB6HC_embedded/Duet3Firmware_MB6HC_embedded.elf \
  tools/run_gcode.py "M115"
```

G-code goes in by writing characters straight into the emulated USART2 and replies come back off the
transmit holding register. Renode does have a socket terminal, but the direct route is deterministic,
needs no ports, and keeps the emulation paused between steps so runs are reproducible.

The lower-level scripts below are for bring-up rather than daily use.

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
