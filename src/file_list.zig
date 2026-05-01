const std = @import("std");
const Io = std.Io;
const Config = @import("config.zig").Config;
const LanguageConfig = @import("config.zig").LanguageConfig;
const WordlistId = @import("wordlist.zig").WordlistId;
const Locale = @import("config.zig").Locale;

pub const FileInfo = struct {
    path: []const u8,
    wordlist_ids: []WordlistId,
};

pub const FileList = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: *const Config,
    suppress_file_rules: bool,
    gitignore_patterns: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, io: Io, config: *const Config, suppress_file_rules: bool) FileList {
        return .{ .allocator = allocator, .io = io, .config = config, .suppress_file_rules = suppress_file_rules };
    }

    pub fn collect(self: *FileList, explicit_paths: []const []const u8) ![]FileInfo {
        var results = std.ArrayList(FileInfo).empty;
        if (explicit_paths.len > 0) {
            for (explicit_paths) |p| {
                if (try self.fileInfo(p)) |info| try results.append(self.allocator, info);
            }
        } else {
            if (!self.suppress_file_rules) {
                self.gitignore_patterns = try self.loadGitignore();
            }
            defer {
                for (self.gitignore_patterns) |p| self.allocator.free(p);
                self.allocator.free(self.gitignore_patterns);
                self.gitignore_patterns = &.{};
            }
            var actual_dir = Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true }) catch return results.toOwnedSlice(self.allocator);
            defer actual_dir.close(self.io);
            var walker = try actual_dir.walkSelectively(self.allocator);
            defer walker.deinit();
            while (try walker.next(self.io)) |entry| {
                switch (entry.kind) {
                    .directory => {
                        if (self.suppress_file_rules or !self.isDirExcluded(entry.path)) {
                            try walker.enter(self.io, entry);
                        }
                    },
                    .file => {
                        if (!self.suppress_file_rules and self.isExcluded(entry.path)) continue;
                        if (try self.fileInfo(entry.path)) |info| try results.append(self.allocator, info);
                    },
                    else => {},
                }
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    fn isExcluded(self: *FileList, rel_path: []const u8) bool {
        const base = std.fs.path.basename(rel_path);
        for (self.config.excludes) |pattern| {
            if (globMatch(pattern, rel_path) or globMatch(pattern, base)) return true;
        }
        for (self.gitignore_patterns) |pattern| {
            if (matchGitignoreFile(pattern, rel_path, base)) return true;
        }
        return false;
    }

    fn isDirExcluded(self: *FileList, rel_path: []const u8) bool {
        return checkDirExcluded(self.config.excludes, rel_path) or
            checkDirExcluded(self.gitignore_patterns, rel_path);
    }

    fn checkDirExcluded(patterns: []const []const u8, rel_path: []const u8) bool {
        const base = std.fs.path.basename(rel_path);
        for (patterns) |pattern| {
            const rooted = std.mem.startsWith(u8, pattern, "/");
            const inner = if (rooted) pattern[1..] else pattern;
            if (std.mem.endsWith(u8, inner, "/")) {
                // dir pattern (trailing slash): strip it and match
                const dir_name = inner[0 .. inner.len - 1];
                if (globMatchInner(dir_name, rel_path)) return true;
                if (!rooted) if (globMatchInner(dir_name, base)) return true;
            } else {
                // plain pattern: root-relative matches full path; relative matches base too
                if (globMatchInner(inner, rel_path)) return true;
                if (!rooted) if (globMatch(pattern, base)) return true;
            }
        }
        return false;
    }

    fn matchGitignoreFile(pattern: []const u8, rel_path: []const u8, base: []const u8) bool {
        const rooted = std.mem.startsWith(u8, pattern, "/");
        const inner = if (rooted) pattern[1..] else pattern;
        if (rooted) {
            return globMatch(inner, rel_path);
        } else {
            return globMatch(inner, rel_path) or globMatch(inner, base);
        }
    }

    fn loadGitignore(self: *FileList) ![]const []const u8 {
        var patterns = std.ArrayList([]const u8).empty;
        const file = Io.Dir.cwd().openFile(self.io, ".gitignore", .{}) catch return patterns.toOwnedSlice(self.allocator);
        defer file.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var reader = Io.File.Reader.init(file, self.io, &rbuf);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        try reader.interface.appendRemaining(self.allocator, &content, .unlimited);
        var lines = std.mem.splitScalar(u8, content.items, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
            try patterns.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        return patterns.toOwnedSlice(self.allocator);
    }

    fn fileInfo(self: *FileList, path: []const u8) !?FileInfo {
        var ids = std.ArrayList(WordlistId).empty;

        // always add english + locale wordlists
        const english_locale: Locale = blk: {
            for (self.config.languages) |lang| {
                if (std.mem.eql(u8, lang.name, "english")) break :blk lang.locale orelse .US;
            }
            break :blk .US;
        };
        try ids.append(self.allocator, .english);
        const locale_id: WordlistId = switch (english_locale) {
            .US => .english_us, .AU => .english_au, .CA => .english_ca,
            .GB => .english_gb, .GBs => .english_gbs, .GBz => .english_gbz,
        };
        try ids.append(self.allocator, locale_id);

        // match language-specific wordlists
        const base = std.fs.path.basename(path);
        for (self.config.languages) |lang| {
            if (std.mem.eql(u8, lang.name, "english") or std.mem.eql(u8, lang.name, "spellr")) continue;
            var matched = false;
            for (lang.includes) |pattern| {
                if (globMatch(pattern, base) or globMatch(pattern, path)) { matched = true; break; }
            }
            if (!matched and lang.hashbangs.len > 0) {
                matched = self.matchesHashbang(path, lang.hashbangs);
            }
            if (matched) {
                if (wordlistIdForLang(lang.name)) |wid| {
                    if (!containsId(ids.items, wid)) try ids.append(self.allocator, wid);
                }
            }
        }

        // No language matched — skip the file (English only applies alongside a matched language)
        if (ids.items.len == 2) {
            ids.deinit(self.allocator);
            return null;
        }

        try ids.append(self.allocator, .spellr);

        return FileInfo{
            .path = try self.allocator.dupe(u8, path),
            .wordlist_ids = try ids.toOwnedSlice(self.allocator),
        };
    }

    fn matchesHashbang(self: *FileList, path: []const u8, hashbangs: []const []const u8) bool {
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        defer file.close(self.io);
        var rbuf: [128]u8 = undefined;
        var reader = Io.File.Reader.init(file, self.io, &rbuf);
        var buf: [128]u8 = undefined;
        var iw = Io.Writer.fixed(&buf);
        const n = reader.interface.stream(&iw, .unlimited) catch 0;
        const first = buf[0..@min(n, buf.len)];
        if (!std.mem.startsWith(u8, first, "#!")) return false;
        const line_end = std.mem.indexOfScalar(u8, first, '\n') orelse n;
        const shebang = first[2..line_end];
        for (hashbangs) |hb| if (std.mem.indexOf(u8, shebang, hb) != null) return true;
        return false;
    }
};

fn wordlistIdForLang(name: []const u8) ?WordlistId {
    if (std.mem.eql(u8, name, "ruby")) return .ruby;
    if (std.mem.eql(u8, name, "javascript")) return .javascript;
    if (std.mem.eql(u8, name, "html")) return .html;
    if (std.mem.eql(u8, name, "css")) return .css;
    if (std.mem.eql(u8, name, "shell")) return .shell;
    if (std.mem.eql(u8, name, "dockerfile")) return .dockerfile;
    if (std.mem.eql(u8, name, "xml")) return .xml;
    if (std.mem.eql(u8, name, "spellr")) return .spellr;
    return null;
}

fn containsId(ids: []WordlistId, id: WordlistId) bool {
    for (ids) |e| if (e == id) return true;
    return false;
}

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/")) {
        return std.mem.startsWith(u8, path, pattern) or std.mem.indexOf(u8, path, pattern) != null;
    }
    return globMatchInner(pattern, path);
}

fn globMatchInner(pattern: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var has_star = false;
    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == str[si] or pattern[pi] == '?')) {
            pi += 1; si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            has_star = true; star_pi = pi + 1; star_si = si; pi += 1;
        } else if (has_star) {
            pi = star_pi; star_si += 1; si = star_si;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}
