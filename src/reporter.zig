const std = @import("std");
const Io = std.Io;
const Miss = @import("checker.zig").Miss;
const Wordlist = @import("wordlist.zig").Wordlist;
const suggester = @import("suggester.zig");
const wordlist_mod = @import("wordlist.zig");

pub const Mode = enum { default, quiet, wordlist, interactive, autocorrect };

pub const ReportAction = union(enum) {
    skip,
    replace: []const u8,
    add_to_wordlist: []const u8,
};

pub const Reporter = struct {
    mode: Mode,
    allocator: std.mem.Allocator,
    io: Io,
    error_count: usize = 0,
    file_count: usize = 0,
    wordlist_words: std.StringHashMap(void),
    replace_all: std.StringHashMap([]const u8),
    skip_all: std.StringHashMap(void),
    found_errors: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, mode: Mode) Reporter {
        return .{
            .mode = mode,
            .allocator = allocator,
            .io = io,
            .wordlist_words = std.StringHashMap(void).init(allocator),
            .replace_all = std.StringHashMap([]const u8).init(allocator),
            .skip_all = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Reporter) void {
        self.wordlist_words.deinit();
        self.replace_all.deinit();
        self.skip_all.deinit();
    }

    pub fn startFile(self: *Reporter, path: []const u8) void {
        _ = path;
        self.file_count += 1;
    }

    pub fn reportMiss(self: *Reporter, miss: Miss, wordlists: []*const Wordlist) !ReportAction {
        self.found_errors = true;
        self.error_count += 1;
        switch (self.mode) {
            .quiet => return .skip,
            .wordlist => {
                const norm = try wordlist_mod.normalize(self.allocator, miss.text);
                try self.wordlist_words.put(norm, {});
                return .skip;
            },
            .default => {
                var buf: [1024]u8 = undefined;
                var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
                try w.interface.print("{s}:{d}:{d}: unknown word \"{s}\"\n", .{
                    miss.path, miss.token.line, miss.token.col + 1, miss.text,
                });
                try w.flush();
                return .skip;
            },
            .interactive => return self.interactivePrompt(miss, wordlists),
            .autocorrect => return self.autocorrect(miss, wordlists),
        }
    }

    pub fn finish(self: *Reporter) !void {
        switch (self.mode) {
            .wordlist => {
                var words = std.ArrayList([]const u8).empty;
                defer words.deinit(self.allocator);
                var it = self.wordlist_words.keyIterator();
                while (it.next()) |k| try words.append(self.allocator, k.*);
                std.sort.pdq([]const u8, words.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }
                }.lt);
                var buf: [4096]u8 = undefined;
                var out: Io.File.Writer = .init(.stdout(), self.io, &buf);
                for (words.items) |w| try out.interface.print("{s}\n", .{w});
                try out.flush();
            },
            .default => {
                if (self.found_errors) {
                    var buf: [512]u8 = undefined;
                    var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
                    try w.interface.print("\n{d} error(s). Run `spellr --interactive` to fix.\n", .{self.error_count});
                    try w.flush();
                }
            },
            else => {},
        }
    }

    fn interactivePrompt(self: *Reporter, miss: Miss, wordlists: []*const Wordlist) !ReportAction {
        const norm = try wordlist_mod.normalize(self.allocator, miss.text);
        defer self.allocator.free(norm);
        if (self.skip_all.contains(norm)) return .skip;
        if (self.replace_all.get(norm)) |r| return .{ .replace = try self.allocator.dupe(u8, r) };

        const suggs = try suggester.suggestions(self.allocator, miss.token, wordlists);
        defer { for (suggs) |s| self.allocator.free(s); self.allocator.free(suggs); }

        var buf: [2048]u8 = undefined;
        var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
        try w.interface.print("\n\x1b[31m{s}:{d}:{d}: unknown word \"{s}\"\x1b[0m\n", .{
            miss.path, miss.token.line, miss.token.col + 1, miss.text,
        });
        for (suggs, 0..) |s, i| try w.interface.print("  [{d}] {s}\n", .{ i + 1, s });
        try w.interface.print("  [a]dd  [r]eplace  [R]eplace all  [s]kip  [S]kip all  [^C] quit\n> ", .{});
        try w.flush();

        const stdin_file = Io.File.stdin();
        const orig = std.posix.tcgetattr(stdin_file.handle) catch return .skip;
        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_file.handle, .NOW, raw) catch {};
        defer std.posix.tcsetattr(stdin_file.handle, .NOW, orig) catch {};

        var ibuf: [1]u8 = undefined;
        var stdin_buf: [256]u8 = undefined;
        var stdin_reader = Io.File.Reader.init(stdin_file, self.io, &stdin_buf);
        var stdin_w = Io.Writer.fixed(&ibuf);
        const n = stdin_reader.interface.stream(&stdin_w, .unlimited) catch return .skip;
        if (n == 0) return .skip;
        const key = ibuf[0];

        switch (key) {
            '1'...'9' => {
                const idx = key - '1';
                if (idx < suggs.len) return .{ .replace = try self.allocator.dupe(u8, suggs[idx]) };
                return .skip;
            },
            'S' => {
                try self.skip_all.put(try self.allocator.dupe(u8, norm), {});
                return .skip;
            },
            3 => std.process.exit(1),
            else => return .skip,
        }
    }

    fn autocorrect(self: *Reporter, miss: Miss, wordlists: []*const Wordlist) !ReportAction {
        const suggs = try suggester.suggestions(self.allocator, miss.token, wordlists);
        defer { for (suggs) |s| self.allocator.free(s); self.allocator.free(suggs); }
        if (suggs.len == 0) {
            var buf: [512]u8 = undefined;
            var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
            try w.interface.print("{s}:{d}:{d}: no suggestion for \"{s}\"\n", .{
                miss.path, miss.token.line, miss.token.col + 1, miss.text,
            });
            try w.flush();
            return .skip;
        }
        return .{ .replace = try self.allocator.dupe(u8, suggs[0]) };
    }
};
