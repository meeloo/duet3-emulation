# M700 velocity jogging — host integration guide

For whoever is writing the thing that drives it (joystick, control panel, mock pad). Assumes no prior
context.

## What M700 is

RepRapFirmware normally moves by **destination** (`G1 X10` = go to X=10). `M700` adds movement by
**velocity**: "run X at 25 mm/s until I say otherwise". That is what an analogue input needs — a stick
deflection is a speed, not a place.

It is a custom command in a fork, not stock RepRapFirmware:
`meeloo/RepRapFirmware`, branch `feature/velocity-jog`.

## Command

```
M700 X<speed> Y<speed> Z<speed> ... [S0] [P<ms>] [R<ms>] [D<n>]
```

| Parameter | Meaning |
|---|---|
| axis letters | Signed speed for that axis, **mm/sec** (degrees/sec for rotational axes). `G20` does **not** rescale these — always machine units. |
| `S0` | Stop jogging now (decelerates normally). |
| `P` | Chunk time in ms, 10–200, default 20. Tuning; see *Latency*. |
| `R` | Watchdog timeout in ms, default 250. |
| `D` | Queue depth, 2–8, default 2. Tuning; see *Latency*. |
| *(none)* | Report status. |

### Three rules that matter

**1. The axis letters present define the entire velocity vector.** Any axis you do not mention is set
to **zero**. This is deliberate: a truncated or partially-parsed command cannot leave an axis running.

```
M700 X25 Y-12    ; X at +25, Y at -12, every other axis stopped
M700 X25         ; Y now STOPS. X continues.
M700 S0          ; everything stops
```

So send the whole vector every time. Do not send `M700 X25` and then `M700 Y10` expecting both to move.

**2. You must keep sending.** A watchdog stops all jogging if no `M700` arrives within `R` ms
(default 250). This is the safety property that matters most: if your process dies, the USB cable is
pulled, or the network drops, the machine **decelerates to a stop under its normal limits** rather
than running until it hits something.

Send at a steady cadence while the stick is off centre — **20–50 Hz is the intended range**. Keep
sending the same value if nothing changed; do not go quiet just because the stick is still.

**3. Releasing the stick means sending zero, not sending nothing.** `M700 X0` (or `M700 S0`) stops
promptly. Falling silent also stops, but only after the watchdog expires — up to 250 ms later.

## Latency and the speed ceiling — read before choosing P and D

These are measured on an emulated Duet 3 MB6HC, timed from command injection to the step pins actually
changing rate.

| `D` | `P` | Latency | Max speed |
|---|---|---|---|
| 5 | 50 ms | 257 ms | 100 mm/s |
| 3 | 20 ms | 126 ms | 40 mm/s |
| **2 (default)** | **20 ms** | **50 ms** | **40 mm/s** |
| 2 | 15 ms | 62 ms | 30 mm/s |
| 2 | 10 ms | 127 ms | 20 mm/s |

Two things to understand:

**The speed ceiling is `2 × acceleration × P`.** It is not arbitrary and not a limit in the jog code:
the motion planner caps each move's entry speed so any move can be the last one queued and still stop
within itself. With `M201 X1000` (1000 mm/s²) and `P=20ms` that is 40 mm/s. `M700` clamps to it rather
than letting you command a speed that silently will not happen.

**If you want both low latency and high speed, raise acceleration.** `M201 X4000` with `P=20ms` gives
160 mm/s at the same 50 ms latency. That is the real lever; `P` alone trades one against the other.

**The defaults are already the measured optimum — do not "tune" them shorter.** Below about 40 ms of
queued motion latency stops following `D×P` and gets *worse*: `Move` wants roughly 50 ms of prepared
motion before it will run moves, so `D=2, P=10` measures 127 ms against 50 ms for `D=2, P=20`.
Doubling the command rate changed the result by 0.3 ms, so this floor is in the firmware, not in how
fast you can send.

So for a joystick, just send:

```
M700 X<vx> Y<vy>   ; at 20-50 Hz. No P or D needed.
```

## How to send it

### Over the network (recommended for a host application)

RepRapFirmware's HTTP API. Two calls:

```
GET /rr_gcode?gcode=<url-encoded command>     -> {"buff":<free space>}
GET /rr_reply                                  -> the text response, if any
```

Verified working:

```sh
curl -s --get --data-urlencode 'gcode=M700 X10 Y-5' http://<board>/rr_gcode
curl -s http://<board>/rr_reply
```

You do not need `/rr_reply` for jogging — fire `rr_gcode` and ignore the response. Do check the
`buff` value occasionally: it is the free space in the input buffer, and if it trends to zero you are
sending faster than the board can consume.

Call `/rr_connect?password=` once at startup; it returns `{"err":0,...}` on success.

### Over serial

Plain text, one command per line, `\n` terminated, to whichever port is configured as a raw G-code
channel. On the emulated board that is `M575 P3 S2 B57600` in `config.g` (Aux2 = USART2, raw mode, no
checksum required).

## Testing without hardware

There is a full emulator: `meeloo/duet3-emulation`. It runs the real firmware and can measure what the
steppers actually did, so a host can be developed and validated before touching a machine.

```sh
# G-code straight in, no VM, deterministic
tools/run_gcode.py --after 2.0 "M700" "M700 X10" "M114"

# with step-pulse capture, to see what the motors really did
tools/run_gcode.py --after 0.05 --trace-steps --edge-log /tmp/e.txt "G91" "M700 X10"
tools/analyse_edges.py /tmp/e.txt            # velocity profile
tools/measure_latency.py /tmp/e.txt --from-speed 3 --to-speed 15 --command M700_X15
```

For HTTP testing, `tools/run_networked.sh` boots it with real networking; the board then answers at
`http://localhost:8080`.

## Error cases

| Response | Meaning |
|---|---|
| `Cannot jog while a print is running` | Jogging refuses to start during a print, and stops if one starts. |
| `Insufficient axes homed` | Same homing rules as `G1`. `M564 H0` allows movement before homing. |
| `Cannot jog: axes are in use by another movement system` | Another movement system owns those axes. |

Jogging is also cancelled by anything that waits for standstill on movement system 0 (`G28`, `G30`,
most `M`-codes that move), and by `M112`/`M999`. If your host sees motion stop unexpectedly, something
else issued one of those.

`M700` with no parameters reports current state, which is the quickest way to check what the firmware
thinks:

```
Jogging active, chunk 20ms, timeout 250ms, queue 2, speeds X10.0 Y-5.0
```

Note the reported speeds are **after clamping** — if you asked for more than `2·a·P` or more than
`M203`, this shows what you actually got.

## Safety notes for the host

- **Send zero on focus loss, disconnect, or any error path.** Do not rely on the watchdog as the
  primary stop; it is the backstop for when your process is gone, not a substitute for stopping.
- **Deadman input is worth having.** A held button that must stay held is the conventional pattern for
  hand-held jog controls.
- **Apply a deadzone** before converting stick position to speed, or the machine will creep.
- **`M112` is the emergency stop**, not `M700 S0`. `M700 S0` decelerates normally.
- Axis limits are enforced per axis: an axis reaching its `M208` limit stops while the others continue
  at their commanded speed. You do not need to implement soft limits yourself, but the machine will
  simply stop moving that axis — reflect that in the UI rather than assuming the command failed.
