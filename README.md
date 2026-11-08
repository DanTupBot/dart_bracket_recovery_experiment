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
2. **Strategy 2: Guarded Syntactic Sandbox**
   - Excludes `{` / `}` from batch auto-fixing (moving `}` across statements inside a block is almost always syntactically valid Dart, but changes control flow).
   - Also detects extra `)` / `]` tokens that stole an outer `(` match mid-expression (where the parser reports `Expected to find ';'` right at the extra closer).
   - Rejects ambiguous nested same-bracket steals where an unclosed `(` or `[` spans across a `,`, `.property`, `?.property`, or binary operator.
3. **Strategy 3: Hybrid (Guarded Syntactic + Semantic Argument/Property Hints)**
   - Simulates using the already-computed semantic diagnostics (`undefined_named_parameter`, `extra_positional_arguments`, `undefined_getter`) that the analysis server already has on `ResolvedUnitResult.diagnostics` during quick-fix computation.
   - When an inner `(` steals an outer `)` and swallows outer arguments (e.g., `EdgeInsets.all(8, child: Text('hi'))`), the analyzer sees that `child:` is not defined on `EdgeInsets.all` and proposes closing `)` right before `child:`.

---

## Benchmark Results (15 Flutter Material Files, 699 Mutations)

* **Exact Fix:** The recovered code's normalized token stream is 100% identical to the original file before the bracket was deleted/duplicated.
* **Wrong (Shifted):** The recovered code parses with 0 syntax errors and 0 synthetic tokens, **but** the bracket was placed in a different location than the original code.
* **Unfixed:** The fixer abstained (returned `null`) because no unambiguous fix was found.

### Strategy 1: Raw Syntactic Token-Stream + Re-parse Sandbox

| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Missing `)`** | 252 | 166 (65.9%) | 44 (17.5%) | 42 (16.7%) | **79.0%** | 1.05 ms |
| **Missing `]`** | 3 | 1 (33.3%) | 0 (0.0%) | 2 (66.7%) | **100.0%** | 2.57 ms |
| **Missing `}`** | 95 | 25 (26.3%) | 24 (25.3%) | 46 (48.4%) | **51.0%** | 4.06 ms |
| **Extra `)`** | 252 | 195 (77.4%) | 0 (0.0%) | 57 (22.6%) | **100.0%** | 1.21 ms |
| **Extra `]`** | 3 | 3 (100.0%) | 0 (0.0%) | 0 (0.0%) | **100.0%** | 2.81 ms |
| **Extra `}`** | 94 | 30 (31.9%) | 17 (18.1%) | 47 (50.0%) | **63.8%** | 1.99 ms |
| **Total `()` / `[]`** | **510** | **365 (71.6%)** | **44 (8.6%)** | **101 (19.8%)** | **89.2%** | **1.15 ms** |

### Strategy 2: Guarded Syntactic Sandbox (Excludes `{}` & Ambiguous Nested Steals)

| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Missing `)`** | 252 | 137 (54.4%) | 18 (7.1%) | 97 (38.5%) | **88.4%** | 0.98 ms |
| **Missing `]`** | 3 | 1 (33.3%) | 0 (0.0%) | 2 (66.7%) | **100.0%** | 2.35 ms |
| **Missing `}`** | 95 | 0 (0.0%) | 0 (0.0%) | 95 (100.0%) | **100.0%** | 3.71 ms |
| **Extra `)`** | 252 | 229 (90.9%) | 0 (0.0%) | 23 (9.1%) | **100.0%** | 2.94 ms |
| **Extra `]`** | 3 | 3 (100.0%) | 0 (0.0%) | 0 (0.0%) | **100.0%** | 2.57 ms |
| **Extra `}`** | 94 | 0 (0.0%) | 0 (0.0%) | 94 (100.0%) | **100.0%** | 1.05 ms |
| **Total `()` / `[]`** | **510** | **370 (72.5%)** | **18 (3.5%)** | **122 (23.9%)** | **95.4%** | **1.97 ms** |

### Strategy 3: Hybrid (Guarded Syntactic + Semantic Argument/Property Hints)

| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Missing `)`** | 252 | 158 (62.7%) | 18 (7.1%) | 76 (30.2%) | **89.8%** | 2.09 ms |
| **Missing `]`** | 3 | 1 (33.3%) | 0 (0.0%) | 2 (66.7%) | **100.0%** | 5.06 ms |
| **Missing `}`** | 95 | 0 (0.0%) | 0 (0.0%) | 95 (100.0%) | **100.0%** | 5.02 ms |
| **Extra `)`** | 252 | 229 (90.9%) | 0 (0.0%) | 23 (9.1%) | **100.0%** | 4.11 ms |
| **Extra `]`** | 3 | 3 (100.0%) | 0 (0.0%) | 0 (0.0%) | **100.0%** | 5.48 ms |
| **Extra `}`** | 94 | 0 (0.0%) | 0 (0.0%) | 94 (100.0%) | **100.0%** | 1.85 ms |
| **Total `()` / `[]`** | **510** | **391 (76.7%)** | **18 (3.5%)** | **101 (19.8%)** | **95.6%** | **3.13 ms** |

---

## Key Takeaways

1. **Deleting Extra `)` / `]` is 100% Precise (`232 / 232` when applied, `91%` recall):**
   - Combining unmatched closer tokens in the scanner stream with `Expected to find ';'` errors on `)` / `]` tokens mid-expression fixes over 90% of extra-bracket errors with **0 false positives**.
2. **Why Pure Syntax Has a "Shifted Paren" Trap on Missing `)`:**
   - When an inner `(` is missing its `)`, it steals the outer `)` and shifts the synthetic `)` to the end of the outer call or expression, which often still parses with **0 syntax errors**:
     - *Swallowed outer arguments:* `Container(padding: EdgeInsets.all(8, child: Text('hi'))` parses cleanly with `child:` inside `EdgeInsets.all(...)` if the synthetic `)` is placed at the end.
     - *Swallowed property/operator suffix:* `Theme.of(context).platform` (missing `)`) parses cleanly as `Theme.of(context.platform)` when `)` is placed at the end.
3. **Using Existing Semantic Diagnostics Fixes Nested Widget Calls for Free:**
   - During quick-fix computation in `analysis_server`, `ResolvedUnitResult.diagnostics` is already available. Using `undefined_named_parameter` / `extra_positional_arguments` / `undefined_getter` offsets inside unclosed `BeginToken` spans recovers nested widget calls without needing any extra resolution passes.
