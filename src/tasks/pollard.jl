using Random

"""Pollard rho и быстрые эвристики для факторизации."""
struct PollardFactoringTask <: AbstractTask
    l5_max_iter::Int
    crossover_ops::Vector{Symbol}
end

PollardFactoringTask(; l5_max_iter::Int = 100_000) =
    PollardFactoringTask(l5_max_iter, [:swap_start, :swap_coeff, :average, :random_mid])

supports_embed(::PollardFactoringTask)::Bool = true

function embed(::PollardFactoringTask, params::Dict{Symbol, Any})::Vector{Float64}
    sx = Float64(get(params, :start_x, 2))
    pc = Float64(get(params, :poly_coeff, 1))
    return [sx / 1000.0, pc / 1000.0]
end

function params_forbidden_by_scars(::PollardFactoringTask, params::Dict{Symbol, Any}, scars::Vector{Scar})::Bool
    sx = get(params, :start_x, 2)
    pc = get(params, :poly_coeff, 1)
    for s in scars
        s.potential < 1e-3 && continue
        c = s.center
        if get(c, :start_x, sx) == sx && get(c, :poly_coeff, pc) == pc
            return true
        end
    end
    false
end

"""Мутирует `params[:_factor]` при успехе."""
function pollard_attempt!(params::Dict{Symbol, Any}, N::BigInt, start_x::BigInt, coeff::BigInt, max_iter::Int)::Tuple{Bool, Float64}
    delete!(params, :_factor)
    N <= BigInt(3) && return (false, 1.0)
    x::BigInt = mod(start_x, N)
    y::BigInt = x
    oneb = BigInt(1)
    for _ = 1:max_iter
        x = mod(x * x + coeff, N)
        y1 = mod(y * y + coeff, N)
        y = mod(y1 * y1 + coeff, N)
        d = gcd(abs(x - y), N)
        if oneb < d < N
            params[:_factor] = d
            return (true, 0.0)
        elseif d == N
            return (false, 0.93)
        end
    end
    return (false, 0.90)
end

function evaluate(::PollardFactoringTask, params::Dict{Symbol, Any}, ::Type{L1})::Tuple{Float64, Bool}
    Nval = big(get(params, :N, 1))
    for p in (2, 3, 5, 7, 11, 13, 17, 19)
        g = gcd(Nval, BigInt(p))
        if !isone(g)
            return (0.1, false)
        end
    end
    return (0.82, false)
end

function evaluate(task::PollardFactoringTask, params::Dict{Symbol, Any}, ::Type{L2})::Tuple{Float64, Bool}
    Nval = big(get(params, :N, 1))
    sx = BigInt(get(params, :start_x, 2))
    c = BigInt(get(params, :poly_coeff, 1))
    found, raw = pollard_attempt!(params, Nval, sx, c, 16)
    return (found ? 0.12 : raw, false)
end

function evaluate(task::PollardFactoringTask, params::Dict{Symbol, Any}, ::Type{L3})::Tuple{Float64, Bool}
    Nval = big(get(params, :N, 1))
    sx = BigInt(get(params, :start_x, 2))
    c = BigInt(get(params, :poly_coeff, 1))
    found, raw = pollard_attempt!(params, Nval, sx, c, 320)
    return (found ? 0.08 : raw, false)
end

function evaluate(task::PollardFactoringTask, params::Dict{Symbol, Any}, ::Type{L4})::Tuple{Float64, Bool}
    Nval = big(get(params, :N, 1))
    sx = BigInt(get(params, :start_x, 2))
    c = BigInt(get(params, :poly_coeff, 1))
    found, raw = pollard_attempt!(params, Nval, sx, c, 3200)
    return (found ? 0.04 : raw, false)
end

function evaluate(task::PollardFactoringTask, params::Dict{Symbol, Any}, ::Type{L5})::Tuple{Float64, Bool}
    delete!(params, :_factor)
    Nval = big(get(params, :N, 1))
    sx = BigInt(get(params, :start_x, 2))
    c = BigInt(get(params, :poly_coeff, 1))
    ok, raw = pollard_attempt!(params, Nval, sx, c, task.l5_max_iter)
    ok && return (0.0, true)
    return (raw, false)
end

function crossover(::PollardFactoringTask, pA::Dict{Symbol, Any}, pB::Dict{Symbol, Any}, op::Symbol; rng::AbstractRNG = Random.default_rng())::Dict{Symbol, Any}
    child = copy(pA)
    if op == :swap_start
        child[:start_x] = get(pB, :start_x, get(child, :start_x, 2))
    elseif op == :swap_coeff
        child[:poly_coeff] = get(pB, :poly_coeff, get(child, :poly_coeff, 1))
    elseif op == :average
        child[:start_x] = (get(pA, :start_x, 2) + get(pB, :start_x, 2)) ÷ 2
        child[:poly_coeff] = (get(pA, :poly_coeff, 1) + get(pB, :poly_coeff, 1)) ÷ 2
    elseif op == :random_mid
        child[:start_x] = rand(rng, [get(pA, :start_x, 2), get(pB, :start_x, 2)])
        child[:poly_coeff] = rand(rng, [get(pA, :poly_coeff, 1), get(pB, :poly_coeff, 1)])
    end
    child
end

function failure_scar_meta(::PollardFactoringTask, params::Dict{Symbol, Any})
    c = Dict{Symbol,Any}(
        :start_x => get(params, :start_x, 2),
        :poly_coeff => get(params, :poly_coeff, 1),
    )
    # радиус в пространстве embed (простая эвристика)
    (c, 0.06, 5, 0.00025)
end

function generate_random_params(task::PollardFactoringTask, scars::Vector{Scar}; rng::AbstractRNG = Random.default_rng(), shared_N::BigInt)::Dict{Symbol, Any}
    local p::Dict{Symbol, Any}
    for _ = 1:800
        p = Dict{Symbol,Any}(
            :N => shared_N,
            :start_x => rand(rng, 2:99_999),
            :poly_coeff => rand(rng, 1:999),
        )
        params_forbidden_by_scars(task, p, scars) || break
    end
    p
end
