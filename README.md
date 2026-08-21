# Duet emulation on Renode

Emulating Duet control boards well enough to run **real RepRapFirmware images**, so firmware
behaviour — motion above all — can be observed and asserted without hardware.

MIT licensed. Contains no RepRapFirmware code: the platform description started from Renode's
MIT-licensed `platforms/cpus/sam_e70.repl`, and the peripheral models are written against Renode's API
from the SAME70 datasheet.

Firmware changes it depends on live in a GPLv3 fork: [`meeloo/RepRapFirmware`](https://github.com/meeloo/RepRapFirmware),
branch `feature/velocity-jog`.

## What works

| | |
|---|---|
| Boot | RepRapFirmware 3.7.0-beta.3 boots to its main loop, no CPU faults |
| G-code | Full console over emulated USART2, and over the network |
| Motion | Real step pulses, counted and timestamped on PIOC |
| Sensors | Thermistors, VREF/VSSA, VIN, MCU temperature — all report plausible values |
| Network | Ethernet up, HTTP API reachable from the host |
| DWC / AxisControl | Both connect and work, including the file browser |
| Filesystem | Read-only, compiled into the image (`files/`) |

Verified examples:

```
$ tools/run_gcode.py --after 2.0 "G91" "G1 X10 F600" "M114"
    X:10.000 Y:0.000 Z:0.000 E:0.000 Count 800 0 0
--- step edges: 1600            # 800 steps x 2 edges, agreeing with M92 X80

$ curl -s http://localhost:8080/rr_connect?password=
{"err":0,"boardType":"duet3mb6hc101","apiLevel":2,...}
```

## What does not work

| | Why |
|---|---|
| **Writing files** | The filesystem is compiled into flash and is read-only. Upload/delete/move/mkdir are refused. Editing config means rebuild + restart. |
| **SD card (HSMCI)** | Not modelled. This is what would make the filesystem writable and let the board host DWC's `/www` itself. |
| **Stepper drivers (TMC5160)** | Not modelled — needs XDMAC and USART-in-SPI-mode first. Motion is unaffected (steps come from the TC/PIO path) but driver *status* is not meaningful. |
| **CAN expansion** | Only `MCAN CCCR` has storage. No expansion boards. |
| **USB** | Only `USBHS_SR` is faked, enough to get past TinyUSB's init spin. No USB console. |
| **Endstops, probes, real ADC dynamics** | Sensor channels hold fixed values; nothing changes with temperature or position. |
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
peripherals/  C# peripheral models: timer/counter, parallel IO, AFEC
scripts/      .resc run scripts
tools/        build, run, and analysis tooling
files/        the embedded filesystem: config.g, macros, gcodes
```

## Peripheral models

| Model | Why it exists |
|---|---|
| `SAME70_TimerCounter.cs` | The step clock. Two chained 16-bit channels at 750kHz. The RB compare is deliberately 16-bit, as the hardware is. |
| `SAME70_ParallelIO.cs` | STEP/DIR observation. All six MB6HC step pins are on PIOC; `TraceMask` logs edges with emulated timestamps. |
| `SAME70_AnalogFrontEnd.cs` | Sensors. RRF computes completed conversions as `CHSR & ISR & ~OVER`; with stubs that is always empty, so nothing ever converted. |

Everything else is left to the SVD fallback, which returns reset values and logs the access — and that
log is the to-do list for what to model next.
