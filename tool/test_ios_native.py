"""Boot one available iPhone simulator, run native asset integration, and stop it."""

import json
from pathlib import Path
import subprocess


def main():
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    candidates = [(runtime, device) for runtime, group in devices["devices"].items()
                  if ".iOS-" in runtime for device in group
                  if device.get("isAvailable") and device["name"].startswith("iPhone")]
    if not candidates:
        raise RuntimeError("No available iPhone simulator runtime on the runner")
    # Stable selection on a runner image; prefer its latest installed iOS runtime.
    def key(item):
        version = tuple(map(int, item[0].rsplit("iOS-", 1)[1].split("-")))
        return version, item[1]["name"], item[1]["udid"]
    _, simulator = sorted(candidates, key=key, reverse=True)[0]
    udid = simulator["udid"]
    print(f"Using {simulator['name']} ({udid})", flush=True)
    try:
        if simulator["state"] != "Booted":
            subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
        # Flutter's 12-minute suite-loading timeout includes the cold Xcode
        # build. Bound the whole command instead so compilation cannot consume
        # the test's startup allowance before the application launches.
        subprocess.run([
            "flutter", "test", "--no-pub", "--ignore-timeouts", "-d", udid,
            "integration_test/native_smoke_test.dart",
        ], cwd=Path(__file__).resolve().parents[1] / "simple_live_app",
            check=True, timeout=25 * 60)
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False)


if __name__ == "__main__":
    main()
