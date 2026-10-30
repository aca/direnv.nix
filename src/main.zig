const std = @import("std");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;
const Sha = std.crypto.hash.sha2.Sha256;
const state_key = "DIRENV_NIX_STATE";
const root_key = "DIRENV_DIR";
const cache_version = "direnv.nix-v2";
const max_file = Io.Limit.limited(8 * 1024 * 1024);

const Change = struct { name: []const u8, before: ?[]const u8, after: ?[]const u8 };
const State = struct { version: u8 = 1, root: []const u8, fingerprint: []const u8, changes: []const Change };
const Entry = struct { name: []const u8, value: ?[]const u8 };
// Raw variables from print-dev-env, applied to the current shell on every entry.
const Cache = struct { version: u8 = 3, fingerprint: []const u8, entries: []const Entry };
const LoadingPolicy = enum { blocked, allow_all, allow_dirs, allowed };
const Shell = enum { bash, zsh, elvish, fish, json };

const App = struct {
    a: Allocator,
    io: Io,
    live: *const Env,
    // Only an explicit `reload` reports Nix failures; prompt-time export is silent.
    verbose: bool = false,

    fn path(self: App, parts: []const []const u8) ![]const u8 {
        return std.fs.path.resolve(self.a, parts);
    }

    fn read(self: App, p: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, p, self.a, max_file);
    }

    fn optionalRead(self: App, p: []const u8) !?[]const u8 {
        return self.read(p) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    fn exists(self: App, p: []const u8) !bool {
        _ = Io.Dir.cwd().statFile(self.io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn mkdir(self: App, p: []const u8) !void {
        _ = try Io.Dir.cwd().createDirPathStatus(self.io, p, .fromMode(0o700));
    }

    // Unique, private temporary file + rename: readers never see a partial cache.
    fn atomicWrite(self: App, p: []const u8, data: []const u8) !void {
        var random: [8]u8 = undefined;
        self.io.random(&random);
        const tmp = try std.fmt.allocPrint(self.a, "{s}.{s}.tmp", .{ p, std.fmt.bytesToHex(random, .lower) });
        const file = try Io.Dir.cwd().createFile(self.io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        defer Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
        try file.writeStreamingAll(self.io, data);
        try Io.Dir.renameAbsolute(tmp, p, self.io);
    }

    fn findRoot(self: App) !?[]const u8 {
        var dir: []const u8 = try std.process.currentPathAlloc(self.io, self.a);
        while (true) {
            if (try self.exists(try self.path(&.{ dir, ".envrc" }))) return dir;
            dir = std.fs.path.dirname(dir) orelse return null;
        }
    }

    fn cacheDir(self: App, env: *const Env, root: []const u8) ![]const u8 {
        const base = env.get("XDG_CACHE_HOME") orelse try self.path(&.{ env.get("HOME") orelse return error.HomeNotSet, ".cache" });
        if (!std.fs.path.isAbsolute(base)) return error.CacheHomeMustBeAbsolute;
        return self.path(&.{ base, "direnv.nix", try digest(self.a, root) });
    }

    // Explicit `direnv allow` grants, per project directory. Kept outside the
    // cache so clearing the cache does not revoke them.
    fn allowPath(self: App, root: []const u8) ![]const u8 {
        const base = self.live.get("XDG_DATA_HOME") orelse try self.path(&.{ self.live.get("HOME") orelse return error.HomeNotSet, ".local", "share" });
        if (!std.fs.path.isAbsolute(base)) return error.DataHomeMustBeAbsolute;
        return self.path(&.{ base, "direnv.nix", "allow", try digest(self.a, root) });
    }

    fn explicitPolicy(self: App, root: []const u8) !LoadingPolicy {
        return if (try self.exists(try self.allowPath(root))) .allowed else .blocked;
    }

    // Read policy from the invoking shell on every export, before either cache
    // fast path. Policy changes do not change the cached Nix environment.
    fn loadingPolicy(self: App, root: []const u8) !LoadingPolicy {
        const all = self.live.get("DIRENV_NIX_ALLOW_ALL") orelse "";
        if (std.mem.eql(u8, all, "1")) return .allow_all;
        if (all.len != 0 and !std.mem.eql(u8, all, "0")) return error.InvalidAllowAll;
        const dirs = self.live.get("DIRENV_NIX_ALLOW_DIRS") orelse return self.explicitPolicy(root);
        var paths = std.mem.splitScalar(u8, dirs, ':');
        // Empty entries grant nothing. Reject relative paths instead of giving
        // the same setting different meanings after each directory change.
        while (paths.next()) |p| {
            if (p.len != 0 and !std.fs.path.isAbsolute(p)) return error.AllowDirectoryMustBeAbsolute;
        }
        paths.reset();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        while (paths.next()) |p| {
            if (p.len == 0) continue;
            const len = Io.Dir.cwd().realPathFile(self.io, p, &buffer) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const allowed = buffer[0..len];
            // findRoot uses getcwd, so root is already a physical path. Check
            // a component boundary: /src/aca must not match /src/aca-other.
            if (std.mem.eql(u8, root, allowed) or std.mem.eql(u8, allowed, "/") or
                (std.mem.startsWith(u8, root, allowed) and root.len > allowed.len and root[allowed.len] == '/')) return .allow_dirs;
        }
        return self.explicitPolicy(root);
    }

    fn statHash(self: App, h: *Sha, p: []const u8) !void {
        hashField(h, p);
        const stat = Io.Dir.cwd().statFile(self.io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                hashField(h, "missing");
                return;
            },
            else => return err,
        };
        var metadata: [160]u8 = undefined;
        hashField(h, try std.fmt.bufPrint(&metadata, "{d}:{d}:{d}:{d}", .{ stat.inode, stat.size, stat.mtime.toNanoseconds(), stat.ctime.toNanoseconds() }));
    }

    fn fingerprint(self: App, root: []const u8, source: []const u8, ops: []const config.Op, base: *const Env) ![]const u8 {
        var h = Sha.init(.{});
        hashField(&h, cache_version);
        hashField(&h, root);
        hashField(&h, source);
        // Hash only what can change the Nix result: Nix configuration and the
        // values .envrc sets before `use`. Unrelated shell variables (terminal,
        // tmux, prompt state) must not force a re-evaluation in every shell.
        var env = try base.clone(self.a);
        try env.put("PWD", root);
        for (ops) |op| switch (op) {
            .set => |s| {
                try env.put(s.name, try config.word(self.a, s.value, &env));
                hashField(&h, "set");
                hashField(&h, s.name);
                hashField(&h, env.get(s.name).?);
            },
            .unset => |name| {
                _ = env.swapRemove(name);
                hashField(&h, "unset");
                hashField(&h, name);
            },
            .nix, .flake => break,
            .watch => {},
        };
        var names: std.ArrayList([]const u8) = .empty;
        var it = base.iterator();
        while (it.next()) |kv| {
            if (nixInput(kv.key_ptr.*)) try names.append(self.a, kv.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, lessString);
        for (names.items) |name| {
            hashField(&h, name);
            hashField(&h, base.get(name).?);
        }
        for ([_][]const u8{ "flake.nix", "flake.lock", "shell.nix", "default.nix" }) |name| try self.statHash(&h, try self.path(&.{ root, name }));
        for (ops) |op| switch (op) {
            .watch => |p| try self.statHash(&h, try self.path(&.{ root, p })),
            .nix => |p| if (p.len != 0) {
                try self.statHash(&h, try self.path(&.{ root, p }));
            },
            .flake => |f| {
                const end = std.mem.indexOfScalar(u8, f.ref, '#') orelse f.ref.len;
                const p = if (end == 0) "." else f.ref[0..end];
                for ([_][]const u8{ "flake.nix", "flake.lock" }) |name| try self.statHash(&h, try self.path(&.{ root, p, name }));
            },
            else => {},
        };
        var result: [32]u8 = undefined;
        h.final(&result);
        return self.a.dupe(u8, &std.fmt.bytesToHex(result, .lower));
    }

    fn loadState(self: App) !?State {
        const raw = self.live.get(state_key) orelse return null;
        const parsed = std.json.parseFromSlice(State, self.a, raw, .{ .allocate = .alloc_always }) catch return error.InvalidShellState;
        if (parsed.value.version != 1) return error.InvalidShellState;
        for (parsed.value.changes) |change| {
            if (!config.managedName(change.name)) return error.InvalidShellState;
            if (change.before) |v| if (std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidShellState;
            if (change.after) |v| if (std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidShellState;
        }
        return parsed.value;
    }

    fn baseline(self: App, state: ?State) !Env {
        var env = try self.live.clone(self.a);
        _ = env.swapRemove(state_key);
        if (state) |old| for (old.changes) |change| {
            // Preserve values the user changed manually while inside a project.
            if (equalOptional(env.get(change.name), change.after)) try set(&env, change.name, change.before);
        };
        return env;
    }

    fn profilePath(self: App, dir: []const u8, fp: []const u8) ![]const u8 {
        return self.path(&.{ dir, try std.fmt.allocPrint(self.a, "profile-{s}", .{fp}) });
    }

    fn loadCache(self: App, dir: []const u8, fp: []const u8) !?[]const Entry {
        if (!try self.exists(try self.profilePath(dir, fp))) return null;
        const raw = try self.optionalRead(try self.path(&.{ dir, "env.json" })) orelse return null;
        const parsed = std.json.parseFromSlice(Cache, self.a, raw, .{ .allocate = .alloc_always }) catch return null;
        const cached = parsed.value;
        if (cached.version != 3 or !std.mem.eql(u8, cached.fingerprint, fp)) return null;
        for (cached.entries) |entry| {
            if (!config.managedName(entry.name)) return null;
            const v = entry.value orelse return null;
            if (std.mem.indexOfScalar(u8, v, 0) != null) return null;
        }
        return cached.entries;
    }

    fn runNix(self: App, root: []const u8, dir: []const u8, fp: []const u8, op: config.Op, env: *const Env) ![]const Entry {
        var child_env = try env.clone(self.a);
        var iter = env.iterator();
        while (iter.next()) |kv| if (volatileName(kv.key_ptr.*)) {
            _ = child_env.swapRemove(kv.key_ptr.*);
        };
        try child_env.put("PWD", root);
        try child_env.put("IN_NIX_SHELL", "impure");
        var argv: std.ArrayList([]const u8) = .empty;
        // Resolve against the restored environment, never the previous project's PATH.
        const nix = try self.findExecutable("nix", &child_env, root);
        try argv.appendSlice(self.a, &.{ nix, "--extra-experimental-features", "nix-command flakes", "print-dev-env", "--json", "--profile", try self.profilePath(dir, fp) });
        switch (op) {
            .nix => |p| {
                const file = if (p.len != 0) p else if (try self.exists(try self.path(&.{ root, "shell.nix" }))) "shell.nix" else "default.nix";
                try argv.appendSlice(self.a, &.{ "--impure", "--file", try self.path(&.{ root, file }), "--arg", "inNixShell", "true" });
            },
            .flake => |f| {
                // Canonicalize the local reference so a leading '-' is never an option.
                const end = std.mem.indexOfScalar(u8, f.ref, '#') orelse f.ref.len;
                const p = if (end == 0) "." else f.ref[0..end];
                const resolved = try std.fmt.allocPrint(self.a, "{s}{s}", .{ try self.path(&.{ root, p }), f.ref[end..] });
                if (f.impure) try argv.append(self.a, "--impure");
                try argv.appendSlice(self.a, &.{ "--no-write-lock-file", resolved });
            },
            else => unreachable,
        }
        // Concurrent pipe draining is needed only on a cache miss. Keep its
        // thread pool and signal setup out of every warm invocation.
        var process_io = Io.Threaded.init(std.heap.page_allocator, .{});
        defer process_io.deinit();
        const result = try std.process.run(self.a, process_io.io(), .{ .argv = argv.items, .cwd = .{ .path = root }, .environ_map = &child_env, .stdout_limit = max_file, .stderr_limit = max_file });
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            if (self.verbose) try Io.File.stderr().writeStreamingAll(self.io, result.stderr);
            return error.NixFailed;
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, self.a, result.stdout, .{ .allocate = .alloc_always });
        if (parsed.value != .object) return error.InvalidNixOutput;
        const variables = parsed.value.object.get("variables") orelse return error.InvalidNixOutput;
        if (variables != .object) return error.InvalidNixOutput;
        var entries: std.ArrayList(Entry) = .empty;
        var vars = variables.object.iterator();
        while (vars.next()) |kv| {
            const name = kv.key_ptr.*;
            if (!config.managedName(name) or nixInternal(name)) continue;
            if (kv.value_ptr.* != .object) return error.InvalidNixOutput;
            const kind = kv.value_ptr.object.get("type") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, "exported")) continue;
            const value = kv.value_ptr.object.get("value") orelse return error.InvalidNixOutput;
            if (value != .string or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidNixOutput;
            try entries.append(self.a, .{ .name = name, .value = value.string });
        }
        return entries.toOwnedSlice(self.a);
    }

    fn applyNix(self: App, env: *Env, vars: []const Entry) !void {
        for (vars) |entry| {
            const value = entry.value.?;
            // Search lists are prepended so the shell's own entries stay usable.
            if (std.mem.eql(u8, entry.name, "PATH") or std.mem.eql(u8, entry.name, "XDG_DATA_DIRS")) {
                const original = env.get(entry.name) orelse "";
                try env.put(entry.name, try std.fmt.allocPrint(self.a, "{s}{s}{s}", .{ value, if (original.len > 0 and value.len > 0) ":" else "", original }));
            } else try env.put(entry.name, value);
        }
        try env.put("IN_NIX_SHELL", "impure");
    }

    fn findExecutable(self: App, name: []const u8, env: *const Env, root: []const u8) ![]const u8 {
        var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "", ':');
        while (paths.next()) |p| {
            const candidate = try self.path(&.{ root, p, name });
            Io.Dir.cwd().access(self.io, candidate, .{ .execute = true }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            };
            return candidate;
        }
        return error.NixNotFound;
    }

    // Runs Nix only when vars is still null; otherwise applies the cached result.
    fn evaluate(self: App, root: []const u8, dir: []const u8, fp: []const u8, ops: []const config.Op, base: *const Env, vars: *?[]const Entry) !Env {
        var env = try base.clone(self.a);
        // Match evaluation from the .envrc directory, including on cache reentry
        // from a descendant. The caller's actual PWD is never exported over.
        try env.put("PWD", root);
        for (ops) |op| switch (op) {
            .set => |s| try env.put(s.name, try config.word(self.a, s.value, &env)),
            .unset => |name| {
                _ = env.swapRemove(name);
            },
            .nix, .flake => {
                if (vars.* == null) vars.* = try self.runNix(root, dir, fp, op, &env);
                try self.applyNix(&env, vars.*.?);
            },
            .watch => {},
        };
        try set(&env, "PWD", base.get("PWD"));
        return env;
    }

    fn exportEnv(self: App, shell: Shell, force: bool) !void {
        const old = try self.loadState();
        const root = try self.findRoot();
        if (root == null and old == null) return;
        var base = try self.baseline(old);
        if (root == null) {
            try self.emit(shell, &base, null);
            return;
        }
        const project = root.?;
        if (try self.loadingPolicy(project) == .blocked) return error.NotAllowed;
        const source = try self.read(try self.path(&.{ project, ".envrc" }));
        const ops = try config.parse(self.a, source);
        const dir = try self.cacheDir(&base, project);
        const fp = try self.fingerprint(project, source, ops, &base);
        var needs_nix = false;
        for (ops) |op| if (op == .nix or op == .flake) {
            needs_nix = true;
        };
        if (!force) {
            if (old) |active| {
                if (std.mem.eql(u8, active.root, project) and std.mem.eql(u8, active.fingerprint, fp) and
                    (!needs_nix or try self.exists(try self.profilePath(dir, fp)))) return;
            }
        }
        var vars: ?[]const Entry = if (needs_nix and !force) try self.loadCache(dir, fp) else null;
        if (needs_nix and vars == null) {
            try self.mkdir(dir);
            const lock = try Io.Dir.cwd().createFile(self.io, try self.path(&.{ dir, "lock" }), .{ .truncate = false, .lock = .exclusive, .permissions = .fromMode(0o600) });
            defer lock.close(self.io);
            // A second terminal may have populated it while this process waited.
            if (!force) vars = try self.loadCache(dir, fp);
            if (vars == null) {
                _ = try self.evaluate(project, dir, fp, ops, &base, &vars);
                // Reject changes during evaluation instead of caching a mixed snapshot.
                if (!std.mem.eql(u8, source, try self.read(try self.path(&.{ project, ".envrc" }))) or
                    !std.mem.eql(u8, fp, try self.fingerprint(project, source, ops, &base))) return error.InputChangedDuringEvaluation;
                if (try self.loadingPolicy(project) == .blocked) return error.NotAllowed;
                try self.atomicWrite(try self.path(&.{ dir, "env.json" }), try std.json.Stringify.valueAlloc(self.a, Cache{ .fingerprint = fp, .entries = vars.? }, .{}));
            }
        }
        const target = try self.evaluate(project, dir, fp, ops, &base, &vars);
        const entries = try diff(self.a, &base, &target);
        var changes: std.ArrayList(Change) = .empty;
        for (entries) |entry| try changes.append(self.a, .{ .name = entry.name, .before = base.get(entry.name), .after = entry.value });
        try self.emit(shell, &target, .{ .root = project, .fingerprint = fp, .changes = changes.items });
    }

    fn emit(self: App, shell: Shell, target: *const Env, state: ?State) !void {
        var out: std.ArrayList(u8) = .empty;
        if (shell == .json) try out.append(self.a, '{');
        for (try diff(self.a, self.live, target)) |entry| try emitEntry(self.a, &out, shell, entry.name, entry.value);
        if (state) |s| {
            const encoded = try std.json.Stringify.valueAlloc(self.a, s, .{});
            if (encoded.len > 96 * 1024) return error.ShellStateTooLarge;
            try emitEntry(self.a, &out, shell, state_key, encoded);
            try emitEntry(self.a, &out, shell, root_key, s.root);
        } else {
            try emitEntry(self.a, &out, shell, state_key, null);
            try emitEntry(self.a, &out, shell, root_key, null);
        }
        if (shell == .json) try out.appendSlice(self.a, "}\n");
        try Io.File.stdout().writeStreamingAll(self.io, out.items);
    }

    fn hook(self: App, shell: Shell) !void {
        if (shell == .json) return error.UnsupportedShell;
        var out: std.ArrayList(u8) = .empty;
        if (shell == .elvish) {
            // Use slurp, not line capture: values and the state may contain
            // embedded newlines. A failed export is never evaluated.
            try out.appendSlice(self.a, "set edit:before-readline = [(all $edit:before-readline) {\n  try {\n    var code = (");
            try shellQuote(self.a, &out, .elvish, try std.process.executablePathAlloc(self.io, self.a));
            try out.appendSlice(self.a, " export elvish | slurp)\n    if (not-eq $code '') { eval $code }\n  } catch {\n    # The loader already reports its error on stderr.\n  }\n}]\n");
            try Io.File.stdout().writeStreamingAll(self.io, out.items);
            return;
        }
        if (shell == .fish) {
            // `source` reads the whole stream, so multiline values are safe.
            // A failed export emits nothing, so nothing is sourced.
            try out.appendSlice(self.a, "function _direnv_nix_hook --on-event fish_prompt\n    ");
            try shellQuote(self.a, &out, .fish, try std.process.executablePathAlloc(self.io, self.a));
            try out.appendSlice(self.a, " export fish | source\nend\n");
            try Io.File.stdout().writeStreamingAll(self.io, out.items);
            return;
        }
        try out.appendSlice(self.a, "_direnv_nix_hook() {\n  local _dnx_status=$? _dnx_code\n  _dnx_code=$(");
        try shellQuote(self.a, &out, shell, try std.process.executablePathAlloc(self.io, self.a));
        try out.appendSlice(self.a, " export ");
        try out.appendSlice(self.a, @tagName(shell));
        try out.appendSlice(self.a, ") && eval \"$_dnx_code\"\n  return \"$_dnx_status\"\n}\n");
        try out.appendSlice(self.a, if (shell == .bash)
            \\if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
            \\  if [[ " ${PROMPT_COMMAND[*]} " != *" _direnv_nix_hook "* ]]; then
            \\    PROMPT_COMMAND=(_direnv_nix_hook "${PROMPT_COMMAND[@]}")
            \\  fi
            \\else
            \\  case ";${PROMPT_COMMAND-};" in
            \\    *';_direnv_nix_hook;'*) ;;
            \\    *) PROMPT_COMMAND="_direnv_nix_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
            \\  esac
            \\fi
            \\
        else
            \\typeset -ga precmd_functions
            \\if (( ! ${precmd_functions[(Ie)_direnv_nix_hook]} )); then
            \\  precmd_functions=(_direnv_nix_hook $precmd_functions)
            \\fi
            \\
        );
        try Io.File.stdout().writeStreamingAll(self.io, out.items);
    }

    fn run(self: App, args: []const [:0]const u8) !void {
        if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
            try Io.File.stdout().writeStreamingAll(self.io,
                \\direnv.nix — a small cached Nix environment loader
                \\Usage: direnv hook bash|zsh|elvish|fish
                \\       direnv export bash|zsh|elvish|fish|json
                \\       direnv reload bash|zsh|elvish|fish|json
                \\       direnv allow|deny|status
                \\Automatic loading: DIRENV_NIX_ALLOW_DIRS=/absolute/dir:/another/dir
                \\                   DIRENV_NIX_ALLOW_ALL=1 (all projects; overrides list)
                \\Explicit loading:  direnv allow (this project directory; deny revokes)
                \\Without an applicable setting or grant, .envrc loading is blocked.
                \\Supported .envrc: [export] NAME=value, unset NAME, use nix [file],
                \\                  use flake [local-path#shell] [--impure], watch_file path
                \\
            );
        } else if (std.mem.eql(u8, args[1], "--version")) {
            try Io.File.stdout().writeStreamingAll(self.io, "direnv.nix 0.1.0-dev (Zig " ++ @import("builtin").zig_version_string ++ ")\n");
        } else if (std.mem.eql(u8, args[1], "hook")) {
            if (args.len != 3) return error.InvalidArguments;
            try self.hook(try parseShell(args[2]));
        } else if (std.mem.eql(u8, args[1], "export") or std.mem.eql(u8, args[1], "reload")) {
            if (args.len != 3) return error.InvalidArguments;
            const reload = std.mem.eql(u8, args[1], "reload");
            var app = self;
            app.verbose = reload;
            try app.exportEnv(try parseShell(args[2]), reload);
        } else if (std.mem.eql(u8, args[1], "allow") or std.mem.eql(u8, args[1], "deny")) {
            if (args.len != 2) return error.InvalidArguments;
            const root = try self.findRoot() orelse return error.NoEnvrc;
            const file = try self.allowPath(root);
            if (std.mem.eql(u8, args[1], "allow")) {
                try self.mkdir(std.fs.path.dirname(file).?);
                try self.atomicWrite(file, try std.fmt.allocPrint(self.a, "{s}\n", .{root}));
            } else Io.Dir.cwd().deleteFile(self.io, file) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        } else if (std.mem.eql(u8, args[1], "status")) {
            if (args.len != 2) return error.InvalidArguments;
            const root = try self.findRoot() orelse return error.NoEnvrc;
            var base = try self.baseline(try self.loadState());
            const dir = try self.cacheDir(&base, root);
            const loading = switch (try self.loadingPolicy(root)) {
                .blocked => "blocked",
                .allow_all => "automatic (DIRENV_NIX_ALLOW_ALL)",
                .allow_dirs => "automatic (DIRENV_NIX_ALLOW_DIRS)",
                .allowed => "explicit (direnv allow)",
            };
            const message = try std.fmt.allocPrint(self.a, "project: {s}\nloading: {s}\ncache: {s}\n", .{ root, loading, dir });
            try Io.File.stdout().writeStreamingAll(self.io, message);
        } else return error.InvalidArguments;
    }
};

fn volatileName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "DIRENV_NIX_")) return true;
    for ([_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn nixInput(name: []const u8) bool {
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return std.mem.startsWith(u8, name, "NIX_");
}

// Build-sandbox values that must not replace the user's: TERM and TZ are the
// sandbox's terminal and timezone, which `nix develop` also ignores.
fn nixInternal(name: []const u8) bool {
    for ([_][]const u8{ "HOME", "SHELL", "TERM", "TZ", "TMP", "TMPDIR", "TEMP", "TEMPDIR", "NIX_BUILD_TOP", "NIX_ENFORCE_PURITY", "NIX_LOG_FD", "NIX_REMOTE", "NIX_STORE", "NIX_BUILD_CORES", "shellHook" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return std.mem.startsWith(u8, name, "BASH_FUNC_");
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hashField(h: *Sha, value: []const u8) void {
    h.update(value);
    h.update(&.{0});
}

fn digest(a: Allocator, value: []const u8) ![]const u8 {
    var bytes: [32]u8 = undefined;
    Sha.hash(value, &bytes, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

fn equalOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
    return b == null;
}

fn set(env: *Env, name: []const u8, value: ?[]const u8) !void {
    if (value) |v| try env.put(name, v) else {
        _ = env.swapRemove(name);
    }
}

fn diff(a: Allocator, before: *const Env, after: *const Env) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var it = after.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (config.managedName(name) and !equalOptional(before.get(name), kv.value_ptr.*)) try entries.append(a, .{ .name = name, .value = kv.value_ptr.* });
    }
    it = before.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (config.managedName(name) and !after.contains(name)) try entries.append(a, .{ .name = name, .value = null });
    }
    return entries.toOwnedSlice(a);
}

fn shellQuote(a: Allocator, out: *std.ArrayList(u8), shell: Shell, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidValue;
    try out.append(a, '\'');
    for (value) |c| switch (shell) {
        .elvish => if (c == '\'') try out.appendSlice(a, "''") else try out.append(a, c),
        // Inside fish single quotes only \' and \\ are escapes.
        .fish => if (c == '\'' or c == '\\') try out.appendSlice(a, &.{ '\\', c }) else try out.append(a, c),
        .bash, .zsh => if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c),
        .json => unreachable,
    };
    try out.append(a, '\'');
}

fn emitEntry(a: Allocator, out: *std.ArrayList(u8), shell: Shell, name: []const u8, value: ?[]const u8) !void {
    if (!config.validName(name)) return error.InvalidVariableName;
    if (shell == .json) {
        // emit wraps the entries in braces; null unsets, as in direnv's format.
        if (out.items.len > 1) try out.append(a, ',');
        try out.appendSlice(a, try std.json.Stringify.valueAlloc(a, name, .{}));
        try out.append(a, ':');
        try out.appendSlice(a, try std.json.Stringify.valueAlloc(a, value, .{}));
        return;
    }
    if (shell == .fish) {
        try out.appendSlice(a, if (value != null) "set -gx " else "set -e -g ");
        try out.appendSlice(a, name);
        if (value) |v| {
            // fish uses PATH/MANPATH as lists for its own lookups.
            const list = std.mem.eql(u8, name, "PATH") or std.mem.eql(u8, name, "MANPATH");
            var parts = std.mem.splitScalar(u8, v, if (list) ':' else 0);
            while (parts.next()) |part| {
                try out.append(a, ' ');
                try shellQuote(a, out, shell, part);
            }
        }
        try out.appendSlice(a, ";\n");
        return;
    }
    try out.appendSlice(a, if (shell == .elvish) (if (value != null) "set-env " else "unset-env ") else (if (value != null) "export " else "unset "));
    try out.appendSlice(a, name);
    if (value) |v| {
        try out.append(a, if (shell == .elvish) ' ' else '=');
        try shellQuote(a, out, shell, v);
    }
    try out.appendSlice(a, ";\n");
}

fn parseShell(shell: []const u8) !Shell {
    return std.meta.stringToEnum(Shell, shell) orelse error.UnsupportedShell;
}

pub fn main(init: std.process.Init.Minimal) void {
    // One arena owns all per-invocation data. Avoid the general-purpose
    // allocator and default threaded-I/O startup for the sub-millisecond path.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var local_io: Io.Threaded = .init_single_threaded;
    local_io.argv0 = .init(init.args);
    defer local_io.deinit();
    var env = std.process.Environ.createMap(init.environ, a) catch std.process.exit(1);
    const app: App = .{ .a = a, .io = local_io.io(), .live = &env };
    const args = init.args.toSlice(a) catch std.process.exit(1);
    app.run(args) catch |err| {
        const message = switch (err) {
            error.NotAllowed => "direnv.nix: project is not allowed; run `direnv allow`, or set DIRENV_NIX_ALLOW_DIRS or DIRENV_NIX_ALLOW_ALL=1 in your shell\n",
            error.InvalidAllowAll => "direnv.nix: DIRENV_NIX_ALLOW_ALL must be 1, 0, or empty\n",
            error.AllowDirectoryMustBeAbsolute => "direnv.nix: DIRENV_NIX_ALLOW_DIRS must contain colon-separated absolute paths\n",
            error.NixFailed => "",
            else => std.fmt.allocPrint(app.a, "direnv.nix: {s}\n", .{@errorName(err)}) catch "direnv.nix: out of memory\n",
        };
        Io.File.stderr().writeStreamingAll(app.io, message) catch {};
        std.process.exit(1);
    };
}
