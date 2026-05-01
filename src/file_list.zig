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

const NestedGitignore = struct {
    prefix: []const u8,
    patterns: []const []const u8,
};

pub const FileList = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: *const Config,
    suppress_file_rules: bool,
    gitignore_patterns: []const []const u8 = &.{},
    nested_gitignores: std.ArrayList(NestedGitignore) = std.ArrayList(NestedGitignore).empty,

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
                for (self.nested_gitignores.items) |scope| {
                    self.allocator.free(scope.prefix);
                    for (scope.patterns) |p| self.allocator.free(p);
                    self.allocator.free(scope.patterns);
                }
                self.nested_gitignores.deinit(self.allocator);
                self.nested_gitignores = std.ArrayList(NestedGitignore).empty;
            }
            var actual_dir = Io.Dir.cwd().openDir(self.io, ".", .{ .iterate = true }) catch return results.toOwnedSlice(self.allocator);
            defer actual_dir.close(self.io);
            var walker = try actual_dir.walkSelectively(self.allocator);
            defer walker.deinit();
            while (try walker.next(self.io)) |entry| {
                switch (entry.kind) {
                    .directory => {
                        if (self.suppress_file_rules or !self.isDirExcluded(entry.path)) {
                            if (!self.suppress_file_rules) try self.loadNestedGitignore(entry.path);
                            try walker.enter(self.io, entry);
                        }
                    },
                    .file, .sym_link => {
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
            if (matchGitignoreFile(pattern, rel_path, base)) return true;
        }
        for (self.gitignore_patterns) |pattern| {
            if (matchGitignoreFile(pattern, rel_path, base)) return true;
        }
        for (self.nested_gitignores.items) |scope| {
            if (matchNestedGitignore(scope, rel_path)) return true;
        }
        return false;
    }

    fn isDirExcluded(self: *FileList, rel_path: []const u8) bool {
        if (checkDirExcluded(self.config.excludes, rel_path)) return true;
        if (checkDirExcluded(self.gitignore_patterns, rel_path)) return true;
        for (self.nested_gitignores.items) |scope| {
            if (matchNestedGitignore(scope, rel_path)) return true;
        }
        return false;
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

    fn loadNestedGitignore(self: *FileList, dir_path: []const u8) !void {
        const gitignore_path = try std.fmt.allocPrint(self.allocator, "{s}/.gitignore", .{dir_path});
        defer self.allocator.free(gitignore_path);
        const file = Io.Dir.cwd().openFile(self.io, gitignore_path, .{}) catch return;
        defer file.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var reader = Io.File.Reader.init(file, self.io, &rbuf);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        try reader.interface.appendRemaining(self.allocator, &content, .unlimited);
        var patterns = std.ArrayList([]const u8).empty;
        var lines = std.mem.splitScalar(u8, content.items, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
            try patterns.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        if (patterns.items.len == 0) {
            patterns.deinit(self.allocator);
            return;
        }
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}/", .{dir_path});
        try self.nested_gitignores.append(self.allocator, .{
            .prefix = prefix,
            .patterns = try patterns.toOwnedSlice(self.allocator),
        });
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

        // always add english + all applicable locale wordlists
        var english_locales: []const Locale = &.{.US};
        for (self.config.languages) |lang| {
            if (std.mem.eql(u8, lang.name, "english")) {
                english_locales = lang.locales;
                break;
            }
        }
        try ids.append(self.allocator, .english);
        for (english_locales) |loc| {
            const locale_id: WordlistId = switch (loc) {
                .US => .english_us,
                .AU => .english_au,
                .CA => .english_ca,
                .GB => .english_gb,
                .GBs => .english_gbs,
                .GBz => .english_gbz,
            };
            if (!containsId(ids.items, locale_id)) try ids.append(self.allocator, locale_id);
        }
        // match language-specific wordlists
        const base = std.fs.path.basename(path);
        for (self.config.languages) |lang| {
            if (std.mem.eql(u8, lang.name, "english") or std.mem.eql(u8, lang.name, "spellr")) continue;
            var matched = false;
            for (lang.includes) |pattern| {
                if (globMatch(pattern, base) or globMatch(pattern, path)) {
                    matched = true;
                    break;
                }
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

        try ids.append(self.allocator, .spellr);

        return FileInfo{
            .path = try self.allocator.dupe(u8, path),
            .wordlist_ids = try ids.toOwnedSlice(self.allocator),
        };
    }

    fn matchesHashbang(self: *FileList, path: []const u8, hashbangs: []const []const u8) bool {
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        defer file.close(self.io);
        var rbuf: [256]u8 = undefined;
        var reader = Io.File.Reader.init(file, self.io, &rbuf);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        reader.interface.appendRemaining(self.allocator, &content, .unlimited) catch {};
        const first = content.items;
        if (!std.mem.startsWith(u8, first, "#!")) return false;
        const line_end = std.mem.indexOfScalar(u8, first, '\n') orelse first.len;
        const shebang = first[2..line_end];
        for (hashbangs) |hb| if (std.mem.indexOf(u8, shebang, hb) != null) return true;
        return false;
    }
};

fn matchGitignoreFile(pattern: []const u8, rel_path: []const u8, base: []const u8) bool {
    const rooted = std.mem.startsWith(u8, pattern, "/");
    const inner = if (rooted) pattern[1..] else pattern;
    // If the effective pattern contains '/', use path-aware matching where * doesn't cross /
    // (gitignore rule: patterns with interior / are anchored path patterns)
    if (std.mem.indexOfScalar(u8, inner, '/') != null) {
        return globMatchPathAware(inner, rel_path);
    }
    if (rooted) {
        return globMatch(inner, rel_path);
    } else {
        return globMatch(inner, base);
    }
}

fn matchNestedGitignore(scope: NestedGitignore, rel_path: []const u8) bool {
    if (!std.mem.startsWith(u8, rel_path, scope.prefix)) return false;
    const rel = rel_path[scope.prefix.len..];
    const base = std.fs.path.basename(rel);
    for (scope.patterns) |pattern| {
        if (matchGitignoreFile(pattern, rel, base)) return true;
    }
    return false;
}

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

// Path-aware glob: * does not cross /. Used for gitignore patterns that contain an interior /.
// Exception: ** patterns match across directory boundaries (gitignore semantics).
fn globMatchPathAware(pattern: []const u8, str: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**") != null) return globMatchInner(pattern, str);
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var has_star = false;
    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == str[si] or pattern[pi] == '?')) {
            pi += 1;
            si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            has_star = true;
            star_pi = pi + 1;
            star_si = si;
            pi += 1;
        } else if (has_star and str[star_si] != '/') {
            pi = star_pi;
            star_si += 1;
            si = star_si;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn globMatchInner(pattern: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var has_star = false;
    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == str[si] or pattern[pi] == '?')) {
            pi += 1;
            si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            has_star = true;
            star_pi = pi + 1;
            star_si = si;
            pi += 1;
        } else if (has_star) {
            pi = star_pi;
            star_si += 1;
            si = star_si;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ── regression tests ──────────────────────────────────────────────────────────

test "globMatchPathAware: star does not cross slash" {
    // Regression: /public/*.html was wrongly matching public/maintenance/default.html
    try std.testing.expect(!globMatchPathAware("public/*.html", "public/maintenance/default.html"));
}

test "globMatchPathAware: star matches within a single path component" {
    try std.testing.expect(globMatchPathAware("public/*.html", "public/index.html"));
}

test "globMatchPathAware: double-star crosses directory boundaries" {
    // Regression: ** patterns must still work after the path-aware fix
    try std.testing.expect(globMatchPathAware("webpack/app/_scenes/**/*.generated.ts", "webpack/app/_scenes/admin/deep/foo.generated.ts"));
}

test "globMatchPathAware: plain pattern (no slash) matches normally" {
    try std.testing.expect(globMatchPathAware("*.rb", "foo.rb"));
    try std.testing.expect(!globMatchPathAware("*.rb", "foo.js"));
}

test "matchGitignoreFile: rooted pattern with interior slash uses path-aware matching" {
    // /public/*.html should NOT match public/sub/file.html (star can't cross slash)
    try std.testing.expect(!matchGitignoreFile("/public/*.html", "public/sub/file.html", "file.html"));
    // but should match direct child
    try std.testing.expect(matchGitignoreFile("/public/*.html", "public/index.html", "index.html"));
}

test "matchGitignoreFile: non-rooted pattern without slash matches basename only" {
    // Regression: *.rb should match by basename, not full path
    try std.testing.expect(matchGitignoreFile("*.rb", "app/models/user.rb", "user.rb"));
    // should not match a different extension
    try std.testing.expect(!matchGitignoreFile("*.rb", "app/models/user.js", "user.js"));
}

test "matchGitignoreFile: non-rooted pattern with interior slash uses path-aware matching" {
    try std.testing.expect(matchGitignoreFile("vendor/bundle", "vendor/bundle", "bundle"));
    try std.testing.expect(!matchGitignoreFile("vendor/bundle", "other/vendor/bundle", "bundle"));
}

test "matchNestedGitignore: patterns only apply within the prefix scope" {
    const scope = NestedGitignore{
        .prefix = ".jj/",
        .patterns = &[_][]const u8{"*"},
    };
    // inside scope: excluded
    try std.testing.expect(matchNestedGitignore(scope, ".jj/anything"));
    // outside scope: not excluded
    try std.testing.expect(!matchNestedGitignore(scope, "other/anything"));
}

test "matchNestedGitignore: double-star pattern excludes nested files" {
    const scope = NestedGitignore{
        .prefix = ".ruby-lsp/",
        .patterns = &[_][]const u8{"**/*.rb"},
    };
    try std.testing.expect(matchNestedGitignore(scope, ".ruby-lsp/deep/nested/foo.rb"));
    try std.testing.expect(!matchNestedGitignore(scope, ".ruby-lsp/deep/nested/foo.ts"));
}

test "matchNestedGitignore: does not match files outside the prefix" {
    const scope = NestedGitignore{
        .prefix = "vendor/",
        .patterns = &[_][]const u8{"*.lock"},
    };
    try std.testing.expect(matchNestedGitignore(scope, "vendor/Gemfile.lock"));
    try std.testing.expect(!matchNestedGitignore(scope, "Gemfile.lock"));
    try std.testing.expect(!matchNestedGitignore(scope, "other/Gemfile.lock"));
}

test "FileList.matchesHashbang: missing file returns false without crash" {
    // Regression: matchesHashbang must not crash on missing files (symlinks to missing targets, etc.)
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const config = @import("config.zig").loadDefault();
    var fl = FileList.init(allocator, io, &config, true);

    const ruby_hashbangs = [_][]const u8{"ruby"};
    try std.testing.expect(!fl.matchesHashbang("/tmp/nonexistent_spellr_test_xyz", &ruby_hashbangs));
}

test "FileList.fileInfo: files with no language match still get english wordlist" {
    // Regression: files that don't match any language were previously returned as null.
    // Now all non-excluded files get at least the english + spellr wordlists.
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const config = @import("config.zig").loadDefault();
    var fl = FileList.init(allocator, io, &config, true);

    // A file with an extension that matches no language
    const result = try fl.fileInfo("some_random_file.xyz");
    try std.testing.expect(result != null);

    const info = result.?;
    defer {
        allocator.free(info.path);
        allocator.free(info.wordlist_ids);
    }

    // Must contain english and spellr at minimum
    var has_english = false;
    var has_spellr = false;
    for (info.wordlist_ids) |wid| {
        if (wid == .english) has_english = true;
        if (wid == .spellr) has_spellr = true;
    }
    try std.testing.expect(has_english);
    try std.testing.expect(has_spellr);
}
