using JSON3
using Statistics: mean

"""Serialize environment to JSON-compatible structures."""

function json_safe(val)
    val isa Dict && return Dict(string(k) => json_safe(v) for (k, v) in val)
    val isa AbstractVector &&
        !(val isa Vector{UInt8}) &&
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
        id = UInt64(s.id),
        center = json_safe(Dict(pairs(s.center))),
        radius = s.radius,
        potential = scar_potential(s, tick),
        fail_level = s.fail_level,
        decay_rate = s.decay_rate,
        last_update = s.last_update,
    )
end

function sample_cpu_per_core()::Vector{Float64}
    nt = Sys.CPU_THREADS
    v = zeros(Float64, nt)
    if !Sys.iswindows()
        return v
    end
    try
        io = IOBuffer()
        run(pipeline(`wmic`, `cpu`, `get`, `loadpercentage`; stdout = io); wait = true)
        txt = String(take!(io))
        pct::Float64 = 0.0
        ok = false
        for line in split(txt, '\n'; keepempty = false)
            line = strip(line)
            isempty(line) && continue
            occursin(r"^[A-Za-z]", line) && continue
            m = match(r"^(\d+)$", line)
            m !== nothing || continue
            pct = clamp(parse(Float64, m.captures[1]), 0.0, 100.0)
            ok = true
            break
        end
        if ok
            f = pct / 100.0
            v .= f
        end
    catch
    end
    return v
end

function state_snapshot(env::Environment)::Dict{Symbol, Any}
    lid =
        isempty(env.nodes) ? nothing :
        argmin([n.D for n in env.nodes])
    leader = lid === nothing ? nothing : serialize_node(env.nodes[lid])

    cpu = sample_cpu_per_core()

    cw = Dict{String, Float64}(string(k) => Float64(v) for (k, v) in env.crossover_weights)

    r = env.recent_events
    lo = max(1, length(r) - min(24, length(r)) + 1)
    rev = Dict{String, Any}[json_safe(copy(d)) for d in r[lo:end]]

    a = env.manual_audit
    loa = max(1, length(a) - min(12, length(a)) + 1)
    aud_tail = Dict{String, Any}[json_safe(copy(d)) for d in a[loa:end]]

    return Dict{Symbol, Any}(
        :tick => env.tick,
        :t_wall_ms => UInt64(round(time() * 1_000)),
        :stop_reason => string(env.stop_reason),
        :paused => env.paused,
        :exploitation_budget => env.exploitation_budget,
        :exploration_budget => env.exploration_budget,
        :metric_weights => copy(env.metric_weights),
        :mean_D => isempty(env.nodes) ? 0.0 : mean(n.D for n in env.nodes),
        :leader_node => leader,
        :attention_tune_alpha => env.attention_tune_alpha,
        :attention_tune_beta => env.attention_tune_beta,
        :attention_tune_gamma => env.attention_tune_gamma,
        :crossover_weights => cw,
        :nodes => [serialize_node(n) for n in env.nodes],
        :scars => [serialize_scar(s, UInt64(env.tick)) for s in env.scars],
        :cpu_usage_per_core => cpu,
        :event_time_s => Dict(string(k) => Float64(v) for (k, v) in env.event_time_s),
        :per_node_time_s =>
            Dict(string(UInt64(id)) => Float64(v) for (id, v) in env.per_node_time_s),
        :metric_l34_buffer_len => length(env.metric_l34_n3),
        :recent_events => rev,
        :manual_audit_tail => aud_tail,
        :mean_D_history => Float64[D for D in env.d_history],
    )
end

function snapshot_json(env::Environment)::String
    JSON3.write(state_snapshot(env))
end
