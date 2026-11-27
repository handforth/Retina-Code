// Second F# sample: computation expressions, units, active patterns, unterminated nested comment
module Program

open System
open System.IO

type Token =
    | Number of float
    | Ident of string
    | Op of char
    | LParen
    | RParen
    | Str of string

let tokenize (input: string) : Token list =
    let rec go i acc =
        if i >= input.Length then List.rev acc
        else
            match input.[i] with
            | c when Char.IsWhiteSpace c -> go (i + 1) acc
            | c when Char.IsDigit c ->
                let j = Seq.findIndex (fun ch -> not (Char.IsDigit ch || ch = '.')) (Seq.append (input.Substring i) [' '])
                go (i + j) (Number (float (input.Substring(i, j))) :: acc)
            | c when Char.IsLetter c ->
                let j = input.Substring(i) |> Seq.takeWhile Char.IsLetterOrDigit |> Seq.length
                go (i + j) (Ident (input.Substring(i, j)) :: acc)
            | '"' ->
                let close = input.IndexOf('"', i + 1)
                go (close + 1) (Str (input.Substring(i + 1, close - i - 1)) :: acc)
            | '(' -> go (i + 1) (LParen :: acc)
            | ')' -> go (i + 1) (RParen :: acc)
            | '+' | '-' | '*' | '/' as c -> go (i + 1) (Op c :: acc)
            | c -> failwithf "unexpected character '%c' at %d" c i
    go 0 []

type Result<'T, 'E> with
    member this.IsOk = match this with Ok _ -> true | Error _ -> false

type ResultBuilder() =
    member _.Bind(m, f) = Result.bind f m
    member _.Return x = Ok x
    member _.ReturnFrom m = m
    member _.Zero() = Ok ()

let result = ResultBuilder()

let parseInt (s: string) =
    match Int32.TryParse s with
    | true, v -> Ok v
    | false, _ -> Error $"not an int: \"{s}\""

let addStrings a b = result {
    let! x = parseInt a
    let! y = parseInt b
    return x + y
}

let (|Prefix|_|) (p: string) (s: string) =
    if s.StartsWith p then Some (s.Substring p.Length) else None

let route path =
    match path with
    | Prefix "/api/" rest -> $"api call: {rest}"
    | Prefix "/static/" file -> sprintf "static file: %s" file
    | "/" -> "home"
    | _ -> "404"

[<EntryPoint>]
let main argv =
    let tokens = tokenize "(1 + 2.5) * x / \"str\""
    tokens |> List.iter (printfn "%A")
    printfn "%A" (addStrings "1" "2")
    printfn "%A" (addStrings "1" "two")
    for p in [ "/"; "/api/users"; "/static/app.js"; "/nope" ] do
        printfn "%-20s -> %s" p (route p)
    let path = Path.Combine(@"C:\temp", "out.txt")
    let lines = [
        "first line"
        @"verbatim \n no escape"
        """triple "quoted" line"""
        $"interpolated {DateTime.Now:yyyy-MM-dd}"
        $$"""double-dollar {{argv.Length}} args and {literal}"""
    ]
    lines |> List.iteri (fun i l -> printfn "%d: %s" i l)
    let mutable counter = 0
    while counter < 3 do
        counter <- counter + 1
    let arr = Array2D.init 3 3 (fun i j -> i * j)
    let slice = arr.[1.., ..1]
    let ops = [ (+); (-); (*); (/) ] |> List.map (fun f -> f 10 2)
    let mulOp = ( * )
    let starParen = (*) 3 4
    printfn "ops=%A mul=%d star=%d" ops (mulOp 2 3) starParen
    use file = new StringWriter()
    file.WriteLine("disposed at end of scope")
    try
        failwith "boom"
    with
    | :? InvalidOperationException as ex -> printfn "invalid: %s" ex.Message
    | ex -> eprintfn "error: %s" ex.Message
    let lazyVal = lazy (printfn "evaluated"; 42)
    printfn "%d" (lazyVal.Force())
    let quotation = <@ 1 + 2 @>
    let typedQuote = <@@ fun x -> x * 2 @@>
    printfn "%A %A" quotation typedQuote
    let nums = [ 0x10; 0o10; 0b10; 1_0 ]
    let floats = [ 1.0; 1e3; 1.5E-3; 2.0f |> float ]
    let units = 5.0<m> / 2.0<s>
    printfn "%A %A %A" nums floats units
    0

and [<Measure>] m
and [<Measure>] s

module Edge =
    // Operators that start with ( and * but are not comments
    let ( *** ) a b = a * b * b
    let ( **. ) a b = a ** b
    let value1 = 2 *** 3
    let value2 = ( *** ) 2 3
    let value3 = (*) 4 5             // a comment, because (* starts one... unless it is (*)
    // Generic type parameters with apostrophes vs char literals
    let pair<'a, 'b> (a: 'a) (b: 'b) = (a, b)
    let chars = pair 'x' '\''
    let tick = 'a'
    let typeParamLike : 'T list -> int = List.length
    // Strings at line boundaries
    let multi = "first line
second line \
    joined continuation"
    let verbatimMulti = @"verbatim
spanning ""lines"""
    let tripleMulti = """triple
spanning "lines"
"""
    let interpMulti = $"""interp
{tick} spanning
"""
    // Comments containing strings that hide closers
    (* comment with "a string containing *) inside" still comment *)
    let afterTrickyComment = 1
    (* comment with a char '"' then *) let afterCharInComment = 2
    // Active pattern with banana clips
    let (|Int|_|) (s: string) = match System.Int32.TryParse s with | true, v -> Some v | _ -> None
    let parse = function Int n -> n | _ -> 0

(* The following comment never closes.
   (* nested level two
      (* level three *)
   still level two *)
   back to level one, with a string "*)" that hides a closer in F#
   let notCode = 1
   end of file
