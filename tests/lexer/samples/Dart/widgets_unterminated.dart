// Second Dart sample: Flutter-ish widget tree and an unterminated nested comment
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' deferred as services;

void main() => runApp(const MyApp(title: 'It\'s an "app"'));

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        useMaterial3: true,
      ),
      home: CounterPage(title: '$title — home'),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key, required this.title});
  final String title;

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> with SingleTickerProviderStateMixin {
  int _count = 0;
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  final _items = <({int id, String label})>[];

  void _increment() {
    setState(() {
      _count++;
      _items.add((id: _count, label: 'Item #$_count (${_count / 2})'));
    });
    _ctrl.forward(from: 0.0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_count',
              style: theme.textTheme.headlineMedium,
            ),
            if (_count > 0) Text("That's ${_count == 1 ? 'once' : '$_count times'}!"),
            for (final item in _items.reversed.take(3))
              ListTile(
                key: ValueKey(item.id),
                title: Text(item.label),
                subtitle: Text(r'raw $subtitle with \n'),
              ),
            ...[
              const Divider(),
              Text('''
Multi-line
text with "quotes" and 'apostrophes'
and ${_items.length} items
'''),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _increment,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class Painter extends CustomPainter {
  Painter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color.fromARGB(0xFF, 0x42, 0xA5, 0xF5)
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;
    final rect = Offset.zero & size;
    canvas.drawArc(rect.deflate(8), -3.14159 / 2, 2 * 3.14159 * progress, false, paint);
  }

  @override
  bool shouldRepaint(covariant Painter old) => old.progress != progress;
}

class Json {
  static Map<String, Object?> parse(String s) => {};
  static const sample = '''
{
  "string": "a \\"quoted\\" value",
  "dollar": "\$not",
  "unicode": "\\u00e9"
}
''';
}

Future<List<T>> retry<T>(Future<List<T>> Function() f, {int times = 3}) async {
  for (var i = 0; i < times - 1; i++) {
    try {
      return await f();
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 100 * (1 << i)));
    }
  }
  return f();
}

final patterns = [
  RegExp(r'^\d{3}-\d{4}$'),
  RegExp('[a-z]+', caseSensitive: false),
  RegExp(r"""\s+"""),
];

const numbers = [0, 1, -1, 0x0, 0xFFFF_FFFF, 1.0, 1e3, 1.5E-10, .25, 1_000.5];
final symbols = [#foo, #bar.baz, #+, #[]];
final ternaryChain = 1 > 2 ? 'a' : 2 > 1 ? "b" : '''c''';
final interpolationEdge1 = '$';
final interpolationEdge2 = '${''}';
final interpolationEdge3 = '$name.length';
final interpolationEdge4 = '${() => '}'}';

/* This comment opens and nests but never balances:
   /* level two
      /* level three */
      still level two
   */
   back at level one — and no closer follows.
   class NotCode { final s = 'string in comment'; }
   void alsoNotCode() {}
