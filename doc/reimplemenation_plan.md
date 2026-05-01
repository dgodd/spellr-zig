❯ describe how spellr works and what features it has, then come up with a plan to implement those features in zig

⏺ Let me explore the spellr codebase to understand what it does before planning a Zig implementation.

⏺ Explore(Explore spellr codebase structure and features)
  ⎿  Done (43 tool uses · 66.7k tokens · 1m 45s)
  (ctrl+o to expand)

⏺ Also let me check the existing reimplementation notes file.

  Read 1 file (ctrl+o to expand)

⏺ Now I have everything I need. Here's a comprehensive description of spellr followed by a Zig implementation plan.

  ---
  How Spellr Works

  Spellr is a source-code-aware spell checker. Unlike generic spell checkers, it understands programming conventions — it splits CamelCase, snake_case, and
  kebab-case identifiers into constituent words before checking, and skips things that aren't prose: URLs, hex colors, base64 strings, ANSI escapes, etc.

  Core Pipeline

  Files → FileList → Tokenizer → LineTokenizer → SpellCheck → Reporter

  1. File Discovery — Uses gitignore-style pattern matching (fast_ignore gem) to find files. Each file is matched against language includes patterns (e.g.,
  *.rb, *.js) and/or its shebang line (#!/usr/bin/env ruby). The active languages for a file determine which wordlists are loaded.

  2. Tokenization — A StringScanner-based per-line cursor that:
  - Matches candidate terms using a compound regex covering TitleCase, UPPER_CASE, lower_case, and non-ASCII alphabetic
  - Applies a waterfall of skip patterns: URLs, hex strings (#fff, 0xDEAD), ANSI escapes, percent-encoded chars, backslash escapes, known API key patterns
  (SendGrid, GTM, Hyperwallet, etc.), repeated letters (xxxxx), sequential letters (abcdef)
  - Runs a Naive Bayes classifier (32 features, pre-trained) to detect base64/API-key-like strings
  - Handles inline disable directives: # spellr:disable-line and /* spellr:disable */ ... /* spellr:enable */ blocks

  3. Spell Checking — Binary search (O(log n)) in sorted, in-memory wordlists. Lookup is case-normalized: downcased + unicode-normalized + curly-quote
  stripped. Multiple wordlists per file: base English (with locale variants US/AU/CA/GB), language-specific (Ruby, JS, HTML, CSS, Shell, Dockerfile), and
  project-local .spellr_wordlists/.

  4. Suggestion Engine — Two-pass:
  1. Jaro-Winkler similarity filter (threshold ~0.834) against all wordlist entries
  2. Damerau-Levenshtein edit distance to rank/filter to top 5 (mistypes) or top 1 (misspells)
  Suggestions are returned in the same case as the original token.

  5. Reporting — Pluggable reporters:
  - Default: file:line:col: unknown word "foo" with error count and hint
  - Interactive (-i): Step through errors one-by-one; add to wordlist, replace, skip, or replace-all/skip-all
  - Wordlist (-w): Output unknown words sorted, for pasting into wordlist files
  - Autocorrect (-a): Auto-apply best suggestion, rewrite files in place
  - Quiet (-q): No output, just exit code

  Features Table

  ┌────────────────────────────────┬──────────────────────────────────────────────────────────────────────┐
  │            Feature             │                               Details                                │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Code-aware tokenization        │ TitleCase, UPPER_CASE, lower_case, non-ASCII splits                  │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Skip heuristics                │ URLs, hex, ANSI escapes, percent-encoding, sequential/repeated chars │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Naive Bayes key detector       │ 32-feature ML classifier for API keys / encoded strings              │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Inline disable directives      │ spellr:disable-line, spellr:disable/enable blocks                    │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Multiple reporters             │ Normal, interactive, wordlist, autocorrect, quiet, dry-run           │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Spell suggestions              │ Jaro-Winkler + Damerau-Levenshtein, case-preserving                  │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Parallel processing            │ Multi-threaded file checking (non-interactive)                       │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Locale-aware wordlists         │ US / AU / CA / GB / GBs / GBz English variants                       │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Language-specific wordlists    │ Ruby, JS, HTML, CSS, Shell, Dockerfile, XML                          │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Project wordlists              │ .spellr_wordlists/ for custom terms, editable                        │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Gitignore-aware file discovery │ Respects .gitignore, configurable excludes/includes                  │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Config merging                 │ Default YAML deep-merged with project .spellr.yml                    │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Unicode support                │ Char and byte offset tracking for multibyte UTF-8                    │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Hashbang detection             │ Match file type from #!/usr/bin/env ruby etc                         │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Interactive wordlist editing   │ Add words in sorted order, restart check from current position       │
  ├────────────────────────────────┼──────────────────────────────────────────────────────────────────────┤
  │ Wordlist management            │ --wordlist mode to generate initial wordlists                        │
  └────────────────────────────────┴──────────────────────────────────────────────────────────────────────┘

  ---
  Zig Implementation Plan

  Library / Dependency Choices

  ┌───────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────┐
  │        Concern        │                                           Approach                                           │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ CLI parsing           │ zig-clap (or hand-rolled via std.process.ArgIterator)                                        │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Tokenizer patterns    │ Hand-written byte-scanning state machine (faster than regex, no dep)                         │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Gitignore matching    │ Custom implementation using std.glob / fnmatch-style patterns                                │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ YAML config           │ zig-yaml package, or a minimal custom parser for the small schema                            │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Parallel processing   │ std.Thread.Pool + std.Thread.WaitGroup                                                       │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Jaro-Winkler          │ Implement directly (~50 lines)                                                               │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Damerau-Levenshtein   │ Implement directly (~60 lines)                                                               │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Unicode normalization │ C FFI to libunicode or ICU, or implement NFC for the limited use case                        │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Embedded wordlists    │ @embedFile at compile time, split on \n at startup                                           │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Naive Bayes weights   │ Embed data.yml via @embedFile, parse at startup (or bake into comptime struct via build.zig) │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Terminal colors       │ Manual ANSI escape sequences                                                                 │
  ├───────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Interactive terminal  │ std.io + raw terminal mode via std.posix.tcsetattr                                           │
  └───────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────┘

  Rationale for hand-written scanner: Ruby's TERM_RE is a compound regex but maps cleanly to a byte-cursor state machine. Zig has no stdlib regex, and pulling
   in a C PCRE2 binding just for this is heavy. A hand-written scanner is faster, auditable, and zero-dependency.

  ---
  Module Structure

  src/
  ├── main.zig
  ├── cli.zig                   # Arg parsing, mode selection
  ├── config/
  │   ├── config.zig            # Config struct (word_minimum_length, key_heuristic_weight, etc.)
  │   ├── loader.zig            # Load .spellr.yml, deep-merge with embedded defaults
  │   └── language.zig          # Language: name, includes[], hashbangs[], locales[], addable
  ├── file_list.zig             # Walk dir, gitignore filter, language matching, hashbang read
  ├── tokenizer/
  │   ├── tokenizer.zig         # Iterate file lines, yield tokens
  │   ├── line_tokenizer.zig    # Byte cursor: find terms, apply skip waterfall
  │   ├── token.zig             # Token: []const u8, line, char_col, byte_col, case_kind
  │   └── patterns.zig          # Skip pattern functions (url, hex, escape, sequential, ...)
  ├── key_detector/
  │   ├── naive_bayes.zig       # Gaussian Naive Bayes predict()
  │   ├── features.zig          # Extract 32 features from []const u8
  │   └── data.zig              # Pre-baked weights (comptime from data.yml or hand-ported)
  ├── wordlist/
  │   ├── wordlist.zig          # Sorted [][]const u8, binary search, normalize, insert
  │   └── embedded.zig          # @embedFile all wordlists, split at startup
  ├── checker.zig               # Per-file check loop: tokenizer → wordlist lookup → reporter
  ├── suggester.zig             # jaro_winkler() + damerau_levenshtein() + filter pipeline
  ├── reporter/
  │   ├── reporter.zig          # Reporter tagged union (comptime dispatch)
  │   ├── default.zig           # file:line:col: unknown word "foo"
  │   ├── interactive.zig       # Raw terminal, prompt per error
  │   ├── wordlist_reporter.zig # Sorted unique unknown words
  │   ├── autocorrect.zig       # Rewrite files with best suggestion applied
  │   └── quiet.zig             # No output, exit code only
  └── run.zig                   # Orchestrate: serial or thread-pool parallel, merge output

  ---
  Implementation Phases

  Phase 1 — Core: tokenize + check + output

  1. Tokenizer state machine (line_tokenizer.zig): byte cursor, find TitleCase/UPPER/lower/non-ASCII terms, apply skip patterns (hex, URL, escape, sequential,
   repeated) as bool-returning functions
  2. Wordlist (wordlist.zig): parse embedded newline-delimited text (via @embedFile) into [][]const u8 sorted slice; binary search with std.sort.binarySearch;
   normalize with std.ascii.toLower + unicode NFC
  3. Token struct with line, char column, byte column, and CaseKind enum (lower, title, upper, other)
  4. Basic checker: iterate tokens, binary-search wordlists, collect Token misses
  5. DefaultReporter: write path:line:col: unknown word "foo"\n to stderr
  6. CLI skeleton: parse --quiet, --wordlist, --interactive, --autocorrect, --dry-run, --config, file args

  Phase 2 — File discovery + config

  1. Config loader: embed default .spellr.yml via @embedFile, parse with zig-yaml, deep-merge with project config; expose typed Config struct
  2. Language matching: for each file, compare path against each language's includes glob patterns (fnmatch); for extension-less files, read first 75 bytes
  for hashbang detection
  3. FileList: std.fs.Dir.walk(), apply gitignore rules (.gitignore + config excludes/includes), yield matched paths with their active language list
  4. Wordlist selection: per file, union of gem wordlists + locale wordlists + .spellr_wordlists/{lang}.txt (loaded from disk if present)

  Phase 3 — Naive Bayes key detector

  1. Feature extractor (features.zig): port 32 features from possible_key.rb — letter frequency diffs, character-set classification
  (hex/lower36/upper36/base64/other), length, chunk stats (mean/variance of title/lower/upper/alpha/alnum/digit chunk lengths), vowel-consonant ratio
  2. Classifier (naive_bayes.zig): Gaussian probability P(x | class) = exp(-(x - mean)² / (2·var)) / sqrt(2π·var), sum log-probs per class, pick winner; apply
   key_heuristic_weight scaling
  3. Integration: in line_tokenizer.zig, after other skip checks pass, run classifier if len >= key_minimum_length; always skip if len > 200

  Phase 4 — Suggestions + reporters

  1. Jaro-Winkler (suggester.zig): standard algorithm, threshold 0.834 (len > 4) or 0.77 (shorter); collect candidates from all active wordlists
  2. Damerau-Levenshtein: standard DP (O(n·m)), filter to distance ≤ ceil((len-1) × 0.25) for mistypes, distance < len - 1 for misspell fallback; cap at 5
  results; sort by distance then similarity
  3. Wild suggestion filter: discard suggestions below 98% of best Jaro-Winkler score
  4. Case restoration: use token's CaseKind to map suggestion back to original case
  5. InteractiveReporter: std.posix.tcsetattr raw mode, print colored prompt, read single keypress, handle 1-9 / a / r / R / s / S / h / ^C
  6. AutocorrectReporter: read entire file, locate token by byte offset, splice in replacement, write back
  7. WordlistReporter: accumulate unknown words in std.StringHashMap, sort at end, write one per line

  Phase 5 — Parallel + polish

  1. Thread pool (run.zig): std.Thread.Pool, dispatch one task per file; each task produces []Token (missed words); main thread collects and serializes
  reporter output in file-path order
  2. Inline directives: in line_tokenizer.zig, scan each line for spellr:disable-line; in tokenizer.zig, track disabled bool toggled by spellr:disable /
  spellr:enable
  3. Dry-run mode: file list walk only, print matched paths
  4. Binary file detection: check first 8KB for null bytes (\x00), skip if found
  5. --suppress-file-rules: bypass gitignore and config exclude/include filters
  6. Unicode char/byte offset tracking: std.unicode.Utf8View.iterator() to advance char count alongside byte cursor

  ---
  Key Zig-Specific Notes

  - @embedFile for wordlists: All wordlists/*.txt files embed at compile time. At startup, std.mem.splitScalar(u8, data, '\n') gives lines; collect into
  ArrayList([]const u8), no allocations per lookup.
  - Comptime Naive Bayes weights: data.yml can be parsed in build.zig and emitted as a generated data.zig file with const weights = [32]ClassWeights{...} —
  eliminating all YAML parsing from the hot path.
  - Arena allocators: Use std.heap.ArenaAllocator per file check, free entire arena after reporting. Avoids per-token allocation tracking.
  - Reporter as tagged union: const Reporter = union(enum) { default: DefaultReporter, interactive: InteractiveReporter, ... } with a report(token) method —
  clean dispatch without vtables.
  - Error handling: Zig's error unions make the "restart check from token" flow explicit: checker.zig returns error.RestartFrom with a position, caller loops.
  - Fnmatch for gitignore: Zig's std.glob can handle the simple patterns; for full gitignore semantics (negation, **) a small custom implementation covers the
   ~90% case used in practice.
  - Single binary: All wordlists, Naive Bayes weights, and default config embedded — the output is a standalone binary with no runtime file dependencies
  beyond user config and project wordlists.
