const std = @import("std");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub const Op = union(enum) {
    set: struct { name: []const u8, value: []const u8 },
    unset: []const u8,
    nix: []const u8,
    flake: struct { ref: []const u8, impure: bool },
    watch: []const u8,
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub fn managedName(name: []const u8) bool {
    if (!validName(name) or std.mem.startsWith(u8, name, "DIRENV_NIX_")) return false;
    for ([_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_", "SHELLOPTS", "BASHOPTS", "UID", "EUID", "PPID" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return false;
    }
    return true;
}

/// One shell-like word: quotes, escapes and $NAME/${NAME}, but no execution,
/// operators, globbing, tilde expansion or parameter expansion operators.
pub fn word(a: Allocator, raw: []const u8, env: ?*const Env) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == 0 or c == '\n' or c == '\r') return error.InvalidValue;
        if (quote == '\'') {
            if (c == '\'') quote = 0 else try out.append(a, c);
            continue;
        }
        if (c == '"') {
            quote = if (quote == '"') 0 else '"';
            continue;
        }
        if (c == '\'' and quote == 0) {
            quote = '\'';
            continue;
        }
        if (c == '\\') {
            i += 1;
            if (i == raw.len) return error.InvalidValue;
            if (quote == '"' and std.mem.indexOfScalar(u8, "$`\"\\", raw[i]) == null) try out.append(a, '\\');
            try out.append(a, raw[i]);
            continue;
        }
        if (c == '`') return error.UnsupportedSyntax;
        if (c == '$') {
            const values = env orelse return error.DynamicPathNotSupported;
            i += 1;
            if (i == raw.len) return error.UnsupportedSyntax;
            const braced = raw[i] == '{';
            if (braced) i += 1;
            const start = i;
            while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '_')) : (i += 1) {}
            const name = raw[start..i];
            if (!validName(name)) return error.UnsupportedSyntax;
            // These values vary per prompt/process and are intentionally absent
            // from the cache key. PWD is supported and fixed to the project root.
            if (std.mem.startsWith(u8, name, "DIRENV_NIX_") or std.mem.eql(u8, name, "SHLVL") or
                std.mem.eql(u8, name, "OLDPWD") or std.mem.eql(u8, name, "_")) return error.UnsupportedVariableExpansion;
            if (braced) {
                if (i == raw.len or raw[i] != '}') return error.UnsupportedSyntax;
            } else i -= 1;
            try out.appendSlice(a, values.get(name) orelse "");
            continue;
        }
        if (quote == 0 and std.mem.indexOfScalar(u8, " \t;|&<>()*?[]{}~", c) != null) return error.UnsupportedSyntax;
        try out.append(a, c);
    }
    if (quote != 0) return error.UnclosedQuote;
    return out.toOwnedSlice(a);
}

pub fn parse(a: Allocator, source: []const u8) ![]const Op {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidValue;
    var ops: std.ArrayList(Op) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var has_nix = false;
    var empty = Env.init(a);
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");
        if (std.mem.startsWith(u8, line, "use ")) {
            if (has_nix) return error.MultipleNixEnvironments;
            has_nix = true;
            const rest = std.mem.trimStart(u8, line[4..], " \t");
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const kind = rest[0..end];
            const arg = std.mem.trim(u8, rest[end..], " \t");
            if (std.mem.eql(u8, kind, "nix")) {
                try ops.append(a, .{ .nix = if (arg.len == 0) "" else try word(a, arg, null) });
            } else if (std.mem.eql(u8, kind, "flake")) {
                // Only --impure is accepted, as a trailing word: `use flake [ref] --impure`.
                var ref_arg = arg;
                var impure = false;
                if (std.mem.eql(u8, arg, "--impure")) {
                    impure = true;
                    ref_arg = "";
                } else if (std.mem.endsWith(u8, arg, " --impure") or std.mem.endsWith(u8, arg, "\t--impure")) {
                    impure = true;
                    ref_arg = std.mem.trimEnd(u8, arg[0 .. arg.len - "--impure".len], " \t");
                }
                const ref = if (ref_arg.len == 0) "." else try word(a, ref_arg, null);
                if (ref.len == 0 or !(ref[0] == '.' or ref[0] == '/' or ref[0] == '#')) return error.OnlyLocalFlakesSupported;
                try ops.append(a, .{ .flake = .{ .ref = ref, .impure = impure } });
            } else return error.UnsupportedSyntax;
        } else if (std.mem.startsWith(u8, line, "watch_file ")) {
            const path = try word(a, std.mem.trim(u8, line[11..], " \t"), null);
            if (path.len == 0) return error.InvalidValue;
            try ops.append(a, .{ .watch = path });
        } else if (std.mem.startsWith(u8, line, "unset ")) {
            const name = std.mem.trim(u8, line[6..], " \t");
            if (!managedName(name)) return error.InvalidVariableName;
            try ops.append(a, .{ .unset = name });
        } else if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const name = line[0..eq];
            if (!managedName(name)) return error.InvalidVariableName;
            _ = try word(a, line[eq + 1 ..], &empty);
            try ops.append(a, .{ .set = .{ .name = name, .value = line[eq + 1 ..] } });
        } else return error.UnsupportedSyntax;
    }
    return ops.toOwnedSlice(a);
}

test "values expand without executing shell syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    try env.put("HOME", "/home/test");
    try std.testing.expectEqualStrings("/home/test/bin:it's fine", try word(a, "\"${HOME}/bin:it's fine\"", &env));
    try std.testing.expectEqualStrings("$(touch /tmp/no)", try word(a, "'$(touch /tmp/no)'", &env));
    try std.testing.expectError(error.UnsupportedSyntax, word(a, "$(id)", &env));
    try std.testing.expectError(error.UnsupportedSyntax, word(a, "foo;id", &env));
    try std.testing.expectError(error.UnclosedQuote, word(a, "'foo", &env));
    try std.testing.expectError(error.UnsupportedSyntax, word(a, "${HOME:-x}", &env));
    try std.testing.expectError(error.UnsupportedVariableExpansion, word(a, "$SHLVL", &env));
}

test "strict limited configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ops = try parse(a, "# project\nexport FOO='hello world'\nuse flake .#dev\nwatch_file nix/dev.nix\nunset BAR\n");
    try std.testing.expectEqual(@as(usize, 4), ops.len);
    try std.testing.expectError(error.UnsupportedSyntax, parse(a, "source .env"));
    try std.testing.expectError(error.MultipleNixEnvironments, parse(a, "use nix\nuse flake"));
    try std.testing.expectError(error.OnlyLocalFlakesSupported, parse(a, "use flake github:NixOS/nixpkgs"));
    for ([_][]const u8{ "use flake --impure", "use flake . --impure", "use flake '.#dev'\t--impure" }) |source| {
        const flake = (try parse(a, source))[0].flake;
        try std.testing.expect(flake.impure);
    }
    try std.testing.expect(!(try parse(a, "use flake .#dev"))[0].flake.impure);
    try std.testing.expectError(error.UnsupportedSyntax, parse(a, "use flake . --refresh"));
    try std.testing.expectError(error.InvalidVariableName, parse(a, "DIRENV_NIX_STATE=bad"));
}
