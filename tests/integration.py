#!/usr/bin/env python3
"""Black-box tests. A fake Nix makes cache correctness tests offline and repeatable."""
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

BIN = Path(os.environ.get("DIRENV_NIX_BIN", Path(__file__).resolve().parents[1] / "zig-out/bin/direnv")).resolve()
BASH = shutil.which("bash")
ZSH = shutil.which("zsh")
ELVISH = shutil.which("elvish")
FISH = shutil.which("fish")
ENV = shutil.which("env")


def elv_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="direnv-nix-test-")
        self.addCleanup(self.tmp.cleanup)
        self.top = Path(self.tmp.name)
        self.project = self.top / "project with 'quotes"
        self.project.mkdir()
        self.fakebin = self.top / "bin"
        self.fakebin.mkdir()
        fake = self.fakebin / "nix"
        fake.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys, time
assert not any(k.startswith("DIRENV_NIX_") for k in os.environ)
p = pathlib.Path.cwd()
with (p / "calls").open("a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
if (p / "fail").exists():
    print("intentional Nix failure", file=sys.stderr)
    sys.exit(1)
if (p / "slow").exists():
    time.sleep(0.15)
profile = pathlib.Path(sys.argv[sys.argv.index("--profile") + 1])
profile.write_text("fake gc root")
value = (p / "value.nix").read_text() if (p / "value.nix").exists() else "hello"
print(json.dumps({"variables": {
    "FROM_NIX": {"type": "exported", "value": value},
    "PATH": {"type": "exported", "value": "/nix/store/fake/bin"},
    "HOME": {"type": "exported", "value": "/homeless-shelter"},
    "TMPDIR": {"type": "exported", "value": "/nonexistent/build"},
    "TERM": {"type": "exported", "value": "xterm-256color"},
    "TZ": {"type": "exported", "value": "UTC"},
    "XDG_DATA_DIRS": {"type": "exported", "value": "/nix/store/fake/share"},
    "NOT_EXPORTED": {"type": "var", "value": "ignored"},
    "shellHook": {"type": "exported", "value": "touch SHOULD_NOT_EXIST"},
    "NIX_SEES_BEFORE": {"type": "exported", "value": os.environ.get("BEFORE", "")},
    "DIRENV_NIX_ALLOW_ALL": {"type": "exported", "value": "1"}
}, "bashFunctions": {"ignored": "touch SHOULD_NOT_EXIST"}}))
''')
        fake.chmod(0o755)
        self.env = {
            "PATH": str(self.fakebin) + ":" + os.environ["PATH"],
            "HOME": str(self.top),
            "XDG_CACHE_HOME": str(self.top / "cache"),
            "TMPDIR": str(self.top),
            "LANG": "C.UTF-8",
            "DIRENV_NIX_ALLOW_DIRS": str(self.top),
            # NixOS zsh always reads its global zshenv, and bash reads bashrc
            # when stdin is a socket; both would source /etc/set-environment
            # and replace the test's allow policy with the host's.
            "__NIXOS_SET_ENVIRONMENT_DONE": "1",
        }

    def config(self, source, project=None):
        p = project or self.project
        (p / ".envrc").write_text(source)
        return p

    def run_cli(self, *args, cwd=None, env=None, ok=True):
        r = subprocess.run([str(BIN), *args], cwd=cwd or self.project, env=env or self.env,
                           capture_output=True, text=True)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.stdout, "", "failure must not emit partial shell code")
        return r

    def apply(self, script, env=None, shell=BASH, cwd=None):
        r = subprocess.run([shell, "-c", script + "\n" + shlex.quote(ENV) + " -0"],
                           cwd=cwd or self.project, env=env or self.env, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        return dict(item.decode().split("=", 1) for item in r.stdout.split(b"\0") if item)

    def activate(self, env=None, cwd=None):
        return self.apply(self.run_cli("export", "bash", env=env, cwd=cwd).stdout, env=env, cwd=cwd)

    def calls(self):
        p = self.project / "calls"
        return len(p.read_text().splitlines()) if p.exists() else 0

    def apply_elvish(self, script, env=None, cwd=None):
        r = subprocess.run([ELVISH, "-norc", "-c", script + "\n" + elv_quote(ENV) + " -0"],
                           cwd=cwd or self.project, env=env or self.env, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        return dict(item.decode().split("=", 1) for item in r.stdout.split(b"\0") if item)

    def apply_fish(self, script, env=None, cwd=None):
        r = subprocess.run([FISH, "--no-config", "-c", script + "\n" + shlex.quote(ENV) + " -0"],
                           cwd=cwd or self.project, env=env or self.env, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        return dict(item.decode().split("=", 1) for item in r.stdout.split(b"\0") if item)

    def test_json_export_and_restoration(self):
        self.env.update({"DELETE": "present"})
        self.config('NEW=\'a"b\\c\'\nunset DELETE\n')
        out = json.loads(self.run_cli("export", "json").stdout)
        self.assertEqual(out["NEW"], 'a"b\\c')
        self.assertIsNone(out["DELETE"])
        self.assertEqual(out["DIRENV_DIR"], str(self.project))
        active = {k: v for k, v in {**self.env, **out}.items() if v is not None}
        self.assertEqual(self.run_cli("export", "json", env=active).stdout, "")
        restored = json.loads(self.run_cli("export", "json", env=active, cwd=self.top).stdout)
        self.assertEqual(restored["DELETE"], "present")
        for name in ("NEW", "DIRENV_NIX_STATE", "DIRENV_DIR"):
            self.assertIsNone(restored[name])
        self.run_cli("hook", "json", ok=False)

    @unittest.skipUnless(FISH, "fish not installed")
    def test_fish_quotes_path_list_and_restoration(self):
        self.env.update({"ORIGINAL": "before", "DELETE": "present"})
        self.config('ORIGINAL="it\'s \\\\ $HOME"\nunset DELETE\nNEW=\'(touch SHOULD_NOT_EXIST) $literal\'\nPATH="$PWD/bin:$PATH"\n')
        active = self.apply_fish(self.run_cli("export", "fish").stdout + "\ntype -q env; or exit 9")
        self.assertEqual(active["ORIGINAL"], "it's \\ " + str(self.top))
        self.assertEqual(active["NEW"], "(touch SHOULD_NOT_EXIST) $literal")
        self.assertNotIn("DELETE", active)
        self.assertEqual(active["PATH"], str(self.project / "bin") + ":" + self.env["PATH"])
        self.assertEqual(active["DIRENV_DIR"], str(self.project))
        self.assertFalse((self.project / "SHOULD_NOT_EXIST").exists())
        self.assertEqual(self.run_cli("export", "fish", env=active).stdout, "")
        restored = self.apply_fish(self.run_cli("export", "fish", env=active, cwd=self.top).stdout, env=active, cwd=self.top)
        for name in ("ORIGINAL", "DELETE", "PATH"):
            self.assertEqual(restored[name], self.env[name])
        self.assertNotIn("NEW", restored)
        self.assertNotIn("DIRENV_NIX_STATE", restored)
        self.assertNotIn("DIRENV_DIR", restored)

    @unittest.skipUnless(FISH, "fish not installed")
    def test_fish_hook_multiline_nix_value_and_failed_export(self):
        value = "한글 'quote' \\ end\nset -gx EVIL yes\n(touch SHOULD_NOT_EXIST)\n"
        (self.project / "value.nix").write_text(value)
        self.config("use nix\nwatch_file value.nix\n")
        hook = self.run_cli("hook", "fish").stdout
        script = hook + hook + "emit fish_prompt\nfunctions -q _direnv_nix_hook; or exit 9"
        active = self.apply_fish(script)
        self.assertEqual(active["FROM_NIX"], value)
        self.assertNotIn("EVIL", active)
        self.assertFalse((self.project / "SHOULD_NOT_EXIST").exists())
        (self.project / "value.nix").write_text("changed")
        (self.project / "fail").touch()
        failed = self.apply_fish(script, env=active)
        self.assertEqual(failed["FROM_NIX"], value)
        self.assertEqual(failed["DIRENV_NIX_STATE"], active["DIRENV_NIX_STATE"])

    @unittest.skipUnless(ELVISH, "elvish not installed")
    def test_elvish_quotes_unsets_path_and_cross_shell_restoration(self):
        self.env.update({"ORIGINAL": "before", "EMPTY": "", "DELETE": "present"})
        self.config('ORIGINAL="it\'s $HOME"\nEMPTY=filled\nunset DELETE\nNEW=\'(touch SHOULD_NOT_EXIST) $literal\'\nPATH="$PWD/bin:$PATH"\n')
        active = self.apply_elvish(self.run_cli("export", "elvish").stdout)
        self.assertEqual(active["ORIGINAL"], "it's " + str(self.top))
        self.assertEqual(active["NEW"], "(touch SHOULD_NOT_EXIST) $literal")
        self.assertNotIn("DELETE", active)
        self.assertEqual(active["PATH"], str(self.project / "bin") + ":" + self.env["PATH"])
        self.assertFalse((self.project / "SHOULD_NOT_EXIST").exists())
        self.assertEqual(self.run_cli("export", "elvish", env=active).stdout, "")
        for shell in ("elvish", "bash"):
            script = self.run_cli("export", shell, env=active, cwd=self.top).stdout
            restored = (self.apply_elvish if shell == "elvish" else self.apply)(script, env=active, cwd=self.top)
            for name in ("ORIGINAL", "EMPTY", "DELETE", "PATH"):
                self.assertEqual(restored[name], self.env[name])
            self.assertNotIn("NEW", restored)
            self.assertNotIn("DIRENV_NIX_STATE", restored)

    @unittest.skipUnless(ELVISH, "elvish not installed")
    def test_elvish_hook_multiline_nix_cache_and_failed_export(self):
        value = "한글 'quote'\nset-env EVIL yes\n(touch SHOULD_NOT_EXIST)\n"
        (self.project / "value.nix").write_text(value)
        self.config("use nix\nwatch_file value.nix\n")
        hook = self.run_cli("hook", "elvish").stdout
        # Simulate the editor namespace for a deterministic noninteractive test;
        # the separate PTY test exercises the real interactive editor.
        script = 'var edit: = (ns [&before-readline=[{ set-env PREVIOUS_HOOK ran }]])\n'
        script += "eval " + elv_quote(hook) + "\neach {|f| $f } $edit:before-readline\n"
        active = self.apply_elvish(script)
        self.assertEqual(active["PREVIOUS_HOOK"], "ran")
        self.assertEqual(active["FROM_NIX"], value)
        self.assertNotIn("EVIL", active)
        self.assertFalse((self.project / "SHOULD_NOT_EXIST").exists())
        self.assertEqual(self.calls(), 1)
        self.assertEqual(self.run_cli("export", "elvish", env=active).stdout, "")
        (self.project / "value.nix").write_text("changed")
        (self.project / "fail").touch()
        failed = self.apply_elvish(script, env=active)
        self.assertEqual(failed["FROM_NIX"], value)
        self.assertEqual(failed["DIRENV_NIX_STATE"], active["DIRENV_NIX_STATE"])

    @unittest.skipUnless(ELVISH and os.name == "posix", "Elvish PTY test requires POSIX")
    def test_elvish_interactive_startup_edits_and_exit(self):
        import pty
        import select
        import time
        self.config("FOO=initial\n")
        snapshot = self.top / "snapshot.json"
        rc = self.top / "rc.elv"
        hook = self.run_cli("hook", "elvish").stdout
        rc.write_text(hook + '''
set edit:prompt = { print 'DNX> ' }
set edit:rprompt = { }
set edit:before-readline = [(all $edit:before-readline) {
  put [&foo=$E:FOO &active=(has-env DIRENV_NIX_STATE)] | to-json > ''' + elv_quote(snapshot) + '''
}]
''')
        master, slave = pty.openpty()
        process = subprocess.Popen([ELVISH, "-rc", str(rc)], cwd=self.project,
                                   env={**self.env, "TERM": "xterm"}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        def wait_snapshot(expected):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if select.select([master], [], [], .02)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
                try:
                    if json.loads(snapshot.read_text()) == expected:
                        return
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                if process.poll() is not None:
                    break
            self.fail("interactive hook did not apply environment: " + output.decode(errors="replace"))
        try:
            wait_snapshot({"foo": "initial", "active": True})
            self.config("FOO=edited\n")
            os.write(master, b"\n")
            wait_snapshot({"foo": "edited", "active": True})
            os.write(master, ("cd " + elv_quote(self.top) + "\n").encode())
            wait_snapshot({"foo": "", "active": False})
        finally:
            if process.poll() is None:
                os.write(master, b"exit\n")
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
            finally:
                os.close(master)

    def test_automatic_loading_edits_and_unsupported_syntax(self):
        self.config("export FOO=one\n")
        self.assertIn("loading: automatic", self.run_cli("status").stdout)
        active = self.activate()
        self.assertEqual(active["FOO"], "one")
        self.assertEqual(list((self.top / "cache").rglob("allow")), [])
        self.config("export FOO=two\n")
        self.assertEqual(self.activate(env=active)["FOO"], "two")
        self.config("source .env\n")
        self.run_cli("export", "bash", env=active, ok=False)

    def test_explicit_allow_and_deny(self):
        self.env.pop("DIRENV_NIX_ALLOW_DIRS")
        self.env["XDG_DATA_HOME"] = str(self.top / "data")
        self.config("FOO=explicit\n")
        sub = self.project / "child"
        sub.mkdir()
        other = self.top / "other"
        other.mkdir()
        self.config("FOO=other\n", other)
        self.run_cli("export", "bash", ok=False)
        # Allowing from a subdirectory grants the project that owns the .envrc.
        self.run_cli("allow", cwd=sub)
        self.assertIn("loading: explicit", self.run_cli("status").stdout)
        self.assertEqual(self.activate(cwd=sub)["FOO"], "explicit")
        self.run_cli("export", "bash", cwd=other, ok=False)
        grants = [p for p in (self.top / "data").rglob("*") if p.is_file()]
        self.assertEqual(len(grants), 1)
        self.assertEqual(grants[0].stat().st_mode & 0o777, 0o600)
        # Grants follow the directory, not the .envrc content, and outlive the cache.
        self.config("FOO=edited\n")
        shutil.rmtree(self.top / "cache", ignore_errors=True)
        self.assertEqual(self.activate()["FOO"], "edited")
        self.run_cli("deny")
        self.assertIn("not allowed", self.run_cli("export", "bash", ok=False).stderr)
        self.run_cli("deny")

    def test_no_policy_blocks_loading_before_parsing_or_nix(self):
        self.env.pop("DIRENV_NIX_ALLOW_DIRS")
        self.config("use nix\n")
        self.assertIn("loading: blocked", self.run_cli("status").stdout)
        self.assertIn("not allowed", self.run_cli("export", "bash", ok=False).stderr)
        self.assertEqual(self.calls(), 0)
        self.assertFalse((self.top / "cache").exists())
        # A project cannot grant itself permission.
        self.config("DIRENV_NIX_ALLOW_ALL=1\n")
        self.assertIn("not allowed", self.run_cli("export", "bash", ok=False).stderr)

    def test_allow_dirs_list_boundaries_and_descendants(self):
        self.config("FOO=allowed\n")
        unrelated = self.top / "other"
        unrelated.mkdir()
        self.env["DIRENV_NIX_ALLOW_DIRS"] = f"{unrelated}:{self.project}/"
        self.assertIn("DIRENV_NIX_ALLOW_DIRS", self.run_cli("status").stdout)
        self.assertEqual(self.activate()["FOO"], "allowed")
        child = self.project / "a" / "b"
        child.mkdir(parents=True)
        self.config("FOO=child\n", child)
        self.assertEqual(self.activate(cwd=child)["FOO"], "child")
        sibling = self.project.with_name(self.project.name + "-other")
        sibling.mkdir()
        self.config("FOO=not-allowed\n", sibling)
        self.run_cli("export", "bash", cwd=sibling, ok=False)
        # Trust is attached to the .envrc's directory, not the invocation's cwd.
        self.env["DIRENV_NIX_ALLOW_DIRS"] = str(child)
        (child / ".envrc").unlink()
        self.run_cli("export", "bash", cwd=child, ok=False)

    def test_allow_dirs_real_paths_and_symlink_escape(self):
        self.config("FOO=allowed\n")
        alias = self.top / "alias"
        alias.symlink_to(self.project, target_is_directory=True)
        self.env["DIRENV_NIX_ALLOW_DIRS"] = str(alias)
        self.assertEqual(self.activate()["FOO"], "allowed")
        self.assertEqual(self.activate(cwd=alias)["FOO"], "allowed")
        outside = self.top / "outside"
        outside.mkdir()
        self.config("FOO=outside\n", outside)
        escape = self.project / "escape"
        escape.symlink_to(outside, target_is_directory=True)
        self.run_cli("export", "bash", cwd=escape, ok=False)
        # '..' must be resolved after following a symlink, not lexically.
        nested = self.project / "nested"
        nested.mkdir()
        alias.unlink()
        alias.symlink_to(nested, target_is_directory=True)
        self.env["DIRENV_NIX_ALLOW_DIRS"] = str(alias) + "/.."
        self.assertEqual(self.activate()["FOO"], "allowed")
        self.run_cli("export", "bash", cwd=outside, ok=False)

    def test_empty_missing_relative_and_root_allow_dirs(self):
        self.config("FOO=allowed\n")
        for dirs in ("", "::", str(self.top / "missing")):
            with self.subTest(dirs=dirs):
                self.env["DIRENV_NIX_ALLOW_DIRS"] = dirs
                self.run_cli("export", "bash", ok=False)
        self.env["DIRENV_NIX_ALLOW_DIRS"] = f":{self.top / 'missing'}::{self.project}:"
        self.assertEqual(self.activate()["FOO"], "allowed")
        for dirs in (".", "~/src", f"{self.project}:relative"):
            self.env["DIRENV_NIX_ALLOW_DIRS"] = dirs
            self.assertIn("absolute paths", self.run_cli("export", "bash", ok=False).stderr)
        self.env["DIRENV_NIX_ALLOW_DIRS"] = "/"
        self.assertEqual(self.activate()["FOO"], "allowed")

    def test_allow_all_precedence_and_boolean_values(self):
        self.config("FOO=allowed\n")
        self.env["DIRENV_NIX_ALLOW_DIRS"] = "relative-invalid-list"
        self.env["DIRENV_NIX_ALLOW_ALL"] = "1"
        self.assertIn("DIRENV_NIX_ALLOW_ALL", self.run_cli("status").stdout)
        self.assertEqual(self.activate()["FOO"], "allowed")
        self.env.pop("DIRENV_NIX_ALLOW_DIRS")
        for value in ("0", ""):
            self.env["DIRENV_NIX_ALLOW_ALL"] = value
            self.run_cli("export", "bash", ok=False)
        for value in ("true", "false", "yes", "2"):
            self.env["DIRENV_NIX_ALLOW_ALL"] = value
            self.assertIn("must be 1, 0, or empty", self.run_cli("export", "bash", ok=False).stderr)
        self.env["DIRENV_NIX_ALLOW_ALL"] = "0"
        self.env["DIRENV_NIX_ALLOW_DIRS"] = str(self.project)
        self.assertEqual(self.activate()["FOO"], "allowed")

    def test_policy_changes_checked_on_active_and_cached_paths(self):
        self.config("use nix\n")
        active = self.activate()
        self.assertEqual(self.calls(), 1)
        for environment in (self.env, active):
            denied = {**environment, "DIRENV_NIX_ALLOW_DIRS": ""}
            self.run_cli("export", "bash", env=denied, ok=False)
            self.run_cli("reload", "bash", env=denied, ok=False)
            self.assertIn("loading: blocked", self.run_cli("status", env=denied).stdout)
        self.assertEqual(self.calls(), 1)
        # Changing only the policy does not invalidate the Nix environment.
        changed = {**active, "DIRENV_NIX_ALLOW_DIRS": str(self.project)}
        self.assertEqual(self.run_cli("export", "bash", env=changed).stdout, "")
        self.activate(env={**self.env, "DIRENV_NIX_ALLOW_DIRS": "", "DIRENV_NIX_ALLOW_ALL": "1"})
        self.assertEqual(self.calls(), 1)
        # Even after revocation, leaving the project still restores the shell.
        denied = {**active, "DIRENV_NIX_ALLOW_DIRS": ""}
        self.assertNotIn("FROM_NIX", self.activate(env=denied, cwd=self.top))

    def test_project_cannot_change_policy_and_nix_does_not_receive_it(self):
        for source in ("DIRENV_NIX_ALLOW_ALL=1\n", "unset DIRENV_NIX_ALLOW_DIRS\n", "FOO=$DIRENV_NIX_ALLOW_ALL\n"):
            self.config(source)
            self.run_cli("export", "bash", ok=False)
        self.config("use nix\n")
        active = self.activate()
        self.assertNotIn("DIRENV_NIX_ALLOW_ALL", active)
        self.assertEqual(active["DIRENV_NIX_ALLOW_DIRS"], self.env["DIRENV_NIX_ALLOW_DIRS"])

    def test_restore_unset_empty_expansion_and_quotes(self):
        self.env.update({"EXISTING": "original", "EMPTY": "", "DELETE": "yes"})
        self.config('export EXISTING="it\'s $HOME"\nunset DELETE\nEMPTY=filled\nNEW=\'$(touch SHOULD_NOT_EXIST)\'\nPATH="$HOME/bin:$PATH"\n')
        active = self.activate()
        self.assertEqual(active["EXISTING"], "it's " + str(self.top))
        self.assertNotIn("DELETE", active)
        self.assertFalse((self.project / "SHOULD_NOT_EXIST").exists())
        self.assertEqual(self.run_cli("export", "bash", env=active).stdout, "")
        restored = self.activate(env=active, cwd=self.top)
        for key in ("EXISTING", "EMPTY", "DELETE", "PATH"):
            self.assertEqual(restored[key], self.env[key])
        self.assertNotIn("NEW", restored)
        self.assertNotIn("DIRENV_NIX_STATE", restored)
        self.assertEqual(active["DIRENV_DIR"], str(self.project))
        self.assertNotIn("DIRENV_DIR", restored)

    def test_manual_changes_survive_exit(self):
        self.config("FOO=project\n")
        active = self.activate()
        active["FOO"] = "manually changed"
        self.assertEqual(self.activate(env=active, cwd=self.top)["FOO"], "manually changed")

    def test_nested_projects_and_parent_discovery(self):
        self.config("FOO=parent\nPARENT_ONLY=yes\n")
        sub = self.project / "child"
        sub.mkdir()
        active = self.activate(cwd=sub)
        self.assertEqual(active["FOO"], "parent")
        self.config("FOO=child\n", sub)
        child = self.activate(env=active, cwd=sub)
        self.assertEqual(child["FOO"], "child")
        self.assertNotIn("PARENT_ONLY", child)
        self.assertEqual(self.activate(env=child)["FOO"], "parent")

    def test_pwd_expansion_is_anchored_to_project_on_cached_reentry(self):
        self.config('PROJECT_BIN="$PWD/bin"\n')
        child = self.project / "child"
        child.mkdir()
        for cwd in (child, self.project, child):
            active = self.activate(cwd=cwd, env={**self.env, "PWD": str(cwd)})
            self.assertEqual(active["PROJECT_BIN"], str(self.project / "bin"))
            self.assertEqual(active["PWD"], str(cwd))
            self.assertEqual(self.run_cli("export", "bash", cwd=cwd, env=active).stdout, "")

    def test_nix_cache_watch_reload_and_profile(self):
        self.config("BEFORE=available\nuse flake .#dev\nwatch_file value.nix\nAFTER=$FROM_NIX\n")
        active = self.activate()
        self.assertEqual(self.calls(), 1)
        self.assertEqual(active["NIX_SEES_BEFORE"], "available")
        self.assertEqual(active["AFTER"], "hello")
        self.assertEqual(active["HOME"], self.env["HOME"])
        self.assertEqual(active["TMPDIR"], self.env["TMPDIR"])
        self.assertNotIn("NOT_EXPORTED", active)
        self.assertNotIn("shellHook", active)
        self.assertTrue(active["PATH"].endswith(self.env["PATH"]))
        self.assertEqual(self.run_cli("export", "bash", env=active).stdout, "")
        self.activate()
        self.assertEqual(self.calls(), 1)
        (self.project / "value.nix").write_text("updated")
        active = self.activate(env=active)
        self.assertEqual(active["AFTER"], "updated")
        self.assertEqual(self.calls(), 2)
        self.assertEqual(self.run_cli("reload", "bash", env=active).stderr, "")
        self.assertEqual(self.calls(), 3)
        for p in (self.top / "cache").rglob("profile-*"):
            p.unlink()
        self.activate(env=active)
        self.assertEqual(self.calls(), 4)
        (self.project / "value.nix").unlink()
        self.activate(env=active)
        self.assertEqual(self.calls(), 5)

    def test_flake_impure_flag(self):
        for source, impure in (("use flake\n", False), ("use flake . --impure\n", True), ("use flake --impure\n", True)):
            self.config(source)
            self.run_cli("reload", "bash")
            argv = json.loads((self.project / "calls").read_text().splitlines()[-1])
            self.assertEqual("--impure" in argv, impure, source)
            self.assertEqual(argv[-1], str(self.project))

    def test_nix_keeps_terminal_timezone_and_extends_data_dirs(self):
        self.config("use nix\n")
        self.env.update({"TERM": "tmux-256color", "XDG_DATA_DIRS": "/usr/share"})
        active = self.activate()
        self.assertEqual(active["TERM"], "tmux-256color")
        self.assertNotIn("TZ", active)
        self.assertEqual(active["XDG_DATA_DIRS"], "/nix/store/fake/share:/usr/share")
        restored = self.activate(env=active, cwd=self.top)
        self.assertEqual(restored["XDG_DATA_DIRS"], "/usr/share")
        self.env.pop("XDG_DATA_DIRS")
        self.assertEqual(self.activate()["XDG_DATA_DIRS"], "/nix/store/fake/share")

    def test_nix_file_arguments(self):
        self.config("use nix 'custom shell.nix'\n")
        self.activate()
        argv = json.loads((self.project / "calls").read_text())
        self.assertIn("--impure", argv)
        self.assertEqual(argv[argv.index("--file") + 1], str(self.project / "custom shell.nix"))

    def test_failure_preserves_cache_and_has_no_stdout(self):
        self.config("use nix\nwatch_file value.nix\n")
        active = self.activate()
        cache = next((self.top / "cache").rglob("env.json"))
        previous = cache.read_bytes()
        (self.project / "value.nix").write_text("changed")
        (self.project / "fail").touch()
        self.assertEqual(self.run_cli("export", "bash", env=active, ok=False).stderr, "")
        self.assertIn("intentional Nix failure", self.run_cli("reload", "bash", env=active, ok=False).stderr)
        self.assertEqual(cache.read_bytes(), previous)
        (self.project / "fail").unlink()
        self.assertEqual(self.activate(env=active)["FROM_NIX"], "changed")

    def test_cache_corruption_and_private_files(self):
        self.config("use nix\n")
        self.activate()
        cache = next((self.top / "cache").rglob("env.json"))
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(cache.parent.stat().st_mode & 0o777, 0o700)
        cache.write_text("truncated {")
        self.activate()
        self.assertEqual(self.calls(), 2)

    def test_concurrent_cache_fill(self):
        self.config("use nix\n")
        (self.project / "slow").touch()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.run_cli("export", "bash").stdout, range(4)))
        self.assertEqual(self.calls(), 1)
        for result in results:
            self.assertEqual(self.apply(result)["FROM_NIX"], "hello")

    def test_only_nix_inputs_invalidate_cache(self):
        self.config("use nix\n")
        self.activate()
        self.activate(env={**self.env, "EXTERNAL_INPUT": "changed", "TERM": "other"})
        self.assertEqual(self.calls(), 1)
        moved = self.activate(env={**self.env, "PATH": "/other/bin:" + self.env["PATH"]})
        self.assertTrue(moved["PATH"].endswith("/other/bin:" + self.env["PATH"]))
        self.assertEqual(self.calls(), 1)
        self.activate(env={**self.env, "NIX_PATH": "nixpkgs=/elsewhere"})
        self.assertEqual(self.calls(), 2)

    def test_changes_during_evaluation_are_not_cached(self):
        self.config("use nix\nwatch_file value.nix\n")
        (self.project / "slow").touch()
        process = subprocess.Popen([str(BIN), "export", "bash"], cwd=self.project,
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # Wait for the fake evaluator to start before changing an input.
        import time
        deadline = time.monotonic() + 5
        while not (self.project / "calls").exists():
            if time.monotonic() > deadline:
                process.kill()
                self.fail("evaluator did not start")
            time.sleep(.005)
        (self.project / "value.nix").write_text("changed during evaluation")
        stdout, stderr = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertIn("InputChangedDuringEvaluation", stderr)
        self.assertEqual(list((self.top / "cache").rglob("env.json")), [])

    def test_default_inputs_and_custom_nix_file_are_watched(self):
        for directive, watched in (("use flake", "flake.lock"), ("use nix", "shell.nix"),
                                   ("use nix custom.nix", "custom.nix")):
            self.config(directive + "\n")
            active = self.activate()
            before = self.calls()
            (self.project / watched).write_text("changed")
            self.activate(env=active)
            self.assertEqual(self.calls(), before + 1)

    def test_multiline_nix_values_are_quoted_and_state_is_validated(self):
        value = "a'quote\nexport EVIL=yes\n$(touch SHOULD_NOT_EXIST)"
        (self.project / "value.nix").write_text(value)
        self.config("use nix\n")
        active = self.activate()
        self.assertEqual(active["FROM_NIX"], value)
        self.assertNotIn("EVIL", active)
        self.assertFalse((self.project / "SHOULD_NOT_EXIST").exists())
        state = json.loads(active["DIRENV_NIX_STATE"])
        state["changes"].append({"name": "X;touch BAD", "before": None, "after": ""})
        active["DIRENV_NIX_STATE"] = json.dumps(state)
        self.run_cli("export", "bash", env=active, ok=False)

    def test_deleted_envrc_restores_environment(self):
        self.config("FOO=bar\n")
        active = self.activate()
        (self.project / ".envrc").unlink()
        self.assertNotIn("FOO", self.activate(env=active))

    def test_bash_hook_preserves_status_and_existing_prompt(self):
        self.config("FOO=bar\n")
        hook = self.run_cli("hook", "bash").stdout
        for prompt in ('PROMPT_COMMAND="echo original"', 'PROMPT_COMMAND=("echo original" "true")'):
            script = prompt + "\n" + hook + hook + '''
false
_direnv_nix_hook
result=$?
[[ $result == 1 && $FOO == bar ]] || exit 9
declare -p PROMPT_COMMAND
'''
            r = subprocess.run([BASH, "-c", script], cwd=self.project, env=self.env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.count("_direnv_nix_hook"), 1)
            self.assertIn("echo original", r.stdout)

    @unittest.skipUnless(ZSH, "zsh not installed")
    def test_zsh_export_and_hook(self):
        self.config('FOO="quotes: \' and $HOME"\n')
        hook = self.run_cli("hook", "zsh").stdout
        r = subprocess.run([ZSH, "-f", "-c", hook + hook + '\nfalse\n_direnv_nix_hook\nr=$?\n[[ $r == 1 && $FOO == "quotes: \' and $HOME" ]] || exit 9\nprint -l $precmd_functions'],
                           cwd=self.project, env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count("_direnv_nix_hook"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
