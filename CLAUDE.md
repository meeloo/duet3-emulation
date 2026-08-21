# duet3-emulation — project rules for Claude

Renode-based emulation of Duet control boards, running **real RepRapFirmware images** so firmware
behaviour can be measured without hardware. `README.md` is the user-facing doc; this file is the
working index.

Firmware changes live in a **separate repo** — `meeloo/RepRapFirmware`, branch `feature/velocity-jog`
(a GPLv3 fork). This repo is MIT and contains no RRF code. Don't mix them.

## Build & run
- `tools/fetch_svd.sh` once — the SAME70 SVD is deliberately not committed (Microchip's data).
- `tools/build_firmware.sh` — compile, embed the filesystem, append the CRC. **That order is not
  optional**: an embedded image links with `_firmware_crc == _firmware_end`, so the filesystem must be
  appended and vector slot 7 moved *before* the CRC is computed. Both tools refuse to run if slot 7
  is not where they expect, rather than silently checksumming the wrong extent.
- `tools/run_gcode.py` — drives the board over emulated USART2 **on macOS**, no VM. Fast and
  deterministic; this is the tool for motion work.
- `tools/run_networked.sh` — boots it in the Lima guest with real networking. Only needed for
  DWC/AxisControl. Slower.
- Toolchain: `/Applications/ArmGNUToolchain/15.3.rel1/...`. Homebrew's `arm-none-eabi-gcc` has **no
  newlib** and fails at `stdint.h` — always pass `CROSS_COMPILE`, never rely on PATH.

## Oracles — measure, don't assert
- **Step edges are the motion oracle.** `run_gcode.py --trace-steps --edge-log` then
  `tools/analyse_edges.py` reconstructs a velocity profile from rising-edge spacing.
- **Validate the profiler against a known-good move before trusting it on anything new.**
  `G1 X2 F600` must come out as a clean trapezoid, steady at exactly 10 mm/s, totalling 2.000 mm. A
  profiler that can't reproduce a `G1` has no business judging a new feature.
- Step counts must agree with `M92`: 10 mm at `M92 X80` is 800 counts and 1600 edges (two per step).
  Agreement is what makes it a measurement rather than a plausible number.
- **Every claim ships with the numbers.** "Jogging is smooth" isn't a result; a bucketed mean/min/max
  table is. This is how the `D3` stutter was found — it looked fine and lost 7% of commanded distance.

## Emulated ≠ real
An emulator only models what it was told to model. Step *timing* comes from `SAME70_TimerCounter.cs`;
nothing here proves a real TMC5160 would follow the pulses. Say so when reporting results.

## Traps — all of these failed silently or lied about the cause
- `emulation LogEthernetTraffic` **launches Wireshark**; absent, it errors and aborts the rest of the
  script. Three "no frames captured" results came from runs that never executed.
- `.resc` comments are `#`, not `;`. A `;` line is parsed as a command and aborts the script.
- A process started via `limactl shell` dies with the SSH session — use `setsid`.
- Renode `--console` exits on **stdin EOF**, so `</dev/null` makes it boot, run and vanish exactly
  like a crash. Feed it `tail -f /dev/null`.
- The TAP registers as **`host.tap`** and connects to a *switch*; the MAC does not attach to it
  directly. The error is "Parameters did not match the signature", which reads like a type problem.
- `pkill -f` is case-sensitive: matching `Renode` never kills `./renode`. Zombie instances keep `tap0`
  open and serve **stale firmware**, which shows up as HTTP responses containing strings that are
  provably not in the binary you just built. If you see that, count the instances first.
- `HttpResponder::GetJsonResponse` is close to the ARM Thumb branch limit. Adding a small `else if`
  chain broke the **link** with `dangerous relocation`. Check size before adding to it.

## Conventions
- Commit subjects say what changed and why it mattered; put measured numbers in the body.
- Peripheral models document *why* a register behaves as it does, citing the RRF/CoreN2G code that
  depends on it — the register map alone doesn't explain the choices.
- New peripherals: let the firmware tell you what it needs. Boot, read the unimplemented-register log,
  model the hot one, repeat. That list is evidence; guessing produced a worse plan every time.
- `platforms/duet3_mb6hc.repl` refers to the SVD by **absolute path** (Renode resolves relative paths
  against its own install dir, and the path must work from macOS *and* the guest). Edit for your
  checkout.
