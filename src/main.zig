const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const file_list_mod = @import("file_list.zig");
const wordlist_mod = @import("wordlist.zig");
const checker_mod = @import("checker.zig");
const reporter_mod = @import("reporter.zig");
const rewriter_mod = @import("rewriter.zig");

const num_wordlist_ids = @typeInfo(wordlist_mod.WordlistId).@"enum".fields.len;

const FileResult = struct {
    arena: std.heap.ArenaAllocator,
    misses: []checker_mod.Miss = &.{},
    done: std.atomic.Value(bool) = .init(false),
};

const WorkCtx = struct {
    files: []const file_list_mod.FileInfo,
    results: []FileResult,
    next_work: std.atomic.Value(usize),
    id_to_ptr: *const [num_wordlist_ids]*const wordlist_mod.Wordlist,
    project_wordlists: []const wordlist_mod.Wordlist,
    config: *const config_mod.Config,
    io: Io,
};

fn processFile(ctx: *WorkCtx, idx: usize) void {
    const fi = ctx.files[idx];
    // page_allocator is always thread-safe; avoids touching the GPA from workers
    ctx.results[idx].arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const fa = ctx.results[idx].arena.allocator();
    var wl_ptrs = std.ArrayList(*const wordlist_mod.Wordlist).empty;
    for (fi.wordlist_ids) |wid| {
        wl_ptrs.append(fa, ctx.id_to_ptr[@intFromEnum(wid)]) catch {
            ctx.results[idx].done.store(true, .release);
            return;
        };
    }
    ctx.results[idx].misses = checker_mod.checkFile(
        fa,
        ctx.io,
        fi.path,
        wl_ptrs.items,
        ctx.project_wordlists,
        ctx.config,
    ) catch &.{};
    ctx.results[idx].done.store(true, .release);
}

fn workerThread(ctx: *WorkCtx) void {
    while (true) {
        const idx = ctx.next_work.fetchAdd(1, .monotonic);
        if (idx >= ctx.files.len) break;
        processFile(ctx, idx);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const opts = try cli.parse(arena, args[1..]);

    if (opts.show_help) {
        cli.printHelp();
        return;
    }
    if (opts.show_version) {
        cli.printVersion();
        return;
    }

    // load config (all config allocations live in config_arena)
    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();
    const config = try config_mod.loadFromFile(config_arena.allocator(), io, opts.config_path);

    // load all embedded wordlists (in arena — long-lived)
    var embedded = try wordlist_mod.loadAll(arena);

    // build id → pointer map
    var id_to_ptr: [num_wordlist_ids]*const wordlist_mod.Wordlist = undefined;
    for (0..num_wordlist_ids) |i| id_to_ptr[i] = embedded.get(@enumFromInt(i));

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

    if (opts.parallel and files.len > 0) {
        try runParallel(gpa, io, opts, files, &id_to_ptr, project_wordlists, &config, &rep, &found_errors);
    } else {
        try runSequential(gpa, io, files, &id_to_ptr, project_wordlists, &config, &rep, &found_errors);
    }

    try rep.finish();

    if (found_errors and opts.mode != .autocorrect) std.process.exit(1);
}

fn runParallel(
    gpa: std.mem.Allocator,
    io: Io,
    opts: cli.Options,
    files: []const file_list_mod.FileInfo,
    id_to_ptr: *const [num_wordlist_ids]*const wordlist_mod.Wordlist,
    project_wordlists: []const wordlist_mod.Wordlist,
    config: *const config_mod.Config,
    rep: *reporter_mod.Reporter,
    found_errors: *bool,
) !void {
    const results = try gpa.alloc(FileResult, files.len);
    defer gpa.free(results);
    for (results) |*r| r.* = .{ .arena = undefined, .misses = &.{}, .done = .init(false) };

    var ctx = WorkCtx{
        .files = files,
        .results = results,
        .next_work = .init(0),
        .id_to_ptr = id_to_ptr,
        .project_wordlists = project_wordlists,
        .config = config,
        .io = io,
    };

    const n_threads = @min(
        if (opts.jobs > 0) opts.jobs else (std.Thread.getCpuCount() catch 1),
        files.len,
    );

    const threads = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(threads);
    var threads_spawned: usize = 0;
    errdefer for (threads[0..threads_spawned]) |t| t.join();

    for (threads) |*t| {
        t.* = try std.Thread.spawn(.{}, workerThread, .{&ctx});
        threads_spawned += 1;
    }

    var next: usize = 0;
    while (next < files.len) {
        if (results[next].done.load(.acquire)) {
            const fi = files[next];
            var wl_ptrs = std.ArrayList(*const wordlist_mod.Wordlist).empty;
            for (fi.wordlist_ids) |wid| try wl_ptrs.append(gpa, id_to_ptr[@intFromEnum(wid)]);

            rep.startFile(fi.path);
            for (results[next].misses) |miss| {
                found_errors.* = true;
                const action = try rep.reportMiss(miss, wl_ptrs.items);
                switch (action) {
                    .skip => {},
                    .replace => |replacement| {
                        defer gpa.free(replacement);
                        const rfa = results[next].arena.allocator();
                        try rewriter_mod.rewriteFile(rfa, io, fi.path, miss.token.line, miss.token.col, miss.text, replacement);
                    },
                    .add_to_wordlist => |lang_name| {
                        try appendToProjectWordlist(gpa, io, lang_name, miss.text);
                    },
                }
            }

            wl_ptrs.deinit(gpa);
            results[next].arena.deinit();
            next += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }

    for (threads) |t| t.join();
}

fn runSequential(
    gpa: std.mem.Allocator,
    io: Io,
    files: []const file_list_mod.FileInfo,
    id_to_ptr: *const [num_wordlist_ids]*const wordlist_mod.Wordlist,
    project_wordlists: []const wordlist_mod.Wordlist,
    config: *const config_mod.Config,
    rep: *reporter_mod.Reporter,
    found_errors: *bool,
) !void {
    for (files) |fi| {
        var wl_ptrs = std.ArrayList(*const wordlist_mod.Wordlist).empty;
        defer wl_ptrs.deinit(gpa);
        for (fi.wordlist_ids) |wid| try wl_ptrs.append(gpa, id_to_ptr[@intFromEnum(wid)]);

        rep.startFile(fi.path);

        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const misses = try checker_mod.checkFile(fa, io, fi.path, wl_ptrs.items, project_wordlists, config);

        for (misses) |miss| {
            found_errors.* = true;
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

    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);
    if (cwd.openFile(io, path, .{})) |existing| {
        var rbuf: [8192]u8 = undefined;
        var reader = Io.File.Reader.init(existing, io, &rbuf);
        try reader.interface.appendRemaining(allocator, &content, .unlimited);
        existing.close(io);
        var it = std.mem.splitScalar(u8, content.items, '\n');
        while (it.next()) |line| {
            const w = std.mem.trim(u8, line, "\r ");
            if (w.len > 0) try words.append(allocator, w);
        }
    } else |_| {}

    var already = false;
    for (words.items) |w| if (std.mem.eql(u8, w, normalized)) {
        already = true;
        break;
    };
    if (!already) {
        try words.append(allocator, try allocator.dupe(u8, normalized));
        std.sort.pdq([]const u8, words.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
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
