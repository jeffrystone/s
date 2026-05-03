using Random

abstract type AbstractTask end

function evaluate(::AbstractTask, params::Dict{Symbol, Any}, ::Type{<:MetricLevel})::Tuple{Float64, Bool}
    error("implement evaluate for concrete task")
end

normalize(::AbstractTask, ::Type{<:MetricLevel}, raw::Float64)::Float64 =
    clamp(raw, 0.0, 1.0)

function crossover(::AbstractTask, pA::Dict{Symbol, Any}, pB::Dict{Symbol, Any}, op::Symbol; rng::AbstractRNG = Random.default_rng())::Dict{Symbol, Any}
    error("implement crossover for concrete task")
end

supports_embed(::AbstractTask)::Bool = false
embed(::AbstractTask, params::Dict{Symbol, Any})::Vector{Float64} =
    Float64[]

generate_random_params(::AbstractTask, ::Vector{Scar}; rng::AbstractRNG = Random.default_rng(), shared_N::BigInt, extreme_seed_fraction::Float64 = 0.0)::Dict{Symbol, Any} =
    error("implement generate_random_params for concrete task")



params_forbidden_by_scars(::AbstractTask, params::Dict{Symbol, Any}, scars::Vector{Scar})::Bool = false

"""Метаданные шрама после провала: center (Dict), radius, fail_level, decay_rate."""
function failure_scar_meta(::AbstractTask, params::Dict{Symbol, Any})
    return (Dict{Symbol,Any}(:sig => UInt64(objectid(params))), 0.01, 3, 0.01)
end

function eval_cache_key(::AbstractTask, ::Dict{Symbol, Any}, ::Type{<:MetricLevel})::Union{Nothing, UInt64}
    return nothing
end
