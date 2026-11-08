import 'dart:io';
import 'dart:math';

import 'package:_fe_analyzer_shared/src/scanner/token.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:args/args.dart';
import 'package:dart_bracket_recovery_experiment/bracket_fixer.dart';
import 'package:path/path.dart' as p;

/// Pinned Flutter repository commit hash so default corpus downloads are 100%
/// deterministic and reproducible over time.
const String pinnedFlutterCommit = 'c197ca5199e9ee5661e865596c9c07294dfab51c';

/// Default sample of 15 Material widget files from `packages/flutter/lib/src/material/`.
const List<String> defaultMaterialFiles = [
  'about.dart',
  'action_buttons.dart',
  'action_chip.dart',
  'action_icons_theme.dart',
  'adaptive_text_selection_toolbar.dart',
  'app.dart',
  'app_bar.dart',
  'app_bar_theme.dart',
  'arc.dart',
  'autocomplete.dart',
  'back_button.dart',
  'badge.dart',
  'badge_theme.dart',
  'banner.dart',
  'banner_theme.dart',
];

class Stats {
  int total = 0;
  int exact = 0;
  int wrong = 0;
  int unfixed = 0;
  int totalMicroseconds = 0;

  void record(String? fixed, String originalNormalized, int elapsedUs) {
    total++;
    totalMicroseconds += elapsedUs;
    if (fixed == null) {
      unfixed++;
    } else if (normalizeCode(fixed) == originalNormalized) {
      exact++;
    } else {
      wrong++;
    }
  }

  double get exactPct => total == 0 ? 0 : exact * 100 / total;
  double get wrongPct => total == 0 ? 0 : wrong * 100 / total;
  double get unfixedPct => total == 0 ? 0 : unfixed * 100 / total;
  double get precisionWhenApplied {
    final applied = exact + wrong;
    return applied == 0 ? 100.0 : exact * 100 / applied;
  }

  double get avgMs => total == 0 ? 0 : (totalMicroseconds / total) / 1000.0;
}

Future<List<File>> loadCorpusFiles(String? corpusPath) async {
  if (corpusPath != null) {
    final dir = Directory(corpusPath);
    if (!dir.existsSync()) {
      stderr.writeln('Directory not found: $corpusPath');
      exit(1);
    }
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  final cacheDir = Directory(p.join('.dart_tool', 'corpus_cache', pinnedFlutterCommit));
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }

  final files = <File>[];
  final client = HttpClient();
  try {
    for (final fileName in defaultMaterialFiles) {
      final cachedFile = File(p.join(cacheDir.path, fileName));
      if (!cachedFile.existsSync()) {
        final uri = Uri.parse(
          'https://raw.githubusercontent.com/flutter/flutter/$pinnedFlutterCommit/packages/flutter/lib/src/material/$fileName',
        );
        stdout.writeln('Downloading $fileName from flutter@$pinnedFlutterCommit...');
        final req = await client.getUrl(uri);
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw HttpException('Failed to download $uri (HTTP ${resp.statusCode})');
        }
        await resp.pipe(cachedFile.openWrite());
      }
      files.add(cachedFile);
    }
  } finally {
    client.close();
  }
  return files;
}

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'corpus',
      abbr: 'c',
      help: 'Optional path to a directory of .dart files to test against.\n'
          'If omitted, downloads 15 Flutter Material files pinned at $pinnedFlutterCommit.',
    )
    ..addOption(
      'samples-per-file',
      abbr: 'n',
      defaultsTo: '25',
      help: 'Max number of closing brackets to sample and mutate per file.',
    )
    ..addOption(
      'seed',
      abbr: 's',
      defaultsTo: '42',
      help: 'Random seed for reproducible sampling.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    );

  final argResults = parser.parse(args);
  if (argResults['help'] as bool) {
    stdout.writeln('Dart Bracket Recovery Benchmark\n');
    stdout.writeln(parser.usage);
    return;
  }

  final corpusPath = argResults['corpus'] as String?;
  final samplesPerFile = int.parse(argResults['samples-per-file'] as String);
  final seed = int.parse(argResults['seed'] as String);

  final files = await loadCorpusFiles(corpusPath);
  stdout.writeln('Loaded ${files.length} Dart files (seed=$seed, maxSamplesPerFile=$samplesPerFile).\n');

  // Warmup JIT
  parseString(content: 'void main() { print([1, 2, (3 + 4)]); }', throwIfDiagnostics: false);

  final mutationKinds = [
    'Missing )',
    'Missing ]',
    'Missing }',
    'Extra )',
    'Extra ]',
    'Extra }',
  ];

  final s1ByKind = {for (final k in mutationKinds) k: Stats()};
  final s2ByKind = {for (final k in mutationKinds) k: Stats()};
  final s3ByKind = {for (final k in mutationKinds) k: Stats()};

  final rng = Random(seed);

  for (final file in files) {
    final content = file.readAsStringSync();
    if (!isCleanParse(content)) continue;

    final origNorm = normalizeCode(content);
    final semanticIndex = SemanticIndex.fromCleanCode(content);
    final res = parseString(content: content, throwIfDiagnostics: false);

    final closers = <Token>[];
    Token? t = res.unit.beginToken;
    while (t != null && !t.isEof) {
      if (!t.isSynthetic &&
          (t.type == TokenType.CLOSE_PAREN ||
              t.type == TokenType.CLOSE_SQUARE_BRACKET ||
              t.type == TokenType.CLOSE_CURLY_BRACKET)) {
        closers.add(t);
      }
      t = t.next;
    }

    closers.shuffle(rng);
    for (final closer in closers.take(samplesPerFile)) {
      final ch = closer.lexeme;

      // 1. Missing bracket mutation (delete `closer`)
      final brokenMissing = content.replaceRange(closer.charOffset, closer.charEnd, '');
      if (!isCleanParse(brokenMissing)) {
        final kind = 'Missing $ch';
        _runAllStrategies(
          brokenMissing,
          origNorm,
          semanticIndex,
          s1ByKind[kind]!,
          s2ByKind[kind]!,
          s3ByKind[kind]!,
        );
      }

      // 2. Extra bracket mutation (duplicate `closer`)
      final brokenExtra = content.replaceRange(closer.charOffset, closer.charEnd, '$ch$ch');
      if (!isCleanParse(brokenExtra)) {
        final kind = 'Extra $ch';
        _runAllStrategies(
          brokenExtra,
          origNorm,
          semanticIndex,
          s1ByKind[kind]!,
          s2ByKind[kind]!,
          s3ByKind[kind]!,
        );
      }
    }
  }

  _printStrategyTable(
    'Strategy 1: Raw Syntactic Token-Stream + Re-parse Sandbox',
    s1ByKind,
  );
  _printStrategyTable(
    'Strategy 2: Guarded Syntactic Sandbox (Excludes `{}` & Ambiguous Nested Steals)',
    s2ByKind,
  );
  _printStrategyTable(
    'Strategy 3: Hybrid (Guarded Syntactic + Semantic Argument/Property Hints)',
    s3ByKind,
  );

  // Also run multi-bracket / paste scenarios using `fixStrategy3MultiPass`
  _runMultiBracketScenarios(files, seed);
}

void _runMultiBracketScenarios(List<File> files, int seed) {
  final rng = Random(seed);
  final scenarios = {
    'Contiguous Missing (2 adjacent `)`/`]`)': Stats(),
    'Contiguous Extra (2 adjacent `)`/`]`)': Stats(),
    'Mismatched Closer (`)` <-> `]`)': Stats(),
    'Two Independent Errors in File': Stats(),
  };

  for (final file in files) {
    final content = file.readAsStringSync();
    if (!isCleanParse(content)) continue;
    final origNorm = normalizeCode(content);
    final origNormNoTrailingComma =
        origNorm.replaceAll(',)', ')').replaceAll(',]', ']');
    final semanticIndex = SemanticIndex.fromCleanCode(content);
    final res = parseString(content: content, throwIfDiagnostics: false);

    final closers = <Token>[];
    Token? t = res.unit.beginToken;
    while (t != null && !t.isEof) {
      if (!t.isSynthetic &&
          (t.type == TokenType.CLOSE_PAREN ||
              t.type == TokenType.CLOSE_SQUARE_BRACKET)) {
        closers.add(t);
      }
      t = t.next;
    }

    final adjacentPairs = <(Token, Token)>[];
    for (int i = 0; i < closers.length - 1; i++) {
      final c1 = closers[i];
      final c2 = closers[i + 1];
      if (c1.next == c2 || (c1.next?.type == TokenType.COMMA && c1.next?.next == c2)) {
        adjacentPairs.add((c1, c2));
      }
    }

    adjacentPairs.shuffle(rng);
    for (final (c1, c2) in adjacentPairs.take(15)) {
      final brokenMissing2 = content.replaceRange(c1.charOffset, c2.charEnd, '');
      if (!isCleanParse(brokenMissing2)) {
        final sw = Stopwatch()..start();
        final fixed = fixStrategy3MultiPass(brokenMissing2, semanticIndex);
        sw.stop();
        final fixedNorm = fixed != null
            ? normalizeCode(fixed).replaceAll(',)', ')').replaceAll(',]', ']')
            : null;
        scenarios['Contiguous Missing (2 adjacent `)`/`]`)']!
            .record(fixedNorm, origNormNoTrailingComma, sw.elapsedMicroseconds);
      }

      final brokenExtra2 = content
          .replaceRange(c2.charOffset, c2.charEnd, '${c2.lexeme}${c2.lexeme}')
          .replaceRange(c1.charOffset, c1.charEnd, '${c1.lexeme}${c1.lexeme}');
      if (!isCleanParse(brokenExtra2)) {
        final sw = Stopwatch()..start();
        final fixed = fixStrategy3MultiPass(brokenExtra2, semanticIndex);
        sw.stop();
        scenarios['Contiguous Extra (2 adjacent `)`/`]`)']!
            .record(fixed, origNorm, sw.elapsedMicroseconds);
      }
    }

    closers.shuffle(rng);
    for (final c in closers.take(15)) {
      final wrongChar = c.type == TokenType.CLOSE_PAREN ? ']' : ')';
      final brokenMismatch = content.replaceRange(c.charOffset, c.charEnd, wrongChar);
      if (!isCleanParse(brokenMismatch)) {
        final sw = Stopwatch()..start();
        final fixed = fixStrategy3MultiPass(brokenMismatch, semanticIndex);
        sw.stop();
        scenarios['Mismatched Closer (`)` <-> `]`)']!
            .record(fixed, origNorm, sw.elapsedMicroseconds);
      }
    }

    for (int i = 0; i + 1 < closers.length && i < 20; i += 2) {
      final cA = closers[i];
      final cB = closers[i + 1];
      if ((cA.charOffset - cB.charOffset).abs() < 200) continue;
      final first = cA.charOffset < cB.charOffset ? cA : cB;
      final second = cA.charOffset < cB.charOffset ? cB : cA;
      final brokenIndep = content
          .replaceRange(second.charOffset, second.charEnd, '${second.lexeme}${second.lexeme}')
          .replaceRange(first.charOffset, first.charEnd, '');
      if (!isCleanParse(brokenIndep)) {
        final sw = Stopwatch()..start();
        final fixed = fixStrategy3MultiPass(brokenIndep, semanticIndex);
        sw.stop();
        scenarios['Two Independent Errors in File']!
            .record(fixed, origNorm, sw.elapsedMicroseconds);
      }
    }
  }

  stdout.writeln('### Multi-Bracket / Paste Scenarios (Strategy 3 Multi-Pass)\n');
  stdout.writeln(
    '| Scenario | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |',
  );
  stdout.writeln(
    '| :--- | :---: | :---: | :---: | :---: | :---: | :---: |',
  );
  for (final e in scenarios.entries) {
    final s = e.value;
    stdout.writeln(
      '| **${e.key}** | ${s.total} | ${s.exact} (${s.exactPct.toStringAsFixed(1)}%) | '
      '${s.wrong} (${s.wrongPct.toStringAsFixed(1)}%) | '
      '${s.unfixed} (${s.unfixedPct.toStringAsFixed(1)}%) | '
      '**${s.precisionWhenApplied.toStringAsFixed(1)}%** | '
      '${s.avgMs.toStringAsFixed(2)} ms |',
    );
  }
  stdout.writeln();
}

void _runAllStrategies(
  String brokenCode,
  String origNorm,
  SemanticIndex semanticIndex,
  Stats s1,
  Stats s2,
  Stats s3,
) {
  final sw1 = Stopwatch()..start();
  final fixed1 = fixStrategy1RawSyntactic(brokenCode);
  sw1.stop();
  s1.record(fixed1, origNorm, sw1.elapsedMicroseconds);

  final sw2 = Stopwatch()..start();
  final fixed2 = fixStrategy2GuardedSyntactic(brokenCode);
  sw2.stop();
  s2.record(fixed2, origNorm, sw2.elapsedMicroseconds);

  final sw3 = Stopwatch()..start();
  final fixed3 = fixStrategy3SemanticHybrid(brokenCode, semanticIndex);
  sw3.stop();
  s3.record(fixed3, origNorm, sw3.elapsedMicroseconds);
}

void _printStrategyTable(String title, Map<String, Stats> byKind) {
  stdout.writeln('### $title\n');
  stdout.writeln(
    '| Mutation Type | Total | Exact Fix | Wrong (Shifted) | Unfixed | Precision (When Applied) | Avg Time |',
  );
  stdout.writeln(
    '| :--- | :---: | :---: | :---: | :---: | :---: | :---: |',
  );

  final overallParensAndBrackets = Stats();
  for (final entry in byKind.entries) {
    final k = entry.key;
    final s = entry.value;
    if (s.total == 0) continue;
    if (!k.endsWith('}')) {
      overallParensAndBrackets.total += s.total;
      overallParensAndBrackets.exact += s.exact;
      overallParensAndBrackets.wrong += s.wrong;
      overallParensAndBrackets.unfixed += s.unfixed;
      overallParensAndBrackets.totalMicroseconds += s.totalMicroseconds;
    }
    stdout.writeln(
      '| **$k** | ${s.total} | ${s.exact} (${s.exactPct.toStringAsFixed(1)}%) | '
      '${s.wrong} (${s.wrongPct.toStringAsFixed(1)}%) | '
      '${s.unfixed} (${s.unfixedPct.toStringAsFixed(1)}%) | '
      '**${s.precisionWhenApplied.toStringAsFixed(1)}%** | '
      '${s.avgMs.toStringAsFixed(2)} ms |',
    );
  }
  final o = overallParensAndBrackets;
  stdout.writeln(
    '| **Total `()` / `[]`** | **${o.total}** | **${o.exact} (${o.exactPct.toStringAsFixed(1)}%)** | '
    '**${o.wrong} (${o.wrongPct.toStringAsFixed(1)}%)** | '
    '**${o.unfixed} (${o.unfixedPct.toStringAsFixed(1)}%)** | '
    '**${o.precisionWhenApplied.toStringAsFixed(1)}%** | '
    '**${o.avgMs.toStringAsFixed(2)} ms** |\n',
  );
}
