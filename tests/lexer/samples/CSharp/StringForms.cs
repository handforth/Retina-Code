// C# lexer stress: verbatim, interpolated, raw string literals, generics, attributes
#nullable enable
#pragma warning disable CS0168, CS0219
#define TRACE_ENABLED
#region Usings
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using static System.Math;
using Dict = System.Collections.Generic.Dictionary<string, int>;
#endregion

/* C# block comments do not nest: /* this opener is text */
namespace Stress.Lexer;

/// <summary>
/// XML doc comment with <see cref="List{T}"/> and <c>code</c> and "quotes".
/// </summary>
/// <typeparam name="T">The element type.</typeparam>
[Serializable]
[Obsolete("Use NewThing instead", error: false)]
public sealed class StringForms<T> where T : class, IComparable<T>, new()
{
    private const string Simple = "double \"quoted\" with \\ and \n and \t and \0";
    private const string Escapes = "hex \x41 and \x0041 unicode \u00e9 and \U0001F600 and \a\b\f\r\v\e";
    private const string Trailing = "ends with backslash \\";
    private const string CommentLike = "// not a comment /* nor this */";
    private const char Quote = '\'';
    private const char Backslash = '\\';
    private const char Uni = '\u0041';
    private const char Hex = '\x41';

    private static readonly string Verbatim = @"C:\Users\path\no\escapes and ""doubled"" quotes";
    private static readonly string VerbatimMulti = @"Line one
Line two with ""quotes""
Line three ends with backslash \";
    private static readonly string Unterminated = "this string never closes
    private static readonly int AfterUnterminated = 1;

    public string Name { get; init; } = "default";
    public int Count { get; private set; }
    public required List<T> Items { get; set; } = [];

    public string Interpolations(int x, double y, string? s)
    {
        var a = $"Simple {x} and {y:F2} and {s ?? "null"} and {x,8} and {y,-10:N3}";
        var b = $"Nested {(x > 0 ? $"positive {x}" : "non-positive")} done";
        var c = $"Escaped braces {{literal}} and {x}";
        var d = $@"Verbatim interpolated C:\{s}\file and ""quotes"" and {x}";
        var e = @$"Also verbatim interpolated {x} with \n literal";
        var f = $"Method call {s?.ToUpper()} and index {Items[0]} and lambda {((Func<int>)(() => 42))()}";
        var g = $"Ternary needs parens: {(x == 1 ? "one" : "other")}";
        var h = $"Format with colon in string: {DateTime.Now:yyyy-MM-dd HH:mm:ss}";
        var i = $"Multi-line interpolation hole {
            x + 1
        } (C# 11)";
        return a + b + c + d + e + f + g + h + i;
    }

    public string RawLiterals(int value)
    {
        var raw1 = """Single-line raw with "quotes" and \n literal""";
        var raw2 = """
            Multi-line raw literal.
              Indentation relative to the closing quotes is preserved.
            "quotes" and ""two"" are fine; no escapes \t here.
            """;
        var raw3 = """"
            Four quotes allow """ inside the content.
            """";
        var raw4 = $"""
            Interpolated raw: {value} and {value * 2}
            Braces need doubling here? No: { is literal only with $$.
            """;
        var raw5 = $$"""
            {
              "name": "{{Name}}",
              "value": {{value}},
              "literal": "{not interpolated}"
            }
            """;
        var raw6 = $$$"""Three dollars: {{literal}} and {{{value}}}""";
        var utf8 = "UTF-8 bytes"u8;
        var rawUtf8 = """raw utf8"""u8;
        return raw1 + raw2 + raw3 + raw4 + raw5 + raw6 + utf8.Length + rawUtf8.Length;
    }

    public void Numbers()
    {
        int dec = 1_000_000;
        int hex = 0xFF_FF;
        int bin = 0b1010_1010;
        long l = 5L;
        ulong ul = 42UL;
        uint u = 42u;
        float f = 3.0f;
        double d = 1.5e-3;
        double d2 = .5;
        double d3 = 1e10D;
        decimal m = 1.5m;
        decimal m2 = 10M;
        nint ni = 42;
        var neg = -0x7F;
    }

    public IEnumerable<TResult> Generics<TResult>(Func<T, TResult> map) where TResult : notnull
    {
        Dictionary<string, List<Dictionary<int, T>>> nested = new();
        List<List<List<int>>> triple = [[[1]]];
        var cmp = 1 < 2 && 3 > 2;
        var shift = 1 << 4 >> 2 >>> 1;
        var generic = Enumerable.Empty<KeyValuePair<string, int?>>();
        T? maybe = default;
        int[] arr = [1, 2, 3, .. new[] { 4, 5 }];
        var range = arr[1..^1];
        var last = arr[^1];
        foreach (var item in Items) yield return map(item);
    }

    [Conditional("TRACE_ENABLED")]
    [return: NotNull]
    public static async Task<int> AttributesAndAsync([CallerMemberName] string caller = "")
    {
        await Task.Delay(10).ConfigureAwait(false);
        await foreach (var x in GetAsync()) { }
        return caller.Length;
    }

    private static async IAsyncEnumerable<int> GetAsync()
    {
        for (var i = 0; i < 3; i++) { await Task.Yield(); yield return i; }
    }

    public string Patterns(object o) => o switch
    {
        null => "null",
        int i when i > 0x10 => $"big int {i}",
        int and > 0 and < 10 => "small positive",
        string { Length: 0 } => "empty string",
        string s => $"string \"{s}\"",
        (int a, int b) => $"tuple {a},{b}",
        int[] { Length: > 2 } arr => $"array starting {arr[0]}",
        not null => "something",
    };

    public record Point(double X, double Y);
    public record struct Pixel(byte R, byte G, byte B);
    public readonly ref struct SpanHolder { public readonly Span<byte> Data; }

    public static implicit operator string(StringForms<T> s) => s.Name;
    public static StringForms<T> operator +(StringForms<T> a, StringForms<T> b) => a;

    private static readonly Regex Re = new(@"^\d{3}-\d{4}$", RegexOptions.Compiled);
    private string @class = "verbatim identifier";
    private int @int = 1;

#if DEBUG
    private const string Mode = "debug";
#elif RELEASE
    private const string Mode = "release";
#else
    private const string Mode = "other";
#endif
}
