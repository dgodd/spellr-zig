/// Line tokenizer: byte-cursor scanner that extracts spell-checkable tokens
/// from a single line, applying all skip heuristics.
const std = @import("std");
const Token = @import("token.zig").Token;
const CaseKind = @import("token.zig").CaseKind;
const key_detector = @import("key_detector.zig");

pub const LineTokenizer = struct {
    line: []const u8,
    pos: usize,
    line_num: u32,
    disabled: bool,
    word_min_len: usize,
    skip_keys: bool,
    key_heuristic_weight: u32,

    pub fn initDefault(line: []const u8, line_num: u32, word_min_len: usize, skip_keys: bool) LineTokenizer {
        return init(line, line_num, word_min_len, skip_keys, 5);
    }

    pub fn init(line: []const u8, line_num: u32, word_min_len: usize, skip_keys: bool, key_heuristic_weight: u32) LineTokenizer {
        // disable-line skips everything after the directive on this line
        const disable_pos = std.mem.indexOf(u8, line, "spellr:disable-line");
        const end = if (disable_pos) |p| p else line.len;
        return .{
            .line = line[0..end],
            .pos = 0,
            .line_num = line_num,
            .disabled = false,
            .word_min_len = word_min_len,
            .skip_keys = skip_keys,
            .key_heuristic_weight = key_heuristic_weight,
        };
    }

    pub fn next(self: *LineTokenizer) ?Token {
        while (self.pos < self.line.len) {
            if (self.tryDisableDirective()) continue;
            if (self.trySkips()) continue;
            if (self.tryAfterKeySkips()) continue;
            const before = self.pos;
            if (self.scanTerm()) |tok| return tok;
            // Only advance if scanTerm itself didn't (e.g. disabled state or unknown char).
            // When scanTerm consumed a too-short word it already moved pos; adding 1 here
            // would skip the first character of the next word (e.g. "isSomething" → "omething").
            if (self.pos == before) self.pos += 1;
        }
        return null;
    }

    // ── directive detection ────────────────────────────────────────────────

    fn tryDisableDirective(self: *LineTokenizer) bool {
        const rest = self.line[self.pos..];
        if (!self.disabled) {
            if (startsWith(rest, "spellr:disable")) {
                self.disabled = true;
                self.pos += "spellr:disable".len;
                return true;
            }
        } else {
            if (startsWith(rest, "spellr:enable")) {
                self.disabled = false;
                self.pos += "spellr:enable".len;
                return true;
            }
        }
        return false;
    }

    // ── skip waterfall ─────────────────────────────────────────────────────

    fn trySkips(self: *LineTokenizer) bool {
        return self.skipNotAlpha() or
            self.skipShellColorEscape() or
            self.skipBackslashEscape() or
            self.skipUrlEncoded() or
            self.skipHex() or
            self.skipUrl() or
            self.skipKnownKeyPattern() or
            self.skipKeyHeuristic();
    }

    fn tryAfterKeySkips(self: *LineTokenizer) bool {
        return self.skipLeftoverNonWordBits() or
            self.skipRepeatedLetters() or
            self.skipSequential();
    }

    // skip non-alpha chars (punctuation, digits, etc.) that can't start a word
    fn skipNotAlpha(self: *LineTokenizer) bool {
        const c = self.line[self.pos];
        // Skip entire multi-byte UTF-8 sequences — wordlists are ASCII-only
        if (c > 0x7F) {
            const seq_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            self.pos += @min(seq_len, self.line.len - self.pos);
            return true;
        }
        // skip anything that isn't ASCII alpha, %, /, #, \, digit
        if (!std.ascii.isAlphabetic(c) and c != '%' and c != '/' and c != '#' and c != '\\' and !std.ascii.isDigit(c)) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    // \e[33m  or  \033[...m  (ANSI color escapes)
    fn skipShellColorEscape(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        if (s.len < 4) return false;
        if (s[0] != '\\') return false;
        var i: usize = 1;
        if (s[i] == 'e') {
            i += 1;
        } else if (s[i] == '0' and i + 1 < s.len and s[i + 1] == '3' and i + 2 < s.len and s[i + 2] == '3') {
            i += 3;
        } else return false;
        if (i >= s.len or s[i] != '[') return false;
        i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        while (i + 1 < s.len and s[i] == ';' and std.ascii.isDigit(s[i + 1])) {
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
        if (i >= s.len or s[i] != 'm') return false;
        i += 1;
        self.pos += i;
        return true;
    }

    // \n \t \r etc.
    fn skipBackslashEscape(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        if (s.len >= 2 and s[0] == '\\' and std.ascii.isAlphabetic(s[1])) {
            self.pos += 2;
            return true;
        }
        return false;
    }

    // %2F  %4A etc. — require at least one digit to avoid eating HAML tags like %center (%ce)
    fn skipUrlEncoded(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        if (s.len >= 3 and s[0] == '%' and isHexDigit(s[1]) and isHexDigit(s[2])) {
            if (!std.ascii.isDigit(s[1]) and !std.ascii.isDigit(s[2])) return false;
            self.pos += 3;
            return true;
        }
        return false;
    }

    // #fff #AABBCC 0xDEAD
    fn skipHex(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        if (s.len >= 4 and s[0] == '#') {
            var i: usize = 1;
            while (i < s.len and isHexDigit(s[i])) i += 1;
            if ((i == 4 or i == 7) and (i >= s.len or !isAlpha(s[i]))) {
                self.pos += i;
                return true;
            }
        }
        if (s.len >= 3 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            var i: usize = 2;
            while (i < s.len and isHexDigit(s[i])) i += 1;
            if (i > 2 and (i >= s.len or !isAlpha(s[i]))) {
                self.pos += i;
                return true;
            }
        }
        return false;
    }

    // URLs: scheme://host/path, user@host, host/path
    fn skipUrl(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        // scheme://
        if (matchScheme(s)) |scheme_len| {
            var i = scheme_len;
            i += skipUserinfo(s[i..]);
            const host_len = skipHostname(s[i..]);
            if (host_len > 0) {
                i += host_len;
                i += skipPort(s[i..]);
                i += skipPath(s[i..]);
                i += skipQuery(s[i..]);
                i += skipFragment(s[i..]);
                self.pos += i;
                return true;
            }
            return false;
        }
        // user@host/path
        const ui = skipUserinfo(s);
        if (ui > 0) {
            const hl = skipHostname(s[ui..]);
            if (hl > 0) {
                var i = ui + hl;
                i += skipPort(s[i..]);
                i += skipPath(s[i..]);
                i += skipQuery(s[i..]);
                i += skipFragment(s[i..]);
                self.pos += i;
                return true;
            }
        }
        // host/path (requires a path to distinguish from plain words)
        const hl = skipHostname(s);
        if (hl > 0 and hl < s.len and s[hl] == '/') {
            var i = hl;
            i += skipPort(s[i..]);
            i += skipPath(s[i..]);
            i += skipQuery(s[i..]);
            i += skipFragment(s[i..]);
            if (i > hl) {
                self.pos += i;
                return true;
            }
        }
        return false;
    }

    // known API key formats: SG., prg-, GTM-, sha1-, sha512-, data:...;base64,
    fn skipKnownKeyPattern(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        // SendGrid: SG.<22chars>.<43chars>
        if (startsWith(s, "SG.")) {
            var i: usize = 3;
            var n: usize = 0;
            while (i < s.len and isWordChar(s[i])) {
                i += 1;
                n += 1;
            }
            if (n == 22 and i < s.len and s[i] == '.') {
                i += 1;
                n = 0;
                while (i < s.len and isWordChar(s[i])) {
                    i += 1;
                    n += 1;
                }
                if (n == 43) {
                    self.pos += i;
                    return true;
                }
            }
        }
        // Hyperwallet: prg-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        if (startsWith(s, "prg-")) {
            if (matchHyperwallet(s)) |n| {
                self.pos += n;
                return true;
            }
        }
        // GTM-XXXXXXX
        if (startsWith(s, "GTM-")) {
            var i: usize = 4;
            var n: usize = 0;
            while (i < s.len and std.ascii.isAlphanumeric(s[i])) {
                i += 1;
                n += 1;
            }
            if (n == 7) {
                self.pos += i;
                return true;
            }
        }
        // sha<N>-<base64> SRI hashes
        const sha_sizes = [_]struct { prefix: []const u8, b64_len: usize }{
            .{ .prefix = "sha1-", .b64_len = 28 },
            .{ .prefix = "sha256-", .b64_len = 44 },
            .{ .prefix = "sha384-", .b64_len = 64 },
            .{ .prefix = "sha512-", .b64_len = 88 },
        };
        for (sha_sizes) |sha| {
            if (startsWith(s, sha.prefix)) {
                var i: usize = sha.prefix.len;
                var n: usize = 0;
                while (i < s.len and isBase64Char(s[i])) {
                    i += 1;
                    n += 1;
                }
                if (n == sha.b64_len) {
                    self.pos += i;
                    return true;
                }
            }
        }
        // data:mime;base64,...
        if (startsWith(s, "data:")) {
            if (matchDataUrl(s)) |n| {
                self.pos += n;
                return true;
            }
        }
        return false;
    }

    // Naive Bayes key heuristic for alphanumeric-heavy strings
    fn skipKeyHeuristic(self: *LineTokenizer) bool {
        if (!self.skip_keys) return false;
        const s = self.line[self.pos..];
        // must match: alnum-sep then num-sep then alnum-sep pattern (THREE_CHUNK_RE)
        const chunk = possibleKeySpan(s) orelse return false;
        if (chunk.len < 6) return false;
        if (chunk.len > 200) {
            self.pos += chunk.len;
            return true;
        }
        if (!hasMinAlpha(chunk, 3)) return false;
        if (key_detector.isKey(chunk, self.key_heuristic_weight)) {
            self.pos += chunk.len;
            return true;
        }
        return false;
    }

    // leftover: /, %, #, \, digits
    fn skipLeftoverNonWordBits(self: *LineTokenizer) bool {
        const c = self.line[self.pos];
        if (c == '/' or c == '%' or c == '#' or c == '\\' or std.ascii.isDigit(c)) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    // repeated single letters: aaaa, xxxxx (same char repeated)
    fn skipRepeatedLetters(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        if (s.len < 2 or !isAlpha(s[0])) return false;
        var i: usize = 1;
        while (i < s.len and s[i] == s[0]) i += 1;
        if (i >= 2 and (i >= s.len or !isAlpha(s[i]))) {
            self.pos += i;
            return true;
        }
        return false;
    }

    // sequential letters: abc, abcdef, ABCDEFG etc.
    fn skipSequential(self: *LineTokenizer) bool {
        const s = self.line[self.pos..];
        if (s.len < 3) return false;
        const first = s[0];
        if (!std.ascii.isAlphabetic(first)) return false;
        const base = std.ascii.toLower(first);
        if (base != 'a') return false; // sequence must start with a/A
        var i: usize = 1;
        while (i < s.len) {
            const expected = base + @as(u8, @intCast(i));
            if (expected > 'z') break;
            const c = std.ascii.toLower(s[i]);
            if (c != expected) break;
            i += 1;
        }
        if (i >= 3 and (i >= s.len or !isAlpha(s[i]))) {
            self.pos += i;
            return true;
        }
        return false;
    }

    // ── term scanning ──────────────────────────────────────────────────────

    fn scanTerm(self: *LineTokenizer) ?Token {
        if (self.disabled) return null;
        const start = self.pos;
        const c = self.line[start];

        // TitleCase: Upper followed by lower(s)
        if (isUpper(c)) {
            const case_kind = blk: {
                // check if there's a lower after the first char
                var i: usize = 1;
                while (i < self.line.len - start and isUpper(self.line[start + i])) i += 1;
                if (i == 1 and start + 1 < self.line.len and isLower(self.line[start + 1])) {
                    // TitleCase: one upper then lowers (with optional apostrophe sequences)
                    break :blk CaseKind.title;
                } else {
                    // UPPER sequence
                    break :blk CaseKind.upper;
                }
            };

            var i: usize = 1;
            switch (case_kind) {
                .title => {
                    while (i < self.line.len - start and isLower(self.line[start + i])) i += 1;
                    i = scanContractions(self.line[start..], i);
                },
                .upper => {
                    while (i < self.line.len - start and isUpper(self.line[start + i])) i += 1;
                    // Match Ruby's UPPER_CASE_RE lookahead: (?=[[:upper:]][[:lower:]]|\b)
                    // Find the largest k satisfying: word-boundary OR start of title-case (upper+lower).
                    var k = i;
                    while (k > 0) {
                        const p = start + k;
                        if (p >= self.line.len) break; // end of string = word boundary
                        const nc = self.line[p];
                        if (!isWordChar(nc)) break; // non-word char = word boundary
                        // Title-case start requires at least 2 lowercase chars (avoids breaking at plural -s)
                        if (isUpper(nc) and p + 2 < self.line.len and isLower(self.line[p + 1]) and isLower(self.line[p + 2])) break;
                        k -= 1;
                    }
                    i = k;
                    // Extend through apostrophe contractions: DOESN'T, WON'T, etc.
                    // But not D'Santos — when the uppercase run is followed by a lowercase letter,
                    // it's a TitleCase word start, not a contraction.
                    if (start + i < self.line.len and self.line[start + i] == '\'') {
                        var j = i + 1;
                        while (start + j < self.line.len and isUpper(self.line[start + j])) j += 1;
                        if (j > i + 1) {
                            const after = start + j;
                            const title_case_follows = after < self.line.len and isLower(self.line[after]);
                            if (!title_case_follows) i = j;
                        }
                    }
                },
                else => unreachable,
            }
            const word = self.line[start .. start + i];
            if (word.len >= self.word_min_len and !isUnicodeAdjacent(self.line, start, start + i)) {
                self.pos = start + i;
                return Token{ .text = word, .line = self.line_num, .col = @intCast(start), .case_kind = case_kind };
            }
            self.pos = start + i;
            return null;
        }

        // lower case word
        if (isLower(c)) {
            var i: usize = 1;
            while (i < self.line.len - start and isLower(self.line[start + i])) i += 1;
            i = scanContractions(self.line[start..], i);
            const word = self.line[start .. start + i];
            if (word.len >= self.word_min_len and !isUnicodeAdjacent(self.line, start, start + i)) {
                self.pos = start + i;
                return Token{ .text = word, .line = self.line_num, .col = @intCast(start), .case_kind = .lower };
            }
            self.pos = start + i;
            return null;
        }

        return null;
    }
};

// ── helpers ──────────────────────────────────────────────────────────────

/// Extend `i` past any apostrophe-contraction groups in `word[i..]`,
/// but stop before a possessive `'s` (apostrophe + single 's' + non-lower-or-end).
fn scanContractions(word: []const u8, start_i: usize) usize {
    if (start_i < 2) return start_i; // don't extend single-char prefixes like a'la
    var i = start_i;
    while (i < word.len and isApostrophe(word[i])) {
        const apos_len = utf8ApostropheLen(word[i]);
        const after_apos = i + apos_len;
        if (after_apos >= word.len or !isLower(word[after_apos])) break;
        // Stop at possessive 's: apostrophe + 's' + (end or non-lower)
        if (word[after_apos] == 's') {
            const after_s = after_apos + 1;
            if (after_s >= word.len or !isLower(word[after_s])) break;
        }
        i = after_apos;
        while (i < word.len and isLower(word[i])) i += 1;
    }
    return i;
}

fn isUnicodeAdjacent(line: []const u8, start: usize, end: usize) bool {
    if (start > 0 and line[start - 1] >= 0x80) return true;
    if (end < line.len and line[end] >= 0x80) return true;
    return false;
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}
fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}
fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
fn isHexDigit(c: u8) bool {
    return std.ascii.isHex(c);
}
fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}
fn isBase64Char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=';
}
fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

fn isApostrophe(c: u8) bool {
    return c == '\'' or c == 0xE2;
} // ASCII ' or start of UTF-8 curly quote
fn utf8ApostropheLen(c: u8) usize {
    return if (c == '\'') 1 else 3;
} // curly quote is 3 bytes

fn hasMinAlpha(s: []const u8, min: usize) bool {
    var n: usize = 0;
    for (s) |c| if (std.ascii.isAlphabetic(c)) {
        n += 1;
    };
    return n >= min;
}

// Match possible-key span: must have alpha-sep / num-sep / alpha-sep pattern
fn possibleKeySpan(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (!std.ascii.isAlphanumeric(s[0])) return null;
    // scan alphanumeric + separators (-_/+)
    var i: usize = 0;
    var has_alpha = false;
    var has_digit = false;
    var sections: usize = 0;
    var in_alpha = std.ascii.isAlphabetic(s[0]);
    if (in_alpha) has_alpha = true else has_digit = true;
    i = 1;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isAlphabetic(c)) {
            if (!in_alpha) {
                sections += 1;
                in_alpha = true;
            }
            has_alpha = true;
            i += 1;
        } else if (std.ascii.isDigit(c)) {
            if (in_alpha) {
                sections += 1;
                in_alpha = false;
            }
            has_digit = true;
            i += 1;
        } else if (c == '-' or c == '_' or c == '/' or c == '+') {
            i += 1;
        } else if (c == '=') {
            // trailing padding
            while (i < s.len and s[i] == '=') i += 1;
            break;
        } else break;
    }
    if (!has_alpha or !has_digit or sections < 2) return null;
    // must not end with alpha (to avoid matching plain identifiers followed by numbers)
    if (i >= s.len or !std.ascii.isAlphanumeric(s[i])) return s[0..i];
    return null;
}

// URL component parsers
fn matchScheme(s: []const u8) ?usize {
    const schemes = [_][]const u8{ "https://", "http://", "sftp://", "ftp://", "mailto:", "//" };
    for (schemes) |sc| {
        if (startsWith(s, sc)) return sc.len;
    }
    return null;
}

fn skipUserinfo(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and std.ascii.isAlphanumeric(s[i])) i += 1;
    if (i > 0 and i < s.len and s[i] == ':') {
        i += 1;
        while (i < s.len and std.ascii.isAlphanumeric(s[i])) i += 1;
    }
    if (i > 0 and i < s.len and s[i] == '@') return i + 1;
    return 0;
}

fn skipHostname(s: []const u8) usize {
    if (s.len == 0) return 0;
    // IP address
    var i: usize = 0;
    var dots: usize = 0;
    while (i < s.len) {
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) break;
        if (i < s.len and s[i] == '.') {
            dots += 1;
            i += 1;
        } else break;
    }
    if (dots == 3 and i > 0) return i - 1; // IP match

    // hostname: alnum + hyphens + dots
    i = 0;
    var has_dot = false;
    while (i < s.len) {
        const start = i;
        while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-' or s[i] == '\\')) i += 1;
        if (i == start) break;
        if (i < s.len and s[i] == '.') {
            has_dot = true;
            i += 1;
        } else break;
    }
    // trim trailing dot
    if (i > 0 and s[i - 1] == '.') i -= 1;
    if (has_dot and i > 0) return i;
    // localhost
    if (startsWith(s, "localhost")) return "localhost".len;
    return 0;
}

fn skipPort(s: []const u8) usize {
    if (s.len < 2 or s[0] != ':') return 0;
    var i: usize = 1;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return if (i > 1) i else 0;
}

fn skipPath(s: []const u8) usize {
    if (s.len == 0 or s[0] != '/') return 0;
    var i: usize = 1;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isAlphanumeric(c) or c == '=' or c == '@' or c == '!' or
            c == '$' or c == '&' or c == '~' or c == '-' or c == '/' or
            c == '.' or c == '_' or c == '\\')
        {
            i += 1;
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            i += 3;
        } else break;
    }
    return i;
}

fn skipQuery(s: []const u8) usize {
    if (s.len == 0 or s[0] != '?') return 0;
    var i: usize = 1;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isAlphanumeric(c) or c == '=' or c == '!' or c == '$' or
            c == '-' or c == '/' or c == '.' or c == '_' or c == '\\' or c == '&')
        {
            i += 1;
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            i += 3;
        } else break;
    }
    return i;
}

fn skipFragment(s: []const u8) usize {
    if (s.len == 0 or s[0] != '#') return 0;
    var i: usize = 1;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isAlphanumeric(c) or c == '=' or c == '!' or c == '$' or
            c == '&' or c == '-' or c == '/' or c == '.' or c == '\\')
        {
            i += 1;
        } else if (c == '%' and i + 2 < s.len and isHexDigit(s[i + 1]) and isHexDigit(s[i + 2])) {
            i += 3;
        } else break;
    }
    return i;
}

fn matchHyperwallet(s: []const u8) ?usize {
    // prg-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    if (!startsWith(s, "prg-")) return null;
    const pattern = [_]usize{ 8, 4, 4, 4, 12 };
    var i: usize = 4;
    for (pattern, 0..) |n, idx| {
        var k: usize = 0;
        while (k < n and i + k < s.len and isHexDigit(s[i + k])) k += 1;
        if (k != n) return null;
        i += n;
        if (idx < 4) {
            if (i >= s.len or s[i] != '-') return null;
            i += 1;
        }
    }
    return i;
}

fn matchDataUrl(s: []const u8) ?usize {
    if (!startsWith(s, "data:")) return null;
    var i: usize = 5;
    // mime type
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '/' or s[i] == ';' or s[i] == '-')) i += 1;
    if (!startsWith(s[i..], ";base64,")) return null;
    i += 8;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '/')) i += 1;
    while (i < s.len and s[i] == '=') i += 1;
    // must not be followed by alnum
    if (i < s.len and std.ascii.isAlphanumeric(s[i])) return null;
    return i;
}

// ── tests ──────────────────────────────────────────────────────────────────

test "basic lower word" {
    var tok = LineTokenizer.initDefault("hello world", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("hello", t1.text);
    const t2 = tok.next().?;
    try std.testing.expectEqualStrings("world", t2.text);
    try std.testing.expect(tok.next() == null);
}

test "title case" {
    var tok = LineTokenizer.initDefault("Hello World", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("Hello", t1.text);
    try std.testing.expect(t1.case_kind == .title);
}

test "upper case" {
    var tok = LineTokenizer.initDefault("FOO BAR", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("FOO", t1.text);
    try std.testing.expect(t1.case_kind == .upper);
}

test "skip hex color" {
    var tok = LineTokenizer.initDefault("#abc hello", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("hello", t1.text);
}

test "skip url" {
    var tok = LineTokenizer.initDefault("see https://example.com/foo for details", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("see", t1.text);
    const t2 = tok.next().?;
    try std.testing.expectEqualStrings("for", t2.text);
    const t3 = tok.next().?;
    try std.testing.expectEqualStrings("details", t3.text);
}

test "disable line directive" {
    var tok = LineTokenizer.initDefault("hello spellr:disable-line typo", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("hello", t1.text);
    try std.testing.expect(tok.next() == null);
}

test "skip repeated letters" {
    var tok = LineTokenizer.initDefault("xxxxxxxx hello", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("hello", t1.text);
}

test "skip sequential letters" {
    var tok = LineTokenizer.initDefault("abcdef hello", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("hello", t1.text);
}

test "camelCase short prefix does not eat first char of next word" {
    // "is" is below word_min_len=3; the 'S' of "Something" must not be skipped
    var tok = LineTokenizer.initDefault("isSomething", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("Something", t1.text);
    try std.testing.expect(tok.next() == null);
}

test "single-char prefix does not eat next word" {
    var tok = LineTokenizer.initDefault("aSomething", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("Something", t1.text);
}

test "center not split" {
    var tok = LineTokenizer.initDefault("    %center", 1, 3, true);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("center", t1.text);
    try std.testing.expect(tok.next() == null);
}

test "UPPER apostrophe contraction extends token" {
    // DOESN'T should be a single token
    var tok = LineTokenizer.initDefault("DOESN'T", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("DOESN'T", t1.text);
    try std.testing.expect(tok.next() == null);
}

test "TitleCase after apostrophe is not absorbed into UPPER token" {
    // D'Santos: "D" is too short (< word_min_len 3), then "Santos" is a separate token
    var tok = LineTokenizer.initDefault("D'Santos", 1, 3, false);
    const t1 = tok.next().?;
    try std.testing.expectEqualStrings("Santos", t1.text);
    try std.testing.expect(t1.case_kind == .title);
    try std.testing.expect(tok.next() == null);
}
