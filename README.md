# Duet emulation on Renode

Emulating Duet control boards well enough to run **real RepRapFirmware images**, so firmware
behaviour — motion above all — can be observed and asserted without hardware.

MIT licensed. Contains no RepRapFirmware code: the platform description started from Renode's
MIT-licensed `platforms/cpus/sam_e70.repl`, and the peripheral models are written against Renode's API
from the SAME70 datasheet.

Firmware changes it depends on live in a GPLv3 fork: [`meeloo/RepRapFirmware`](https://github.com/meeloo/RepRapFirmware).
`feature/velocity-jog` is everything together; it is also split into reviewable branches:

| branch | what |
|---|---|
| `upstream/velocity-jog-m700` | M700 velocity jogging |
| `upstream/axis-following-m604` | M604 axis following (stacks on M700) |
| `upstream/fix-embedded-files-compile` | `USE_EMBEDDED_FILES` does not compile on 3.7.0-beta.3 |
| `upstream/fix-embedded-file-api` | file API is hidden on embedded builds, and returned invalid JSON |
| `upstream/fix-embedded-dir-listing` | directory listing on embedded filesystems |
| `upstream/host-unit-tests` | host-native test harness |
| `build/embedded-mb6hc-config` | the embedded build config this emulator uses |

## What works

| | |
|---|---|
| Boot | RepRapFirmware 3.7.0-beta.3 boots to its main loop, no CPU faults |
| G-code | Full console over emulated USART2, and over the network |
| Motion | Real step pulses, counted and timestamped on PIOC |
| Sensors | Thermistors, VREF/VSSA, VIN, MCU temperature — all report plausible values |
| Network | Ethernet up, HTTP API reachable from the host |
| DWC / AxisControl | Both connect and work, including the file browser |
| Filesystem | A **writable FAT32 SD card** over emulated HSMCI (a real image; reads, writes and `M28`/`M29`/`M30` all persist to the file), or a read-only one compiled into the image (`files/`) |
| Reboot | `M999` and DWC's reboot button reset the board and it comes back |
| Velocity jogging | M700 exercised end to end; latency measured from command to step-rate change |
| Axis following | M604 exercised end to end; follower-to-leader skew measured |

Verified examples:

```
$ tools/run_gcode.py --after 2.0 "G91" "G1 X10 F600" "M114"
    X:10.000 Y:0.000 Z:0.000 E:0.000 Count 800 0 0
--- step edges: 1600            # 800 steps x 2 edges, agreeing with M92 X80

$ curl -s http://localhost:8080/rr_connect?password=
{"err":0,"boardType":"duet3mb6hc101","apiLevel":2,...}

$ tools/measure_latency.py e.txt --from-speed 3 --to-speed 15 --command M700_X15
latency: 38.5 ms                # M700 default D2 P20, command injection to step-rate change
```

Measured behaviour these tools were built to establish:

| | |
|---|---|
| M700 jog latency | **38.5 ms** at the default `D2 P20`; latency tracks `D x P` above ~40ms of queued motion |
| M604 follower skew | **0.0000 ms** across straight moves, helical arcs and jogging |
| `M999` reboot | uptime 16s -> 6s, HTTP back within 5s |

All of these are **emulator** numbers. They establish that the firmware logic does what it claims;
they are not predictions about a real board, whose SPI, driver and bus timing this does not model.

## What does not work

| | Why |
|---|---|
| **Writing files (embedded build only)** | With `USE_EMBEDDED_FILES` the filesystem is in flash and read-only. Use the SD card build instead, which is writable. |
| **Stepper drivers (TMC5160)** | **Partial.** USART1 is modelled in SPI mode with a six-deep TMC5160 daisy chain, and the frames it receives are decoded and answered correctly. But the firmware sends only one frame at start-up and then stops, so driver reads never cycle and `M569.2` does not return — the cause is not yet identified. Motion is unaffected (steps come from the TC/PIO path); driver *status* is still not meaningful. |
| **CAN expansion** | Only `MCAN CCCR` has storage. No expansion boards. |
| **USB** | Only `USBHS_SR` is faked, enough to get past TinyUSB's init spin. No USB console. |
| **Endstops, probes, real ADC dynamics** | Sensor channels hold fixed values; nothing changes with temperature or position. |
| **XDMAC completion interrupt** | Deliberately not wired to the NVIC. `ID_XDMAC = 58` genuinely is unconnected, and connecting it *looks* like a fidelity fix, but it wedges the board — `M115` stops answering and AFEC starts collapse from 4255 to 86. Drivers that need it must poll, as the HSMCI one does. |
| **Timing fidelity** | Step *timing* comes from the TC model. Nothing here proves a real TMC5160 would follow the pulses. |

## Tested on

- **Host:** macOS 27 (Darwin 27.0.0), Apple Silicon (arm64).
- **Renode:** 1.16.1 — macOS portable build for the direct path, Linux ARM64 portable inside Lima for
  the networked path.
- **Guest:** Lima 2.2.0, default Ubuntu template, `vz` (Apple Virtualization.framework), 4 CPU / 6 GiB.
- **Toolchain:** ARM GNU Toolchain 15.3.rel1 (`/Applications/ArmGNUToolchain/...`).
- **Board:** Duet 3 MB6HC (ATSAME70Q20B) only. Mini 5+ (SAME54), MB6XD and Duet 2 (SAM4E) are not
  started — the structure is meant to extend to them.

Nothing here has been tested on Linux or Intel hosts.

## Installation

**1. Toolchain.** Homebrew's `arm-none-eabi-gcc` will not work — it has no newlib and fails at
`stdint.h`. Install ARM's:

```sh
brew install --cask gcc-arm-embedded
```

**2. Repos**, side by side, as RepRapFirmware's build expects:

```sh
git clone https://github.com/meeloo/RepRapFirmware.git -b feature/velocity-jog
git clone https://github.com/meeloo/RRFLibraries.git -b feature/host-test-portability
# plus the other Duet3D dependencies: CoreN2G, CANlib, FreeRTOS, LibTinyusb, LibMbedTls
git clone https://github.com/meeloo/duet3-emulation.git
```

**3. Renode** (macOS portable build, no installer needed):

```sh
curl -LO https://github.com/renode/renode/releases/download/v1.16.1/renode-1.16.1-dotnet.osx-arm64-portable.dmg
hdiutil attach -nobrowse renode-1.16.1-dotnet.osx-arm64-portable.dmg -mountpoint /tmp/renode-mnt
cp -R /tmp/renode-mnt/Renode.app ~/Renode.app && hdiutil detach /tmp/renode-mnt
xattr -dr com.apple.quarantine ~/Renode.app
```

**4. SVD and paths.**

```sh
tools/fetch_svd.sh
```

Then edit the `ApplySVD` line in `platforms/duet3_mb6hc.repl` to your checkout — it is an **absolute
path** on purpose, because Renode resolves relative paths against its own install directory and the
same path must work from macOS and the Lima guest.

Point the tools at your Renode with `RENODE_DIR`, or edit `DEFAULT_RENODE` in `tools/run_gcode.py`.

## Running with an SD card

```sh
tools/make_sdcard.sh                     # 64MB FAT32 image built from files/
tools/run_gcode.py --sdcard build/sdcard.img --settle 6.0 "M115" "M20"
```

Writes persist to the image. `M28`/`M29`, DWC uploads and `M30` all work.

Use the SD build (`build/firmware_sd.bin`, from the normal `Duet3_MB6HC` config plus
`Scripts/CrcAppender.py`) rather than the embedded-files one, which has mass storage compiled out.

## Running: motion (macOS, no VM)

```sh
tools/build_firmware.sh
tools/run_gcode.py --after 2.0 "M115" "M114"
tools/run_gcode.py --after 2.0 --trace-steps --edge-log /tmp/e.txt "G91" "G1 X10 F600"
tools/analyse_edges.py /tmp/e.txt
```

`build_firmware.sh` compiles, embeds `files/` and appends the CRC. That order matters: an embedded
image links with `_firmware_crc == _firmware_end`, so the filesystem must be appended and vector slot
7 moved before the CRC is computed. Without a valid CRC, `AppMain` sits in a 3-blink loop instead of
booting — which is also true on real hardware, so build a flashable binary the same way.

## Running: network, DWC and AxisControl

Renode needs a layer-2 TAP interface and macOS has none — `utun` is layer 3, and third-party TAP
kexts do not load on Apple Silicon (`No TUNTAP kernel extension found, running in dummy mode`).
Renode's own emulated network services are UDP-only, so bridging in-process would mean writing a TCP
stack. Hence a Linux guest:

```
board 192.168.100.50 --emulated GMAC--> switch --> tap0 192.168.100.1  (Lima guest)
guest :8080 --socat--> 192.168.100.50:80 --Lima--> macOS localhost:8080
```

```sh
brew install lima
limactl start --name=duet --tty=false --cpus=4 --memory=6 template://default
limactl shell duet -- bash ~/work/duet3/duet3-emulation/tools/setup_guest.sh   # once

tools/build_firmware.sh
tools/run_networked.sh
curl -s http://localhost:8080/rr_connect?password=
```

Lima mounts the home directory at the same path in the guest, so the firmware is still built on macOS
and one set of paths works on both sides.

**DWC** does not need to live on the board: `config.g` sets `M586 P0 C"*"`, so serve DWC from anywhere
and point it at `http://localhost:8080`. **AxisControl** uses the same address.

## Layout

```
platforms/    .repl platform description (+ fetched SVD, not committed)
peripherals/  C# peripheral models, one file per SAME70 peripheral
scripts/      .resc run scripts
tools/        build, run, and analysis tooling
docs/         integration notes for host software (AxisControl, DWC)
files/        the embedded filesystem: config.g, macros, gcodes
```

`tools/`: `build_firmware.sh` (compile + embed + CRC), `run_gcode.py` (drive the board over emulated
USART2), `run_networked.sh` + `setup_guest.sh` + `guest_run.sh` (the Lima path), `make_sdcard.sh`,
`analyse_edges.py` (step edges to a velocity profile), `measure_latency.py` (command to step-rate
change), `fetch_svd.sh`.

`docs/`: `M700-host-integration.md` for anything driving the jog API, `M604-axiscontrol-migration.md`
for moving a G-code dust shoe onto the firmware follower.

## Peripheral models

| Model | Why it exists |
|---|---|
| `SAME70_TimerCounter.cs` | The step clock. Two chained 16-bit channels at 750kHz. The RB compare is deliberately 16-bit, as the hardware is. |
| `SAME70_ParallelIO.cs` | STEP/DIR observation. All six MB6HC step pins are on PIOC; `TraceMask` logs edges with emulated timestamps. |
| `SAME70_AnalogFrontEnd.cs` | Sensors. RRF computes completed conversions as `CHSR & ISR & ~OVER`; with stubs that is always empty, so nothing ever converted. |
| `SAME70_Hsmci.cs` | SD card controller. Renode's `SDCard` is the card; this is the SAME70 side. |
| `SAME70_Xdmac.cs` | DMA. SD data moves by XDMAC, not through HSMCI's FIFO, so the card is unusable without it. |
| `SAME70_ResetController.cs` | Reboot. `ResetProcessor()` requests a reset then spins in `for(;;){}`; with no RSTC the request vanished and the board wedged there with the network stack dead, looking exactly like a networking fault. |
| `SAME70_UsartSpi.cs` | USART1 in SPI mode with the TMC5160 daisy chain behind it. The drivers are modelled inside it because the chain is electrically one shift register, not separately addressable devices. |

Everything else is left to the SVD fallback, which returns reset values and logs the access — and that
log is the to-do list for what to model next.
