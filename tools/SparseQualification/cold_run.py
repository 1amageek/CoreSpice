#!/usr/bin/env python3
"""Run a retained qualification deck in a fresh bounded process group."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(executable, deck, output, timeout, mode="cli", allocation=268435456, work=2000000000, execution_profile=None, live_bytes=None):
    executable, deck = executable.resolve(strict=True), deck.resolve(strict=True)
    if live_bytes is not None and (mode != "probe" or not isinstance(live_bytes, int) or not 0 < live_bytes <= 18446744073709551615):
        raise ValueError("live-bytes requires probe mode and a positive UInt64 value")
    profile = None
    if execution_profile is not None:
        if mode != "cli" or not execution_profile.is_absolute():
            raise ValueError("execution-profile requires CLI mode and an absolute path")
        execution_profile = execution_profile.resolve(strict=True)
        profile_bytes = execution_profile.read_bytes()
        profile = dict(absolute_path=str(execution_profile), bytes=len(profile_bytes),
                       sha256=hashlib.sha256(profile_bytes).hexdigest())
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve()
    csv = output / "waveform.csv"
    if mode == "cli":
        args = [str(executable), "-b", str(deck), "--csv", str(csv), "--json"]
        if profile is not None:
            args += ["--execution-profile", str(execution_profile)]
    elif mode == "probe":
        args = [str(executable), str(deck), str(csv), str(output / "native.json"), str(allocation), str(work)]
        if live_bytes is not None:
            args += ["--live-bytes", str(live_bytes)]
    else:
        args = [str(executable), "-b", "-r", str(output / "waveform.raw"), str(deck)]
    command = ["/usr/bin/time", "-l"] + args
    environment = os.environ.copy()
    if mode == "ngspice":
        environment["SPICE_ASCIIRAWFILE"] = "1"
    started = time.monotonic()
    timed_out = False
    with (output / "stdout.txt").open("wb") as stdout, (output / "stderr.txt").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, env=environment,
                                   start_new_session=True, cwd=output)
        try:
            returncode = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        finally:
            # The time/CLI leader may exit while an ignoring descendant still owns the group.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            returncode = process.wait(timeout=2)
    elapsed = time.monotonic() - started
    stderr = (output / "stderr.txt").read_text(errors="replace")
    rss = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$", stderr, re.MULTILINE)
    time_line = re.search(r"^\s*([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys\s*$", stderr, re.MULTILINE)
    receipt = dict(schema_version=1, mode=mode, command=command, executable=str(executable),
                   executable_sha256=sha256(executable), deck=str(deck), deck_sha256=sha256(deck),
                   process_wall_seconds=elapsed, timeout_seconds=timeout, timed_out=timed_out,
                   returncode=returncode, status="timed_out" if timed_out else "succeeded" if returncode == 0 else "refused_or_failed",
                   maximum_resident_set_bytes=int(rss[1]) if rss else None,
                   time_l=dict(real_seconds=float(time_line[1]), user_seconds=float(time_line[2]), system_seconds=float(time_line[3])) if time_line else None,
                   measurement="cold process including load, preparation, solve, audit and output", artifacts={})
    if live_bytes is not None:
        receipt["probe_live_bytes"] = live_bytes
    if profile is not None:
        receipt["execution_profile"] = profile
        if not execution_profile.exists() or execution_profile.read_bytes() != profile_bytes:
            receipt["status"] = "execution_profile_changed"
    for path in sorted(output.iterdir()):
        if path.is_file():
            receipt["artifacts"][path.name] = dict(sha256=sha256(path), bytes=path.stat().st_size)
    if receipt["status"] == "succeeded":
        expected = output / ("waveform.raw" if mode == "ngspice" else "waveform.csv")
        if not expected.exists() or expected.stat().st_size == 0:
            receipt["status"] = "missing_output"
        elif rss is None or time_line is None:
            receipt["status"] = "missing_process_measurement"
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("deck", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--mode", choices=["cli", "probe", "ngspice"], default="cli")
    parser.add_argument("--allocation", type=int, default=268435456)
    parser.add_argument("--work", type=int, default=2000000000)
    parser.add_argument("--execution-profile", type=Path)
    parser.add_argument("--live-bytes", type=int)
    args = parser.parse_args()
    if args.timeout <= 0 or args.allocation <= 0 or args.work <= 0:
        parser.error("timeout/allocation/work must be positive")
    if args.live_bytes is not None and (args.mode != "probe" or not 0 < args.live_bytes <= 18446744073709551615):
        parser.error("live-bytes requires probe mode and a positive UInt64 value")
    if args.execution_profile is not None and (args.mode != "cli" or not args.execution_profile.is_absolute()):
        parser.error("execution-profile requires CLI mode and an absolute path")
    receipt = run(args.executable, args.deck, args.output, args.timeout, args.mode, args.allocation, args.work, args.execution_profile, args.live_bytes)
    print(json.dumps(receipt, indent=2, sort_keys=True))
    raise SystemExit(0 if receipt["status"] == "succeeded" else 1)
