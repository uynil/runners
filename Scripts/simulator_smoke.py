#!/usr/bin/env python3
"""Run installed Debug apps on a paired simulator and require an application-level receipt.

Example: python3 Scripts/simulator_smoke.py --phone PHONE_UUID --watch WATCH_UUID \
    --action map-sync --id MAP_UUID

Uses existing maps/activities only. It never creates fixtures or downloads map data.
map-remove removes only the specified Watch map; the phone copy is retained.
"""
import argparse
import json
import pathlib
import subprocess
import time
import uuid


def simctl(*args):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phone", type=uuid.UUID, required=True)
    parser.add_argument("--watch", type=uuid.UUID, required=True)
    parser.add_argument("--id", type=uuid.UUID, required=True)
    parser.add_argument("--action", choices=["map-sync", "map-remove", "activity-receive"], required=True)
    args = parser.parse_args()
    phone, watch, identity = str(args.phone).upper(), str(args.watch).upper(), str(args.id).upper()
    simctl("launch", watch, "com.uynil.Runners.watchkitapp")
    started = time.time()
    simctl("launch", "--terminate-running-process", phone, "com.uynil.Runners", "--qa-" + args.action, identity)
    root = pathlib.Path(simctl("get_app_container", phone, "com.uynil.Runners", "data"))
    result = root / "Documents/simulator-qa-result.json"
    while time.time() - started < 55:
        try:
            record = json.loads(result.read_text())
            if record["at"] >= started and record["action"] == "--qa-" + args.action and record["mapID"] == identity:
                print(json.dumps(record, ensure_ascii=False))
                return 0 if record["passed"] else 1
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.25)
    print("FAIL: no fresh simulator scenario result; both apps must be installed, paired and reachable.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
