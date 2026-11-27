// Dart lexer stress: interpolation, raw strings, triple quotes, nested comments
library stress;

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import "package:meta/meta.dart" as meta;
export 'src/a.dart' hide B;
part 'part.dart';

/* Dart block comments nest: /* inner /* deeper */ */ still outer */
const afterNested = 'visible';

/// Doc comment with [references] and `code`.
/// ```dart
/// var x = 'inside a doc code block';
/// ```
/** Old-style doc comment with 'quotes' */
class Documented {}

final name = 'World';
final simple = 'Hello, $name!';
final braced = 'Hello, ${name.toUpperCase()}!';
final nested = "outer ${'middle ${"inner $name"} middle'} outer";
final dollarEsc = 'cost: \$5 and \${notInterp}';
final escapes = 'tab\t nl\n cr\r bs\\ sq\' dq\" hex\x41 uni\u0041 \u{1F600} \$';
final trailing = 'ends with backslash \\';
final dq = "double \"quoted\" and 'single' inside";
final unterminated = 'no closing quote
final afterUnterminated = 1;

final raw = r'Raw: \n stays, $name stays, \t stays';
final rawDouble = r"Raw double: C:\path\file and ${notInterp}";
final triple = '''
Triple single-quoted with 'quotes' and "doubles"
and $name interpolation and ${1 + 2}
and \''' escaped triple
''';
final tripleDouble = """
Triple double: "a" ""b"" and ${'nested ${"deep"}'}
""";
final rawTriple = r'''
Raw triple: $name \n ${x} all literal
''';
final rawTripleDouble = r"""raw "" triple""";
final adjacent = 'one ' "two " '''three''' r'four';
final exprInterp = '${[1, 2, 3].map((x) => '$x').join(', ')}';
final mapInterp = '${{'a': 1}['a']}';
final closingBraceInString = '${'}'}';

// Numbers
const dec = 1000000;
const sep = 1_000_000;
const hex = 0xFF_FF;
const hexUp = 0XDEADBEEF;
const flt = 1.5e-3;
const flt2 = .5;
const exp = 1E10;
const neg = -0x7F;

// Generics and annotations
@immutable
class Pair<A extends Object?, B> {
  final A first;
  final B second;
  const Pair(this.first, this.second);

  Pair<B, A> swap() => Pair(second, first);

  @override
  String toString() => 'Pair($first, $second)';

  @override
  bool operator ==(Object other) =>
      other is Pair<A, B> && other.first == first && other.second == second;

  @override
  int get hashCode => Object.hash(first, second);
}

typedef Mapper<T, R> = R Function(T value);
typedef void Callback(int x);

abstract interface class Repository<K, V extends Comparable<V>> {
  Future<V?> find(K key);
  Stream<List<V>> watchAll();
}

sealed class Shape {}
final class Circle extends Shape { final double r; Circle(this.r); }
final class Square extends Shape { final double s; Square(this.s); }

double area(Shape s) => switch (s) {
      Circle(r: var r) when r > 0 => 3.14159 * r * r,
      Circle() => 0,
      Square(:final s) => s * s,
    };

mixin Logging on Object {
  void log(String msg) => print('[${runtimeType}] $msg');
}

extension StringX on String {
  String get reversed => split('').reversed.join();
  bool get isBlank => trim().isEmpty;
}

extension type UserId(int value) implements int {}

enum Status implements Comparable<Status> {
  active('A', 1),
  inactive('I', 0);

  const Status(this.code, this.weight);
  final String code;
  final int weight;

  @override
  int compareTo(Status other) => weight - other.weight;
}

bool comparisons(int a, int b) => a < b && b > a;
int shifts(int a) => (a << 2) >> 1 >>> 3;
final generic = <String, List<Map<int, Set<double>>>>{};
final list = <int>[1, 2, 3];
final set = <String>{'a', 'b'};
final record = (1, name: 'x', 2.0);
final (int a, String b) = (1, 'b');
final nullAware = maybe?.value ?? 'default';
final cascade = StringBuffer()..write('a')..writeln("b")..write('''c''');
final spread = [...list, ...?nullableList, if (true) 4, for (var i in list) i * 2];

Future<void> main(List<String> args) async {
  final sw = Stopwatch()..start();
  await for (final x in Stream.fromIterable([1, 2, 3])) {
    print('x=$x elapsed=${sw.elapsedMilliseconds / 1000}s');
  }
  final data = jsonDecode('{"key": "value", "n": 1}') as Map<String, dynamic>;
  print(jsonEncode({'name': name, 'data': data}));
  try {
    throw FormatException('bad "format"', 'src', 0);
  } on FormatException catch (e, st) {
    print('caught $e\n$st');
  } finally {
    print(r'finally $done');
  }
  outer:
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      if (j == i) continue outer;
      if (i + j > 3) break outer;
    }
  }
  late final int lazy;
  lazy = 42;
  assert(lazy > 0, 'must be positive: $lazy');
}

Stream<int> countdown(int from) async* {
  for (var i = from; i >= 0; i--) {
    yield i;
  }
  yield* Stream.value(-1);
}

Iterable<int> naturals() sync* {
  var n = 0;
  while (true) yield n++;
}

/* nested /* comment */ closes properly */ final lastLine = "done";
