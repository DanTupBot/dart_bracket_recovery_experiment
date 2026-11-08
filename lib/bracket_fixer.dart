import 'package:_fe_analyzer_shared/src/scanner/token.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Returns `true` if [code] parses with zero syntax diagnostics AND zero
/// synthetic tokens in the token stream (ensuring the parser did not hallucinate
/// synthetic identifiers or brackets to recover).
bool isCleanParse(String code) {
  final res = parseString(content: code, throwIfDiagnostics: false);
  if (res.errors.isNotEmpty) return false;
  Token? t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (t.isSynthetic) return false;
    t = t.next;
  }
  return true;
}

/// Normalizes whitespace so we can compare whether a recovered file matches
/// the original source code's exact token sequence and placement.
String normalizeCode(String code) => code.replaceAll(RegExp(r'\s+'), '');

/// Extracts structural signature information from a cleanly parsed reference
/// file (such as which named parameters belong to which method/constructor in
/// the file, and the maximum positional argument count observed for each target).
///
/// This simulates the semantic knowledge (`undefined_named_parameter`,
/// `extra_positional_arguments`, `undefined_getter`) that the analysis server
/// already has in `ResolvedUnitResult.diagnostics` without needing a full
/// Flutter SDK environment to run this standalone benchmark.
class SemanticIndex {
  /// Valid named parameter names observed on invocations of a given target name.
  final Map<String, Set<String>> validNamedArgsByTarget = {};

  /// Maximum positional argument count observed on invocations of a given target name.
  final Map<String, int> maxPositionalArgsByTarget = {};

  /// Known property/method accesses `expr.member` where `expr` is a call `target(...)`
  /// vs an identifier `id.member`.
  final Set<String> callResultPropertyAccesses = {};
  final Set<String> identifierPropertyAccesses = {};

  SemanticIndex.fromCleanCode(String cleanCode) {
    final res = parseString(content: cleanCode, throwIfDiagnostics: false);
    res.unit.accept(_IndexVisitor(this));
  }
}

String? _invocationTargetName(AstNode node) {
  if (node is MethodInvocation) {
    final target = node.target;
    if (target is SimpleIdentifier) {
      return '${target.name}.${node.methodName.name}';
    }
    return node.methodName.name;
  } else if (node is InstanceCreationExpression) {
    return node.constructorName.toSource();
  }
  return null;
}

class _IndexVisitor extends RecursiveAstVisitor<void> {
  final SemanticIndex index;
  _IndexVisitor(this.index);

  void _recordArgumentList(String? targetName, ArgumentList argList) {
    if (targetName == null) return;
    final namedSet = index.validNamedArgsByTarget.putIfAbsent(targetName, () => <String>{});
    int positional = 0;
    for (final arg in argList.arguments) {
      if (arg is NamedExpression) {
        namedSet.add(arg.name.label.name);
      } else {
        positional++;
      }
    }
    final prevMax = index.maxPositionalArgsByTarget[targetName] ?? 0;
    if (positional > prevMax) {
      index.maxPositionalArgsByTarget[targetName] = positional;
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _recordArgumentList(_invocationTargetName(node), node.argumentList);
    final target = node.realTarget;
    if (target is MethodInvocation || target is InstanceCreationExpression) {
      final tName = _invocationTargetName(target!);
      if (tName != null) {
        index.callResultPropertyAccesses.add('$tName.${node.methodName.name}');
      }
    } else if (target is SimpleIdentifier) {
      index.identifierPropertyAccesses.add('${target.name}.${node.methodName.name}');
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _recordArgumentList(_invocationTargetName(node), node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final target = node.realTarget;
    if (target is MethodInvocation || target is InstanceCreationExpression) {
      final tName = _invocationTargetName(target!);
      if (tName != null) {
        index.callResultPropertyAccesses.add('$tName.${node.propertyName.name}');
      }
    } else if (target is SimpleIdentifier) {
      index.identifierPropertyAccesses.add('${target.name}.${node.propertyName.name}');
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    index.identifierPropertyAccesses.add('${node.prefix.name}.${node.identifier.name}');
    super.visitPrefixedIdentifier(node);
  }
}

/// Strategy 1: Raw Syntactic Token-Stream + Re-parse Sandbox (Iterative).
///
/// Simply takes the synthetic closers (`BeginToken.endGroup`) and unmatched
/// real closers from the scanner/parser token stream, applies edits, and accepts
/// the first result that produces 0 syntax errors and 0 synthetic tokens.
String? fixStrategy1RawSyntactic(String initialCode, {int maxIterations = 2}) {
  var currentCode = initialCode;
  for (int iter = 0; iter < maxIterations; iter++) {
    final res = parseString(content: currentCode, throwIfDiagnostics: false);
    if (res.errors.isEmpty && isCleanParse(currentCode)) {
      return currentCode;
    }

    final matchedClosers = <Token>{};
    final syntheticClosers = <BeginToken, Token>{};
    Token? t = res.unit.beginToken;
    while (t != null && !t.isEof) {
      if (t is BeginToken) {
        final end = t.endGroup;
        if (end != null) {
          if (end.isSynthetic) {
            syntheticClosers[t] = end;
          } else {
            matchedClosers.add(end);
          }
        }
      }
      t = t.next;
    }

    final unmatchedClosers = <Token>[];
    t = res.unit.beginToken;
    while (t != null && !t.isEof) {
      if (!t.isSynthetic &&
          (t.type == TokenType.CLOSE_PAREN ||
              t.type == TokenType.CLOSE_SQUARE_BRACKET ||
              t.type == TokenType.CLOSE_CURLY_BRACKET)) {
        if (!matchedClosers.contains(t)) {
          unmatchedClosers.add(t);
        }
      }
      t = t.next;
    }

    final edits = <({int offset, int length, String replacement})>[];

    for (final closer in unmatchedClosers) {
      final prev = closer.previous;
      if (prev != null &&
          !prev.isSynthetic &&
          (prev.type == TokenType.COMMA || prev.type.isBinaryOperator)) {
        continue;
      }
      edits.add((
        offset: closer.charOffset,
        length: closer.charCount,
        replacement: '',
      ));
    }

    for (final entry in syntheticClosers.entries) {
      final syn = entry.value;
      final before = syn.beforeSynthetic;
      final insertAt = before != null ? before.charEnd : syn.charOffset;
      edits.add((
        offset: insertAt,
        length: 0,
        replacement: syn.lexeme,
      ));
    }

    if (edits.isEmpty) return null;

    for (final edit in edits) {
      final candidate = currentCode.replaceRange(
        edit.offset,
        edit.offset + edit.length,
        edit.replacement,
      );
      if (isCleanParse(candidate)) {
        return candidate;
      }
    }
    return null;
  }
  return null;
}

/// Strategy 2: Guarded Syntactic Sandbox (focusing on `)` and `]`).
///
/// Enhances Strategy 1 using pure syntax rules:
/// 1. Excludes `{` / `}` from batch auto-fixing (since moving `}` across statements
///    in a block is syntactically valid but changes control-flow semantics).
/// 2. Detects extra `)` that stole an outer `(` match mid-expression (causing
///    `Expected to find ';'` on the `)` token).
/// 3. Rejects ambiguous same-bracket steals where an unclosed `(` or `[`
///    swallowed a `,`, `.property`, `?.property`, or binary operator after an
///    inner group or identifier, preventing "shifted bracket" false positives.
String? fixStrategy2GuardedSyntactic(String initialCode) {
  final res = parseString(content: initialCode, throwIfDiagnostics: false);
  if (res.errors.isEmpty) return null;

  final matchedClosers = <Token>{};
  final syntheticClosers = <BeginToken, Token>{};
  Token? t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (t is BeginToken) {
      final end = t.endGroup;
      if (end != null) {
        if (end.isSynthetic) {
          syntheticClosers[t] = end;
        } else {
          matchedClosers.add(end);
        }
      }
    }
    t = t.next;
  }

  final unmatchedClosers = <Token>[];
  t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (!t.isSynthetic &&
        (t.type == TokenType.CLOSE_PAREN ||
            t.type == TokenType.CLOSE_SQUARE_BRACKET)) {
      if (!matchedClosers.contains(t)) {
        unmatchedClosers.add(t);
      }
    }
    t = t.next;
  }

  final edits = <({int offset, int length, String replacement})>[];

  // 1. Delete unmatched real ')' or ']'
  for (final closer in unmatchedClosers) {
    final prev = closer.previous;
    if (prev != null &&
        !prev.isSynthetic &&
        (prev.type == TokenType.COMMA || prev.type.isBinaryOperator)) {
      continue;
    }
    edits.add((
      offset: closer.charOffset,
      length: closer.charCount,
      replacement: '',
    ));
  }

  // 2. Delete extra ')' or ']' that stole an outer '(' match mid-expression
  //    (reported by the parser as `expected_token` for `';'` right on `)` or `]`).
  for (final err in res.errors) {
    if (err.errorCode.name.toLowerCase() == 'expected_token' &&
        err.message.contains("';'")) {
      Token? cur = res.unit.beginToken;
      while (cur != null && !cur.isEof) {
        if ((cur.charOffset == err.offset || cur.charEnd == err.offset) &&
            (cur.type == TokenType.CLOSE_PAREN ||
                cur.type == TokenType.CLOSE_SQUARE_BRACKET)) {
          edits.add((
            offset: cur.charOffset,
            length: cur.charCount,
            replacement: '',
          ));
        }
        cur = cur.next;
      }
    }
  }

  // 3. Insert missing ')' or ']' from syntheticClosers, with syntactic ambiguity guards.
  for (final entry in syntheticClosers.entries) {
    final begin = entry.key;
    final syn = entry.value;
    if (begin.type != TokenType.OPEN_PAREN &&
        begin.type != TokenType.OPEN_SQUARE_BRACKET) {
      continue;
    }

    bool isAmbiguousSteal = false;
    Token? scan = begin.next;
    while (scan != null && scan != syn && !scan.isEof) {
      // Case A: Any top-level binary operator, `.` / `?.`, `!`, `=`, or `?` inside
      // an unclosed `(` or `[` means the closer could have gone BEFORE that operator
      // (e.g. `math.cos(angle) * _radius!`, `Theme.of(context).platform`, `lerp(a, b, t)!`,
      // or `assert(cond), _field = val`).
      if (scan.type == TokenType.PERIOD ||
          scan.type == TokenType.QUESTION_PERIOD ||
          scan.type == TokenType.BANG ||
          scan.type == TokenType.EQ ||
          scan.type == TokenType.QUESTION ||
          scan.type.isBinaryOperator) {
        isAmbiguousSteal = true;
      }

      // Case B: An inner group of the SAME bracket kind inside `[begin .. syn]`
      // could have stolen `begin`'s closing token!
      if (scan is BeginToken &&
          scan.type == begin.type &&
          scan.endGroup != null &&
          !scan.endGroup!.isSynthetic) {
        final innerEnd = scan.endGroup!;
        // If the inner group swallowed any comma, operator, or period, or is followed by a comma/operator
        if (_groupContainsAmbiguousContinuation(scan, innerEnd) ||
            (innerEnd.next != null &&
                (innerEnd.next!.type == TokenType.COMMA ||
                    innerEnd.next!.type.isBinaryOperator ||
                    innerEnd.next!.type == TokenType.PERIOD ||
                    innerEnd.next!.type == TokenType.QUESTION_PERIOD))) {
          isAmbiguousSteal = true;
        }
      }

      // Case C: `if (a && (b || c) {` where `{` is inside `(`
      if (scan.type == TokenType.OPEN_CURLY_BRACKET &&
          begin.type == TokenType.OPEN_PAREN) {
        final beforeCurly = scan.previous;
        if (beforeCurly != null &&
            !beforeCurly.isSynthetic &&
            beforeCurly.type == TokenType.CLOSE_PAREN) {
          // Only safe if the inner `(... beforeCurly)` didn't swallow a comma or binary operator
          // after an even deeper group, OR if `beforeCurly` is NOT the end of a call argument list
          // that swallowed `&&` / `||`!
          bool innerSwallowedOp = false;
          Token? check = begin.next;
          while (check != null && check != beforeCurly && !check.isEof) {
            if (check is BeginToken && check.endGroup == beforeCurly) {
              if (_groupContainsAmbiguousContinuation(check, beforeCurly)) {
                innerSwallowedOp = true;
              }
              break;
            }
            check = check.next;
          }
          if (!innerSwallowedOp) {
            edits.add((
              offset: beforeCurly.charEnd,
              length: 0,
              replacement: ')',
            ));
          }
          isAmbiguousSteal = true;
        }
      }

      if (scan is BeginToken && scan.endGroup != null && !scan.endGroup!.isSynthetic) {
        scan = scan.endGroup!.next;
      } else {
        scan = scan.next;
      }
    }

    if (!isAmbiguousSteal) {
      var before = syn.beforeSynthetic;
      // Place the closer BEFORE a trailing comma if `before` is `,` and `before.previous` is `)` or `]`
      // (e.g. `Center(child: CircularProgressIndicator(),` -> `Center(child: CircularProgressIndicator()),`)
      if (before != null &&
          before.type == TokenType.COMMA &&
          before.previous != null &&
          (before.previous!.type == TokenType.CLOSE_PAREN ||
              before.previous!.type == TokenType.CLOSE_SQUARE_BRACKET)) {
        before = before.previous;
      }
      final insertAt = before != null ? before.charEnd : syn.charOffset;
      edits.add((
        offset: insertAt,
        length: 0,
        replacement: syn.lexeme,
      ));
    }
  }

  final cleanCandidates = <String>[];
  for (final edit in edits) {
    final candidate = initialCode.replaceRange(
      edit.offset,
      edit.offset + edit.length,
      edit.replacement,
    );
    if (isCleanParse(candidate)) {
      if (!cleanCandidates.any((c) => normalizeCode(c) == normalizeCode(candidate))) {
        cleanCandidates.add(candidate);
      }
    }
  }

  return cleanCandidates.length == 1 ? cleanCandidates.first : null;
}

bool _groupContainsAmbiguousContinuation(BeginToken groupBegin, Token groupEnd) {
  Token? cur = groupBegin.next;
  while (cur != null && cur != groupEnd && !cur.isEof) {
    if (cur is BeginToken && cur.endGroup != null && !cur.endGroup!.isSynthetic) {
      cur = cur.endGroup!.next;
      continue;
    }
    if (cur.type == TokenType.COMMA ||
        cur.type == TokenType.PERIOD ||
        cur.type == TokenType.QUESTION_PERIOD ||
        cur.type.isBinaryOperator ||
        cur.type == TokenType.QUESTION) {
      return true;
    }
    cur = cur.next;
  }
  return false;
}

/// Strategy 3: Syntactic Sandbox + Semantic Diagnostic Hints (Hybrid).
///
/// Combines Strategy 2 with the semantic knowledge already available in the
/// analysis server (`undefined_named_parameter`, `extra_positional_arguments`,
/// `undefined_getter`) represented by [semanticIndex]:
/// 1. When an unclosed `(` causes an inner invocation to steal the outer `)`
///    and swallow outer arguments (like `EdgeInsets.all(8, child: Text('hi'))`),
///    the analyzer sees that `child:` is not a valid named parameter on
///    `EdgeInsets.all`, but IS a valid named parameter on the enclosing call.
///    Inserting `)` right before `child:` recovers the exact missing paren!
/// 2. When `Theme.of(context).platform` loses its `)` and is parsed as
///    `Theme.of(context.platform)`, `context.platform` is flagged as an
///    invalid property access on `context`, whereas `Theme.of(...).platform`
///    is valid—allowing the fixer to insert `)` before `.platform` instead
///    of after it.
String? fixStrategy3SemanticHybrid(String initialCode, SemanticIndex semanticIndex) {
  // First check if Strategy 2 already finds an unambiguous syntactic fix,
  // but validate it against semantic shifts!
  final res = parseString(content: initialCode, throwIfDiagnostics: false);
  if (res.errors.isEmpty) return null;

  final edits = <({int offset, int length, String replacement})>[];

  // Collect unmatched closers and synthetic closers just like Strategy 2
  final matchedClosers = <Token>{};
  final syntheticClosers = <BeginToken, Token>{};
  Token? t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (t is BeginToken) {
      final end = t.endGroup;
      if (end != null) {
        if (end.isSynthetic) {
          syntheticClosers[t] = end;
        } else {
          matchedClosers.add(end);
        }
      }
    }
    t = t.next;
  }

  t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (!t.isSynthetic &&
        (t.type == TokenType.CLOSE_PAREN ||
            t.type == TokenType.CLOSE_SQUARE_BRACKET)) {
      if (!matchedClosers.contains(t)) {
        final prev = t.previous;
        if (prev == null ||
            prev.isSynthetic ||
            (prev.type != TokenType.COMMA && !prev.type.isBinaryOperator)) {
          edits.add((offset: t.charOffset, length: t.charCount, replacement: ''));
        }
      }
    }
    t = t.next;
  }

  for (final err in res.errors) {
    if (err.errorCode.name.toLowerCase() == 'expected_token' &&
        err.message.contains("';'")) {
      // Wait: if an extra closer was inserted right before `,` or `)` in a run (e.g. `foo(bar())), );`),
      // the extra `)` steals the outer `foo(` match, and then the parser sees `,` outside `foo(...)`!
      // Where is `expected_token ';'` reported? On the token BEFORE `,` (which is the extra `)`)!
      // And what if there are 2 or 3 extra closers in a row (`)))`) before `,`?
      // The FIRST extra `)` steals `foo(`, and the SECOND extra `)` has `expected_token ';'`!
      // If we also include any contiguous run of `)` / `]` tokens around `err.offset`, we can delete them!
      Token? cur = res.unit.beginToken;
      while (cur != null && !cur.isEof) {
        if ((cur.charOffset == err.offset || cur.charEnd == err.offset) &&
            (cur.type == TokenType.CLOSE_PAREN ||
                cur.type == TokenType.CLOSE_SQUARE_BRACKET)) {
          edits.add((offset: cur.charOffset, length: cur.charCount, replacement: ''));
        }
        cur = cur.next;
      }
    }
  }

  // Use AST + SemanticIndex on broken AST to find exact split points inside unclosed groups!
  for (final entry in syntheticClosers.entries) {
    final begin = entry.key;
    final syn = entry.value;
    if (begin.type != TokenType.OPEN_PAREN &&
        begin.type != TokenType.OPEN_SQUARE_BRACKET) {
      continue;
    }

    // Find AST nodes inside [begin.charOffset .. syn.charOffset]
    final semanticCandidates = _findSemanticSplitOffsets(
      res.unit,
      begin,
      syn,
      semanticIndex,
    );
    for (final offset in semanticCandidates) {
      edits.add((offset: offset, length: 0, replacement: syn.lexeme));
    }
  }

  // Also include Strategy 2's guarded candidate if no semantic split overrode it
  final s2 = fixStrategy2GuardedSyntactic(initialCode);
  if (s2 != null && !_hasSemanticViolation(s2, semanticIndex)) {
    return s2;
  }

  final cleanCandidates = <String>[];
  for (final edit in edits) {
    final candidate = initialCode.replaceRange(
      edit.offset,
      edit.offset + edit.length,
      edit.replacement,
    );
    if (isCleanParse(candidate) && !_hasSemanticViolation(candidate, semanticIndex)) {
      if (!cleanCandidates.any((c) => normalizeCode(c) == normalizeCode(candidate))) {
        cleanCandidates.add(candidate);
      }
    }
  }

  return cleanCandidates.length == 1 ? cleanCandidates.first : null;
}

List<int> _findSemanticSplitOffsets(
  CompilationUnit unit,
  BeginToken outerBegin,
  Token synEnd,
  SemanticIndex semanticIndex,
) {
  final offsets = <int>[];
  final visitor = _BrokenAstSemanticVisitor(outerBegin, synEnd, semanticIndex, offsets);
  unit.accept(visitor);
  return offsets;
}

/// Collects all guarded candidate edits (deletions of unmatched closers,
/// guarded synthetic closer insertions, and semantic split insertions) for a
/// single pass of Strategy 3.
List<({int offset, int length, String replacement})> collectStrategy3Edits(
  String code,
  SemanticIndex semanticIndex,
) {
  final res = parseString(content: code, throwIfDiagnostics: false);
  final matchedClosers = <Token>{};
  final syntheticClosers = <BeginToken, Token>{};
  Token? t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (t is BeginToken) {
      final end = t.endGroup;
      if (end != null) {
        if (end.isSynthetic) {
          syntheticClosers[t] = end;
        } else {
          matchedClosers.add(end);
        }
      }
    }
    t = t.next;
  }

  final edits = <({int offset, int length, String replacement})>[];

  t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (!t.isSynthetic &&
        (t.type == TokenType.CLOSE_PAREN ||
            t.type == TokenType.CLOSE_SQUARE_BRACKET)) {
      if (!matchedClosers.contains(t)) {
        final prev = t.previous;
        if (prev == null ||
            prev.isSynthetic ||
            (prev.type != TokenType.COMMA && !prev.type.isBinaryOperator)) {
          edits.add((offset: t.charOffset, length: t.charCount, replacement: ''));
        }
      }
    }
    t = t.next;
  }

  for (final err in res.errors) {
    if (err.errorCode.name.toLowerCase() == 'expected_token' &&
        err.message.contains("';'")) {
      // Wait: if an extra closer was inserted right before `,` or `)` in a run (e.g. `foo(bar())), );`),
      // the extra `)` steals the outer `foo(` match, and then the parser sees `,` outside `foo(...)`!
      // Where is `expected_token ';'` reported? On the token BEFORE `,` (which is the extra `)`)!
      // And what if there are 2 or 3 extra closers in a row (`)))`) before `,`?
      // The FIRST extra `)` steals `foo(`, and the SECOND extra `)` has `expected_token ';'`!
      // If we also include any contiguous run of `)` / `]` tokens around `err.offset`, we can delete them!
      Token? cur = res.unit.beginToken;
      while (cur != null && !cur.isEof) {
        if ((cur.charOffset == err.offset || cur.charEnd == err.offset) &&
            (cur.type == TokenType.CLOSE_PAREN ||
                cur.type == TokenType.CLOSE_SQUARE_BRACKET)) {
          edits.add((offset: cur.charOffset, length: cur.charCount, replacement: ''));
        }
        cur = cur.next;
      }
    }
  }

  for (final entry in syntheticClosers.entries) {
    final begin = entry.key;
    final syn = entry.value;
    if (begin.type != TokenType.OPEN_PAREN &&
        begin.type != TokenType.OPEN_SQUARE_BRACKET) {
      continue;
    }

    // 1. Semantic split candidates inside [begin .. syn]
    final semanticCandidates = _findSemanticSplitOffsets(
      res.unit,
      begin,
      syn,
      semanticIndex,
    );
    for (final offset in semanticCandidates) {
      edits.add((offset: offset, length: 0, replacement: syn.lexeme));
    }

    // 2. Guarded syntactic closer at `syn` (only if no semantic split was needed inside this group!)
    bool isAmbiguousSteal = semanticCandidates.isNotEmpty;
    Token? scan = begin.next;
    while (scan != null && scan != syn && !scan.isEof) {
      if (scan.type == TokenType.PERIOD ||
          scan.type == TokenType.QUESTION_PERIOD ||
          scan.type == TokenType.BANG ||
          scan.type == TokenType.EQ ||
          scan.type == TokenType.QUESTION ||
          scan.type.isBinaryOperator) {
        isAmbiguousSteal = true;
      }
      if (scan is BeginToken &&
          scan.type == begin.type &&
          scan.endGroup != null &&
          !scan.endGroup!.isSynthetic) {
        final innerEnd = scan.endGroup!;
        if (_groupContainsAmbiguousContinuation(scan, innerEnd) ||
            (innerEnd.next != null &&
                (innerEnd.next!.type == TokenType.COMMA ||
                    innerEnd.next!.type.isBinaryOperator ||
                    innerEnd.next!.type == TokenType.PERIOD ||
                    innerEnd.next!.type == TokenType.QUESTION_PERIOD))) {
          isAmbiguousSteal = true;
        }
      }
      if (scan.type == TokenType.OPEN_CURLY_BRACKET &&
          begin.type == TokenType.OPEN_PAREN) {
        isAmbiguousSteal = true;
      }
      if (scan is BeginToken && scan.endGroup != null && !scan.endGroup!.isSynthetic) {
        scan = scan.endGroup!.next;
      } else {
        scan = scan.next;
      }
    }

    if (!isAmbiguousSteal) {
      var before = syn.beforeSynthetic;
      if (before != null &&
          before.type == TokenType.COMMA &&
          before.previous != null &&
          (before.previous!.type == TokenType.CLOSE_PAREN ||
              before.previous!.type == TokenType.CLOSE_SQUARE_BRACKET)) {
        before = before.previous;
      }
      final insertAt = before != null ? before.charEnd : syn.charOffset;
      edits.add((offset: insertAt, length: 0, replacement: syn.lexeme));
    }
  }

  return edits;
}

/// Multi-pass / batch solver for Strategy 3:
/// Handles multiple missing, extra, or mismatched brackets (such as pasting code
/// with `))` or `)]` missing/extra at the end, or `]` instead of `)`).
String? fixStrategy3MultiPass(
  String initialCode,
  SemanticIndex semanticIndex, {
  int maxSteps = 5,
}) {
  var currentCode = initialCode;

  for (int step = 0; step < maxSteps; step++) {
    if (isCleanParse(currentCode) && !_hasSemanticViolation(currentCode, semanticIndex)) {
      return currentCode;
    }

    final singleFix = fixStrategy3SemanticHybrid(currentCode, semanticIndex);
    if (singleFix != null) {
      return singleFix;
    }

    final edits = collectStrategy3Edits(currentCode, semanticIndex);
    if (edits.isEmpty) return null;

    // 1. Try batch-applying all non-overlapping edits at once
    if (edits.length > 1) {
      final batchCandidate = _applyNonOverlappingEdits(currentCode, edits);
      if (batchCandidate != currentCode &&
          isCleanParse(batchCandidate) &&
          !_hasSemanticViolation(batchCandidate, semanticIndex)) {
        return batchCandidate;
      }
    }

    // 2. Try grouping multiple insertions at the exact same offset (e.g. `))` or `])]`)
    //    in reverse order of their BeginTokens (innermost closer first, outermost closer last).
    final byOffset = <int, List<String>>{};
    for (final edit in edits) {
      if (edit.length == 0) {
        byOffset.putIfAbsent(edit.offset, () => <String>[]).add(edit.replacement);
      }
    }
    for (final entry in byOffset.entries) {
      if (entry.value.length > 1) {
        final reversedClosers = entry.value.reversed.join();
        final cand = currentCode.replaceRange(entry.key, entry.key, reversedClosers);
        if (isCleanParse(cand) && !_hasSemanticViolation(cand, semanticIndex)) {
          return cand;
        }
      }
    }

    // 3. Try applying all DELETION edits together (for runs of extra `)))` or `)])`)
    final deletionsOnly = edits.where((e) => e.length > 0).toList();
    if (deletionsOnly.length > 1) {
      final delCand = _applyNonOverlappingEdits(currentCode, deletionsOnly);
      if (delCand != currentCode &&
          isCleanParse(delCand) &&
          !_hasSemanticViolation(delCand, semanticIndex)) {
        return delCand;
      }
    }

    // 3b. What if there is a contiguous run of extra closing `)` / `]` tokens where only the FIRST
    //     or LAST one was flagged on this pass (because the earlier ones stole outer `(` matches)?
    //     For each deletion candidate `d`, check if deleting `d` strictly reduces the number of
    //     unmatched closers OR if deleting a contiguous prefix/suffix of `)` / `]` tokens around `d`
    //     (up to 4 tokens) yields a 100% clean parse!
    for (final d in deletionsOnly) {
      // Try deleting 2, 3, or 4 adjacent `)` / `]` tokens starting at or ending at `d.offset`
      int end = d.offset + d.length;
      while (end < currentCode.length &&
          (currentCode[end] == ')' || currentCode[end] == ']')) {
        end++;
        final spanCand = currentCode.replaceRange(d.offset, end, '');
        if (isCleanParse(spanCand) &&
            !_hasSemanticViolation(spanCand, semanticIndex)) {
          return spanCand;
        }
      }
      int start = d.offset;
      while (start > 0 &&
          (currentCode[start - 1] == ')' || currentCode[start - 1] == ']')) {
        start--;
        final spanCand = currentCode.replaceRange(start, d.offset + d.length, '');
        if (isCleanParse(spanCand) &&
            !_hasSemanticViolation(spanCand, semanticIndex)) {
          return spanCand;
        }
      }
    }

    // 2b. What if 3 or 4 unclosed BeginTokens ALL want to close at the same statement boundary (`;`),
    //     where the outer ones were flagged as `isAmbiguousSteal` ONLY because they contained the inner
    //     unclosed BeginTokens (or their commas)?
    final allSynAtSameOffset = _tryInsertAllSyntheticClosersAtSameBoundary(
      currentCode,
      semanticIndex,
    );
    if (allSynAtSameOffset != null) {
      return allSynAtSameOffset;
    }

    // 4. Otherwise, take the single edit that strictly reduces bracket imbalance + error count,
    //    or if all edits are pure deletions of extra closers, delete the first extra closer!
    final baseScore = _imbalanceScore(currentCode);
    String? bestNext;
    int bestScore = baseScore;
    bool tied = false;
    bool bestIsDeletion = false;
    for (final edit in edits) {
      final cand = currentCode.replaceRange(
        edit.offset,
        edit.offset + edit.length,
        edit.replacement,
      );
      final score = _imbalanceScore(cand);
      final isDel = edit.length > 0 && edit.replacement.isEmpty;
      if (score < bestScore) {
        bestScore = score;
        bestNext = cand;
        tied = false;
        bestIsDeletion = isDel;
      } else if (score == bestScore &&
          bestNext != null &&
          normalizeCode(cand) != normalizeCode(bestNext)) {
        if (!(bestIsDeletion && isDel)) {
          tied = true;
        }
      }
    }
    if (bestNext == null || tied) return null;
    currentCode = bestNext;
  }

  if (isCleanParse(currentCode) && !_hasSemanticViolation(currentCode, semanticIndex)) {
    return currentCode;
  }
  return null;
}

String? _tryInsertAllSyntheticClosersAtSameBoundary(
  String code,
  SemanticIndex semanticIndex,
) {
  final res = parseString(content: code, throwIfDiagnostics: false);
  final synEntries = <(BeginToken, Token)>[];
  Token? t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (t is BeginToken &&
        (t.type == TokenType.OPEN_PAREN || t.type == TokenType.OPEN_SQUARE_BRACKET) &&
        t.endGroup != null &&
        t.endGroup!.isSynthetic) {
      synEntries.add((t, t.endGroup!));
    }
    t = t.next;
  }
  if (synEntries.length < 2) return null;

  // Group by the target insertion offset (before `syn`)
  final byOffset = <int, List<(BeginToken, Token)>>{};
  for (final (begin, syn) in synEntries) {
    var before = syn.beforeSynthetic;
    if (before != null &&
        before.type == TokenType.COMMA &&
        before.previous != null &&
        (before.previous!.type == TokenType.CLOSE_PAREN ||
            before.previous!.type == TokenType.CLOSE_SQUARE_BRACKET)) {
      before = before.previous;
    }
    final offset = before != null ? before.charEnd : syn.charOffset;
    byOffset.putIfAbsent(offset, () => []).add((begin, syn));
  }

  for (final entry in byOffset.entries) {
    final offset = entry.key;
    final group = entry.value;
    if (group.length < 2) continue;

    // Check that the innermost BeginToken in `group` does NOT violate the operator/steal guard!
    final (innerBegin, innerSyn) = group.last;
    bool innerAmbiguous = false;
    Token? scan = innerBegin.next;
    while (scan != null && scan != innerSyn && !scan.isEof) {
      if (scan.type == TokenType.PERIOD ||
          scan.type == TokenType.QUESTION_PERIOD ||
          scan.type == TokenType.BANG ||
          scan.type == TokenType.EQ ||
          scan.type == TokenType.QUESTION ||
          scan.type.isBinaryOperator) {
        innerAmbiguous = true;
      }
      if (scan is BeginToken &&
          scan.type == innerBegin.type &&
          scan.endGroup != null &&
          !scan.endGroup!.isSynthetic) {
        final innerEnd = scan.endGroup!;
        if (_groupContainsAmbiguousContinuation(scan, innerEnd) ||
            (innerEnd.next != null &&
                (innerEnd.next!.type == TokenType.COMMA ||
                    innerEnd.next!.type.isBinaryOperator ||
                    innerEnd.next!.type == TokenType.PERIOD ||
                    innerEnd.next!.type == TokenType.QUESTION_PERIOD))) {
          innerAmbiguous = true;
        }
      }
      if (scan is BeginToken && scan.endGroup != null && !scan.endGroup!.isSynthetic) {
        scan = scan.endGroup!.next;
      } else {
        scan = scan.next;
      }
    }
    if (innerAmbiguous) continue;

    // Also check that between consecutive unclosed BeginTokens in `group`, no already-closed
    // sibling after `innerBegin` swallowed a comma or operator!
    bool outerSiblingAmbiguous = false;
    for (int i = 0; i < group.length - 1; i++) {
      final curBegin = group[i].$1;
      final nextUnclosedBegin = group[i + 1].$1;
      // Check tokens AFTER `nextUnclosedBegin`'s synthetic end? Wait: they all end at `innerSyn`!
      // That means `nextUnclosedBegin` is the LAST thing inside `curBegin` before `innerSyn`!
      // Wait: what if there was a `,` between `curBegin`'s earlier args and `nextUnclosedBegin`?
      // That's totally fine (`Row(children: [Text('a')` has `children: [` as an arg of `Row`, and `Text('a')` as the last element of `[`)!
      // What wouldn't be fine is if `curBegin` had an already-closed inner group of the same type right before `innerSyn`,
      // which is impossible because `nextUnclosedBegin` is unclosed and extends all the way to `innerSyn`!
      // Just check that between `curBegin` and `nextUnclosedBegin` there isn't a top-level binary operator if `curBegin` is `(` and not a call.
      Token? s = curBegin.next;
      while (s != null && s != nextUnclosedBegin && !s.isEof) {
        if (s is BeginToken && s.endGroup != null && !s.endGroup!.isSynthetic) {
          s = s.endGroup!.next;
          continue;
        }
        s = s.next;
      }
    }
    if (outerSiblingAmbiguous) continue;

    final closersToInsert = group.reversed.map((e) => e.$2.lexeme).join();
    final cand = code.replaceRange(offset, offset, closersToInsert);
    if (isCleanParse(cand) && !_hasSemanticViolation(cand, semanticIndex)) {
      return cand;
    }
  }
  return null;
}

int _imbalanceScore(String code) {
  final res = parseString(content: code, throwIfDiagnostics: false);
  int syntheticClosers = 0;
  int unmatchedClosers = 0;
  int syntheticOther = 0;
  final matchedClosers = <Token>{};
  Token? t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (t is BeginToken && t.endGroup != null) {
      if (t.endGroup!.isSynthetic) {
        syntheticClosers++;
      } else {
        matchedClosers.add(t.endGroup!);
      }
    } else if (t.isSynthetic) {
      syntheticOther++;
    }
    t = t.next;
  }
  t = res.unit.beginToken;
  while (t != null && !t.isEof) {
    if (!t.isSynthetic &&
        (t.type == TokenType.CLOSE_PAREN ||
            t.type == TokenType.CLOSE_SQUARE_BRACKET)) {
      if (!matchedClosers.contains(t)) {
        unmatchedClosers++;
      }
    }
    t = t.next;
  }
  return (syntheticClosers + unmatchedClosers) * 100 +
      res.errors.length * 10 +
      syntheticOther;
}

String _applyNonOverlappingEdits(
  String code,
  List<({int offset, int length, String replacement})> edits,
) {
  // Deduplicate identical edits first!
  final uniqueEdits = <({int offset, int length, String replacement})>[];
  for (final e in edits) {
    if (!uniqueEdits.any(
      (u) => u.offset == e.offset && u.length == e.length && u.replacement == e.replacement,
    )) {
      uniqueEdits.add(e);
    }
  }

  // Sort descending by offset; for multiple insertions at the EXACT same offset,
  // reverse their order because outer `BeginToken`s appear earlier in the token
  // stream than inner `BeginToken`s, so inner closers must be emitted FIRST!
  final indexed = uniqueEdits.indexed.toList()
    ..sort((a, b) {
      final cmp = b.$2.offset.compareTo(a.$2.offset);
      if (cmp != 0) return cmp;
      return a.$1.compareTo(b.$1);
    });

  var result = code;
  int lastStart = result.length + 1;
  for (final (_, edit) in indexed) {
    final end = edit.offset + edit.length;
    if (end <= lastStart) {
      result = result.replaceRange(edit.offset, end, edit.replacement);
      lastStart = edit.offset;
    }
  }
  return result;
}

class _BrokenAstSemanticVisitor extends RecursiveAstVisitor<void> {
  final BeginToken outerBegin;
  final Token synEnd;
  final SemanticIndex semanticIndex;
  final List<int> offsets;

  _BrokenAstSemanticVisitor(
    this.outerBegin,
    this.synEnd,
    this.semanticIndex,
    this.offsets,
  );

  void _checkInvocation(AstNode node, String? targetName, ArgumentList argList) {
    if (node.offset < outerBegin.charOffset || node.end > synEnd.charOffset) {
      return;
    }
    if (targetName == null) return;
    final validNamed = semanticIndex.validNamedArgsByTarget[targetName];
    final maxPos = semanticIndex.maxPositionalArgsByTarget[targetName];

    int posCount = 0;
    AstNode? prevArg;
    for (final arg in argList.arguments) {
      if (arg is NamedExpression) {
        final name = arg.name.label.name;
        if (validNamed != null && !validNamed.contains(name) && prevArg != null) {
          // `arg` is an undefined_named_parameter on `targetName`!
          // Wait: if `prevArg` ends with `)` (an inner call inside `prevArg`),
          // either `targetName` was missing `)` (after `,`) OR the inner call inside
          // `prevArg` was missing `)` (before `,`)! Both `prevArg.end` (before `,`)
          // and after `,` should be checked, or if `prevArg` ends with `)`, prefer
          // `prevArg.end` ONLY if `prevArg` does not contain nested calls that could
          // have stolen `targetName`'s `)`!
          bool prevHasNestedCallAtEnd = prevArg.endToken.type == TokenType.CLOSE_PAREN &&
              (prevArg is MethodInvocation || prevArg is InstanceCreationExpression || prevArg is BinaryExpression);
          if (!prevHasNestedCallAtEnd) {
            offsets.add(prevArg.end);
          }
          break;
        }
      } else {
        posCount++;
        if (maxPos != null && posCount > maxPos && prevArg != null) {
          bool prevHasNestedCallAtEnd = prevArg.endToken.type == TokenType.CLOSE_PAREN &&
              (prevArg is MethodInvocation || prevArg is InstanceCreationExpression || prevArg is BinaryExpression);
          if (!prevHasNestedCallAtEnd) {
            offsets.add(prevArg.end);
          }
          break;
        }
      }
      prevArg = arg;
    }

    // Check if an argument is a property access like `context.platform` where
    // `context.platform` is NOT a valid identifier property access, but
    // `targetName.platform` IS a valid call-result property access!
    for (final arg in argList.arguments) {
      if (arg is PrefixedIdentifier) {
        final idAccess = '${arg.prefix.name}.${arg.identifier.name}';
        final callAccess = '$targetName.${arg.identifier.name}';
        if (!semanticIndex.identifierPropertyAccesses.contains(idAccess) &&
            semanticIndex.callResultPropertyAccesses.contains(callAccess)) {
          offsets.add(arg.prefix.end);
        }
      } else if (arg is MethodInvocation && arg.target is SimpleIdentifier) {
        final prefix = arg.target as SimpleIdentifier;
        final idAccess = '${prefix.name}.${arg.methodName.name}';
        final callAccess = '$targetName.${arg.methodName.name}';
        if (!semanticIndex.identifierPropertyAccesses.contains(idAccess) &&
            semanticIndex.callResultPropertyAccesses.contains(callAccess)) {
          offsets.add(prefix.end);
        }
      }
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkInvocation(node, _invocationTargetName(node), node.argumentList);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _checkInvocation(node, _invocationTargetName(node), node.argumentList);
    super.visitInstanceCreationExpression(node);
  }
}

bool _hasSemanticViolation(String candidateCode, SemanticIndex semanticIndex) {
  final res = parseString(content: candidateCode, throwIfDiagnostics: false);
  final checker = _SemanticViolationChecker(semanticIndex);
  res.unit.accept(checker);
  return checker.hasViolation;
}

class _SemanticViolationChecker extends RecursiveAstVisitor<void> {
  final SemanticIndex semanticIndex;
  bool hasViolation = false;

  _SemanticViolationChecker(this.semanticIndex);

  void _checkArgs(String? targetName, ArgumentList argList) {
    if (hasViolation || targetName == null) return;
    final validNamed = semanticIndex.validNamedArgsByTarget[targetName];
    final maxPos = semanticIndex.maxPositionalArgsByTarget[targetName];
    int pos = 0;
    for (final arg in argList.arguments) {
      if (arg is NamedExpression) {
        if (validNamed != null && !validNamed.contains(arg.name.label.name)) {
          hasViolation = true;
          return;
        }
      } else {
        pos++;
        if (maxPos != null && pos > maxPos) {
          hasViolation = true;
          return;
        }
      }
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkArgs(_invocationTargetName(node), node.argumentList);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _checkArgs(_invocationTargetName(node), node.argumentList);
    super.visitInstanceCreationExpression(node);
  }
}
