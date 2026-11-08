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
      // Case A: An inner group of the SAME bracket kind closed right before `syn`
      // (or before a suffix/operator that ends at `syn`), meaning the inner
      // group may have stolen `begin`'s closing token!
      if (scan is BeginToken &&
          scan.type == begin.type &&
          scan.endGroup != null &&
          !scan.endGroup!.isSynthetic) {
        final innerEnd = scan.endGroup!;
        if (innerEnd.next == syn) {
          // Check if the inner group swallowed a comma, period, or binary operator
          if (_groupContainsAmbiguousContinuation(scan, innerEnd)) {
            isAmbiguousSteal = true;
          }
        } else if (innerEnd.next != null &&
            (innerEnd.next!.type.isBinaryOperator ||
                innerEnd.next!.type == TokenType.PERIOD ||
                innerEnd.next!.type == TokenType.QUESTION_PERIOD)) {
          isAmbiguousSteal = true;
        }
      }

      // Case B: If `begin` is `[` (e.g. index expression `items[i].value == x`),
      // and inside `[begin .. syn]` there is a `.` or binary operator, the `]`
      // could have belonged before `.` or `==`.
      if (begin.type == TokenType.OPEN_SQUARE_BRACKET &&
          (scan.type == TokenType.PERIOD ||
              scan.type == TokenType.QUESTION_PERIOD ||
              scan.type.isBinaryOperator)) {
        isAmbiguousSteal = true;
      }

      // Case C: `if (a && (b || c) {` where `{` is inside `(`
      if (scan.type == TokenType.OPEN_CURLY_BRACKET &&
          begin.type == TokenType.OPEN_PAREN) {
        final beforeCurly = scan.previous;
        if (beforeCurly != null &&
            !beforeCurly.isSynthetic &&
            beforeCurly.type == TokenType.CLOSE_PAREN) {
          edits.add((
            offset: beforeCurly.charEnd,
            length: 0,
            replacement: ')',
          ));
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
      final before = syn.beforeSynthetic;
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
          // Propose closing the inner invocation right after `prevArg` (before the comma).
          offsets.add(prevArg.end);
          break;
        }
      } else {
        posCount++;
        if (maxPos != null && posCount > maxPos && prevArg != null) {
          // `arg` exceeds max positional arguments (`extra_positional_arguments`)!
          offsets.add(prevArg.end);
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
