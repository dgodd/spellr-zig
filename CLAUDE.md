# spellr (Zig implementation)

This is a Zig 0.16.0 reimplementation of [spellr](https://github.com/robotdana/spellr), a source-code-aware spell checker originally written in Ruby. The Zig implementation lives in `zig/` within the parent spellr repository.

## Build and test

```sh
zig build          # build ./zig-out/bin/spellr
zig build test     # run unit tests
zig build run      # build and run
```

Requires Zig 0.16.0 exactly. The wordlists at `../wordlists/` are embedded at compile time via `@embedFile` through the `wordlists/` symlink at the project root.

## Project structure

```
zig/
  root.zig              # entry point (re-exports main from src/main.zig)
  build.zig             # build script
  build.zig.zon         # package manifest
  wordlists -> ../wordlists   # symlink so @embedFile can reach parent dir
  src/
    main.zig            # CLI wiring: args → config → files → check → report
    cli.zig             # argument parsing, Options struct
    config.zig          # .spellr.yml parsing, Config/LanguageConfig structs
    file_list.zig       # directory walk, glob matching, language detection
    checker.zig         # file reading, line iteration, miss collection
    line_tokenizer.zig  # byte-cursor scanner: CamelCase/UPPER/lower tokens
    token.zig           # Token and CaseKind types
    key_detector.zig    # Naive Bayes key/API-secret classifier
    wordlist.zig        # sorted wordlist binary search + embedded wordlists
    suggester.zig       # Jaro-Winkler + Damerau-Levenshtein suggestion engine
    reporter.zig        # output modes: default, quiet, wordlist, interactive, autocorrect
    rewriter.zig        # in-place file rewriting for autocorrect/interactive replace
```

## Zig 0.16 API patterns used throughout

Zig 0.16 replaced `std.io`/`std.fs` with `std.Io` (capital I). Key patterns:

- **stdout/stderr**: `var w: Io.File.Writer = .init(.stdout(), io, &buf);` then `w.interface.print(...)` + `w.flush()`
- **file read**: `Io.File.Reader.init(file, io, &rbuf)` + `reader.interface.appendRemaining(allocator, &list, .unlimited)`
- **file open**: `Io.Dir.cwd().openFile(io, path, .{})`
- **dir walk**: `dir.walk(allocator)` then `walker.next(io)` — must open a real dir fd, not use the AT.FDCWD sentinel
- **create dir**: `Io.Dir.cwd().createDirPath(io, path)`
- **stdin (interactive)**: `Io.File.Reader.init(Io.File.stdin(), io, &buf)` + fixed 1-byte writer + `.unlimited`
- **ArrayList**: `std.ArrayList(T).empty` — allocator is passed per method call (`.append(allocator, x)`, `.deinit(allocator)`, `.toOwnedSlice(allocator)`)
- **main signature**: `pub fn main(init: std.process.Init) !void` — `init.gpa`, `init.arena.allocator()`, `init.io`, `init.minimal.args.toSlice(arena)`
- **args type**: `init.minimal.args.toSlice(arena)` returns `[]const [:0]const u8` (sentinel-terminated)

## Tokenization pipeline

`LineTokenizer` (in `line_tokenizer.zig`) is the core. It runs a skip waterfall before yielding any token:

1. `spellr:disable-line` — truncates line at init time
2. `spellr:disable` / `spellr:enable` — block-level disable mid-line
3. Non-alpha chars (punctuation, digits)
4. ANSI/shell color escapes (`\e[33m`, `\033[...m`)
5. Backslash escapes
6. URL percent-encoding (`%XX`)
7. Hex color codes (`#abc`, `#aabbcc`)
8. URLs (`https://...`, `http://...`, etc.)
9. Known key patterns (SG., prg-, GTM-, sha1-, sha512-, data:)
10. Naive Bayes key heuristic (`skipKeyHeuristic` → `key_detector.isKey`)
11. Leftover non-word chars (`/`, `%`, `#`, `\`, digits)
12. Repeated-letter runs (`xxxxxxxx`)
13. Sequential-letter runs (`abcdef`)

Then it scans a word token and classifies it as `.lower`, `.upper`, `.title`, or `.other` (non-Latin Unicode).

## Key detector

`key_detector.isKey(s)` is only called from `skipKeyHeuristic`, which first gates on:
- `possibleKeySpan`: string must have alpha sections, digit sections, and ≥ 2 alternations
- length ≥ 6 and ≤ 200
- ≥ 3 alphabetic chars

The Naive Bayes classifier has 8 classes × 37 features. Weights are baked in as compile-time constants transcribed from the Ruby `data.yml`. Key classes get a log-probability boost of `log(10^key_heuristic_weight)` (default weight 5).

## Wordlists

All wordlists are embedded at compile time via `@embedFile`. They are sorted plain-text files (one word per line) enabling binary search. The `wordlists/` symlink at the package root points to `../wordlists/` to stay within the Zig package boundary.

Languages and their wordlists:
- `english` + locale variant (US/AU/CA/GB/GBs/GBz) — always loaded
- `ruby`, `javascript`, `html`, `css`, `shell`, `dockerfile`, `xml` — matched by file extension/hashbang
- `spellr` — always added last (spellr's own terminology)

Project-specific wordlists are read from `.spellr_wordlists/*.txt` at runtime.

## Suggestion engine

`suggester.suggestions(allocator, token, wordlists)`:
1. Normalize the misspelled word (lowercase, strip apostrophes)
2. Scan all wordlist words, keep those with Jaro-Winkler similarity ≥ threshold
3. Sort by descending similarity
4. Compute Damerau-Levenshtein distance for candidates
5. Return "mistypes" (DL ≤ 25% of length) or fall back to closest "misspell"
6. Filter to within 98% of the best similarity score
7. Apply original word's case transformation to suggestions

## Reporter modes

| Flag | Mode | Behaviour |
|------|------|-----------|
| (none) | `default` | Print `path:line:col: unknown word "..."` to stderr; summary at end |
| `-q` | `quiet` | Silent; exit 1 if errors found |
| `-w` | `wordlist` | Print unknown words sorted to stdout |
| `-i` | `interactive` | Raw-terminal prompt per miss; numbered suggestions, `a`dd, `r`eplace, `S`kip all, `^C` quit |
| `-a` | `autocorrect` | Auto-apply top suggestion; report if no suggestion |

## Configuration (.spellr.yml)

Parsed by `config.zig`. Recognised keys:
- `word_minimum_length` (default 3)
- `key_heuristic_weight` (default 5)
- `key_minimum_length` (default 6)
- `locale: US|AU|CA|GB|GBs|GBz` (default US)

Language and exclude customisation from YAML is not yet implemented; defaults from `config.zig` are used.
