# Duet emulation on Renode

MIT licensed (see LICENSE). Contains no RepRapFirmware code; the platform description started from
Renode's `platforms/cpus/sam_e70.repl`, which is MIT, and the peripheral models are written against
Renode's API from the SAME70 datasheet.

**Two setup notes before anything works:**

* Run `tools/fetch_svd.sh` once. The SAME70 SVD is not committed - it is Microchip's register
  description and this project has no clear right to redistribute it.
* `platforms/duet3_mb6hc.repl` refers to that SVD by **absolute path**, currently under
  `/Users/smetrot/work/duet3/duet3-emulation`. Renode resolves relative paths against its own install
  directory rather than the platform file, and the same path has to work from both macOS and the Lima
  guest, so this is deliberate - but you must edit it to match your checkout.

Emulating Duet control boards well enough to run real RepRapFirmware images, so that firmware
behaviour — motion above all — can be observed and asserted without hardware.

Target board today is the **Duet 3 Mainboard 6HC (ATSAME70Q20B)**. The structure is meant to extend to
the Mini 5+ (SAME54), MB6XD and Duet 2 (SAM4E) later.

## Status

**DWC and AxisControl can talk to it.** RepRapFirmware runs on the emulated board with a real network
interface, reachable from macOS:

```
$ curl -s http://localhost:8080/rr_connect?password=
{"err":0,"sessionTimeout":8000,"boardType":"duet3mb6hc101","apiLevel":2,"sessionKey":0}

$ curl -s "http://localhost:8080/rr_model?key=state"
{"result":{"status":"idle","machineMode":"FFF","currentTool":0,...}}
```

`Access-Control-Allow-Origin: *` is set (from `M586 P0 C"*"`), so DWC can be served from anywhere and
pointed at `http://localhost:8080` - no SD card and no `/www` on the board.

Motion, sensors and the G-code console all work too; see below.

### Why there is a Linux VM

Renode needs a layer-2 TAP interface to put the board on a network. macOS has none - `utun` is layer 3,
and the third-party TAP kexts do not load on Apple Silicon (`No TUNTAP kernel extension found, running
in dummy mode`). Renode's own emulated network services are UDP-only (`CreateNetworkServer` offers just
`StartTFTP`), so bridging in-process would mean writing a TCP stack. A Linux guest has `/dev/net/tun`
built in, so the emulator runs there:

```
board 192.168.100.50 --emulated GMAC--> switch --> tap0 192.168.100.1  (Lima guest)
guest :8080 --socat--> 192.168.100.50:80 --Lima--> macOS localhost:8080
```

Lima mounts the home directory at the same path in the guest, so one set of paths works on both sides
and the firmware is still built on macOS.

### Running it

```sh
brew install lima
limactl start --name=duet --tty=false --cpus=4 --memory=6 template://default
limactl shell duet -- bash ~/work/duet3/duet3-emulation/tools/setup_guest.sh   # once

tools/build_firmware.sh      # compile, embed config.g, append CRC
tools/run_networked.sh       # boot it in the guest
curl -s http://localhost:8080/rr_connect?password=
```

For motion work without the network, `tools/run_gcode.py` still drives the board over the emulated
USART2 on macOS directly, which is faster and deterministic.

### Five things that had to be got right

Each of these failed silently or misleadingly, so they are worth knowing:

| Symptom | Cause |
|---|---|
| Script does nothing, machine never runs | `emulation LogEthernetTraffic` launches Wireshark; absent, it errors and aborts the rest of the script |
| `No such command or device: Note` | `.resc` comments are `#`, not `;` |
| Renode dies mid-boot | Started via `limactl shell`, it belongs to the SSH session's process group - needs `setsid` |
| Renode boots, runs, then vanishes | `--console` exits on stdin EOF, so `</dev/null` kills it; feed it `tail -f /dev/null` |
| `connector Connect ... "Parameters did not match the signature"` | The TAP registers as `host.tap`, and connects to a *switch* - the MAC does not attach to it directly |

## Pretending hardware is attached

`files/sys/config.g` is now an ordinary Cartesian printer - two heaters, two thermistors, two fans, a
tool, four drives - so DWC and AxisControl have something realistic to show. The readings behind it
come from AFEC channel values in the platform file:

```
M105  ->  T:25.0 /0.0 T0:25.0 /0.0 B:25.0 /0.0
boards[0].vIn     -> {"current":24.0,"max":24.0,"min":24.0}
network.interfaces[0].state -> "active"
```

Two things about the ADC scaling that cost an hour and are not guessable:

* `Thermistor::TryGetTemperature` needs **VREF and VSSA** (AFEC1 ch9 and ch1) as well as the thermistor
  channel, because it computes `R = seriesR * (temp - vssa) / (vref - temp)`. Without them every
  sensor reports `badVref` and reads 2000.0, whatever the thermistor channel says.
* The thermistor path compares against `OversampledAdcRange` = 1<<16 and the readings reach it
  unscaled, so those channels want **16-bit** values - VREF 65535, and 64124 for 100k at 25C. The VIN
  path divides by `1<<AdcBits` with `AdcBits` = 14, so *that* channel wants 14-bit - 8602 for 24V. The
  two are calibrated against what the firmware reports, not derived.

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
