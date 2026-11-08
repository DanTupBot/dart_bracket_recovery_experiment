# Dart Bracket Recovery Experiment

Experiments and benchmarks for recovering missing and extra parentheses/brackets (`()`, `[]`, `{}`) in Dart code using the Fasta scanner/parser token stream (`package:_fe_analyzer_shared` and `package:analyzer`), exploring approaches for [Dart-Code/Dart-Code#1832](https://github.com/Dart-Code/Dart-Code/issues/1832).

## Running the Benchmark

```bash
dart pub get
dart run bin/benchmark.dart
```

By default, `bin/benchmark.dart` automatically downloads (and caches in `.dart_tool/corpus_cache/`) 15 Material widget files from `flutter/flutter` pinned at commit [`c197ca5199e9ee5661e865596c9c07294dfab51c`](https://github.com/flutter/flutter/tree/c197ca5199e9ee5661e865596c9c07294dfab51c/packages/flutter/lib/src/material), so the benchmark is 100% deterministic without needing to clone the Flutter repository.

You can also run it against any local directory of Dart files:

```bash
dart run bin/benchmark.dart --corpus /path/to/dart/files --samples-per-file 25 --seed 42
```

---

## How the Fasta Scanner & Parser Already Recover Brackets

Under the hood, `_fe_analyzer_shared` already maintains rich bracket-pairing metadata on the token stream:
1. **Scanner Grouping (`AbstractScanner.discardBeginGroupUntil`)**:
   - Every opening `(`, `[`, `{`, `${` is scanned as a `BeginToken` with an `endGroup` pointer to its matching closer.
   - When the scanner encounters a mismatched closer, it runs a two-option lookahead trial (`option1` vs `option2`) to decide whether to insert synthetic closers (`SyntheticToken`) for unclosed `BeginToken`s on the stack, or leave the closing token unmatched in the stream.
2. **Parser Rewriting (`TokenStreamRewriter.moveSynthetic`)**:
   - Whenever the parser sees `beginToken.endGroup!.isSynthetic` at a construct boundary (e.g. `ensureCloseParen`, `parseLiteralListSuffix`), it calls `rewriter.moveSynthetic(...)` to move the scanner's synthetic closer earlier to where the grammar expected it.

---

## Strategies Compared

1. **Strategy 1: Raw Syntactic Token-Stream + Re-parse Sandbox**
   - Uses `BeginToken.endGroup` (synthetic closers) to propose insertions and unmatched real closers to propose deletions.
   - Re-parses candidate edits in memory and accepts the edit if it yields **0 syntax errors and 0 synthetic tokens** (preventing false positives where the parser hallucinated a zero-length `SyntheticStringToken` identifier).
2. **Strategy 2: Guarded Syntactic Sandbox (Zero-Breakage Syntactic Rules)**
   - Excludes `{` / `}` from batch auto-fixing (moving `}` across statements inside a block is almost always syntactically valid Dart, but changes control flow).
   - Detects extra `)` / `]` tokens that stole an outer `(` match mid-expression (where the parser reports `Expected to find ';'` right at the extra closer).
   - Rejects ambiguous `(` / `[` insertions where the unclosed group spans across an operator (`.`, `?.`, `!`, `=`, `?`, or binary operators) or contains an inner group of the same bracket kind that swallowed a comma or operator, and places synthetic closers before trailing commas when preceded by `)` / `]`.
3. **Strategy 3: Hybrid (Guarded Syntactic + Semantic Argument/Property Hints)**
   - Combines Strategy 2 with the already-computed semantic diagnostics (`undefined_named_parameter`, `extra_positional_arguments`, `undefined_getter`) that the analysis server already has on `ResolvedUnitResult.diagnostics` during quick-fix computation.
   - When an inner `(` steals an outer `)` and swallows outer arguments (e.g., `EdgeInsets.all(8, child: Text('hi'))`), the analyzer sees that `child:` is not defined on `EdgeInsets.all` and proposes closing `)` right before `child:` (provided the previous argument doesn't end with an ambiguous nested call).

---

## Benchmark Results (15 Flutter Material Files, 699 Mutations)

* **Exact Fix:** The recovered code's normalized token stream is 100% identical to the original file before the bracket was deleted/duplicated.
* **Wrong (Shifted):** The recovered code parses with 0 syntax errors and 0 synthetic tokens, **but** the bracket was placed in a different location than the original code.
* **Unfixed:** The fixer abstained (returned `null`) because no unambiguous fix was found.

### Strategy 1: Raw Syntactic Token-Stream + Re-parse Sandbox

| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Missing `)`** | 252 | 166 (65.9%) | 44 (17.5%) | 42 (16.7%) | **79.0%** | 1.05 ms |
| **Missing `]`** | 3 | 1 (33.3%) | 0 (0.0%) | 2 (66.7%) | **100.0%** | 2.70 ms |
| **Missing `}`** | 95 | 25 (26.3%) | 24 (25.3%) | 46 (48.4%) | **51.0%** | 4.20 ms |
| **Extra `)`** | 252 | 195 (77.4%) | 0 (0.0%) | 57 (22.6%) | **100.0%** | 1.20 ms |
| **Extra `]`** | 3 | 3 (100.0%) | 0 (0.0%) | 0 (0.0%) | **100.0%** | 2.72 ms |
| **Extra `}`** | 94 | 30 (31.9%) | 17 (18.1%) | 47 (50.0%) | **63.8%** | 1.89 ms |
| **Total `()` / `[]`** | **510** | **365 (71.6%)** | **44 (8.6%)** | **101 (19.8%)** | **89.2%** | **1.14 ms** |

### Strategy 2: Guarded Syntactic Sandbox (Excludes `{}` & Ambiguous Nested Steals)

| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Missing `)`** | 252 | 90 (35.7%) | 0 (0.0%) | 162 (64.3%) | **100.0%** | 0.79 ms |
| **Missing `]`** | 3 | 0 (0.0%) | 0 (0.0%) | 3 (100.0%) | **100.0%** | 1.78 ms |
| **Missing `}`** | 95 | 0 (0.0%) | 0 (0.0%) | 95 (100.0%) | **100.0%** | 3.86 ms |
| **Extra `)`** | 252 | 229 (90.9%) | 0 (0.0%) | 23 (9.1%) | **100.0%** | 3.05 ms |
| **Extra `]`** | 3 | 3 (100.0%) | 0 (0.0%) | 0 (0.0%) | **100.0%** | 2.71 ms |
| **Extra `}`** | 94 | 0 (0.0%) | 0 (0.0%) | 94 (100.0%) | **100.0%** | 1.04 ms |
| **Total `()` / `[]`** | **510** | **322 (63.1%)** | **0 (0.0%)** | **188 (36.9%)** | **100.0%** | **1.93 ms** |

### Strategy 3: Hybrid (Guarded Syntactic + Semantic Argument/Property Hints)

| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Missing `)`** | 252 | 111 (44.0%) | 0 (0.0%) | 141 (56.0%) | **100.0%** | 1.71 ms |
| **Missing `]`** | 3 | 0 (0.0%) | 0 (0.0%) | 3 (100.0%) | **100.0%** | 4.54 ms |
| **Missing `}`** | 95 | 0 (0.0%) | 0 (0.0%) | 95 (100.0%) | **100.0%** | 5.22 ms |
| **Extra `)`** | 252 | 229 (90.9%) | 0 (0.0%) | 23 (9.1%) | **100.0%** | 4.28 ms |
| **Extra `]`** | 3 | 3 (100.0%) | 0 (0.0%) | 0 (0.0%) | **100.0%** | 5.39 ms |
| **Extra `}`** | 94 | 0 (0.0%) | 0 (0.0%) | 94 (100.0%) | **100.0%** | 1.77 ms |
| **Total `()` / `[]`** | **510** | **343 (67.3%)** | **0 (0.0%)** | **167 (32.7%)** | **100.0%** | **3.01 ms** |

---

## Multi-Bracket / Paste Scenarios (Strategy 3 Multi-Pass)

When pasting code, there are often **multiple** missing/extra brackets at once (e.g., missing `))` or `)]` at the end of a pasted expression, extra `))` at the end, a mismatched `]` instead of `)`, or multiple independent errors).

`fixStrategy3MultiPass` handles these by:
1. Trying to apply all non-overlapping guarded edits in a single batch pass, or grouping multiple synthetic closers that land at the exact same offset (e.g. `))` or `)]` before `;`), and
2. Otherwise stepping iteratively (up to 5 steps) by picking the unique edit that strictly reduces total bracket imbalance (`syntheticClosers + unmatchedClosers`) and syntax error count, accepting the result **only** if it reaches a 100% clean parse with no ties.

| Scenario | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Contiguous Missing (2 adjacent `)`/`]`)** | 138 | 67 (48.6%) | 0 (0.0%) | 71 (51.4%) | **100.0%** | 4.19 ms |
| **Contiguous Missing (3 adjacent `)`/`]`)** | 33 | 10 (30.3%) | 0 (0.0%) | 23 (69.7%) | **100.0%** | 8.02 ms |
| **Contiguous Missing (4+ adjacent `)`/`]`)** | 15 | 5 (33.3%) | 0 (0.0%) | 10 (66.7%) | **100.0%** | 8.13 ms |
| **Contiguous Extra (2 adjacent `)`/`]`)** | 138 | 131 (94.9%) | 0 (0.0%) | 7 (5.1%) | **100.0%** | 10.51 ms |
| **Contiguous Extra (3 adjacent `)`/`]`)** | 33 | 31 (93.9%) | 0 (0.0%) | 2 (6.1%) | **100.0%** | 31.90 ms |
| **Contiguous Extra (4+ adjacent `)`/`]`)** | 15 | 14 (93.3%) | 0 (0.0%) | 1 (6.7%) | **100.0%** | 41.42 ms |
| **Mismatched Closer (`)` <-> `]`)** | 210 | 106 (50.5%) | 0 (0.0%) | 104 (49.5%) | **100.0%** | 6.65 ms |
| **Two Independent Errors in File** | 130 | 47 (36.2%) | 0 (0.0%) | 83 (63.8%) | **100.0%** | 10.37 ms |
| **Total Multi-Bracket** | **712** | **411 (57.7%)** | **0 (0.0%)** | **301 (42.3%)** | **100.0%** | **9.66 ms** |

