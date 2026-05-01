const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const file_list_mod = @import("file_list.zig");
const wordlist_mod = @import("wordlist.zig");
const checker_mod = @import("checker.zig");
const reporter_mod = @import("reporter.zig");
const rewriter_mod = @import("rewriter.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const opts = try cli.parse(arena, args[1..]);

    if (opts.show_help) { cli.printHelp(); return; }
    if (opts.show_version) { cli.printVersion(); return; }

    // load config (all config allocations live in config_arena)
    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();
    const config = try config_mod.loadFromFile(config_arena.allocator(), io, opts.config_path);

    // load all embedded wordlists (in arena — long-lived)
    var embedded = try wordlist_mod.loadAll(arena);

    // build id → pointer map
    const num_ids = @typeInfo(wordlist_mod.WordlistId).@"enum".fields.len;
    var id_to_ptr: [num_ids]*const wordlist_mod.Wordlist = undefined;
    for (0..num_ids) |i| id_to_ptr[i] = embedded.get(@enumFromInt(i));

    // load project wordlists
    const project_wordlists = try checker_mod.loadProjectWordlists(gpa, io);
    defer {
        for (project_wordlists) |wl| {
            gpa.free(wl.name);
            wl.deinit(gpa);
        }
        gpa.free(project_wordlists);
    }

    // discover files
    var fl = file_list_mod.FileList.init(gpa, io, &config, opts.suppress_file_rules);
    const files = try fl.collect(opts.files);
    defer {
        for (files) |fi| {
            gpa.free(fi.path);
            gpa.free(fi.wordlist_ids);
        }
        gpa.free(files);
    }

    if (opts.dry_run) {
        var buf: [4096]u8 = undefined;
        var out: Io.File.Writer = .init(.stdout(), io, &buf);
        for (files) |fi| try out.interface.print("{s}\n", .{fi.path});
        try out.flush();
        return;
    }

    var rep = reporter_mod.Reporter.init(gpa, io, opts.mode);
    defer rep.deinit();

    var found_errors = false;

    for (files) |fi| {
        var wl_ptrs = std.ArrayList(*const wordlist_mod.Wordlist).empty;
        defer wl_ptrs.deinit(gpa);
        for (fi.wordlist_ids) |wid| try wl_ptrs.append(gpa, id_to_ptr[@intFromEnum(wid)]);

        rep.startFile(fi.path);

        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const misses = try checker_mod.checkFile(fa, io, fi.path, wl_ptrs.items, project_wordlists, &config);

        for (misses) |miss| {
            found_errors = true;
            const action = try rep.reportMiss(miss, wl_ptrs.items);
            switch (action) {
                .skip => {},
                .replace => |replacement| {
                    defer gpa.free(replacement);
                    try rewriter_mod.rewriteFile(fa, io, fi.path, miss.token.line, miss.token.col, miss.text, replacement);
                },
                .add_to_wordlist => |lang_name| {
                    try appendToProjectWordlist(gpa, io, lang_name, miss.text);
                },
            }
        }
    }

    try rep.finish();

    if (found_errors and opts.mode != .autocorrect) std.process.exit(1);
}

fn appendToProjectWordlist(allocator: std.mem.Allocator, io: Io, lang_name: []const u8, word: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, ".spellr_wordlists/{s}.txt", .{lang_name});
    defer allocator.free(path);

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, ".spellr_wordlists") catch {};

    var words = std.ArrayList([]const u8).empty;
    defer words.deinit(allocator);

    const normalized = try wordlist_mod.normalize(allocator, word);
    defer allocator.free(normalized);

    if (cwd.openFile(io, path, .{})) |existing| {
        var rbuf: [8192]u8 = undefined;
        var reader = Io.File.Reader.init(existing, io, &rbuf);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(allocator);
        try reader.interface.appendRemaining(allocator, &content, .unlimited);
        existing.close(io);
        var it = std.mem.splitScalar(u8, content.items, '\n');
        while (it.next()) |line| {
            const w = std.mem.trim(u8, line, "\r ");
            if (w.len > 0) try words.append(allocator, w);
        }
    } else |_| {}

    var already = false;
    for (words.items) |w| if (std.mem.eql(u8, w, normalized)) { already = true; break; };
    if (!already) {
        try words.append(allocator, try allocator.dupe(u8, normalized));
        std.sort.pdq([]const u8, words.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }
        }.lt);
    }

    const f = try cwd.createFile(io, path, .{});
    var wbuf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(f, io, &wbuf);
    for (words.items) |w| try writer.interface.print("{s}\n", .{w});
    try writer.flush();
    f.close(io);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("line_tokenizer.zig");
    _ = @import("wordlist.zig");
    _ = @import("suggester.zig");
    _ = @import("key_detector.zig");
}
