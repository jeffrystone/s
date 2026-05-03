using Random
using LinearAlgebra: dot, norm
using Statistics: mean
using DataStructures: isempty, PriorityQueue

"""Planner and simulation helpers (cold start, shots, resonance, analysis). ASCII comments."""
const _LEVELS = (L1, L2, L3, L4, L5)

function recompute_D!(node::Node, mw::AbstractVector)
    node.D = clamp(dot(mw, node.metric_components), 0.0, 1.0)
end

function apply_metric_once!(task::AbstractTask, node::Node, ::Type{L}, mw::AbstractVector; record::Bool) where {L<:MetricLevel}
    raw, _ = evaluate(task, node.params, L)
    idx = level_index(L)
    nrm = normalize(task, L, raw)
    node.metric_components[idx] = nrm
    recompute_D!(node, mw)
    record && push!(node.mutation_history, (nameof(L), nrm))
    delete!(node.params, :_factor)
end

function warm_start!(task::AbstractTask, node::Node, settings::Settings)
    mw = Vector{Float64}(settings.metric_weights)
    apply_metric_once!(task, node, L1, mw; record = false)
    apply_metric_once!(task, node, L2, mw; record = false)
end

effcost(settings::Settings, k::Int, cold::Bool) =
    cold && k <= 2 ? 0.0 : Float64(settings.cost[k])

function choose_shot_level(node::Node, settings::Settings, cold::Bool)
    for k in 1:5
        node.hp >= effcost(settings, k, cold) && return _LEVELS[k]
    end
    return nothing
end

function enqueue_evt!(env::Environment, ev::Event, pr::Float64)
    env.schedule_seq += UInt64(1)
    Base.push!(env.event_queue, (ev, env.schedule_seq) => queue_key(pr, env.schedule_seq))
end

function clear_events!(env::Environment)
    while !isempty(env.event_queue)
        Base.popfirst!(env.event_queue)
    end
end

scar_potential(s::Scar, t::UInt64) =
    max(0.0, s.potential * exp(-s.decay_rate * Float64(max(t, s.last_update) - s.last_update)))

function strong_scar_near(task::AbstractTask, env::Environment, node::Node)
    supports_embed(task) || return false
    evec = embed(task, node.params)
    isempty(evec) && return false
    tn = UInt64(env.tick)
    for s in env.scars
        scar_potential(s, tn) < 0.25 && continue
        ce = zeros(length(evec))
        for (k, vv) in s.center
            if k == :start_x && length(ce) >= 1
                ce[1] = Float64(vv) / 1000
            elseif k == :poly_coeff && length(ce) >= 2
                ce[2] = Float64(vv) / 1000
            end
        end
        norm(evec - ce) <= s.radius && return true
    end
    false
end

res_candidates(env::Environment, nid::UInt64) =
    UInt64[m.id for m in env.nodes if m.id != nid && m.mp > 0]

function fetch_node(nodes::Vector{Node}, id::UInt64)
    i = findfirst(n -> n.id == id, nodes)
    i === nothing ? nothing : nodes[i]
end

function pick_partner(task::AbstractTask, env::Environment, a::UInt64, cand::Vector{UInt64}, rng::AbstractRNG, st::Settings)
    na = fetch_node(env.nodes, a)
    @assert na !== nothing && !isempty(cand)
    best = cand[1]
    bests = Inf
    use_emb = supports_embed(task)
    va = use_emb ? embed(task, na.params) : Float64[]
    denom = env.exploitation_budget + env.exploration_budget
    n_amp = denom > 0 ? env.exploration_budget / denom : 0.5
    for bid in cand
        nb = fetch_node(env.nodes, bid)
        nb === nothing && continue
        key = (min(a, bid), max(a, bid))
        mem = get(env.resonance_memory, key, 0.35)
        dmem = st.attention_gamma * (1 - clamp(mem, 0.0, 1.0))
        dist =
            use_emb && !isempty(va) ? st.attention_alpha * norm(va - embed(task, nb.params)) :
            rand(rng)
        suf = rand(rng) * st.attention_beta
        jitter = randn(rng) * n_amp * 0.15
        sc = dist + suf + dmem + jitter
        if sc < bests
            bests = sc
            best = bid
        end
    end
    best
end

function wsample(rng::AbstractRNG, ops::Vector{Symbol}, wt::Vector{Float64})::Symbol
    s = sum(wt)
    r = rand(rng) * max(s, eps())
    acc = 0.0
    for i in eachindex(ops)
        acc += max(wt[i], 0)
        if r <= acc
            return ops[i]
        end
    end
    ops[end]
end

function offspring_n(hpA::Float64, mpB::Float64)::Int
    clamp(round(Int, log(2 + hpA) * sqrt(max(mpB, 0.01))), 1, 36)
end

function ll_score(task::AbstractTask, ch::Dict{Symbol, Any}, mw::Vector{Float64})::Float64
    r1, _ = evaluate(task, ch, L1)
    r2, _ = evaluate(task, ch, L2)
    delete!(ch, :_factor)
    return mw[1] * normalize(task, L1, r1) + mw[2] * normalize(task, L2, r2)
end

function resonance_pr(env::Environment, st::Settings, a::UInt64, b::UInt64)::Float64
    st.attention_gamma * 0.65 * get(env.resonance_memory, (min(a, b), max(a, b)), 0.35)
end

"""Scar rupture when D < 0.2 in scar region."""
function rupture_scars!(env::Environment, task::AbstractTask, node::Node, st::Settings)
    node.D >= 0.2 && return
    if supports_embed(task)
        ev = embed(task, node.params)
        isempty(ev) && return
        k = length(env.scars)
        while k >= 1
            sc = env.scars[k]
            p = scar_potential(sc, env.tick)
            p <= st.scar_eps && (deleteat!(env.scars, k); k -= 1; continue)
            ce = zeros(length(ev))
            for (kk, vv) in sc.center
                kk == :start_x && length(ce) >= 1 && (ce[1] = Float64(vv) / 1000)
                kk == :poly_coeff && length(ce) >= 2 && (ce[2] = Float64(vv) / 1000)
            end
            if norm(ev - ce) < sc.radius
                deleteat!(env.scars, k)
            end
            k -= 1
        end
    else
        k = length(env.scars)
        while k >= 1
            sc = env.scars[k]
            p = scar_potential(sc, env.tick)
            p <= st.scar_eps && (deleteat!(env.scars, k); k -= 1; continue)
            matched = true
            for (key, vv) in sc.center
                if get(node.params, key, nothing) != vv
                    matched = false
                    break
                end
            end
            matched && deleteat!(env.scars, k)
            k -= 1
        end
    end
end

function analysis_pass!(env::Environment, task::AbstractTask, st::Settings; rng::AbstractRNG = Random.default_rng())
    tnow = env.tick
    newsc = Scar[]
    for s in env.scars
        p = scar_potential(s, tnow)
        if p > st.scar_eps
            push!(
                newsc,
                Scar(copy(s.center), s.radius, p, s.fail_level, s.decay_rate, tnow),
            )
        end
    end
    env.scars[:] = newsc

    keep = Node[]
    epsd = 1e-6
    for n in env.nodes
        if n.hp <= epsd && n.mp <= epsd && !n.mp_frozen
            continue
        end
        if n.mp_frozen && n.resonance_win_streak >= 4
            n.mp_frozen = false
            n.mp += 5.0
            n.resonance_win_streak = 0
        end
        push!(keep, n)
    end
    env.nodes[:] = keep

    avgD = isempty(env.nodes) ? 0.0 : mean(n.D for n in env.nodes)
    push!(env.d_history, avgD)
    while length(env.d_history) > st.stuck_window
        popfirst!(env.d_history)
    end
    if length(env.d_history) >= 2
        oldm = mean(view(env.d_history, 1:length(env.d_history) - 1))
        newm = env.d_history[end]
        if newm >= oldm - 1e-3
            env.stuck_counter += 1
        else
            env.stuck_counter = 0
        end
        if env.stuck_counter >= st.stuck_ticks
            tr = st.exploration_transfer * env.exploitation_budget
            env.exploration_budget += tr
            env.exploitation_budget = max(0.0, env.exploitation_budget - tr)
            env.stuck_counter = 0
        end
        if newm < oldm - 0.02
            env.exploitation_budget += 2.0
        end
    end

    for n in env.nodes
        n.D < 0.2 && rupture_scars!(env, task, n, st)
    end

    if !isempty(env.nodes) && rand(rng) < 0.08
        mw = env.metric_weights
        mw[3] *= 0.99
        mw[4] *= 1.005
        sm = sum(mw)
        sm > 0 && (mw ./= sm)
    end
end

function rebuild_schedule!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    rng::AbstractRNG = Random.default_rng(),
)
    clear_events!(env)
    cold = env.tick < st.cold_start_ticks
    mw = env.metric_weights

    if cold
        denom = env.exploitation_budget + env.exploration_budget
        if denom <= 1e-6
            env.exploration_budget = 100.0
            env.exploitation_budget = 0.0
        else
            t = denom
            env.exploration_budget = t
            env.exploitation_budget = 0.0
        end
    end

    if env.tick > 0 && env.tick % st.analysis_interval == 0
        enqueue_evt!(
            env,
            Event(ANALYSIS),
            Float64(st.analysis_priority_quantum),
        )
    end

    for na in env.nodes
        na.active || continue

        lk = choose_shot_level(na, st, cold)
        if lk !== nothing
            ik = level_index(lk)
            pr = (1.0 - clamp(na.D, 0.0, 1.0)) * max(na.hp, 1e-6) * mw[ik]
            enqueue_evt!(env, Event(SHOT; node_id = na.id), pr)
        end

        if !cold &&
           na.hp >= st.heavy_shot_hp_min &&
           na.D <= st.D_thresh_heavy &&
           !strong_scar_near(task, env, na)
            prh =
                (1.0 - clamp(na.D, 0.0, 1.0)) *
                max(na.hp, 1e-6) *
                mw[5] * 1.2
            enqueue_evt!(env, Event(HEAVY_SHOT; node_id = na.id), prh)
        end

        if !cold && na.hp > 1 && na.mp > 0 && !na.mp_frozen
            cand = res_candidates(env, na.id)
            if !isempty(cand)
                bid =
                    supports_embed(task) ?
                    pick_partner(task, env, na.id, cand, rng, st) :
                    cand[rand(rng, 1:length(cand))]
                nb = fetch_node(env.nodes, bid)
                if nb !== nothing
                    mut = clamp((na.D + nb.D) / 2, 0.0, 1.0)
                    pr =
                        mut *
                        (na.mp + nb.mp) *
                        0.04 *
                        (1.2 + resonance_pr(env, st, na.id, bid))
                    enqueue_evt!(
                        env,
                        Event(
                            RESONANCE;
                            node_id = na.id,
                            partner_id = bid,
                        ),
                        pr,
                    )
                end
            end
        end
    end
end

function handle_shot!(env::Environment, task::AbstractTask, st::Settings, ev::Event)
    cold = env.tick < st.cold_start_ticks
    na = fetch_node(env.nodes, ev.node_id)
    na === nothing && return
    lk = choose_shot_level(na, st, cold)
    lk === nothing && return

    appeal_l34!(task, env, na, st, lk, cold)

    apply_metric_once!(task, na, lk, env.metric_weights; record = true)
    k = level_index(lk)
    na.hp = max(0.0, na.hp - effcost(st, k, cold))
    rupture_scars!(env, task, na, st)
end

"""If L4 looks much worse than a fresh cheap L3 re-check, pay for L5 one-off or trim metric_weights (stub)."""
function appeal_l34!(
    task::AbstractTask,
    env::Environment,
    na::Node,
    st::Settings,
    lk::Type{<:MetricLevel},
    cold::Bool,
)
    !(lk <: L4) && return
    cold && return
    if na.hp < effcost(st, 5, false) + 5.0
        return
    end
    p0 = Dict{Symbol, Any}(pairs(na.params))
    r3, _ = evaluate(task, copy(p0), L3)
    n3 = normalize(task, L3, r3)
    r5, succ = evaluate(task, copy(p0), L5)
    delete!(p0, :_factor)
    if succ || r5 <= 0.25
        return
    end
    n5 = normalize(task, L5, r5)
    gap = max(0.0, n5 - n3)
    gap < 0.25 && return

    mw = env.metric_weights
    if gap > 0.45 && mw[3] > 1e-3
        mw[3] = max(0.0, mw[3] * 0.97)
        s = sum(mw)
        s > 0 && (mw ./= s)
        na.hp = max(0.0, na.hp - 60.0)
    else
        na.hp = max(0.0, na.hp - 90.0)
    end
end

function handle_heavy_shot!(env::Environment, task::AbstractTask, st::Settings, ev::Event)
    cold = env.tick < st.cold_start_ticks
    cold && return

    na = fetch_node(env.nodes, ev.node_id)
    na === nothing && return
    na.hp >= st.heavy_shot_hp_min || return
    na.D <= st.D_thresh_heavy || return
    strong_scar_near(task, env, na) && return

    D0 = na.D
    raw, ok = evaluate(task, na.params, L5)
    na.metric_components[5] = normalize(task, L5, raw)
    recompute_D!(na, env.metric_weights)
    push!(na.heavy_shots, (D0, ok))

    na.hp = max(0.0, na.hp - effcost(st, 5, cold))

    if ok
        env.stop_reason = :factor_found
    else
        na.hp = min(na.hp, 15.0)
        na.mp_frozen = true
        na.resonance_win_streak = 0
        if UInt64(env.tick) >= UInt64(st.cold_start_ticks)
            c, radius, fail_l, decay = failure_scar_meta(task, na.params)
            push!(env.scars, Scar(c, radius, 1.0, fail_l, decay, UInt64(env.tick)))
        end
    end
    rupture_scars!(env, task, na, st)
end

function child_outperforms_parents(childD::Float64, da::Float64, db::Float64)::Bool
    avg = (da + db) / 2.0
    childD < avg || childD <= min(da, db) + 0.05
end

function handle_resonance!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    na = fetch_node(env.nodes, ev.node_id)
    nb = fetch_node(env.nodes, ev.partner_id)
    (na === nothing || nb === nothing) && return

    cand = res_candidates(env, na.id)
    ev.partner_id ∈ cand || return

    ops =
        isempty(env.crossover_weights) ? [:swap_start, :swap_coeff, :average, :random_mid] :
        Symbol[k for (k, _) in env.crossover_weights]

    isempty(ops) && append!(ops, [:swap_start, :swap_coeff])

    wt = Float64[get(env.crossover_weights, o, 1.0) for o in ops]
    mw = env.metric_weights
    Noffs = offspring_n(Float64(na.hp), Float64(nb.mp))

    best::Union{Nothing, Dict{Symbol, Any}} = nothing
    best_score = Inf

    for _ = 1:Noffs
        op = wsample(rng, ops, wt)
        ch = crossover(task, na.params, nb.params, op; rng = rng)
        params_forbidden_by_scars(task, ch, env.scars) && continue
        chi = Dict{Symbol, Any}(pairs(ch))
        sc = ll_score(task, chi, mw)
        if sc < best_score
            best_score = sc
            best = chi
        end
    end
    best === nothing && return

    na.mp = max(0.0, na.mp - 6.0)
    nb.mp = max(0.0, nb.mp - 10.0)
    na.hp = max(0.0, na.hp - 9.0)

    child_hp = max(26.0, st.default_hp * 0.45)
    child_mp = max(20.0, st.default_mp * 0.5)
    ch_node = Node(env.next_id, best; hp = child_hp, mp = child_mp)
    env.next_id += UInt64(1)

    warm_start!(task, ch_node, st)
    push!(env.nodes, ch_node)

    tax = clamp(10.0 * (1.0 - clamp(ch_node.D, 0.0, 1.0)), 1.5, 30.0)
    ch_node.hp = max(0.0, ch_node.hp - tax)

    den = env.exploitation_budget + env.exploration_budget
    fr = den > 0 ? clamp(env.exploitation_budget / den, 0.0, 1.0) : 0.5
    env.exploration_budget += tax * fr

    improving = child_outperforms_parents(ch_node.D, na.D, nb.D)

    rk = (min(ev.node_id, ev.partner_id), max(ev.node_id, ev.partner_id))
    mv = get(env.resonance_memory, rk, 0.45)
    if improving
        na.resonance_win_streak += 1
        nb.resonance_win_streak += 1
        env.resonance_memory[rk] = clamp(mv + 0.06, 0.0, 1.0)
        nb.mp_frozen && (nb.hp += 5.5)
        na.mp_frozen && (na.hp += 5.5)
    else
        env.resonance_memory[rk] = clamp(mv - 0.04, 0.0, 1.0)
    end
end

function handle_analysis_evt!(env::Environment, task::AbstractTask, st::Settings; rng::AbstractRNG = Random.default_rng())
    analysis_pass!(env, task, st; rng = rng)
end

function handle_manual!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    Symbol(get(ev.payload, :action, :noop)) === :add_node || return
    raw_params = get(ev.payload, :params, nothing)
    raw_params === nothing && return
    p::Dict{Symbol, Any} = Dict{Symbol, Any}(pairs(raw_params))
    hp = Float64(get(ev.payload, :hp, st.default_hp))
    mp = Float64(get(ev.payload, :mp, st.default_mp))
    nid = env.next_id
    env.next_id += UInt64(1)
    n = Node(nid, p; hp = hp, mp = mp)
    warm_start!(task, n, st)
    push!(env.nodes, n)
end

function drain_manual!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    rng::AbstractRNG = Random.default_rng(),
)
    while isready(env.manual_events)
        ev = take!(env.manual_events)
        handle_manual!(env, task, st, ev; rng = rng)
    end
end

function step!(env::Environment, task::AbstractTask, st::Settings; rng::AbstractRNG = Random.default_rng())
    env.stop_reason == :factor_found && return env

    drain_manual!(env, task, st; rng)
    rebuild_schedule!(env, task, st; rng)

    if isempty(env.event_queue)
        env.tick += UInt64(1)
        return env
    end

    pr = Base.popfirst!(env.event_queue)
    ev, _ = pr.first

    if ev.type == SHOT
        handle_shot!(env, task, st, ev)
    elseif ev.type == HEAVY_SHOT
        handle_heavy_shot!(env, task, st, ev)
    elseif ev.type == RESONANCE
        handle_resonance!(env, task, st, ev; rng)
    elseif ev.type == ANALYSIS
        handle_analysis_evt!(env, task, st; rng)
    elseif ev.type == MANUAL
        handle_manual!(env, task, st, ev; rng)
    end

    env.tick += UInt64(1)

    env
end

function build_environment(
    task::AbstractTask,
    st::Settings;
    N_init::Int = 6,
    shared_N::BigInt = BigInt(14_723),
    rng::AbstractRNG = Random.default_rng(),
)
    pq = PriorityQueue{Tuple{Event,UInt64},Float64}()
    ch = Channel{Event}(max(1, st.manual_channel_capacity))
    scar0 = Scar[]
    nodes = Node[]
    next_id::UInt64 = 1

    cw = Dict{Symbol,Float64}(
        :swap_start => 1.0,
        :swap_coeff => 1.2,
        :average => 0.9,
        :random_mid => 0.8,
    )

    mw = Vector{Float64}(st.metric_weights)
    mw ./= sum(mw)

    for _ = 1:N_init
        p = generate_random_params(task, Scar[]; rng = rng, shared_N = shared_N)::Dict{
            Symbol,
            Any,
        }
        n = Node(next_id, p; hp = st.default_hp, mp = st.default_mp)
        warm_start!(task, n, st)
        push!(nodes, n)
        next_id += UInt64(1)
    end

    env = Environment(
        nodes,
        scar0,
        pq,
        52.0,
        72.0,
        mw,
        cw,
        Dict{Tuple{UInt64,UInt64},Float64}(),
        UInt64(0),
        false,
        ch,
        next_id,
        UInt64(0),
        Float64[],
        0,
        :running,
    )

    env
end

function simulate!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    max_steps::Int = 10_000,
    rng::AbstractRNG = Random.default_rng(),
)::Environment
    for _ = 1:max_steps
        env.stop_reason == :factor_found && break
        step!(env, task, st; rng)
    end
    env
end
