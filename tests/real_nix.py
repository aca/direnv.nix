#!/usr/bin/env python3
"""Smoke test against real Nix: python3 tests/real_nix.py /nix/store/...-source."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

binary = Path(__file__).resolve().parents[1] / "zig-out/bin/direnv"
nixpkgs = Path(sys.argv[1]).resolve()
assert (nixpkgs / "pkgs").is_dir(), "pass an existing nixpkgs source path"
system = subprocess.check_output(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"], text=True).strip()

with tempfile.TemporaryDirectory(prefix="direnv-nix-real-") as tmp:
    root = Path(tmp)
    env = {k: v for k, v in os.environ.items() if not k.startswith("DIRENV_")}
    env["XDG_CACHE_HOME"] = str(root / "cache")
    env["BEFORE_REAL_NIX"] = "before"
    env["DIRENV_NIX_ALLOW_DIRS"] = str(root)
    (root / "shell.nix").write_text('''{ inNixShell ? false, pkgs ? import %s {} }:
pkgs.mkShellNoCC {
  packages = [ pkgs.hello ];
  REAL_NIX_VALUE = "works";
  shellHook = "export SHOULD_NOT_RUN=yes";
}
''' % str(nixpkgs))
    (root / "flake.nix").write_text('''{
  inputs.nixpkgs.url = "path:%s";
  outputs = { self, nixpkgs }: {
    devShells.%s.default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.%s; };
  };
}
''' % (str(nixpkgs), system, system))

    def run(*args, environment=env):
        r = subprocess.run([str(binary), *args], cwd=root, env=environment, text=True, capture_output=True)
        assert r.returncode == 0, r.stderr
        return r

    def apply(script, environment=env):
        r = subprocess.run([shutil.which("bash"), "-c", script + "\n" + shlex.quote(shutil.which("env")) + " -0"], cwd=root, env=environment, capture_output=True)
        assert r.returncode == 0, r.stderr
        return dict(entry.decode().split("=", 1) for entry in r.stdout.split(b"\0") if entry)

    for directive in ("use nix", "use flake"):
        (root / ".envrc").write_text(directive + "\n")
        cold = run("export", "bash")
        assert cold.stderr == "", cold.stderr
        active = apply(cold.stdout)
        assert active["REAL_NIX_VALUE"] == "works"
        assert "SHOULD_NOT_RUN" not in active
        assert active["HOME"] == env["HOME"]
        assert active["PATH"].endswith(env["PATH"])
        hello = subprocess.check_output(["hello"], env=active, text=True).strip()
        assert hello == "Hello, world!", hello
        assert run("export", "bash", environment=active).stdout == "", "unchanged prompt must emit nothing"
        # No nix on PATH: only a cache hit can succeed.
        warm = run("export", "bash", environment={**env, "PATH": "/nonexistent"})
        assert apply(warm.stdout)["REAL_NIX_VALUE"] == "works"
        state = json.loads(active["DIRENV_NIX_STATE"])
        profile = next((root / "cache").rglob("profile-" + state["fingerprint"]))
        assert profile.is_symlink() and profile.exists()
        roots = subprocess.check_output(["nix-store", "--query", "--roots", str(profile.resolve())], text=True)
        assert str(profile.parent) in roots, roots
        print(f"PASS {directive}: real package, cache hit, empty prompt output, GC root")
