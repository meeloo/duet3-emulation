# Dust shoe: what changed in the firmware, and what AxisControl should do about it

For whoever maintains AxisControl. Assumes no prior context.

## What changed

The Z-independent dust shoe used to be tracked in G-code: `daemon.g` polled Z every 50 ms and issued
a `G53 G1 U…` whenever it had drifted more than 0.1 mm. That is reactive — U could only start moving
after Z already had, and the correcting move queued behind whatever motion was already planned.

There is now a firmware command that does it inside the motion planner:

```gcode
M604 A"U" B"Z" E1     ; U follows Z; the relationship is captured from current positions
M604 E0               ; disengage
M604                  ; report: U follows Z as -1.000 * Z + 70.000, engaged
```

U and Z become **one coordinated move**. Measured skew between the two step trains is 0.0000 ms at
the start, middle and end of a move, and it holds for straight moves, helical arcs and velocity
jogging. The `daemon.g` tracking loop goes away entirely.

It lives in `meeloo/RepRapFirmware`, branch `feature/velocity-jog`. `M604` is a **provisional command
number** — free in that firmware, but not blessed by Duet3D, so treat it as something that might move.

## What this means for AxisControl

### 1. `U{-var.newOffset}` becomes redundant — but do not just delete it

Two places generate it:

* `src/probing/rrf.ts`, in the Z-probe macro:
  ```ts
  p.dustShoeAxis
    ? `G10 L1 Z{var.newOffset} ${p.dustShoeAxis}{-var.newOffset}`
    : 'G10 L1 Z{var.newOffset}',
  ```
* `src/atc/files.ts`, `probeZ()`:
  ```ts
  const shoe = config.dustShoe ? ' U{-var.newOffset} ; and the dust shoe follows the tool' : '';
  ```

`M604` applies its rule in **machine coordinates, after tool offsets**. A longer tool puts the carriage
higher for the same work Z, so the leader's machine coordinate rises and the follower moves down by
the same amount. Tool length is therefore compensated automatically, and the U half of that `G10 L1`
is doing nothing.

It is *harmless* — a derived coordinate ignores its own tool offset, so it cannot double-compensate —
but it is misleading to leave in, because it reads as though it matters.

**The catch:** it is still required on firmware without `M604`. So this needs to be conditional, not
removed. There is no object-model field advertising `M604`, so the options are a config toggle
(something like `dustShoeFirmwareTracking`) or a firmware-version check. A toggle is honest; a version
check will be wrong the moment the command is renamed or upstreamed.

### 2. Do not remove `global.dustShoeEngaged`

`src/atc/files.ts` gates the tool-change hooks on it:

```ts
'if {exists(global.dustShoeEngaged)}\n\tM98 P"dustShoeRetract.g"\n'
```

The obvious migration — "M604 replaces the global" — breaks this: the hooks stop firing because the
global no longer exists. Keep `global.dustShoeEngaged` in `dustShoeConfig.g` as the marker meaning
"this machine has a dust shoe", and let the engage/retract macros go on setting it. `M604` replaces
the *tracking*, not the *state flag*.

The `M98` calls themselves are unchanged. The macros keep their positioning moves — the engaged
height is a machine property and belongs in configuration, not firmware.

### 3. The UI copy is now wrong

`src/panels/atc.ts`:

> Calls `dustShoeRetract.g` before the change and `dustShoeEngage.g` after it, **and follows the tool
> offset with U so the brush stays level with the cutter.**

The second half stops being true once firmware tracking is on — U follows Z continuously, not just at
tool changes, and it does so without the offset trick.

### 4. Read the state from the object model

`move.axisFollower` carries the state, so there is no need to parse the text of an `M604` report:

```json
{"engaged":true,"follower":"U","leader":"Z","offset":70.000,"scale":-1.000}
```

`follower` and `leader` are empty strings when nothing is configured, and `engaged` is flagged `live`
so it arrives with the frequently-updated part of the model.

Note this is *firmware* state. It is not a substitute for `global.dustShoeEngaged`, which still has to
exist because the tool-change hooks are gated on it (see above) — but it is the right thing for a UI
to display, because it reflects what the motion planner is actually doing rather than what a macro
last set.

## What has not changed

* `src/atc/check.ts` — the "dust shoe configured but no U axis" validation is still correct.
* `dustShoeEngage.g` / `dustShoeRetract.g` still exist and are still called the same way.
* Ordering still matters: the engage macro must position U **before** engaging, because `M604 E1`
  captures the current separation rather than taking an absolute target.

## Firmware behaviour worth knowing

* Scale defaults to **-1**. A shoe carried on the Z carriage moves the opposite way to stay put. This
  matches `targetU = U - deltaZ` in the old `daemon.g`.
* Engaging is refused unless the follower axis is homed, matching the old daemon's check.
* The follower is clamped to its `M208` range, so the shoe tracks down until it reaches its lower
  limit and then rests there while Z carries on into the work.
* Movement system 0 only, one relationship at a time.
