# spellr (Zig implementation)

This is a standalone Zig 0.16.0 reimplementation of [spellr](https://github.com/robotdana/spellr), a source-code-aware spell checker originally written in Ruby.

## Build and test

```sh
zig build          # build ./zig-out/bin/spellr
zig build test     # run unit tests
zig build run      # build and run
```

Requires Zig 0.16.0 exactly. Wordlists are embedded at compile time via `@embedFile` from the `wordlists/` directory at the project root.

## Project structure

```
root.zig              # entry point (re-exports main from src/main.zig)
build.zig             # build script
build.zig.zon         # package manifest
wordlists/            # plain-text wordlist files embedded at compile time
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
- **dir walk**: `dir.walkSelectively(allocator)` then `walker.next(io)` — must open a real dir fd, not use the AT.FDCWD sentinel; call `walker.enter(io, entry)` to descend into a directory
- **Io.Threaded (tests)**: `var t = std.Io.Threaded.init(allocator, .{})` (no error), `defer t.deinit()`, `t.io()` — use to construct an `Io` value in unit tests
- **create dir**: `Io.Dir.cwd().createDirPath(io, path)`
- **stdin (interactive keypress)**: use `std.posix.read(Io.File.stdin().handle, &buf)` directly — do NOT use `Io.File.Reader.stream` for this, because the first `stream` call in positional mode attempts `sendFile`, gets `error.Unimplemented` from a fixed writer, switches mode, and returns 0; the raw `posix.read` is consistent with the `tcgetattr`/`tcsetattr` calls that surround it
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

**UPPER apostrophe handling**: after scanning an UPPER run, `scanTerm` tries to extend through an apostrophe contraction (DOESN'T, WON'T). It only extends if the uppercase letters after the apostrophe are *not* immediately followed by a lowercase letter — this prevents "D'Santos" being tokenized as "D'S" + "antos" instead of correctly yielding "Santos" as a separate `.title` token.

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

## Parallel processing (`main.zig`)

Files are checked in parallel by default using a work-stealing thread pool built from raw `std.Thread.spawn` (Zig 0.16 has no `std.Thread.Pool`).

- `WorkCtx` holds the file list, a `results` slice, and an atomic work counter (`next_work`).
- Worker threads call `fetchAdd(.monotonic)` to claim file indices and write results into `results[idx]`.
- Each worker allocates its arena from `std.heap.page_allocator` (always thread-safe) to avoid GPA contention.
- Each `FileResult` has a `done: std.atomic.Value(bool)` flag written with `.release` and read by the main thread with `.acquire`.
- The main thread consumes results in order (index 0, 1, 2, …), spinning with `Thread.yield` until each `done` flag is set, so output is deterministic regardless of completion order.
- `-j N` / `--jobs N` sets the worker count; `--no-parallel` disables threading entirely. Interactive and autocorrect modes always run sequentially.

## Reporter modes

| Flag | Mode | Behaviour |
|------|------|-----------|
| (none) | `default` | Print `path:line:col: unknown word "..."` to stderr; summary at end |
| `-q` | `quiet` | Silent; exit 1 if errors found |
| `-w` | `wordlist` | Print unknown words sorted to stdout |
| `-i` | `interactive` | Raw-terminal prompt per miss; numbered suggestions, `a`dd, `r`eplace, `S`kip all, `^C` quit |
| `-a` | `autocorrect` | Auto-apply top suggestion; report if no suggestion |

## File discovery (`file_list.zig`)

`FileList.collect` walks the directory tree using `walkSelectively`. Key behaviours:

- **Symlinks** are treated as files (`.file, .sym_link =>` branch in the walker switch).
- **Root `.gitignore`** is loaded once before the walk into `gitignore_patterns`.
- **Nested `.gitignore`** files are loaded via `loadNestedGitignore` each time a directory is entered, stored as `NestedGitignore` entries with a `prefix` (e.g. `".jj/"`) so patterns are scoped to that subtree. Both `isExcluded` and `isDirExcluded` iterate `nested_gitignores` and call `matchNestedGitignore`.
- **Glob semantics** (gitignore-compatible):
  - Patterns without `/` match basename only.
  - Patterns with an interior `/` use `globMatchPathAware` where `*` does not cross `/`.
  - If the pattern contains `**`, `globMatchPathAware` delegates to `globMatchInner` (unrestricted crossing).
  - Patterns with a trailing `/` match directory names.
- **No language guard**: `fileInfo` always returns a result for any non-excluded path, with at minimum `english` + `spellr` wordlists. Files matching language patterns get additional wordlist IDs appended.
- **Hashbang detection**: uses `appendRemaining` (not a single `stream` call) because `Io.File.Reader` in positional mode calls `sendFile` on the first `stream`, which returns 0 bytes when the writer returns `error.Unimplemented`, then switches to simple mode. `appendRemaining` loops internally and handles this transparently.

## Configuration (.spellr.yml)

Parsed by `config.zig`. Recognised keys:
- `word_minimum_length` (default 3)
- `key_heuristic_weight` (default 5)
- `key_minimum_length` (default 6)
- `locale: US|AU|CA|GB|GBs|GBz` (default US)
- `excludes:` list — appended to the built-in exclude patterns
- `languages:` map — can add `includes:` globs and `locale:` to existing languages, or define new custom language entries
