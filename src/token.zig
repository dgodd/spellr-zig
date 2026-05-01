const std = @import("std");

pub const CaseKind = enum {
    lower, // hello
    title, // Hello
    upper, // HELLO
    other, // non-Latin

    pub fn apply(self: CaseKind, allocator: std.mem.Allocator, word: []const u8) ![]u8 {
        const out = try allocator.dupe(u8, word);
        switch (self) {
            .lower => { for (out) |*c| c.* = std.ascii.toLower(c.*); },
            .upper => { for (out) |*c| c.* = std.ascii.toUpper(c.*); },
            .title => {
                if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
                for (out[1..]) |*c| c.* = std.ascii.toLower(c.*);
            },
            .other => {},
        }
        return out;
    }
};

pub const Token = struct {
    text: []const u8,
    line: u32,
    col: u32, // 0-based byte offset in line
    case_kind: CaseKind,

    pub fn normalize(self: Token, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.text.len);
        var j: usize = 0;
        for (self.text) |c| {
            // strip curly apostrophes (UTF-8: 0xE2 0x80 0x98/0x99) handled at scan site
            out[j] = std.ascii.toLower(c);
            j += 1;
        }
        return out[0..j];
    }
};
