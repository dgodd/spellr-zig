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
    error_paths: std.ArrayList([]const u8),
    error_path_set: std.StringHashMap(void),
    found_errors: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: Io, mode: Mode) Reporter {
        return .{
            .mode = mode,
            .allocator = allocator,
            .io = io,
            .wordlist_words = std.StringHashMap(void).init(allocator),
            .replace_all = std.StringHashMap([]const u8).init(allocator),
            .skip_all = std.StringHashMap(void).init(allocator),
            .error_paths = std.ArrayList([]const u8).empty,
            .error_path_set = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Reporter) void {
        self.wordlist_words.deinit();
        self.replace_all.deinit();
        self.skip_all.deinit();
        for (self.error_paths.items) |p| self.allocator.free(p);
        self.error_paths.deinit(self.allocator);
        self.error_path_set.deinit();
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
                if (!self.error_path_set.contains(miss.path)) {
                    const duped = try self.allocator.dupe(u8, miss.path);
                    try self.error_paths.append(self.allocator, duped);
                    try self.error_path_set.put(duped, {});
                }
                const col = miss.token.col;
                const before = std.mem.trimStart(u8, miss.line_text[0..col], " \t");
                const after = std.mem.trimEnd(u8, miss.line_text[col + miss.text.len ..], " \t\r\n");
                var buf: [8192]u8 = undefined;
                var w: Io.File.Writer = .init(.stdout(), self.io, &buf);
                try w.interface.print("\x1b[36m{s}:{d}:{d}\x1b[0m {s}\x1b[1;31m{s}\x1b[0m{s}\n", .{
                    miss.path, miss.token.line, col, before, miss.text, after,
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
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lt);
                var buf: [4096]u8 = undefined;
                var out: Io.File.Writer = .init(.stdout(), self.io, &buf);
                for (words.items) |w| try out.interface.print("{s}\n", .{w});
                try out.flush();
            },
            .default => {
                var buf: [8192]u8 = undefined;
                var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
                const file_s: []const u8 = if (self.file_count == 1) "file" else "files";
                const error_s: []const u8 = if (self.error_count == 1) "error" else "errors";
                try w.interface.print("\n{d} {s} checked\n{d} {s} found", .{
                    self.file_count, file_s, self.error_count, error_s,
                });
                if (self.error_count > 0) {
                    try w.interface.print("\n\nto add or replace words interactively, run:\n  spellr --interactive", .{});
                    if (self.error_paths.items.len <= 20) {
                        for (self.error_paths.items) |p| try w.interface.print(" {s}", .{p});
                    }
                    try w.interface.print("\n", .{});
                } else {
                    try w.interface.print("\n", .{});
                }
                try w.flush();
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
        defer {
            for (suggs) |s| self.allocator.free(s);
            self.allocator.free(suggs);
        }

        const col = miss.token.col;
        const before = std.mem.trimStart(u8, miss.line_text[0..col], " \t");
        const after = std.mem.trimEnd(u8, miss.line_text[col + miss.text.len ..], " \t\r\n");

        var buf: [2048]u8 = undefined;
        var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
        try w.interface.print("\n\x1b[36m{s}:{d}:{d}\x1b[0m {s}\x1b[1;31m{s}\x1b[0m{s}\n", .{
            miss.path, miss.token.line, col, before, miss.text, after,
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
        const n = std.posix.read(stdin_file.handle, &ibuf) catch return .skip;
        if (n == 0) return .skip;
        const key = ibuf[0];

        switch (key) {
            '1'...'9' => {
                const idx = key - '1';
                if (idx < suggs.len) return .{ .replace = try self.allocator.dupe(u8, suggs[idx]) };
                return .skip;
            },
            'a' => {
                try w.interface.print("\n  Add to which wordlist?\n", .{});
                var visible: [16]*const Wordlist = undefined;
                var visible_len: usize = 0;
                for (wordlists) |wl| {
                    if (std.mem.startsWith(u8, wl.name, "english_")) continue;
                    visible[visible_len] = wl;
                    visible_len += 1;
                    try w.interface.print("  [{d}] {s}\n", .{ visible_len, wl.name });
                }
                try w.interface.print("> ", .{});
                try w.flush();
                var kbuf: [1]u8 = undefined;
                const kn = std.posix.read(stdin_file.handle, &kbuf) catch return .skip;
                if (kn == 0) return .skip;
                const k = kbuf[0];
                if (k >= '1' and k <= '9') {
                    const idx = k - '1';
                    if (idx < visible_len) return .{ .add_to_wordlist = visible[idx].name };
                }
                return .skip;
            },
            'r', 'R' => {
                std.posix.tcsetattr(stdin_file.handle, .NOW, orig) catch {};
                try w.interface.print("\n  Replace \"{s}\" with: ", .{miss.text});
                try w.flush();
                var repl_buf: [512]u8 = undefined;
                var repl_len: usize = 0;
                var ch: [1]u8 = undefined;
                while (repl_len < repl_buf.len) {
                    const rn = std.posix.read(stdin_file.handle, &ch) catch break;
                    if (rn == 0 or ch[0] == '\n' or ch[0] == '\r') break;
                    repl_buf[repl_len] = ch[0];
                    repl_len += 1;
                }
                const replacement = std.mem.trim(u8, repl_buf[0..repl_len], " \t");
                if (replacement.len == 0) return .skip;
                const duped = try self.allocator.dupe(u8, replacement);
                if (key == 'R') {
                    try self.replace_all.put(
                        try self.allocator.dupe(u8, norm),
                        try self.allocator.dupe(u8, duped),
                    );
                }
                return .{ .replace = duped };
            },
            's' => return .skip,
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
        defer {
            for (suggs) |s| self.allocator.free(s);
            self.allocator.free(suggs);
        }
        if (suggs.len == 0) {
            var buf: [512]u8 = undefined;
            var w: Io.File.Writer = .init(.stderr(), self.io, &buf);
            try w.interface.print("{s}:{d}:{d}: no suggestion for \"{s}\"\n", .{
                miss.path, miss.token.line, miss.token.col, miss.text,
            });
            try w.flush();
            return .skip;
        }
        return .{ .replace = try self.allocator.dupe(u8, suggs[0]) };
    }
};
