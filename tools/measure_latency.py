#!/usr/bin/env python3
"""Measure how long a jog velocity change takes to reach the step pins.

Reads an edge log containing MARK lines (a command was injected) and rising edges. Both timestamps
come from the same emulated clock, so the result is a measurement rather than a correlation between
two time bases.

Only the FIRST transition is measured. A jog stream repeats the same command to feed the watchdog, so
every later mark is already at the target speed and would report a latency near zero - which is how
this went wrong the first time.
"""
import argparse
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('edgelog')
    ap.add_argument('--pin', type=int, default=18)
    ap.add_argument('--steps-per-mm', type=float, default=80.0)
    ap.add_argument('--from-speed', type=float, required=True, help='speed before the change, mm/s')
    ap.add_argument('--to-speed', type=float, required=True, help='speed commanded by the change, mm/s')
    ap.add_argument('--tolerance', type=float, default=0.2, help='fraction of target counted as reached')
    ap.add_argument('--command', required=True,
                    help='label of the command that causes the change, e.g. M700_X30. The FIRST mark '
                         'carrying this label is the one timed from - later repeats feed the watchdog '
                         'and are not causative.')
    args = ap.parse_args()

    marks, edges = [], []
    for line in open(args.edgelog):
        f = line.split()
        if len(f) != 3:
            continue
        if f[1] == 'MARK':
            marks.append((float(f[0]), f[2]))
        elif int(f[1]) == args.pin and f[2] == '1':
            edges.append(float(f[0]))

    mm_per_step = 1.0 / args.steps_per_mm
    samples = []          # (time_of_second_edge, velocity)
    for a, b in zip(edges, edges[1:]):
        dt = (b - a) / 1e6
        if dt > 0:
            samples.append((b, mm_per_step / dt))
    if not samples:
        sys.exit("no step intervals in the log")

    band = args.tolerance * args.to_speed
    target_hits = [t for t, v in samples if abs(v - args.to_speed) <= band]
    if not target_hits:
        fastest = max(v for _, v in samples)
        sys.exit(f"never reached {args.to_speed} mm/s (fastest seen {fastest:.1f})")
    t_target = target_hits[0]

    # The last moment it was still clearly at the old speed, so we time from the command that changed it.
    old_band = args.tolerance * args.from_speed
    old_hits = [t for t, v in samples if t < t_target and abs(v - args.from_speed) <= old_band]
    t_old = old_hits[-1] if old_hits else 0.0

    candidate = [t for t, label in marks if label == args.command]
    if not candidate:
        have = sorted({label for _, label in marks})
        sys.exit(f"no mark labelled {args.command}; log has {have}")
    t_cmd = candidate[0]
    if t_cmd > t_target:
        sys.exit("the labelled command came after the speed change - wrong label?")

    print(f"command at {t_cmd/1000:.1f} ms, {args.to_speed} mm/s reached at {t_target/1000:.1f} ms")
    print(f"latency: {(t_target - t_cmd)/1000:.1f} ms")


if __name__ == '__main__':
    main()
