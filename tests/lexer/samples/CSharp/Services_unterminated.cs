// Second C# sample: minimal API, LINQ, records, events; ends inside an unterminated raw string.
using System.Collections.Concurrent;
using System.ComponentModel.DataAnnotations;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<ITodoStore, InMemoryTodoStore>();
builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
});

var app = builder.Build();

app.MapGet("/", () => Results.Text($"""
    <!doctype html>
    <html><body>
      <h1>Todos ({DateTime.UtcNow:O})</h1>
      <p>Use <code>GET /todos</code> or <code>POST /todos</code>.</p>
    </body></html>
    """, "text/html"));

app.MapGet("/todos", (ITodoStore store, bool? done) =>
    store.All()
         .Where(t => done is null || t.Done == done)
         .OrderBy(t => t.Created)
         .Select(t => new { t.Id, t.Title, t.Done, Age = (DateTime.UtcNow - t.Created).TotalMinutes / 60.0 }));

app.MapPost("/todos", async (HttpContext ctx, ITodoStore store) =>
{
    var input = await ctx.Request.ReadFromJsonAsync<TodoInput>();
    if (input is not { Title.Length: > 0 })
        return Results.BadRequest(new { error = "Title is required", hint = @"Send {""title"": ""...""}" });
    var todo = store.Add(input.Title.Trim());
    return Results.Created($"/todos/{todo.Id}", todo);
});

app.MapDelete("/todos/{id:int}", (int id, ITodoStore store) =>
    store.Remove(id) ? Results.NoContent() : Results.NotFound($"No todo #{id}"));

app.Run();

public sealed record TodoInput([Required, MaxLength(200)] string Title);

public sealed record Todo(int Id, string Title, bool Done, DateTime Created)
{
    public Todo Complete() => this with { Done = true };
    public override string ToString() => $"#{Id} [{(Done ? 'x' : ' ')}] {Title}";
}

public interface ITodoStore
{
    IEnumerable<Todo> All();
    Todo Add(string title);
    bool Remove(int id);
    event EventHandler<TodoChangedEventArgs>? Changed;
}

public sealed class TodoChangedEventArgs(Todo todo, string kind) : EventArgs
{
    public Todo Todo { get; } = todo;
    public string Kind { get; } = kind;
}

internal sealed class InMemoryTodoStore : ITodoStore
{
    private readonly ConcurrentDictionary<int, Todo> _items = new();
    private int _nextId;

    public event EventHandler<TodoChangedEventArgs>? Changed;

    public IEnumerable<Todo> All() => _items.Values;

    public Todo Add(string title)
    {
        var id = Interlocked.Increment(ref _nextId);
        var todo = new Todo(id, title, false, DateTime.UtcNow);
        _items[id] = todo;
        OnChanged(todo, "added");
        return todo;
    }

    public bool Remove(int id)
    {
        if (!_items.TryRemove(id, out var removed)) return false;
        OnChanged(removed, "removed");
        return true;
    }

    private void OnChanged(Todo t, string kind, [CallerMemberName] string caller = "") =>
        Changed?.Invoke(this, new TodoChangedEventArgs(t, $"{kind} via {caller}"));
}

public static class Extensions
{
    public static IEnumerable<IGrouping<char, string>> ByInitial(this IEnumerable<string> words) =>
        from w in words
        where !string.IsNullOrWhiteSpace(w)
        let first = char.ToUpperInvariant(w[0])
        orderby first ascending, w.Length descending
        group w by first into g
        select g;

    public static T Also<T>(this T self, Action<T> action) { action(self); return self; }

    public static unsafe int SumUnsafe(int[] values)
    {
        int total = 0;
        fixed (int* p = values)
        {
            for (int* q = p; q < p + values.Length; q++) total += *q;
        }
        return total;
    }

    public static ref int FirstRef(Span<int> span) => ref span[0];

    public static (int Min, int Max) MinMax(params int[] xs) => (xs.Min(), xs.Max());

    public static string Describe(this object? o) => o switch
    {
        null => "null",
        IEnumerable<int> seq when seq.Any() => $"ints: {string.Join(", ", seq)}",
        Todo { Done: true } t => $"done: {t.Title}",
        _ => o.ToString() ?? string.Empty,
    };
}

file static class Internal
{
    internal const string Json = """
        {"a": 1, "b": [true, false, null], "c": "quote \" inside raw"}
        """;
    internal static readonly string[] Lines = [ "one", @"two\verbatim", $"three {1 + 2}", """four""" ];
    internal static readonly object[] Nums = [ 0, 0x0, 0b0, 0L, 0UL, 0u, 0f, 0d, 0m, 1e1, .1, 1_0 ];
    internal static readonly char[] Chars = [ 'a', '\'', '\\', '\n', '\u0000', '\x7', '"' ];
}

checked { var big = int.MaxValue; }
unchecked { var wrap = int.MaxValue + 1; }
goto end;
end:
Console.WriteLine(nameof(Internal.Json) + typeof(Todo).Name + sizeof(int) + default(int));

// The raw string below never closes; everything after is raw content.
var template = """
    Dear {name},

    This "raw" literal has no closing triple quote, so:
    class NotCode { }  // not a comment
    /* not a block comment */
    $"not interpolated {x}"
