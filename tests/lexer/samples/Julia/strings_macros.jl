# Julia lexer stress: triple strings, $(expr) interpolation, nested comments, macros

#= Julia block comments nest: #= inner #= deeper =# =# still outer
   and this line is still a comment =#
after_nested = "visible"

#=
Multi-line block comment with "strings" and 'chars' and $interp
=#

"""
    docstring(x)

A docstring with `code`, \$escaped dollar and "quotes".
```julia
julia> docstring(1)
2
```
"""
docstring(x) = x + 1

module Stress

using LinearAlgebra, Statistics
using Base: @kwdef
import Base: +, show, getindex
export Point, norm2

name = "World"
s1 = "Hello, $name!"
s2 = "Expr: $(1 + 2) and call: $(uppercase(name)) and nested: $("inner $(name)")"
s3 = "Escapes: \t \n \r \\ \" \$ \x41 \u00e9 \U1F600 \101 \e"
s4 = "Trailing backslash \\"
s5 = "Multi-line regular string
continues here with $name"
s6 = "Unterminated on this line
s7 = "after"

t1 = """
    Triple-quoted with "quotes" and ""two"" and $name
    and $(length(name)) interpolation
    indentation is stripped
    """
t2 = """single-line triple"""
t3 = """ends with quote\""""
t4 = """
    Nested triple: $("""inner $(name) triple""")
    """

# Characters vs transpose operator
c1 = 'a'
c2 = '\''
c3 = '\\'
c4 = '\n'
c5 = '\u00e9'
c6 = '😀'
c7 = '\x41'
A = [1 2; 3 4]
At = A'
Att = A''
v = x'y
w = A'[1]
z = (A)' * 2
u = [1, 2]'

# Non-standard string literals
r1 = r"^\d+\.\d+$"i
r2 = r"no $interp and \n literal"
b1 = b"bytes \x00\xff"
raw1 = raw"C:\path\no\escapes $nope"
v1 = v"1.2.3"
big1 = big"123456789012345678901234567890"
html1 = html"<b>bold</b>"
md1 = md"# Markdown *string*"
sub1 = s"\1 replacement \g<name>"
cmd1 = `ls -la $dir`
cmd2 = `echo "quoted $(name)" 'single'`
cmd3 = ```triple backtick
command```
r3 = r"""
multi-line regex with "quotes"
"""

# Numbers
n1 = 1_000_000
n2 = 0xFF_FF
n3 = 0b1010
n4 = 0o17
n5 = 1.5e-3
n6 = 1.5f0
n7 = 1.5f-3
n8 = .5
n9 = 5.
n10 = 1e10
n11 = 0x1p4
n12 = 2im
n13 = 1.5im
n14 = 3//4
n15 = 2x + 3y
n16 = 1.5e3x
n17 = Inf32
n18 = NaN
n19 = 0x1.8p3

# Types and generics
abstract type Shape{T<:Real} end

struct Point{T<:Real} <: Shape{T}
    x::T
    y::T
end

mutable struct Counter
    count::Int
    Counter() = new(0)
end

@kwdef struct Config
    name::String = "default"
    size::Int = 10
    ratio::Float64 = 0.5
end

primitive type Byte 8 end

Point(x::T, y::T) where {T<:Integer} = Point{T}(x, y)
+(a::Point{T}, b::Point{T}) where T = Point(a.x + b.x, a.y + b.y)
norm2(p::Point) = sqrt(p.x^2 + p.y^2)
getindex(p::Point, i::Int) = i == 1 ? p.x : p.y

function show(io::IO, p::Point{T}) where {T}
    print(io, "Point{$T}($(p.x), $(p.y))")
end

const Vec{T} = Vector{T} where T
f(x::Union{Int,Nothing}=nothing; kw::Symbol=:default, kwargs...) = (x, kw, kwargs)
g(args...) = sum(args)
h = (x, y) -> x * y
k = x -> x^2
anon = function (a, b)
    a + b
end

# Operators
ops = (1 + 2, 1 - 2, 1 * 2, 1 / 2, 1 ÷ 2, 1 \ 2, 1 ^ 2, 1 % 2,
       1 == 2, 1 != 2, 1 ≠ 2, 1 ≤ 2, 1 ≥ 2, 1 === 2, 1 !== 2,
       true && false, true || false, !true, 1 & 2, 1 | 2, 1 ⊻ 2, ~1,
       1 << 2, 1 >> 2, 1 >>> 2, [1, 2] .+ 1, [1, 2] .* [3, 4], 1:10, 1:2:10)
x = 5
x += 1; x -= 1; x *= 2; x /= 2; x ^= 2; x .+= 1
pipe = [1, 2, 3] |> sum |> sqrt
comp = (sqrt ∘ abs)(-4)
symbols = (:sym, :+, :(a + b), Symbol("with space"), :end)
quoted = quote
    a = 1
    b = $x
end
ternary = x > 0 ? "pos" : x < 0 ? "neg" : "zero"
range = A[begin:end, end]

# Macros
@time sum(1:1000)
@show x y
@assert x > 0 "x must be positive: $x"
@inbounds for i in 1:10
    @simd for j in 1:10
        A[1] += i * j
    end
end
@macroexpand @show x
@views A[1, :]
@. y = sin(x) + cos(x)

macro mymacro(ex)
    return :( println("Expression: ", $(string(ex))); $(esc(ex)) )
end

@mymacro 1 + 2

# Control flow
for (i, v) in enumerate([10, 20, 30])
    i == 2 && continue
    println("$i => $v")
end
while x > 1
    x ÷= 2
end
let a = 1, b = 2
    a + b
end
begin
    local y = 10
    global z = y
end
try
    error("boom: $(x)")
catch e
    @warn "caught" exception = (e, catch_backtrace())
finally
    println("finally")
end
result = [i^2 for i in 1:10 if isodd(i)]
gen = (i for i in 1:3)
dict = Dict("a" => 1, :b => 2.0, 3 => 'c')
nt = (a = 1, b = "two")
do_block = map([1, 2, 3]) do x
    x * 2
end

end # module

#= block comment #= nested =# closed properly =# final_value = 42
