// F# lexer stress: nested (* *) comments, verbatim/triple strings, interpolation
namespace Stress.Lexer

(* F# block comments nest: (* inner (* deeper *) *) still outer
   and this line is still a comment *)

(* A comment with "a string containing *)" inside — strings in comments are lexed in F# *)

/// XML doc comment with <summary>tags</summary> and 'quotes'
/// <param name="x">the value</param>

open System
open System.Collections.Generic
open System.Text.RegularExpressions

[<AutoOpen>]
module Strings =
    let name = "World"
    let simple = "Hello, \"World\" with \\ and \n and \t and \u0041 and \U0001F600"
    let trailing = "ends with backslash \\"
    let verbatim = @"C:\Users\path\no\escapes and ""doubled"" quotes"
    let triple = """Triple-quoted with "quotes" and \n literal"""
    let tripleMulti = """
        Multi-line triple string
        with "quotes" and (* not a comment *)
        // and not a line comment either
        """
    let interp = $"Hello, {name}! Length: {name.Length} and {if name.Length > 3 then "long" else "short"}"
    let interpFormat = $"Pi is {Math.PI:F2} and padded |{42,8}| and hex {255:X}"
    let interpVerbatim = $@"Path: C:\{name}\file and {{escaped braces}}"
    let verbatimInterp = @$"Also verbatim-interp {name}"
    let interpTriple = $"""Triple interp: "{name}" and {name.ToUpper()}"""
    let dollarDollar = $$"""JSON: {"name": "{{name}}", "braces": {}}"""
    let typedInterp = $"%s{name} has %d{name.Length} chars"
    let nestedInterp = $"""outer {$"inner {name}"} outer"""
    let multiLineRegular = "line one
line two of a regular string"
    let unterminated = "missing close quote
    let afterUnterminated = 1
    let byteString = "bytes"B
    let charLit = 'a'
    let charEscapes = ['\n'; '\''; '\\'; '\u0041'; '"'; '\t'; '\b']
    let byteChar = 'a'B

module Numbers =
    let i = 42
    let i8 = 42y
    let u8 = 42uy
    let i16 = 42s
    let u16 = 42us
    let l = 42L
    let ul = 42UL
    let u = 42u
    let n = 42n
    let un = 42un
    let big = 123456789012345678901234567890I
    let hex = 0xFF_FF
    let oct = 0o17
    let bin = 0b1010_1010
    let f32 = 3.0f
    let f32b = 3.0F
    let f64 = 1.5e-3
    let dec = 1.5m
    let dec2 = 10M
    let float32Hex = 0x3F800000lf
    let sep = 1_000_000
    let range = [1..10]
    let rangeStep = [0..2..20]
    let floatRange = [1.0 .. 0.5 .. 3.0]

type Shape =
    | Circle of radius: float
    | Rect of width: float * height: float
    | Triangle of a: float * b: float * c: float
    member this.Area =
        match this with
        | Circle r -> Math.PI * r ** 2.0
        | Rect (w, h) -> w * h
        | Triangle (a, b, c) ->
            let s = (a + b + c) / 2.0
            sqrt (s * (s - a) * (s - b) * (s - c))

[<Struct>]
type Point = { X: float; Y: float }
    with static member (+) (a: Point, b: Point) = { X = a.X + b.X; Y = a.Y + b.Y }

[<Measure>] type m
[<Measure>] type s
let speed = 10.0<m/s>
let accel = 9.81<m/s^2>

type IRepository<'T when 'T : equality> =
    abstract member Find : id: int -> 'T option
    abstract member All : unit -> seq<'T>

type InMemoryRepo<'T when 'T : equality>(items: 'T list) =
    let store = Dictionary<int, 'T>()
    do items |> List.iteri (fun i x -> store.[i] <- x)
    member val Count = items.Length with get, set
    interface IRepository<'T> with
        member _.Find id = match store.TryGetValue id with | true, v -> Some v | _ -> None
        member _.All () = store.Values :> seq<_>

let inline add< ^T when ^T : (static member (+) : ^T * ^T -> ^T)> (a: ^T) (b: ^T) = a + b
let generic<'a, 'b> (f: 'a -> 'b) (x: 'a) : 'b = f x
let comparisons a b = a < b && b > a || a <> b
let shifts a = (a <<< 2) >>> 1 ||| 0x0F &&& 0xF0 ^^^ 1
let pipes = [1; 2; 3] |> List.map ((*) 2) |> List.filter (fun x -> x > 2) |> List.sum
let compose = (fun x -> x + 1) >> (fun x -> x * 2) << id
let operatorAsValue = (*)          // not a comment opener: ( * )
let operatorSpaced = ( *) 2 3       // also not a comment
let tuple = (1, "two", 3.0)
let struct' = struct (1, 2)
let list = [ 1; 2; 3 ]
let array = [| 1; 2; 3 |]
let seq' = seq { for i in 1 .. 10 do if i % 2 = 0 then yield i * i }
let anonRecord = {| Name = "x"; Age = 3 |}
let optional = Some 1 |> Option.map ((+) 1) |> Option.defaultValue 0
let identWithTicks = ``a name with spaces`` + 1
let ``a name with spaces`` = 1
let x' = 1
let x'' = x' + 1

let rec fib = function
    | 0 | 1 as n -> n
    | n -> fib (n - 1) + fib (n - 2)

let (|Even|Odd|) n = if n % 2 = 0 then Even else Odd

let describe n =
    match n with
    | Even when n > 100 -> "big even"
    | Even -> "even"
    | Odd -> "odd"

let asyncWork = async {
    do! Async.Sleep 100
    let! x = async { return 42 }
    return x * 2
}

let taskWork = task {
    let! v = System.Threading.Tasks.Task.FromResult "done"
    return $"result: {v}"
}

#if DEBUG
let mode = "debug"
#else
let mode = "release"
#endif

#nowarn "40"
#light "on"

let regex = Regex(@"^\d{3}-\d{4}$", RegexOptions.Compiled)
let isMatch = regex.IsMatch "555-1234"

(* final nested (* comment *) closes *) let last = 'z'
