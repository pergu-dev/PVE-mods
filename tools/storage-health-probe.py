#!/usr/bin/env python3

import argparse
import datetime
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path


def run(command, timeout=120):
    started = time.monotonic()
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return {
            "command": command,
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "command": command,
            "returncode": None,
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "",
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "timed_out": True,
        }


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_command_result(path, result):
    path.write_text(
        f"command: {' '.join(result['command'])}\n"
        f"returncode: {result['returncode']}\n"
        f"elapsed_seconds: {result['elapsed_seconds']}\n"
        f"timed_out: {str(result['timed_out']).lower()}\n\n"
        "===== STDOUT =====\n"
        f"{result['stdout']}"
        "\n===== STDERR =====\n"
        f"{result['stderr']}",
        encoding="utf-8",
    )


def parse_scan(output):
    devices = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        match = re.match(r"^(\S+)(?:\s+-d\s+(\S+))?", line)
        if not match:
            continue

        devices.append({
            "path": match.group(1),
            "type": match.group(2),
            "scan_line": line,
        })
    return devices


def decode_json(result):
    try:
        return json.loads(result["stdout"])
    except (json.JSONDecodeError, TypeError):
        return None


def stable_identity(data, fallback):
    if not isinstance(data, dict):
        return fallback

    candidates = [
        data.get("serial_number"),
        data.get("wwn", {}).get("naa") if isinstance(data.get("wwn"), dict) else None,
        data.get("nvme_eui64"),
        data.get("nvme_nguid"),
    ]
    for value in candidates:
        if value not in (None, ""):
            return str(value)
    return fallback


def safe_filename(value):
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value)
    return value.strip("_") or "device"


def block_device_sysfs_path(device):
    name = Path(device["path"]).name
    path = Path("/sys/class/block") / name / "device"

    try:
        return str(path.resolve())
    except OSError:
        return ""


def uses_ata_no_wake(device):
    if device.get("type") in ("ata", "sat"):
        return True

    return "/ata" in block_device_sysfs_path(device)


def smartctl_command(device, no_wake):
    command = ["smartctl", "-a", "-j"]
    if no_wake and uses_ata_no_wake(device):
        command.extend(["-n", "standby"])
    command.append(device["path"])
    return command


def decode_smartctl_exit_bits(returncode):
    if returncode is None:
        return ["timeout"]

    meanings = (
        (1, "command_line_error"),
        (2, "device_open_or_identify_failed"),
        (4, "smart_command_failed"),
        (8, "smart_status_disk_failing"),
        (16, "prefail_attribute_below_threshold"),
        (32, "smart_status_past_threshold"),
        (64, "error_log_contains_records"),
        (128, "self_test_log_contains_errors"),
    )
    return [name for bit, name in meanings if returncode & bit]


def collect_device(device, output_dir, baseline):
    no_wake_result = run(smartctl_command(device, True))
    no_wake_data = decode_json(no_wake_result)
    identity = stable_identity(no_wake_data, os.path.basename(device["path"]))
    device_dir = output_dir / safe_filename(identity)
    device_dir.mkdir(parents=True, exist_ok=True)

    write_json(device_dir / "scan.json", device)
    write_command_result(device_dir / "no-wake.txt", no_wake_result)
    if no_wake_data is not None:
        write_json(device_dir / "no-wake.json", no_wake_data)

    summary = {
        "identity": identity,
        "path": device["path"],
        "type": device.get("type"),
        "sysfs_path": block_device_sysfs_path(device),
        "ata_no_wake_applied": uses_ata_no_wake(device),
        "no_wake_returncode": no_wake_result["returncode"],
        "no_wake_exit_bits": decode_smartctl_exit_bits(
            no_wake_result["returncode"]
        ),
        "no_wake_elapsed_seconds": no_wake_result["elapsed_seconds"],
        "baseline_requested": baseline,
        "baseline_performed": False,
    }

    if baseline:
        baseline_result = run(smartctl_command(device, False))
        baseline_data = decode_json(baseline_result)
        write_command_result(device_dir / "baseline.txt", baseline_result)
        if baseline_data is not None:
            write_json(device_dir / "baseline.json", baseline_data)
            summary["identity"] = stable_identity(baseline_data, identity)
        summary["baseline_performed"] = True
        summary["baseline_returncode"] = baseline_result["returncode"]
        summary["baseline_exit_bits"] = decode_smartctl_exit_bits(
            baseline_result["returncode"]
        )
        summary["baseline_elapsed_seconds"] = baseline_result["elapsed_seconds"]

        after_result = run(smartctl_command(device, True))
        after_data = decode_json(after_result)
        write_command_result(device_dir / "after-baseline-no-wake.txt", after_result)
        if after_data is not None:
            write_json(device_dir / "after-baseline-no-wake.json", after_data)
        summary["after_baseline_returncode"] = after_result["returncode"]
        summary["after_baseline_exit_bits"] = decode_smartctl_exit_bits(
            after_result["returncode"]
        )
        summary["after_baseline_elapsed_seconds"] = after_result["elapsed_seconds"]

    write_json(device_dir / "summary.json", summary)
    return summary


def main():
    parser = argparse.ArgumentParser(
        description="Collect read-only ZFS and SMART behavior fixtures for PVE-mods storage health development."
    )
    parser.add_argument(
        "--baseline",
        action="store_true",
        help="Perform one full SMART query per device. This may wake sleeping disks.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output directory. Defaults to storage-health-probe-<timestamp>.",
    )
    parser.add_argument(
        "--device",
        action="append",
        default=[],
        help=(
            "Collect only the specified device. May be repeated, "
            "for example: --device /dev/sda --device /dev/nvme0"
        ),
    )
    parser.add_argument(
        "--discovery-only",
        action="store_true",
        help="Record device discovery and ZFS status without SMART queries.",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        parser.error("run as root so smartctl can access all devices")

    for executable in ("smartctl", "zpool"):
        if not shutil.which(executable):
            parser.error(f"required executable not found: {executable}")

    timestamp = datetime.datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
    output_dir = args.output or Path("/root") / f"storage-health-probe-{timestamp}"
    output_dir.mkdir(parents=True, exist_ok=False)

    metadata = {
        "generated_at": datetime.datetime.now().astimezone().isoformat(),
        "hostname": socket.gethostname(),
        "kernel": platform.release(),
        "platform": platform.platform(),
        "baseline_requested": args.baseline,
        "warning": "Baseline mode may wake sleeping disks." if args.baseline else "No-wake mode requested for ATA devices.",
    }
    write_json(output_dir / "metadata.json", metadata)

    version_result = run(["smartctl", "--version"])
    write_command_result(output_dir / "smartctl-version.txt", version_result)

    zpool_status = run(["zpool", "status", "-gLP"])
    write_command_result(output_dir / "zpool-status-gLP.txt", zpool_status)

    zpool_health = run(["zpool", "status", "-x"])
    write_command_result(output_dir / "zpool-status-x.txt", zpool_health)

    scan_result = run(["smartctl", "--scan"])
    write_command_result(output_dir / "smartctl-scan.txt", scan_result)
    devices = parse_scan(scan_result["stdout"])

    if args.device:
        requested = set(args.device)
        discovered = {device["path"] for device in devices}
        missing = sorted(requested - discovered)

        if missing:
            parser.error(
                "requested device(s) not discovered: "
                + ", ".join(missing)
            )

        devices = [
            device
            for device in devices
            if device["path"] in requested
        ]

    write_json(output_dir / "devices.json", devices)

    summaries = []

    if not args.discovery_only:
        device_output_dir = output_dir / "devices"
        device_output_dir.mkdir()

        for device in devices:
            print(
                f"Collecting {device['path']} "
                f"({device.get('type') or 'auto'})",
                flush=True,
            )
            summaries.append(
                collect_device(
                    device,
                    device_output_dir,
                    args.baseline,
                )
            )

    write_json(output_dir / "summary.json", {
        "device_count": len(devices),
        "baseline_requested": args.baseline,
        "discovery_only": args.discovery_only,
        "requested_devices": args.device,
        "devices": summaries,
    })

    print(f"Wrote {output_dir}")
    if not args.baseline:
        print("No baseline queries were requested. Re-run with --baseline only if waking sleeping disks is acceptable.")


if __name__ == "__main__":
    main()
