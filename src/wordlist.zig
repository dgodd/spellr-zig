const std = @import("std");
const Io = std.Io;

pub const Wordlist = struct {
    name: []const u8,
    words: [][]const u8,
    /// Non-null when this Wordlist owns the data buffer that backs its word slices.
    owned_data: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, data: []const u8) !Wordlist {
        var list = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const word = std.mem.trim(u8, line, "\r ");
            if (word.len > 0) try list.append(allocator, word);
        }
        return .{ .name = name, .words = try list.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: Wordlist, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        if (self.owned_data) |d| allocator.free(d);
    }

    pub fn contains(self: Wordlist, allocator: std.mem.Allocator, word: []const u8) !bool {
        const norm = try normalize(allocator, word);
        defer allocator.free(norm);
        return binarySearch(self.words, norm);
    }

    pub fn iterator(self: Wordlist) WordIterator {
        return .{ .words = self.words, .idx = 0 };
    }
};

pub const WordIterator = struct {
    words: [][]const u8,
    idx: usize,
    pub fn next(self: *WordIterator) ?[]const u8 {
        if (self.idx >= self.words.len) return null;
        defer self.idx += 1;
        return self.words[self.idx];
    }
};

fn binarySearch(words: [][]const u8, target: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = words.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, words[mid], target)) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

pub fn normalize(allocator: std.mem.Allocator, word: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, word.len);
    var j: usize = 0;
    var i: usize = 0;
    while (i < word.len) {
        const c = word[i];
        // normalize curly apostrophes (U+2018/2019 = E2 80 98/99) to plain apostrophe
        if (c == 0xE2 and i + 2 < word.len and word[i + 1] == 0x80 and
            (word[i + 2] == 0x98 or word[i + 2] == 0x99))
        { out[j] = '\''; j += 1; i += 3; continue; }
        // strip trailing straight apostrophe (possessives)
        if (c == '\'' and i + 1 == word.len) { i += 1; continue; }
        out[j] = std.ascii.toLower(c);
        j += 1;
        i += 1;
    }
    return out[0..j];
}

// ── embedded wordlists ──────────────────────────────────────────────────────

const ENGLISH_DATA      = @embedFile("../wordlists/english.txt");
const ENGLISH_US_DATA   = @embedFile("../wordlists/english/US.txt");
const ENGLISH_AU_DATA   = @embedFile("../wordlists/english/AU.txt");
const ENGLISH_CA_DATA   = @embedFile("../wordlists/english/CA.txt");
const ENGLISH_GB_DATA   = @embedFile("../wordlists/english/GB.txt");
const ENGLISH_GBS_DATA  = @embedFile("../wordlists/english/GBs.txt");
const ENGLISH_GBZ_DATA  = @embedFile("../wordlists/english/GBz.txt");
const RUBY_DATA         = @embedFile("../wordlists/ruby.txt");
const JAVASCRIPT_DATA   = @embedFile("../wordlists/javascript.txt");
const HTML_DATA         = @embedFile("../wordlists/html.txt");
const CSS_DATA          = @embedFile("../wordlists/css.txt");
const SHELL_DATA        = @embedFile("../wordlists/shell.txt");
const DOCKERFILE_DATA   = @embedFile("../wordlists/dockerfile.txt");
const XML_DATA          = @embedFile("../wordlists/xml.txt");
const SPELLR_DATA       = @embedFile("../wordlists/spellr.txt");

pub const WordlistId = enum {
    english, english_us, english_au, english_ca, english_gb, english_gbs, english_gbz,
    ruby, javascript, html, css, shell, dockerfile, xml, spellr,
};

pub const EmbeddedWordlists = struct {
    lists: [15]Wordlist,
    pub fn get(self: *EmbeddedWordlists, id: WordlistId) *Wordlist {
        return &self.lists[@intFromEnum(id)];
    }
};

pub fn loadAll(allocator: std.mem.Allocator) !EmbeddedWordlists {
    return .{ .lists = .{
        try Wordlist.init(allocator, "english",      ENGLISH_DATA),
        try Wordlist.init(allocator, "english_us",   ENGLISH_US_DATA),
        try Wordlist.init(allocator, "english_au",   ENGLISH_AU_DATA),
        try Wordlist.init(allocator, "english_ca",   ENGLISH_CA_DATA),
        try Wordlist.init(allocator, "english_gb",   ENGLISH_GB_DATA),
        try Wordlist.init(allocator, "english_gbs",  ENGLISH_GBS_DATA),
        try Wordlist.init(allocator, "english_gbz",  ENGLISH_GBZ_DATA),
        try Wordlist.init(allocator, "ruby",         RUBY_DATA),
        try Wordlist.init(allocator, "javascript",   JAVASCRIPT_DATA),
        try Wordlist.init(allocator, "html",         HTML_DATA),
        try Wordlist.init(allocator, "css",          CSS_DATA),
        try Wordlist.init(allocator, "shell",        SHELL_DATA),
        try Wordlist.init(allocator, "dockerfile",   DOCKERFILE_DATA),
        try Wordlist.init(allocator, "xml",          XML_DATA),
        try Wordlist.init(allocator, "spellr",       SPELLR_DATA),
    }};
}

test "binary search finds word" {
    const allocator = std.testing.allocator;
    const data = "aardvark\naardvarks\naback\n";
    const wl = try Wordlist.init(allocator, "test", data);
    defer wl.deinit(allocator);
    try std.testing.expect(try wl.contains(allocator, "aardvark"));
    try std.testing.expect(try wl.contains(allocator, "Aardvark"));
    try std.testing.expect(!try wl.contains(allocator, "zzzzz"));
}
