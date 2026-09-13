#!/usr/bin/env python3
"""Select an available tvOS simulator matching the CI build SDK."""

import argparse
import json
import subprocess
import sys


def select_device(devices: dict, sdk_version: str) -> tuple[str, str]:
    runtime = "com.apple.CoreSimulator.SimRuntime.tvOS-" + sdk_version.replace(".", "-")
    candidates = [
        device for device in devices.get("devices", {}).get(runtime, [])
        if device.get("isAvailable") and "Apple TV" in device.get("name", "")
    ]
    if not candidates:
        raise ValueError(f"No available Apple TV simulator for {runtime}")
    candidates.sort(key=lambda device: (
        "1080p" not in device["name"],
        "4K" not in device["name"],
        device["name"],
        device["udid"],
    ))
    return candidates[0]["udid"], candidates[0]["name"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-version", required=True)
    args = parser.parse_args()
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True, text=True, check=True, timeout=60,
        )
        identifier, name = select_device(json.loads(result.stdout), args.sdk_version)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"CI simulator selection failed: {error}", file=sys.stderr)
        return 1
    print(f"Selected tvOS {args.sdk_version}: {name} ({identifier})", file=sys.stderr)
    print(identifier)
    return 0


if __name__ == "__main__":
    sys.exit(main())
