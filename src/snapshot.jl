using JSON3
using Statistics: mean

"""Serialize environment to JSON-compatible structures."""

function json_safe(val)
    val isa Dict && return Dict(string(k) => json_safe(v) for (k, v) in val)
    val isa AbstractVector &&
        !(val isa Vector{UInt8}) &&
        !isempty(val) &&
        !(val isa String) &&
        return [json_safe(x) for x in val]
    val isa Tuple && return Any[json_safe(x) for x in val]
    val isa BigInt && return string(val)
    val isa Symbol && return string(val)
    val isa Integer && !isa(val, BigInt) && return val
    val isa AbstractFloat && return Float64(val)
    val isa String && return val
    val isa Bool && return val
    val === nothing && return nothing
    return string(val)
end

function serialize_node(n::Node)
    return (
        id = UInt64(n.id),
        hp = n.hp,
        mp = n.mp,
        dissonance = n.D,
        active = n.active,
        mp_frozen = n.mp_frozen,
        resonance_streak = n.resonance_win_streak,
        params = json_safe(Dict(pairs(n.params))),
    )
end

function serialize_scar(s::Scar, tick::UInt64)
    (
        center = json_safe(Dict(pairs(s.center))),
        radius = s.radius,
        potential = scar_potential(s, tick),
        fail_level = s.fail_level,
        decay_rate = s.decay_rate,
        last_update = s.last_update,
    )
end

function state_snapshot(env::Environment)::Dict{Symbol, Any}
    return Dict{Symbol, Any}(
        :tick => env.tick,
        :stop_reason => string(env.stop_reason),
        :exploitation_budget => env.exploitation_budget,
        :exploration_budget => env.exploration_budget,
        :metric_weights => copy(env.metric_weights),
        :mean_D => isempty(env.nodes) ? 0.0 : mean(n.D for n in env.nodes),
        :nodes => [serialize_node(n) for n in env.nodes],
        :scars => [serialize_scar(s, UInt64(env.tick)) for s in env.scars],
    )
end

function snapshot_json(env::Environment)::String
    JSON3.write(state_snapshot(env))
end
