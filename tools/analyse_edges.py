#!/usr/bin/env python3
"""Turn a step-edge log into a velocity profile.

Reads "microseconds pin level" lines as written by run_gcode.py --edge-log. Velocity comes from the
spacing of rising edges: one step is 1/steps-per-mm of travel, so v = (1/spm) / dt.

Rising and falling edge of the same pulse usually carry the same timestamp, because RepRapFirmware
sets and clears the pin inside one emulated time quantum. That is why only rising edges are used.
"""

import argparse
import collections
import sys


def load(path, pin):
    times = []
    with open(path) as handle:
        for line in handle:
            parts = line.split()
            # --trace-steps interleaves "<micros> MARK <command>" lines into the same log; they have
            # three fields too, so they have to be skipped by content rather than by field count.
            if len(parts) != 3 or parts[1] == 'MARK':
                continue
            micros, edge_pin, level = float(parts[0]), int(parts[1]), int(parts[2])
            if level == 1 and (pin is None or edge_pin == pin):
                times.append(micros)
    return sorted(times)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('edgelog')
    parser.add_argument('--pin', type=int, default=18, help='step pin to analyse (default 18, driver 0 / X)')
    parser.add_argument('--steps-per-mm', type=float, default=80.0)
    parser.add_argument('--bucket-ms', type=float, default=50.0, help='averaging window, defaults to one jog chunk')
    args = parser.parse_args()

    times = load(args.edgelog, args.pin)
    if len(times) < 2:
        raise SystemExit(f"{args.edgelog}: only {len(times)} rising edge(s) on pin {args.pin}, nothing to profile")

    mm_per_step = 1.0 / args.steps_per_mm
    start = times[0]
    span_s = (times[-1] - start) / 1e6

    # Instantaneous velocity between consecutive steps.
    instant = []
    for earlier, later in zip(times, times[1:]):
        dt = (later - earlier) / 1e6
        if dt > 0:
            instant.append(((later - start) / 1000.0, mm_per_step / dt))

    buckets = collections.OrderedDict()
    for ms, velocity in instant:
        key = int(ms // args.bucket_ms) * args.bucket_ms
        buckets.setdefault(key, []).append(velocity)

    print(f"pin {args.pin}: {len(times)} steps over {span_s * 1000:.1f}ms = {len(times) * mm_per_step:.3f}mm")
    print(f"peak {max(v for _, v in instant):.2f} mm/s")
    print()
    print(f"{'t (ms)':>9}  {'mean mm/s':>10}  {'min':>7}  {'max':>7}  steps")
    for key, values in buckets.items():
        print(f"{key:9.0f}  {sum(values) / len(values):10.2f}  {min(values):7.2f}  {max(values):7.2f}  {len(values)}")


if __name__ == '__main__':
    main()
