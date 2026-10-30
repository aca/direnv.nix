#!/usr/bin/env python3
"""Paired warm-path comparison: python3 bench_compare.py BEFORE AFTER [runs].

Uses the same fixture and environment for both binaries. Randomized execution
order reduces timing drift. No environment values are included in the results.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).parent / "tests"))
from integration import Integration, BASH, ENV

binaries = [Path(p).resolve() for p in sys.argv[1:3]]
assert len(binaries) == 2
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 1000
fixture = Integration()
fixture.setUp()


def run(binary, cwd, env):
    r = subprocess.run([str(binary), "export", "bash"], cwd=cwd, env=env, capture_output=True)
    if r.returncode:
        raise RuntimeError(r.stderr.decode())
    return r.stdout


try:
    base = {k: v for k, v in os.environ.items() if not k.startswith("DIRENV_")}
    base.update(fixture.env)
    outside = fixture.top / "outside"
    outside.mkdir()
    rng = random.Random(0)
    results = {}
    for name, source in (("no-project", None), ("env-only", 'export BENCH_VALUE=hello\n'),
                         ("nix-cache", 'use flake\n')):
        if source is not None:
            fixture.config(source)
        cwd = outside if source is None else fixture.project
        # Separate caches keep the benchmark valid even across format changes.
        envs = [{**base, "XDG_CACHE_HOME": str(fixture.top / f"cache-{i}")} for i in range(2)]
        active = []
        for binary, env in zip(binaries, envs):
            script = run(binary, cwd, env)
            r = subprocess.run([BASH, "-c", script.decode() + "\n" + ENV + " -0"],
                               cwd=cwd, env=env, capture_output=True, check=True)
            active.append(dict(x.decode().split("=", 1) for x in r.stdout.split(b"\0") if x))
        for mode, environments in (("reentry", envs), ("unchanged", active)):
            if name == "no-project" and mode == "unchanged":
                continue
            for _ in range(25):
                for binary, env in zip(binaries, environments):
                    run(binary, cwd, env)
            samples = [[], []]
            for _ in range(runs):
                order = [0, 1]
                rng.shuffle(order)
                for i in order:
                    start = time.perf_counter_ns()
                    run(binaries[i], cwd, environments[i])
                    samples[i].append((time.perf_counter_ns() - start) / 1_000_000)
            medians = [statistics.median(s) for s in samples]
            results[f"{name}/{mode}"] = {
                "before_median_ms": round(medians[0], 3),
                "after_median_ms": round(medians[1], 3),
                "before_p95_ms": round(sorted(samples[0])[int(runs * .95)], 3),
                "after_p95_ms": round(sorted(samples[1])[int(runs * .95)], 3),
                "median_reduction_percent": round((1 - medians[1] / medians[0]) * 100, 1),
            }
    print(json.dumps({"platform": platform.platform(), "runs_per_binary_per_case": runs,
                      "environment_variable_count": len(base),
                      "binary_sha256": [hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries],
                      "note": "paired randomized order; process launch included; fake Nix populates warm cache",
                      "results": results}, indent=2))
finally:
    fixture.doCleanups()
