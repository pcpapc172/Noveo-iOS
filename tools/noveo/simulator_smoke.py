#!/usr/bin/env python3
"""Launch the full simulator archive in a disposable simulator; never touch user simulators."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
import time


def run(*args, timeout=120):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    runtime_data = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))
    runtimes = [r for r in runtime_data["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
    if not runtimes:
        raise RuntimeError("No installed iOS simulator runtime")
    runtime = max(runtimes, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
    devices = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    version = [int(x) for x in runtime["version"].split(".")]
    version += [0] * (3 - len(version))
    runtime_version = (version[0] << 16) | (version[1] << 8) | version[2]
    candidates = [d for d in devices if d["name"].startswith("iPhone") and
                  d.get("minRuntimeVersion", 0) <= runtime_version <= d.get("maxRuntimeVersion", 0xffffffff)]
    if not candidates:
        raise RuntimeError("No compatible iPhone device type")
    # simctl validates runtime/device compatibility; prefer a modern, standard-size phone.
    device_type = next((d for d in candidates if d["name"] == "iPhone 18 Pro"), candidates[-1])
    udid = run("xcrun", "simctl", "create", "Noveo-CI-" + os.environ.get("GITHUB_RUN_ID", "smoke"),
               device_type["identifier"], runtime["identifier"]).strip()
    recording = None
    try:
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
        with tempfile.TemporaryDirectory(prefix="noveo-smoke-") as stage:
            # ditto preserves executable permissions and framework symlinks in the IPA.
            run("ditto", "-x", "-k", str(args.archive.resolve()), stage)
            apps = list((Path(stage) / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise RuntimeError("Expected exactly one app in the archive")
            app = apps[0]
            with (app / "Info.plist").open("rb") as file:
                bundle = plistlib.load(file)["CFBundleIdentifier"]
            run("xcrun", "simctl", "install", udid, str(app), timeout=180)
            with (args.output / "recording.log").open("w") as log:
                recording = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264",
                                              "--force", str(args.output / "launch.mp4")], stdout=log, stderr=log)
                time.sleep(1)
                first = run("xcrun", "simctl", "launch", udid, bundle)
                time.sleep(6)
                run("xcrun", "simctl", "io", udid, "screenshot", str(args.output / "launch.png"))
                second = run("xcrun", "simctl", "launch", udid, bundle)
                first_pid = re.search(r":\s*(\d+)\s*$", first)
                second_pid = re.search(r":\s*(\d+)\s*$", second)
                if not first_pid or not second_pid or first_pid[1] != second_pid[1]:
                    raise RuntimeError("App exited or restarted during startup smoke check")
                (args.output / "result.json").write_text(json.dumps({
                    "bundle": bundle, "runtime": runtime["identifier"], "device": device_type["name"],
                    "pid": int(first_pid[1]), "survived_seconds": 6,
                    "scope": "Startup only; does not validate Noveo login or chat functionality"
                }, indent=2))
                recording.send_signal(signal.SIGINT)
                recording.wait(timeout=30)
                recording = None
    finally:
        if recording is not None and recording.poll() is None:
            recording.send_signal(signal.SIGINT)
            recording.wait(timeout=30)
        subprocess.run(["xcrun", "simctl", "shutdown", udid], timeout=60, check=False)
        subprocess.run(["xcrun", "simctl", "delete", udid], timeout=60, check=False)


if __name__ == "__main__":
    main()
