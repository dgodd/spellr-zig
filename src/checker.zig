const std = @import("std");
const Io = std.Io;
const LineTokenizer = @import("line_tokenizer.zig").LineTokenizer;
const Token = @import("token.zig").Token;
const Wordlist = @import("wordlist.zig").Wordlist;
const wordlist_mod = @import("wordlist.zig");
const Config = @import("config.zig").Config;

pub const Miss = struct {
    token: Token,
    path: []const u8,
    text: []const u8,
};

pub fn checkFile(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    wordlists: []*const Wordlist,
    project_wordlists: []const Wordlist,
    config: *const Config,
) ![]Miss {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return &[_]Miss{};
        return err;
    };
    defer file.close(io);

    var rbuf: [65536]u8 = undefined;
    var reader = Io.File.Reader.init(file, io, &rbuf);
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);
    try reader.interface.appendRemaining(allocator, &content, .unlimited);

    // skip binary files
    if (std.mem.indexOfScalar(u8, content.items, 0) != null) return &[_]Miss{};

    var misses = std.ArrayList(Miss).empty;
    var line_num: u32 = 1;
    var file_disabled = false;

    var lines = std.mem.splitScalar(u8, content.items, '\n');
    while (lines.next()) |line| {
        defer line_num += 1;

        // multi-line block disable/enable
        if (!file_disabled and
            std.mem.indexOf(u8, line, "spellr:disable") != null and
            std.mem.indexOf(u8, line, "spellr:disable-line") == null and
            std.mem.indexOf(u8, line, "spellr:enable") == null)
        {
            file_disabled = true;
        }
        if (file_disabled and std.mem.indexOf(u8, line, "spellr:enable") != null) {
            file_disabled = false;
        }
        if (file_disabled) continue;

        var tokenizer = LineTokenizer.init(line, line_num, config.word_minimum_length, true);
        while (tokenizer.next()) |token| {
            if (try isKnown(allocator, token.text, wordlists, project_wordlists)) continue;
            try misses.append(allocator, .{
                .token = token,
                .path = path,
                .text = try allocator.dupe(u8, token.text),
            });
        }
    }

    return misses.toOwnedSlice(allocator);
}

fn isKnown(
    allocator: std.mem.Allocator,
    word: []const u8,
    wordlists: []*const Wordlist,
    project_wordlists: []const Wordlist,
) !bool {
    for (wordlists) |wl| if (try wl.contains(allocator, word)) return true;
    for (project_wordlists) |*wl| if (try wl.contains(allocator, word)) return true;
    return false;
}

pub fn loadProjectWordlists(allocator: std.mem.Allocator, io: Io) ![]Wordlist {
    var lists = std.ArrayList(Wordlist).empty;
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, ".spellr_wordlists", .{ .iterate = true }) catch return lists.toOwnedSlice(allocator);
    defer dir.close(io);

    var reader_dir = try dir.walk(allocator);
    defer reader_dir.deinit();
    while (try reader_dir.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".txt")) continue;
        const full = try std.fmt.allocPrint(allocator, ".spellr_wordlists/{s}", .{entry.path});
        defer allocator.free(full);
        const f = cwd.openFile(io, full, .{}) catch continue;
        var rbuf: [65536]u8 = undefined;
        var r = Io.File.Reader.init(f, io, &rbuf);
        var data = std.ArrayList(u8).empty;
        try r.interface.appendRemaining(allocator, &data, .unlimited);
        f.close(io);
        // name: dupe because entry.path is invalidated on the next walker.next() call
        const name = try allocator.dupe(u8, entry.path[0 .. entry.path.len - 4]);
        errdefer allocator.free(name);
        // data_slice: transfer ownership to Wordlist so words (slices into it) stay valid
        const data_slice = try data.toOwnedSlice(allocator);
        var wl = try Wordlist.init(allocator, name, data_slice);
        wl.owned_data = data_slice;
        try lists.append(allocator, wl);
    }
    return lists.toOwnedSlice(allocator);
}
