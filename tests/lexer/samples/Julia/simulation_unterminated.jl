#!/usr/bin/env julia
# Second Julia sample: simulation code, ends inside an unterminated nested block comment.

using Random
using Printf
using Statistics: mean, std

Random.seed!(0x2A)

"""
    Particle{T}

A particle with position `pos` and velocity `vel`. Units are \$m\$ and \$m/s\$.
"""
mutable struct Particle{T<:AbstractFloat}
    pos::Vector{T}
    vel::Vector{T}
    mass::T
end

Particle(dim::Int; T::Type=Float64) = Particle{T}(rand(T, dim), randn(T, dim) .* T(0.1), one(T))

struct World{T}
    particles::Vector{Particle{T}}
    gravity::Vector{T}
    dt::T
end

function World(n::Integer; dim=2, dt=1e-2, g=-9.81)
    ps = [Particle(dim) for _ in 1:n]
    grav = zeros(dim)
    grav[end] = g
    World{Float64}(ps, grav, dt)
end

function step!(w::World{T}) where {T}
    @inbounds for p in w.particles
        p.vel .+= w.gravity .* w.dt
        p.pos .+= p.vel .* w.dt
        for d in eachindex(p.pos)
            if p.pos[d] < zero(T)
                p.pos[d] = -p.pos[d]
                p.vel[d] = -p.vel[d] * T(0.9)
            elseif p.pos[d] > one(T)
                p.pos[d] = 2one(T) - p.pos[d]
                p.vel[d] *= -0.9
            end
        end
    end
    return w
end

energy(p::Particle) = 0.5 * p.mass * sum(abs2, p.vel)
energy(w::World) = sum(energy, w.particles)

function simulate(n_steps::Int=1_000; n=100, verbose::Bool=false)
    w = World(n)
    energies = Vector{Float64}(undef, n_steps)
    for i in 1:n_steps
        step!(w)
        energies[i] = energy(w)
        if verbose && i % 100 == 0
            @printf("step %5d  E = %.6e  mean x = %.3f\n", i, energies[i], mean(p.pos[1] for p in w.particles))
        end
    end
    return energies
end

const HEADER = """
    Simulation report
    =================
    Particles:   $(100)
    Generated:   $(round(Int, time()))
    Literal:     \$(not interpolated)
    """

function report(es::AbstractVector{<:Real})
    println(HEADER)
    println("min = $(minimum(es)), max = $(maximum(es))")
    println("mean ± std = $(round(mean(es), digits=3)) ± $(round(std(es), sigdigits=2))")
    println("ratio = ", es[end] / es[1], " (final/initial)")
    s = join(["$(i):$(round(e; digits=2))" for (i, e) in enumerate(es[1:5])], ", ")
    println("first five: [$s]")
end

# Matrix literals, adjoints, broadcasting
M = [1.0 2.0 3.0
     4.0 5.0 6.0
     7.0 8.0 10.0]
Mt = M'
inv_check = M * inv(M) ≈ I(3)
v = M[:, 1]'
w = M'M
cols = [M[:, j]' for j in axes(M, 2)]
dot_ops = M .^ 2 .- 1 ./ (M .+ eps())
strings_with_quotes = ["it's", "\"dq\"", 'c', 'x'']

# Multiple dispatch with parametric types
describe(x::Number) = "number $x"
describe(x::AbstractString) = "string \"$x\""
describe(x::AbstractVector{T}) where {T<:Number} = "vector of $(T) with $(length(x)) elements"
describe(::Nothing) = "nothing"
describe(x) = "something: $(typeof(x))"

for x in (1, 2.5, "s", [1, 2], nothing, :sym, 'c', 1//2, 3im)
    println(describe(x))
end

# Keyword args, splatting, named tuples
opts = (verbose = true, n = 10)
es = simulate(200; opts...)
report(es)

# String macros and command literals
pattern = r"(?<num>\d+)\s*(?<unit>[a-z]+)"x
m = match(pattern, "42 kg")
m !== nothing && println("num=$(m[:num]) unit=$(m["unit"])")
cmd = `julia --version`
fmt = Printf.Format("%08.3f|%-5s|%x\n")
Printf.format(stdout, fmt, π, "pi", 255)

# Unicode identifiers and operators
α = 0.5
β₁ = 2α
Δt = 1e-3
x̄ = mean([1, 2, 3])
∑(xs) = sum(xs)
a ⊗ b = kron(a, b)
√2, ∛27, 2 ∈ [1, 2], 3 ∉ [1, 2], [1] ⊆ [1, 2]

# Numeric edge cases
nums = [0x0, 0xff, 0b1, 0o7, 1_0, 1e0, 1E0, 1f0, 1.0e-10, .1, 1., 0x1p0, 0x.8p1]
juxt = 2π + 3x̄ - 4(α + 1) + 5.0e-1β₁
rationals = 1//3 + 2//3
complexes = 1 + 2im, 3.0im, im^2

# Interpolation edge cases at line boundaries
multi_interp = "value: $(
    1 + 2
) spans lines"
nested_quotes = "outer $(join(["a", "b"], "\", \"")) outer"
dollar_end = "ends with dollar \$"
var_then_text = "$(α)x and $α and $(β₁)"
triple_interp = """
    $(round(mean([1, 2, 3]); digits = 2)) and "$(join(1:3, ","))"
    """
transpose_after_string = ["a" "b"]'
char_vs_adjoint = [x' for x in eachcol(M)]

#= This block comment opens and nests but never balances.
   #= second level
      #= third level =#
   back to second =#
   still first level:
   function not_code()
       "string inside comment $(x)"
   end
   end of file reached inside a block comment
