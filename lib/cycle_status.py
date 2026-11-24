#!/usr/bin/env python3
"""Report a build cycle's progress and whether it is finished.

Usage: cycle_status.py [--brief] <cycle-dir> <in-flight-builds>

Exit status: 0 if the cycle is finished (nothing running, nothing ready, and
every package left unbuilt has failed or depends on a failed package),
1 if it is still in progress, 2 on error.

--brief prints a single progress line instead of a table.
"""
import json
import os
import sys


def read_lines(path):
    try:
        with open(path) as f:
            return {line.strip() for line in f if line.strip()}
    except FileNotFoundError:
        return set()


def main():
    args = sys.argv[1:]
    brief = "--brief" in args
    args = [a for a in args if a != "--brief"]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    cycle_dir, in_flight = args

    try:
        with open(os.path.join(cycle_dir, "biocdeps.json")) as f:
            all_deps = json.load(f)
        with open(os.path.join(cycle_dir, "remaining-packages.json")) as f:
            remaining = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Cycle state not readable yet: {e}", file=sys.stderr)
        return 2

    successful = read_lines(os.path.join(cycle_dir, "logs/successful-packages.txt"))
    failed = read_lines(os.path.join(cycle_dir, "logs/failed-packages.txt"))
    ready = read_lines(os.path.join(cycle_dir, "ready_packages.txt"))

    unbuilt = [p for p in remaining if p not in failed]
    blocked = [p for p in unbuilt if any(d in failed for d in all_deps.get(p, []))]
    waiting = len(unbuilt) - len(blocked)

    if brief:
        print(f"{len(successful)}/{len(all_deps)} built, {len(failed)} failed, "
              f"{in_flight} running, {len(ready)} ready, {waiting} left, "
              f"{len(blocked)} blocked")
    else:
        print(f"Total packages:     {len(all_deps)}")
        print(f"Successful:         {len(successful)}")
        print(f"Failed:             {len(failed)}")
        print(f"Running:            {in_flight}")
        print(f"Ready to dispatch:  {len(ready)}")
        print(f"Left to build:      {waiting}")
        print(f"Blocked by failure: {len(blocked)}")

    if not in_flight.isdigit():
        return 1
    # deps in biocdeps.json are recursive, so a direct check finds every
    # package blocked by a failure, however deep.
    if int(in_flight) == 0 and not ready and waiting == 0:
        if not brief:
            print("Cycle finished.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
