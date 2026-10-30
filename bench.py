#!/usr/bin/env python3
"""Repeatable warm-start benchmark; includes subprocess launch overhead.

python3 bench.py [iterations]
Uses temporary fixtures; never changes the invoking shell or its direnv config.
"""
import json
import os
import platform
from pathlib import Path
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

binary = Path(__file__).resolve().parent / "zig-out/bin/direnv"
iterations = int(sys.argv[1]) if len(sys.argv) > 1 else 300
assert iterations > 0
bash = shutil.which("bash")
env_bin = shutil.which("env")
direnv = shutil.which("direnv")


def run(argv, cwd, env):
    r = subprocess.run(argv, cwd=cwd, env=env, capture_output=True)
    if r.returncode:
        raise RuntimeError(r.stderr.decode())
    return r.stdout


def apply(script, cwd, env):
    data = run([bash, "-c", script.decode() + "\n" + shlex.quote(env_bin) + " -0"], cwd, env)
    return dict(item.decode().split("=", 1) for item in data.split(b"\0") if item)


def measure(argv, cwd, env):
    for _ in range(20):
        run(argv, cwd, env)
    samples = []
    for _ in range(iterations):
        start = time.perf_counter_ns()
        run(argv, cwd, env)
        samples.append((time.perf_counter_ns() - start) / 1_000_000)
    return {"median_ms": round(statistics.median(samples), 3),
            "p95_ms": round(sorted(samples)[int((len(samples) - 1) * .95)], 3)}


with tempfile.TemporaryDirectory(prefix="direnv-nix-bench-") as tmp:
    root = Path(tmp)
    project = root / "project"
    project.mkdir()
    outside = root / "outside"
    outside.mkdir()
    fakebin = root / "bin"
    fakebin.mkdir()
    fake = fakebin / "nix"
    fake.write_text(f"#!{sys.executable}\n" + '''
import json, pathlib, sys
pathlib.Path(sys.argv[sys.argv.index("--profile") + 1]).write_text("fake profile")
print(json.dumps({"variables": {"PATH": {"type": "exported", "value": "/nix/store/bench/bin"},
"NIX_VALUE": {"type": "exported", "value": "cached"}}}))
''')
    fake.chmod(0o755)
    env = {"HOME": str(root), "PATH": str(fakebin) + ":" + os.environ["PATH"],
           "XDG_CACHE_HOME": str(root / "cache"), "XDG_DATA_HOME": str(root / "data"),
           "XDG_CONFIG_HOME": str(root / "config"), "DIRENV_LOG_FORMAT": "",
           "DIRENV_NIX_ALLOW_DIRS": f"{outside}:{project}"}
    rows = {}
    rows["direnv.nix/no-project"] = measure([str(binary), "export", "bash"], outside, env)
    for label, source in (("env-only", 'export BENCH_VALUE=hello\nexport PATH="$HOME/bin:$PATH"\n'),
                          ("nix-cache", "use flake\nexport BENCH_VALUE=hello\n")):
        (project / ".envrc").write_text(source)
        active = apply(run([str(binary), "export", "bash"], project, env), project, env)
        rows[f"direnv.nix/{label}/reentry"] = measure([str(binary), "export", "bash"], project, env)
        rows[f"direnv.nix/{label}/unchanged"] = measure([str(binary), "export", "bash"], project, active)
        # Complete hook path: shell launch, command substitution and eval included.
        command = 'eval "$(' + shlex.quote(str(binary)) + ' export bash)"'
        rows[f"direnv.nix/{label}/shell+reentry"] = measure([bash, "-c", command], project, env)
    all_env = {**env, "DIRENV_NIX_ALLOW_ALL": "1"}
    all_active = apply(run([str(binary), "export", "bash"], project, all_env), project, all_env)
    rows["direnv.nix/nix-cache/allow-all/reentry"] = measure([str(binary), "export", "bash"], project, all_env)
    rows["direnv.nix/nix-cache/allow-all/unchanged"] = measure([str(binary), "export", "bash"], project, all_active)
    if direnv:
        (project / ".envrc").write_text('export BENCH_VALUE=hello\nexport PATH="$HOME/bin:$PATH"\n')
        run([direnv, "allow"], project, env)
        active = apply(run([direnv, "export", "bash"], project, env), project, env)
        rows["direnv/env-only/reentry"] = measure([direnv, "export", "bash"], project, env)
        rows["direnv/env-only/unchanged"] = measure([direnv, "export", "bash"], project, active)
        rows["direnv/no-project"] = measure([direnv, "export", "bash"], outside, env)
        command = 'eval "$(' + shlex.quote(direnv) + ' export bash)"'
        rows["direnv/env-only/shell+reentry"] = measure([bash, "-c", command], project, env)
    print(json.dumps({"iterations": iterations, "platform": platform.platform(),
                      "binary_version": run([str(binary), "--version"], root, env).decode().strip(),
                      "direnv_version": run([direnv, "version"], root, env).decode().strip() if direnv else None,
                      "note": "wall time includes process launch; ALLOW_DIRS has two entries matching the second unless allow-all is specified; Nix cache fixture uses fake Nix; direnv comparison is env-only",
                      "results": rows}, indent=2))
