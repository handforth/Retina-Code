// Java second sample: annotations galore, inner classes, unterminated text block and comment
package org.example.svc;

import java.io.*;
import java.nio.file.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import javax.annotation.processing.Generated;

@Generated(value = "codegen", date = "2026-01-01T00:00:00Z", comments = "/* not a comment */")
@SuppressWarnings("serial")
public class ServiceUnterminated extends AbstractService<Request, Response>
        implements AutoCloseable, Comparable<ServiceUnterminated> {

    private static final long serialVersionUID = -1234567890123456789L;
    private static final AtomicInteger COUNTER = new AtomicInteger(0x7FFF_FFFF);
    private final ExecutorService pool = Executors.newFixedThreadPool(4);
    private final ConcurrentMap<String, CompletableFuture<List<? extends Response>>> cache =
            new ConcurrentHashMap<>(16, 0.75f, 2);

    @Inject
    @Named("primary")
    private Repository<Long, Entity<Long>> repo;

    @Override
    public int compareTo(ServiceUnterminated other) {
        return Integer.compare(this.hashCode(), other.hashCode());
    }

    @Override
    public void close() throws IOException {
        pool.shutdownNow();
    }

    public CompletableFuture<Response> handle(final Request req) {
        return CompletableFuture.supplyAsync(() -> {
            try (var in = Files.newBufferedReader(Path.of(req.path()));
                 var out = new StringWriter()) {
                in.transferTo(out);
                return new Response(200, out.toString());
            } catch (IOException | UncheckedIOException e) {
                throw new CompletionException("failed: \"" + req.path() + "\"", e);
            } finally {
                COUNTER.incrementAndGet();
            }
        }, pool);
    }

    protected <E extends Exception> void rethrow(Exception e) throws E {
        @SuppressWarnings("unchecked") E cast = (E) e;
        throw cast;
    }

    private static String describe(Object o) {
        return switch (o) {
            case null -> "null";
            case Integer i when i > 0x10 -> "big int " + i;
            case Integer i -> "int " + i;
            case Long l -> "long " + l + 'L';
            case String s -> "string \"" + s + "\"";
            case int[] arr -> "int array of " + arr.length;
            default -> o.getClass().getName();
        };
    }

    private static int oldSwitch(char c) {
        switch (c) {
            case 'a':
            case 'b':
                return 1;
            case '\'':
                return 2;
            case '\\':
                return 3;
            case '\u0000':
                return 4;
            default:
                return 0;
        }
    }

    static final String HTML = """
        <html>
            <body class="main">
                <p>It's a "text block" with <b>tags</b></p>
                <script>var x = "</script>";</script>
            </body>
        </html>
        """;

    static final String ESCAPES = """
        tab:\t newline:\n quote:\" backslash:\\ unicode:A octal:\101
        line-continuation:\
        joined
        triple-escaped:\"""
        """;

    // Generic method calls and type witnesses
    void generics() {
        List<String> a = Collections.<String>emptyList();
        Map<String, Map<String, List<Integer>>> deep = new TreeMap<>(Comparator.reverseOrder());
        Optional<? extends CharSequence> opt = Optional.of("x");
        Class<?>[] types = {String.class, int.class, int[].class, Map.Entry.class};
        boolean b = 1 < 2 && 3 > 2;
        int shift = -1 >>> 28;
        List<List<List<String>>> triple = List.of(List.of(List.of("deep")));
    }

    class InnerNonStatic {
        int value = ServiceUnterminated.this.hashCode();
    }

    static abstract class Visitor<R> {
        abstract R visitNum(int n);
        abstract R visitAdd(Node l, Node r);
    }

    interface Node {
        <R> R accept(Visitor<R> v);
        default String show() { return "Node@" + Integer.toHexString(hashCode()); }
        static Node num(int n) { return new Node() { public <R> R accept(Visitor<R> v) { return v.visitNum(n); } }; }
    }

    // Lambdas, method refs, and anonymous classes with generics
    static final Comparator<Map.Entry<String, List<Integer>>> BY_SIZE =
            Comparator.comparing((Map.Entry<String, List<Integer>> e) -> e.getValue().size())
                    .thenComparing(Map.Entry::getKey, String.CASE_INSENSITIVE_ORDER)
                    .reversed();

    static final Callable<String> ANON = new Callable<>() {
        @Override
        public String call() throws Exception {
            return "anon \"callable\" with 'char' and \\ backslash";
        }
    };

    static String concat(Object... parts) {
        StringBuilder sb = new StringBuilder();
        for (Object p : parts) sb.append(p).append('|');
        return sb.length() > 0 ? sb.substring(0, sb.length() - 1) : "";
    }

    static int ternaries(int a, int b) {
        return a > b ? a - b : a < b ? b - a : 0;
    }

    static String charOps() {
        char c = 'x';
        c += 1;
        c++;
        return "" + c + '!' + (char) 0x41 + (int) 'A';
    }

    static String unicodeIdentifiers() {
        String café = "café";
        int Δ = 5;
        return café + Δ;
    }

    // Numbers at odd positions
    double[] nums = {0, 0., .0, 0.0, 0e0, 0E+0, 0x0p0, 1_0.0_1, 0_7, 0b0, 0xFFFF_FFFFL, 1e-9f, 7D};

    /** Unclosed javadoc-style comment is below; a text block is opened first. */
    static final String UNTERMINATED_BLOCK = """
        This text block never closes.
        "quotes" and 'apostrophes' and // comment markers
        /* block markers */ and } braces { everywhere
        public void notCode() {}
    /*
     * And here begins a real block comment if the text block above were closed.
     * The two unterminated constructs nest the lexer state at EOF.
     */
    static int afterEverything = 42;
