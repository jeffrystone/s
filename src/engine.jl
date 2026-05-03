using Random
using LinearAlgebra: dot, norm
using Statistics: mean, cor, std
using DataStructures: isempty, PriorityQueue
using NearestNeighbors: KDTree, knn

"""Planner and simulation helpers (cold start, shots, resonance, analysis). ASCII comments."""
const _LEVELS = (L1, L2, L3, L4, L5)

function event_time_symbol(t::EventType)::Symbol
    t === SHOT && return :shot
    t === HEAVY_SHOT && return :heavy_shot
    t === RESONANCE && return :resonance
    t === ANALYSIS && return :analysis
    t === MANUAL && return :manual
    return :unknown
end

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

function eval_maybe_cached(task::AbstractTask, env::Environment, st::Settings, params::Dict{Symbol, Any}, ::Type{L}) where {L}
    key = eval_cache_key(task, params, L)
    if !(st.evaluate_cache_enabled && key !== nothing)
        return evaluate(task, params, L)
    end
    k = UInt64(key)
    haskey(env.eval_cache, k) && return env.eval_cache[k]
    out = evaluate(task, params, L)
    while length(env.eval_cache) >= st.evaluate_cache_max && !isempty(env.eval_cache_order)
        old = popfirst!(env.eval_cache_order)
        delete!(env.eval_cache, old)
    end
    env.eval_cache[k] = out
    push!(env.eval_cache_order, k)
    return out
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

function push_metric_l34_pair!(env::Environment, st::Settings, n3::Float64, n4::Float64)
    push!(env.metric_l34_n3, clamp(n3, 0.0, 1.0))
    push!(env.metric_l34_n4, clamp(n4, 0.0, 1.0))
    cap = max(4, st.analysis_calibration_buffer_max)
    while length(env.metric_l34_n3) > cap
        popfirst!(env.metric_l34_n3)
        popfirst!(env.metric_l34_n4)
    end
end

"""§4.5: корреляция пар L3 vs L4 и перекос между уровнями → подстройка `metric_weights[3:4]`."""
function maybe_calibration_l34_weights!(env::Environment, st::Settings)
    nw = env.metric_weights
    n3v = env.metric_l34_n3
    n4v = env.metric_l34_n4
    length(n3v) == length(n4v) || return
    length(n3v) < st.analysis_calibration_min_samples && return

    n3 = copy(n3v)
    n4 = copy(n4v)
    σ3 = std(n3)
    σ4 = std(n4)
    ρ = (σ3 < 1e-8 || σ4 < 1e-8) ? 0.0 : Float64(cor(n3, n4))
    ρ = clamp(ρ, -1.0, 1.0)
    g = mean(Float64.(n4) .- Float64.(n3))
    η = st.analysis_calibration_eta
    gt = st.analysis_calibration_gap_threshold

    if g > gt
        nw[3] = max(0.0, nw[3] * (1.0 - η * min(g / max(gt * 4, 0.03), 1.0)))
        nw[4] *= (1.0 + 0.55 * η * min(g / max(gt * 4, 0.03), 1.0))
    elseif g < -gt
        nw[3] *= (1.0 + 0.55 * η * min((-g) / max(gt * 4, 0.03), 1.0))
        nw[4] = max(0.0, nw[4] * (1.0 - 0.55 * η * min((-g) / max(gt * 4, 0.03), 1.0)))
    end

    if ρ >= st.analysis_calibration_corr_strong
        nw[3] *= (1.0 + 0.35 * η * min((ρ - st.analysis_calibration_corr_strong) / max(1.0 - st.analysis_calibration_corr_strong, 0.05), 1.0))
        nw[4] = max(0.0, nw[4] * (1.0 - 0.2 * η))
    elseif ρ <= -st.analysis_calibration_corr_strong
        nw[3] = max(0.0, nw[3] * (1.0 - 0.35 * η * min((-ρ - st.analysis_calibration_corr_strong) / max(1.0 - st.analysis_calibration_corr_strong, 0.05), 1.0)))
        nw[4] *= (1.0 + 0.2 * η)
    end

    sm = sum(nw)
    sm > 0 && (nw ./= sm)
end

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
        jitter = randn(rng) * n_amp * 0.15 * (env.stuck_counter > 0 ? st.resonance_stuck_jitter_amp : 1.0)
        sc = dist + suf + dmem + jitter
        if sc < bests
            bests = sc
            best = bid
        end
    end
    best
end

function pick_partner_kdtree(task::AbstractTask, env::Environment, a::UInt64, cand::Vector{UInt64}, rng::AbstractRNG, st::Settings)::UInt64
    na = fetch_node(env.nodes, a)
    @assert na !== nothing && !isempty(cand)
    va = embed(task, na.params)
    dlen = length(va)
    isempty(va) && return pick_partner(task, env, a, cand, rng, st)

    cols = Vector{Float64}[]
    idmap = UInt64[]
    for bid in cand
        nb = fetch_node(env.nodes, bid)
        nb === nothing && continue
        e = embed(task, nb.params)
        length(e) == dlen || continue
        push!(cols, Float64[e[i] for i = 1:dlen])
        push!(idmap, bid)
    end
    isempty(cols) && return cand[rand(rng, 1:length(cand))]
    pts = reduce(hcat, cols)
    tree = KDTree(pts)
    kq = min(st.kdtree_nn, size(pts, 2))
    idxs, _ = knn(tree, va, kq, true)
    sub = UInt64[idmap[i] for i in idxs]
    isempty(sub) && return pick_partner(task, env, a, cand, rng, st)
    return pick_partner(task, env, a, sub, rng, st)
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

function ll_score(task::AbstractTask, ch::Dict{Symbol, Any}, mw::Vector{Float64}, env::Environment, st::Settings)::Float64
    r1, _ = eval_maybe_cached(task, env, st, ch, L1)
    r2, _ = eval_maybe_cached(task, env, st, ch, L2)
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
                Scar(s.id, copy(s.center), s.radius, p, s.fail_level, s.decay_rate, tnow),
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

    if length(env.metric_l34_n3) >= st.analysis_calibration_min_samples &&
       length(env.metric_l34_n3) == length(env.metric_l34_n4)
        maybe_calibration_l34_weights!(env, st)
    elseif !isempty(env.nodes) && rand(rng) < 0.02
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
                tick_u = env.tick
                rebuild_kdtree =
                    st.use_kdtree_resonance &&
                    supports_embed(task) &&
                    length(cand) >= 3 &&
                    (tick_u == UInt64(0) ||
                     tick_u - env.kdtree_tick_built >= UInt64(st.kdtree_rebuild_ticks))
                bid =
                    rebuild_kdtree ? begin
                        b = pick_partner_kdtree(task, env, na.id, cand, rng, st)
                        env.kdtree_tick_built = tick_u
                        b
                    end :
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

    n_pred =
        lk <: L4 && !cold ? begin
            p0 = Dict{Symbol, Any}(pairs(na.params))
            r3, _ = evaluate(task, p0, L3)
            normalize(task, L3, r3)
        end : nothing

    apply_metric_once!(task, na, lk, env.metric_weights; record = true)
    if lk <: L4 && !cold && n_pred !== nothing
        push_metric_l34_pair!(
            env,
            st,
            Float64(n_pred),
            Float64(na.metric_components[4]),
        )
    end
    k = level_index(lk)
    na.hp = max(0.0, na.hp - effcost(st, k, cold))
    lk <: L4 && appeal_post_l4!(task, env, na, st, cold, n_pred)
    rupture_scars!(env, task, na, st)
end

"""Расхождение L3-vs-L4 после L4 (агент §4.2)."""
function appeal_post_l4!(
    task::AbstractTask,
    env::Environment,
    na::Node,
    st::Settings,
    cold::Bool,
    n_pred::Union{Nothing, Float64},
)
    cold && return
    n_pred === nothing && return
    !st.appeal_l3_vs_l4 && return
    n4 = na.metric_components[4]
    (n_pred <= st.appeal_l3_threshold && n4 >= st.appeal_l4_threshold) || return
    gap = n4 - n_pred
    gap < st.appeal_min_gap && return

    mw = env.metric_weights

    if st.appeal_use_l5_recheck
        if na.hp < effcost(st, 5, false) + 1.0
            return
        end
        p5 = Dict{Symbol, Any}(pairs(na.params))
        raw5, succ = eval_maybe_cached(task, env, st, p5, L5)
        delete!(na.params, :_factor)
        if succ
            na.metric_components[5] = normalize(task, L5, raw5)
            recompute_D!(na, mw)
            env.stop_reason = :factor_found
            return
        end
        na.metric_components[5] = normalize(task, L5, raw5)
        recompute_D!(na, mw)
        na.hp = max(0.0, na.hp - effcost(st, 5, false))
        return
    end

    if gap >= 0.45 && mw[3] > 1e-3
        mw[3] = max(0.0, mw[3] * 0.97)
        s = sum(mw)
        s > 0 && (mw ./= s)
        na.hp = max(0.0, na.hp - st.appeal_hp_cost_heavy)
    else
        na.hp = max(0.0, na.hp - st.appeal_hp_cost_light)
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
            sid = env.next_scar_id
            env.next_scar_id += UInt64(1)
            push!(env.scars, Scar(sid, c, radius, 1.0, fail_l, decay, UInt64(env.tick)))
        end
    end
    rupture_scars!(env, task, na, st)
end

function child_outperforms_parents(childD::Float64, da::Float64, db::Float64)::Bool
    avg = (da + db) / 2.0
    childD < avg || childD <= min(da, db) + 0.05
end

"""Тело скрещивания родителей `na` и `nb`; вызывается из события RESONANCE или MANUAL."""
function perform_resonance_between!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    na::Node,
    nb::Node,
    rng::AbstractRNG,
)::Nothing
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
        sc = ll_score(task, chi, mw, env, st)
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

    rk = (min(na.id, nb.id), max(na.id, nb.id))
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
    return
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

    perform_resonance_between!(env, task, st, na, nb, rng)
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
    pl = ev.payload
    act = Symbol(get(pl, :action, :noop))

    function as_u64(x)::UInt64
        x isa UInt64 && return x
        x isa AbstractString && return parse(UInt64, String(x))
        x isa Integer && return UInt64(x)
        return UInt64(round(Int, Float64(x)))
    end

    if act === :add_node
        raw_params = get(pl, :params, nothing)
        raw_params === nothing && return
        p::Dict{Symbol, Any} = Dict{Symbol, Any}(pairs(raw_params))
        hp = Float64(get(pl, :hp, st.default_hp))
        mp = Float64(get(pl, :mp, st.default_mp))
        nid = env.next_id
        env.next_id += UInt64(1)
        n = Node(nid, p; hp = hp, mp = mp)
        warm_start!(task, n, st)
        push!(env.nodes, n)
        return
    end

    if act === :delete_node
        v = get(pl, :node_id, nothing)
        v === nothing && return
        nid = as_u64(v)
        i = findfirst(n -> n.id == nid, env.nodes)
        i === nothing && return
        victim = env.nodes[i]
        c, radius, fail_l, decay = failure_scar_meta(task, victim.params)
        sid = env.next_scar_id
        env.next_scar_id += UInt64(1)
        push!(
            env.scars,
            Scar(
                sid,
                c,
                radius,
                0.45,
                min(fail_l, 4),
                decay,
                UInt64(env.tick),
            ),
        )
        deleteat!(env.nodes, i)
        return
    end

    if act === :force_resonance
        va = get(pl, :node_a, nothing)
        vb = get(pl, :node_b, nothing)
        (va === nothing || vb === nothing) && return
        ida = as_u64(va)
        idb = as_u64(vb)
        na = fetch_node(env.nodes, ida)
        nb = fetch_node(env.nodes, idb)
        (na === nothing || nb === nothing) && return
        ida == idb && return
        na.hp > 0.5 || return
        na.mp > 0 || return
        nb.mp > 0 || return
        perform_resonance_between!(env, task, st, na, nb, rng)
        return
    end

    if act === :clear_scar
        if haskey(pl, :scar_id)
            sid = as_u64(pl[:scar_id])
            k = findfirst(s -> s.id == sid, env.scars)
            k === nothing && return
            deleteat!(env.scars, k)
            return
        end
        ix = get(pl, :scar_index, nothing)
        ix === nothing && return
        j = Int(ix)
        (j < 1 || j > length(env.scars)) && return
        deleteat!(env.scars, j)
        return
    end

    if act === :set_mp_frozen
        v = get(pl, :node_id, nothing)
        v === nothing && return
        nid = as_u64(v)
        n = fetch_node(env.nodes, nid)
        n === nothing && return
        n.mp_frozen = Bool(get(pl, :frozen, true))
        return
    end

    return
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

    t0 = time()
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
    dt = time() - t0
    sym = event_time_symbol(ev.type)
    env.event_time_s[sym] = get(env.event_time_s, sym, 0.0) + dt
    if ev.node_id != UInt64(0)
        env.per_node_time_s[ev.node_id] = get(env.per_node_time_s, ev.node_id, 0.0) + dt
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
        Dict{Symbol, Float64}(),
        Dict{UInt64, Float64}(),
        Dict{UInt64, Tuple{Float64, Bool}}(),
        UInt64[],
        UInt64(0),
        UInt64(1),
        Float64[],
        Float64[],
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
