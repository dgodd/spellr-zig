const std = @import("std");
const Io = std.Io;

pub const Locale = enum { US, AU, CA, GB, GBs, GBz };

pub const LanguageConfig = struct {
    name: []const u8,
    includes: []const []const u8,
    hashbangs: []const []const u8,
    locale: ?Locale,
    addable: bool,
};

pub const Config = struct {
    word_minimum_length: usize = 3,
    key_heuristic_weight: u32 = 5,
    key_minimum_length: usize = 6,
    excludes: []const []const u8,
    languages: []LanguageConfig,
};

const DEFAULT_EXCLUDES = [_][]const u8{
    ".git/", ".spellr_wordlists/", ".DS_Store", "Gemfile.lock",
    ".rspec_status", "*.png", "*.jpg", "*.jpeg", "*.gif", "*.ico",
    ".gitkeep", ".keep", "*.svg", "*.eot", "*.ttf", "*.woff", "*.woff2",
    "*.zip", "*.pdf", "*.xlsx", "*.gz",
};

const RUBY_INCLUDES = [_][]const u8{
    "*.rb", "*.rake", "*.gemspec", "*.erb", "*.haml", "*.jbuilder",
    "*.builder", "Gemfile", "Rakefile", "config.ru", "Capfile", ".simplecov",
};
const RUBY_HASHBANGS = [_][]const u8{"ruby"};
const HTML_INCLUDES = [_][]const u8{
    "*.html", "*.hml", "*.jsx", "*.tsx", "*.js", "*.ts",
    "*.jsx.snap", "*.tsx.snap", "*.coffee", "*.haml", "*.erb",
    "*.rb", "*.builder", "*.css", "*.scss", "*.sass", "*.less",
};
const JS_INCLUDES = [_][]const u8{
    "*.html", "*.hml", "*.jsx", "*.tsx", "*.js", "*.ts",
    "*.jsx.snap", "*.tsx.snap", "*.coffee", "*.haml", "*.erb", "*.json",
};
const SHELL_INCLUDES = [_][]const u8{ "*.sh", "Dockerfile" };
const SHELL_HASHBANGS = [_][]const u8{ "bash", "sh" };
const DOCKERFILE_INCLUDES = [_][]const u8{"Dockerfile"};
const CSS_INCLUDES = [_][]const u8{ "*.css", "*.sass", "*.scss", "*.less" };
const XML_INCLUDES = [_][]const u8{ "*.xml", "*.html", "*.haml", "*.hml", "*.svg" };
const EMPTY_INCLUDES = [_][]const u8{};
const EMPTY_HASHBANGS = [_][]const u8{};

var DEFAULT_LANGUAGES = [_]LanguageConfig{
    .{ .name = "english",    .includes = &EMPTY_INCLUDES,       .hashbangs = &EMPTY_HASHBANGS,  .locale = .US,  .addable = true },
    .{ .name = "ruby",       .includes = &RUBY_INCLUDES,        .hashbangs = &RUBY_HASHBANGS,   .locale = null, .addable = true },
    .{ .name = "html",       .includes = &HTML_INCLUDES,        .hashbangs = &EMPTY_HASHBANGS,  .locale = null, .addable = true },
    .{ .name = "javascript", .includes = &JS_INCLUDES,          .hashbangs = &EMPTY_HASHBANGS,  .locale = null, .addable = true },
    .{ .name = "shell",      .includes = &SHELL_INCLUDES,       .hashbangs = &SHELL_HASHBANGS,  .locale = null, .addable = true },
    .{ .name = "dockerfile", .includes = &DOCKERFILE_INCLUDES,  .hashbangs = &EMPTY_HASHBANGS,  .locale = null, .addable = true },
    .{ .name = "css",        .includes = &CSS_INCLUDES,         .hashbangs = &EMPTY_HASHBANGS,  .locale = null, .addable = true },
    .{ .name = "xml",        .includes = &XML_INCLUDES,         .hashbangs = &EMPTY_HASHBANGS,  .locale = null, .addable = true },
    .{ .name = "spellr",     .includes = &EMPTY_INCLUDES,       .hashbangs = &EMPTY_HASHBANGS,  .locale = null, .addable = false },
};

pub fn loadDefault() Config {
    return .{
        .excludes = &DEFAULT_EXCLUDES,
        .languages = &DEFAULT_LANGUAGES,
    };
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: Io, path: []const u8) !Config {
    var config = loadDefault();
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch return config;
    var rbuf: [8192]u8 = undefined;
    var reader = Io.File.Reader.init(file, io, &rbuf);
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);
    try reader.interface.appendRemaining(allocator, &content, .unlimited);
    file.close(io);
    try parseYamlOverrides(allocator, &config, content.items);
    return config;
}

fn parseYamlOverrides(allocator: std.mem.Allocator, config: *Config, yaml: []const u8) !void {
    var lines = std.mem.splitScalar(u8, yaml, '\n');

    const Section = enum { none, excludes, languages };
    var section: Section = .none;
    var current_lang_idx: ?usize = null;
    var in_lang_includes = false;
    var in_lang_locale = false;

    var extra_excludes = std.ArrayList([]const u8).empty;
    defer extra_excludes.deinit(allocator);
    var pending_includes = std.ArrayList([]const u8).empty;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (line.len == 0 or line[0] == '#') continue;

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) indent += 1;
        const trimmed = line[indent..];

        if (indent == 0) {
            if (in_lang_includes) try flushLangIncludes(allocator, config, current_lang_idx, &pending_includes);
            section = .none;
            current_lang_idx = null;
            in_lang_includes = false;
            in_lang_locale = false;

            if (std.mem.startsWith(u8, trimmed, "excludes:")) {
                section = .excludes;
            } else if (std.mem.startsWith(u8, trimmed, "languages:")) {
                section = .languages;
            } else {
                if (parseKV(trimmed, "word_minimum_length")) |v|
                    config.word_minimum_length = std.fmt.parseInt(usize, v, 10) catch config.word_minimum_length;
                if (parseKV(trimmed, "key_heuristic_weight")) |v|
                    config.key_heuristic_weight = std.fmt.parseInt(u32, v, 10) catch config.key_heuristic_weight;
                if (parseKV(trimmed, "key_minimum_length")) |v|
                    config.key_minimum_length = std.fmt.parseInt(usize, v, 10) catch config.key_minimum_length;
            }
            continue;
        }

        switch (section) {
            .none => {},
            .excludes => {
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    const item = parseListItem(trimmed[2..]);
                    if (item.len > 0) try extra_excludes.append(allocator, try allocator.dupe(u8, item));
                }
            },
            .languages => {
                if (indent == 2 and std.mem.endsWith(u8, trimmed, ":") and !std.mem.startsWith(u8, trimmed, "-")) {
                    // Start of a new language block.
                    if (in_lang_includes) try flushLangIncludes(allocator, config, current_lang_idx, &pending_includes);
                    in_lang_includes = false;
                    in_lang_locale = false;
                    const lang_name = trimmed[0 .. trimmed.len - 1];
                    current_lang_idx = findLangIdx(config, lang_name);
                } else if (indent == 4) {
                    if (in_lang_includes and !std.mem.startsWith(u8, trimmed, "-")) {
                        try flushLangIncludes(allocator, config, current_lang_idx, &pending_includes);
                        in_lang_includes = false;
                    }
                    in_lang_locale = false;
                    if (std.mem.startsWith(u8, trimmed, "includes:")) {
                        in_lang_includes = true;
                    } else if (std.mem.startsWith(u8, trimmed, "locale:")) {
                        // Scalar locale: `locale: AU`
                        if (parseKV(trimmed, "locale")) |v| {
                            if (v.len > 0) applyLocale(config, current_lang_idx, v);
                        } else {
                            in_lang_locale = true; // list form: items follow at indent 6
                        }
                    }
                } else if (indent >= 6) {
                    if (in_lang_includes and std.mem.startsWith(u8, trimmed, "- ")) {
                        const item = parseListItem(trimmed[2..]);
                        if (item.len > 0) try pending_includes.append(allocator, try allocator.dupe(u8, item));
                    } else if (in_lang_locale and std.mem.startsWith(u8, trimmed, "- ")) {
                        // Take only the first locale from the list.
                        const item = parseListItem(trimmed[2..]);
                        if (item.len > 0) {
                            applyLocale(config, current_lang_idx, item);
                            in_lang_locale = false;
                        }
                    }
                }
            },
        }
    }

    if (in_lang_includes) try flushLangIncludes(allocator, config, current_lang_idx, &pending_includes);
    // Discard any unflushed items (language not in config).
    for (pending_includes.items) |item| allocator.free(item);
    pending_includes.deinit(allocator);

    if (extra_excludes.items.len > 0) {
        var combined = std.ArrayList([]const u8).empty;
        try combined.appendSlice(allocator, config.excludes);
        try combined.appendSlice(allocator, extra_excludes.items);
        config.excludes = try combined.toOwnedSlice(allocator);
    }
}

fn flushLangIncludes(allocator: std.mem.Allocator, config: *Config, lang_idx: ?usize, pending: *std.ArrayList([]const u8)) !void {
    if (pending.items.len == 0) return;
    if (lang_idx) |idx| {
        config.languages[idx].includes = try pending.toOwnedSlice(allocator);
    } else {
        for (pending.items) |item| allocator.free(item);
        pending.clearRetainingCapacity();
    }
}

fn findLangIdx(config: *const Config, name: []const u8) ?usize {
    for (config.languages, 0..) |lang, i| {
        if (std.mem.eql(u8, lang.name, name)) return i;
    }
    return null;
}

fn applyLocale(config: *Config, lang_idx: ?usize, value: []const u8) void {
    const loc = parseLocale(value);
    if (lang_idx) |idx| {
        if (std.mem.eql(u8, config.languages[idx].name, "english")) config.languages[idx].locale = loc;
    } else {
        // top-level locale or english not yet found
        for (config.languages) |*lang| {
            if (std.mem.eql(u8, lang.name, "english")) { lang.locale = loc; break; }
        }
    }
}

fn parseListItem(s: []const u8) []const u8 {
    const comment = std.mem.indexOfScalar(u8, s, '#') orelse s.len;
    return std.mem.trim(u8, s[0..comment], " \t'\"");
}

fn parseKV(line: []const u8, key: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, t, key)) return null;
    const rest = t[key.len..];
    if (rest.len < 2 or rest[0] != ':') return null;
    return std.mem.trim(u8, rest[1..], " \t'\"");
}

fn parseLocale(s: []const u8) Locale {
    if (std.mem.eql(u8, s, "AU")) return .AU;
    if (std.mem.eql(u8, s, "CA")) return .CA;
    if (std.mem.eql(u8, s, "GB")) return .GB;
    if (std.mem.eql(u8, s, "GBs")) return .GBs;
    if (std.mem.eql(u8, s, "GBz")) return .GBz;
    return .US;
}
