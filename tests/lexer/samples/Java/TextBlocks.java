/*
 * Java lexer stress sample: text blocks, generics, annotations, literals.
 * Block comments do NOT nest in Java: /* this inner opener is just text
 */
package com.example.lexer.stress;

import java.util.*;
import java.util.function.Function;
import java.util.stream.Collectors;
import static java.util.Map.entry;

/**
 * Javadoc with {@code List<String>} and {@link Map#get(Object)} and <b>html</b>.
 * @param <T> the element type
 * @author someone
 */
@SuppressWarnings({"unchecked", "rawtypes"})
@Deprecated(since = "9", forRemoval = true)
public final class TextBlocks<T extends Comparable<? super T>> implements Iterable<T> {

    private static final String SIMPLE = "simple \"quoted\" string with \\ and \t tab";
    private static final String UNICODE = "Aé 😀 and octal \101 \7 \377";
    private static final char QUOTE = '\'';
    private static final char BACKSLASH = '\\';
    private static final char UNI = 'A';
    private static final char NUL = '\0';
    private static final String TRAILING = "ends with backslash \\";
    private static final String COMMENTY = "// not a comment /* nor this */";

    private static final String TEXT_BLOCK = """
        Hello, "world"!
          Indented line with ""two quotes"" and \""" escaped triple
        Line with trailing backslash joins \
        the next line.
        Line with \s explicit space and \t tab and \n newline escape
        // not a comment inside text block
        /* also not a comment */
        """;

    private static final String EMPTY_BLOCK = """
        """;

    private static final String JSON = """
        {
          "name": "value",
          "nested": { "a": [1, 2, 3] },
          "escaped": "quote \\" here"
        }""";

    private static final String SQL = """
            SELECT id, "name"
            FROM users
            WHERE status = 'active' -- trailing sql comment
            """.stripIndent();

    // Numeric literals
    int dec = 1_000_000;
    int hex = 0xFF_FF;
    int hexUpper = 0XCAFE;
    int bin = 0b1010_1010;
    int oct = 017;
    long big = 9_223_372_036_854_775_807L;
    long lower = 5l;
    float f = 3.0f;
    float f2 = 1e10F;
    double d = 1.5e-3;
    double d2 = .5d;
    double d3 = 5.D;
    double hexFloat = 0x1.8p1;
    double hexFloat2 = 0X1P-3d;
    char c = 'a';
    char tab = '\t';

    private final List<Map<String, List<T>>> nested = new ArrayList<>();
    private final Map<String, Function<? super T, ? extends Number>> fns = new HashMap<>();

    @Override
    public Iterator<T> iterator() {
        return Collections.<T>emptyList().iterator();
    }

    public <R extends Number & Comparable<R>> R max(List<? extends R> xs) {
        R best = null;
        for (R x : xs) {
            if (best == null || x.compareTo(best) > 0) best = x;
        }
        return best;
    }

    static int shifts(int a) {
        return (a << 2) >> 1 >>> 3;  // shifts, not generics
    }

    static boolean comparisons(int a, int b, int c) {
        return a < b && b > c || a <= c && c >= b;
    }

    sealed interface Shape permits Circle, Square, Rect {}
    record Circle(double r) implements Shape {}
    record Square(double side) implements Shape {}
    non-sealed static class Rect implements Shape {}

    static double area(Shape s) {
        return switch (s) {
            case Circle c when c.r() > 0 -> Math.PI * c.r() * c.r();
            case Circle c -> 0;
            case Square sq -> sq.side() * sq.side();
            case Rect r -> {
                yield -1;
            }
        };
    }

    enum Planet {
        MERCURY(3.303e+23, 2.4397e6),
        EARTH(5.976e+24, 6.37814e6);

        private final double mass, radius;
        Planet(double mass, double radius) { this.mass = mass; this.radius = radius; }
    }

    @FunctionalInterface
    interface Op<A, B> { B apply(A a) throws Exception; }

    @interface Marker {
        String value() default "";
        int[] nums() default {1, 2, 3};
    }

    @Marker(value = "x", nums = {0x1, 0b1, 01})
    void annotated(@SuppressWarnings("unused") final int param, String... rest) {
        var list = List.of("a", "b", "c");
        var joined = list.stream()
                .map(String::toUpperCase)
                .filter(s -> !s.isEmpty())
                .collect(Collectors.joining(", ", "[", "]"));
        Object o = joined;
        if (o instanceof String str && !str.isBlank()) {
            System.out.printf("%s has %d chars%n", str, str.length());
        }
        label:
        for (int i = 0; i < 10; i++) {
            for (int j = 0; j < i; j++) {
                if (j > 3) continue label;
                if (i * j > 20) break label;
            }
        }
        int[][] grid = new int[3][4];
        int x = grid.length > 0 ? grid[0].length : -1;
        Runnable r = () -> { };
        Function<Integer, Function<Integer, Integer>> add = a -> b -> a + b;
        Map<String, Integer> m = Map.ofEntries(entry("one", 1), entry("two", 2));
    }

    static class Inner<K, V extends List<K>> {
        transient volatile K key;
        synchronized V get() { return null; }
        native void nativeMethod();
        strictfp double calc() { return 0.0; }
    }

    // A unicode escape in a comment is processed early in real Java: \u000A
    // Line comment containing "a string" and 'c' and """ triple
    /* Block comment with "string" and """text block""" inside */

    public static void main(String[] args) throws Exception {
        String s = "unterminated string at end of line
        int after = 1;
        String nested = "outer \"inner \\\"deep\\\" inner\" outer";
        System.out.println(TEXT_BLOCK + SIMPLE + nested);
        assert args.length >= 0 : "never";
        new Thread(() -> System.out.println("lambda")).start();
        int[] arr = {1, 2, 3,};
        char[] chars = {'a', '\n', 'ÿ', '"'};
    }
}
