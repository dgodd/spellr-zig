const config = @import("config");
const std = @import("std");
const Io = std.Io;

const reporter_mod = @import("reporter.zig");

pub const Options = struct {
    mode: reporter_mod.Mode = .default,
    config_path: []const u8 = ".spellr.yml",
    suppress_file_rules: bool = false,
    dry_run: bool = false,
    parallel: bool = true,
    jobs: usize = 0, // 0 = use CPU count
    files: []const []const u8 = &[_][]const u8{},
    show_help: bool = false,
    show_version: bool = false,
};

const HELP =
    \\Usage: spellr [options] [files...]
    \\
    \\  -i, --interactive    Interactive spell checking
    \\  -a, --autocorrect    Automatically apply best suggestion
    \\  -w, --wordlist       Output unknowns as wordlist
    \\  -q, --quiet          No output, just exit code
    \\  -d, --dry-run        List files that would be checked
    \\  -f, --suppress-file-rules  Ignore gitignore/config patterns
    \\  -c, --config FILE    Config file (default: .spellr.yml)
    \\  -j, --jobs N         Number of parallel workers (default: CPU count)
    \\  --no-parallel        Disable parallel processing
    \\  -v, --version        Show version
    \\  -h, --help           Show this help
    \\
;

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var opts = Options{};
    var files = std.ArrayList([]const u8).empty; // stores slices of sentinel strings (coerced)
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            opts.mode = .interactive;
            opts.parallel = false;
        } else if (std.mem.eql(u8, arg, "--autocorrect") or std.mem.eql(u8, arg, "-a")) {
            opts.mode = .autocorrect;
            opts.parallel = false;
        } else if (std.mem.eql(u8, arg, "--wordlist") or std.mem.eql(u8, arg, "-w")) {
            opts.mode = .wordlist;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.mode = .quiet;
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-d")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--suppress-file-rules") or std.mem.eql(u8, arg, "-f")) {
            opts.suppress_file_rules = true;
        } else if (std.mem.eql(u8, arg, "--jobs") or std.mem.eql(u8, arg, "-j")) {
            i += 1;
            if (i < args.len) opts.jobs = std.fmt.parseInt(usize, args[i], 10) catch 0;
            if (opts.jobs == 0) opts.parallel = false;
        } else if (std.mem.eql(u8, arg, "--no-parallel")) {
            opts.parallel = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            opts.show_version = true;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) opts.config_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            try files.append(allocator, arg);
        }
    }
    opts.files = try files.toOwnedSlice(allocator);
    return opts;
}

pub fn printHelp() void {
    std.debug.print("{s}", .{HELP});
}

pub fn printVersion() void {
    std.debug.print("spellr {s}\n", .{config.version});
}
