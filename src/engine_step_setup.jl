"""Сборка среды, один такт симуляции, цикл simulate."""

function _init_crossover_weights(task::AbstractTask)::Dict{Symbol, Float64}
    if task isa PollardFactoringTask
        n = length(task.crossover_ops)
        n <= 0 && return Dict{Symbol, Float64}(:average => 1.0)
        return Dict(op => inv(Float64(n)) for op in task.crossover_ops)
    end
    Dict{Symbol, Float64}(:mix => 1.0)
end

function build_environment(
    task::AbstractTask,
    st::Settings;
    N_init::Integer = 8,
    shared_N::BigInt = big(221),
    rng::AbstractRNG = default_rng(),
)::Environment
    nodes = Node[]
    next_id = UInt64(1)
    for _ = 1:Int(N_init)
        p = generate_random_params(task, Scar[]; rng = rng, shared_N = shared_N)
        n = Node(next_id, p; hp = st.default_hp, mp = st.default_mp, D = 0.5)
        warm_start!(task, n, st)
        push!(nodes, n)
        next_id += UInt64(1)
    end

    pq = PriorityQueue{Tuple{Event, UInt64}, Float64}()
    env = Environment(
        nodes,
        Scar[],
        pq,
        55.0,
        75.0,
        Vector{Float64}(st.metric_weights),
        _init_crossover_weights(task),
        Dict{Tuple{UInt64, UInt64}, Float64}(),
        UInt64(0),
        true,
        Channel{Event}(max(4, st.manual_channel_capacity)),
        next_id,
        UInt64(0),
        Float64[],
        Float64[],
        0,
        :running,
        Dict{Symbol, Float64}(),
        Dict{UInt64, Float64}(),
        Dict{UInt64, Tuple{Float64, Bool}}(),
        UInt64[],
        UInt64(0),
        UInt64(1),
        Float64[],
        Float64[],
        Dict{Symbol, Any}[],
        Dict{Symbol, Any}[],
        1.0,
        1.0,
        1.0,
        1,
        false,
    )
    return env
end

function _dispatch_event!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    if ev.type === SHOT
        handle_shot!(env, task, st, ev; rng = rng)
    elseif ev.type === HEAVY_SHOT
        handle_heavy_shot!(env, task, st, ev; rng = rng)
    elseif ev.type === RESONANCE
        handle_resonance!(env, task, st, ev; rng = rng)
    elseif ev.type === ANALYSIS
        handle_analysis_evt!(env, task, st, ev; rng = rng)
    else
        handle_manual!(env, task, st, ev; rng = rng)
    end
    nothing
end

function step!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    rng::AbstractRNG = default_rng(),
)
    drain_manual!(env, task, st; rng = rng)
    env.paused && return
    env.stop_reason !== :running && return

    rebuild_schedule!(env, task, st; rng = rng)
    if isempty(env.event_queue)
        env.tick += UInt64(1)
        return
    end
    pr = Base.popfirst!(env.event_queue)
    ev, _ = pr.first
    _dispatch_event!(env, task, st, ev; rng = rng)
    env.tick += UInt64(1)
    nothing
end

function simulate!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    max_ticks::Integer = 10^7,
    rng::AbstractRNG = default_rng(),
)::Environment
    while env.stop_reason === :running && env.tick < UInt64(max_ticks)
        step!(env, task, st; rng = rng)
    end
    return env
end
