# spellr — Zig reimplementation

A from-scratch reimplementation of [spellr](https://github.com/robotdana/spellr) in [Zig](https://ziglang.org/) 0.16.0.

spellr is a source-code-aware spell checker that tokenises CamelCase, snake_case and kebab-case identifiers, skips URLs and hex strings, and uses a Naive Bayes classifier to detect API keys and other non-word token patterns.

## Why Zig

The Ruby gem works well, but requires a Ruby runtime. The goal here was a single self-contained binary that embeds all wordlists at compile time and has no runtime dependencies — useful for CI environments and for learning how Zig 0.16's new `std.Io` API works in practice.

## Building

Requires Zig 0.16.0.

```sh
zig build                          # debug binary → zig-out/bin/spellr
zig build -Doptimize=ReleaseFast   # release binary (~3.7 MB, includes all wordlists)
zig build test                     # run unit tests
```

## Usage

```sh
spellr [options] [files...]
```

| Option | Description |
|--------|-------------|
| (none) | Check files, print `path:line:col: unknown word "..."` to stderr |
| `-i`, `--interactive` | Interactive mode — prompt for each miss with numbered suggestions |
| `-a`, `--autocorrect` | Auto-apply the top suggestion for each miss |
| `-w`, `--wordlist` | Print unknown words (sorted) to stdout, for adding to a wordlist |
| `-q`, `--quiet` | No output; exit 1 if any errors found |
| `-d`, `--dry-run` | Print files that would be checked, then exit |
| `-f`, `--suppress-file-rules` | Ignore exclude patterns from config |
| `-c FILE`, `--config FILE` | Config file (default: `.spellr.yml`) |
| `-v`, `--version` | Print version |
| `-h`, `--help` | Print help |

With no file arguments, spellr walks the current directory recursively, skipping patterns listed in `.spellr.yml` (and sensible defaults like `.git/`, images, lock files).

## What was reimplemented

### Tokeniser (`line_tokenizer.zig`, `token.zig`)

The byte-cursor scanner is a direct port of the Ruby `LineTokenizer`. It applies a skip waterfall before yielding any spell-checkable token:

1. `spellr:disable-line` directives (truncates the line at init time)
2. `spellr:disable` / `spellr:enable` block directives
3. Non-alphabetic punctuation and digits
4. ANSI/shell colour escapes (`\e[33m`, `\033[...m`)
5. Backslash escapes
6. URL percent-encoding (`%XX`)
7. Hex colour codes (`#abc`, `#aabbcc`)
8. URLs (`https://`, `http://`, `ftp://`, `mailto:`, `//`)
9. Known key formats (SendGrid `SG.`, GTM tags, SRI hashes `sha1-`/`sha512-`, data URIs)
10. Naive Bayes key heuristic (see below)
11. Leftover non-word characters
12. Repeated-letter runs (`xxxxxxxx`)
13. Sequential-letter runs (`abcdef`, `ABCDE`)

What remains is classified as `lower`, `upper`, `title` (TitleCase), or `other` (non-Latin Unicode). The case kind is used to apply the same capitalisation to any replacement word in interactive/autocorrect mode.

### Naive Bayes key detector (`key_detector.zig`)

The Ruby implementation includes a Naive Bayes classifier trained to distinguish API keys, tokens, and hashes from regular identifiers. It has 8 classes (four "key" and four "not key", split by character set: hex, base64, lower-alphanumeric, upper-alphanumeric) and 37 features per token (character frequencies, chunk statistics, vowel/consonant ratios, letter frequency differences against the expected uniform distribution for that character set).

The Zig version bakes the pre-trained weights directly into the source as compile-time constants, transcribed from the Ruby `lib/spellr/key_tuner/data.yml`. The classifier is only invoked on strings that pass a structural pre-filter (`possibleKeySpan`: must have at least two alternating alpha/digit sections, length 6–200, at least 3 alphabetic characters).

### Wordlists (`wordlist.zig`)

Wordlists are sorted plain-text files. Lookup is a binary search after lowercasing and stripping possessive apostrophes. All 15 wordlists are embedded at compile time via `@embedFile`:

- `english.txt` + locale supplements (`english/US.txt`, `AU.txt`, `CA.txt`, `GB.txt`, `GBs.txt`, `GBz.txt`)
- `ruby.txt`, `javascript.txt`, `html.txt`, `css.txt`, `shell.txt`, `dockerfile.txt`, `xml.txt`
- `spellr.txt` (spellr's own terminology)

Project-specific words go in `.spellr_wordlists/<language>.txt` and are loaded at runtime.

### File discovery (`file_list.zig`)

Directory walking uses `Io.Dir.walk`. Language detection matches files by glob pattern (e.g. `*.rb` → ruby wordlist) and by hashbang (`#!/usr/bin/env ruby`). Glob matching supports `*` and `?` wildcards, and directory patterns ending in `/`.

### Suggestion engine (`suggester.zig`)

For each misspelled word:
1. Scan all wordlist entries, keep those with Jaro-Winkler similarity above a length-dependent threshold (~0.77–0.83)
2. Sort by descending similarity
3. Compute Damerau-Levenshtein edit distance for candidates
4. Return "mistypes" (DL ≤ 25% of word length) or fall back to the closest "misspell"
5. Filter to within 98% of the best Jaro-Winkler score
6. Apply the original word's case transformation to each suggestion

### Reporter (`reporter.zig`, `rewriter.zig`)

All five output modes from the Ruby gem are implemented. Interactive mode uses `tcsetattr` for raw terminal input (reading a single keypress without requiring Enter). In-place file rewriting for `--autocorrect` and interactive replace is handled by `rewriter.zig`, which locates the token by line/column and splices the replacement in.

## Notable differences from the Ruby gem

- **No `.gitignore` integration.** The Ruby gem reads `.gitignore` to exclude files; this implementation only uses the patterns in `.spellr.yml`.
- **No YAML language configuration.** Language `includes`, `excludes`, and `hashbangs` come from compiled-in defaults; only `word_minimum_length`, `key_heuristic_weight`, `key_minimum_length`, and `locale` are read from `.spellr.yml`.
- **No parallel processing.** The `--no-parallel` flag is accepted but has no effect; files are always checked sequentially.
- **Single binary.** All wordlists (~786 KB of text) are embedded in the binary at compile time. The release build is ~3.7 MB.

## What Zig 0.16 looked like in practice

Zig 0.16.0 shipped a major I/O API change: `std.io` and `std.fs` were largely replaced by `std.Io` (capital I), which threads an `io: std.Io` value through every file operation. The `main` function signature became `pub fn main(init: std.process.Init) !void`, providing `init.gpa`, `init.arena`, `init.io`, and `init.minimal.args`. Writing this reimplementation was a useful exercise in navigating a rapidly changing standard library.
