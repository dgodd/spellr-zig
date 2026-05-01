const std = @import("std");
const Wordlist = @import("wordlist.zig").Wordlist;
const normalize = @import("wordlist.zig").normalize;
const CaseKind = @import("token.zig").CaseKind;
const Token = @import("token.zig").Token;

const MAX_SUGGESTIONS = 5;

pub fn suggestions(
    allocator: std.mem.Allocator,
    token: Token,
    wordlists: []*const Wordlist,
) ![][]const u8 {
    const term = try normalize(allocator, token.text);
    defer allocator.free(term);

    const threshold: f64 = if (term.len > 4) 0.834 else 0.77;

    const Candidate = struct {
        word: []const u8,
        jw: f64,
        dl: ?usize = null,
    };

    var candidates = std.ArrayList(Candidate).empty;
    defer candidates.deinit(allocator);

    for (wordlists) |wl| {
        var it = wl.iterator();
        while (it.next()) |word| {
            const sim = jaroWinkler(word, term);
            if (sim >= threshold) {
                var dup = false;
                for (candidates.items) |c| if (std.mem.eql(u8, c.word, word)) { dup = true; break; };
                if (!dup) try candidates.append(allocator, .{ .word = word, .jw = sim });
            }
        }
    }

    std.sort.pdq(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.jw != b.jw) return a.jw > b.jw;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lessThan);

    const mistype_threshold: usize = @intCast(@max(1, @divTrunc(@as(isize, @intCast((term.len -| 1))) * 25, 100) + 1));
    var mistypes = std.ArrayList(Candidate).empty;
    defer mistypes.deinit(allocator);

    for (candidates.items) |*c| {
        if (mistypes.items.len >= MAX_SUGGESTIONS) break;
        c.dl = damerauLevenshtein(allocator, c.word, term) catch continue;
        if (c.dl.? <= mistype_threshold) try mistypes.append(allocator, c.*);
    }

    // build final candidate list (mistypes or misspell fallback)
    var result = std.ArrayList(Candidate).empty;
    defer result.deinit(allocator);

    if (mistypes.items.len > 0) {
        try result.appendSlice(allocator, mistypes.items);
    } else {
        for (candidates.items) |*c| {
            if (result.items.len >= 1) break;
            c.dl = damerauLevenshtein(allocator, c.word, term) catch continue;
            const min_len = @min(term.len, c.word.len);
            if (c.dl.? < min_len -| 1) try result.append(allocator, c.*);
        }
    }

    // wild filter: keep within 98% of best similarity
    if (result.items.len > 1) {
        const best_jw = result.items[0].jw;
        const wild_threshold = best_jw * 0.98;
        var i: usize = result.items.len;
        while (i > 0) {
            i -= 1;
            if (result.items[i].jw < wild_threshold) _ = result.orderedRemove(i);
        }
    }

    var out = std.ArrayList([]const u8).empty;
    for (result.items) |c| {
        const suggested = try token.case_kind.apply(allocator, c.word);
        try out.append(allocator, suggested);
    }
    return out.toOwnedSlice(allocator);
}

pub fn jaroWinkler(s1: []const u8, s2: []const u8) f64 {
    const jaro_sim = jaro(s1, s2);
    if (jaro_sim < 0.7) return jaro_sim;

    var prefix: usize = 0;
    const max_prefix = @min(@min(s1.len, s2.len), 4);
    while (prefix < max_prefix and s1[prefix] == s2[prefix]) prefix += 1;

    return jaro_sim + @as(f64, @floatFromInt(prefix)) * 0.1 * (1.0 - jaro_sim);
}

fn jaro(s1: []const u8, s2: []const u8) f64 {
    if (s1.len == 0 and s2.len == 0) return 1.0;
    if (s1.len == 0 or s2.len == 0) return 0.0;
    if (std.mem.eql(u8, s1, s2)) return 1.0;

    const match_dist = (@max(s1.len, s2.len) / 2) -| 1;
    var s1_matches = std.mem.zeroes([256]bool);
    var s2_matches = std.mem.zeroes([256]bool);
    var matches: f64 = 0;
    var transpositions: f64 = 0;

    for (s1, 0..) |c1, i| {
        const start = if (i > match_dist) i - match_dist else 0;
        const end = @min(i + match_dist + 1, s2.len);
        for (s2[start..end], start..) |c2, j| {
            if (s2_matches[j] or c1 != c2) continue;
            s1_matches[i] = true;
            s2_matches[j] = true;
            matches += 1;
            break;
        }
    }

    if (matches == 0) return 0.0;

    var k: usize = 0;
    for (s1, 0..) |c1, i| {
        if (!s1_matches[i]) continue;
        while (!s2_matches[k]) k += 1;
        if (c1 != s2[k]) transpositions += 1;
        k += 1;
    }

    return (matches / @as(f64, @floatFromInt(s1.len)) +
        matches / @as(f64, @floatFromInt(s2.len)) +
        (matches - transpositions / 2.0) / matches) / 3.0;
}

pub fn damerauLevenshtein(allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) !usize {
    const m = s1.len;
    const n = s2.len;
    if (m == 0) return n;
    if (n == 0) return m;

    var dp = try allocator.alloc([]usize, m + 1);
    defer allocator.free(dp);
    for (dp) |*row| row.* = try allocator.alloc(usize, n + 1);
    defer for (dp) |row| allocator.free(row);

    for (0..m + 1) |i| dp[i][0] = i;
    for (0..n + 1) |j| dp[0][j] = j;

    for (1..m + 1) |i| {
        for (1..n + 1) |j| {
            const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;
            dp[i][j] = @min(
                @min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
                dp[i - 1][j - 1] + cost,
            );
            if (i > 1 and j > 1 and s1[i - 1] == s2[j - 2] and s1[i - 2] == s2[j - 1]) {
                dp[i][j] = @min(dp[i][j], dp[i - 2][j - 2] + cost);
            }
        }
    }
    return dp[m][n];
}

test "jaro winkler similar" {
    const sim = jaroWinkler("hello", "helo");
    try std.testing.expect(sim > 0.8);
}

test "damerau levenshtein" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try damerauLevenshtein(allocator, "hello", "helo"));
    try std.testing.expectEqual(@as(usize, 0), try damerauLevenshtein(allocator, "hello", "hello"));
    try std.testing.expectEqual(@as(usize, 1), try damerauLevenshtein(allocator, "ab", "ba"));
}
