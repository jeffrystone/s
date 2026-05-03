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

function strong_scar_near(task::AbstractTask, env::Environment, node::Node, st::Settings)
    supports_embed(task) || return false
    evec = embed(task, node.params)
    isempty(evec) && return false
    dlen = length(evec)
    tn = UInt64(env.tick)

    filt = Scar[]
    for s in env.scars
        scar_potential(s, tn) < 0.25 && continue
        push!(filt, s)
    end
    isempty(filt) && return false

    function cen(s::Scar)::Vector{Float64}
        ce = zeros(Float64, dlen)
        for (k, vv) in s.center
            if k == :start_x && dlen >= 1
                ce[1] = Float64(vv) / 1000
            elseif k == :poly_coeff && dlen >= 2
                ce[2] = Float64(vv) / 1000
            end
        end
        return ce
    end

    function brute_near()::Bool
        for s in filt
            norm(evec - cen(s)) <= s.radius && return true
        end
        return false
    end

    if length(filt) < st.strong_scar_kdtree_min
        return brute_near()
    end

    pts = zeros(Float64, dlen, length(filt))
    Rmax::Float64 = maximum(s.radius for s in filt; init = 0.05)
    for i in eachindex(filt)
        pts[:, i] = cen(filt[i])
    end
    tree = KDTree(pts)
    cand = inrange(tree, evec, Rmax, false)
    for ix in cand
        s = filt[ix]
        norm(evec - pts[:, ix]) <= s.radius && return true
    end
    return false
end

res_candidates(env::Environment, nid::UInt64) =
    UInt64[m.id for m in env.nodes if m.id != nid && m.mp > 0]

function record_recent_event!(env::Environment, st::Settings, payload::Dict{Symbol, Any})
    push!(env.recent_events, copy(payload))
    cap = max(4, st.recent_events_max)
    while length(env.recent_events) > cap
        popfirst!(env.recent_events)
    end
    return nothing
end

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
        dmem =
            st.attention_gamma *
            env.attention_tune_gamma *
            (1 - clamp(mem, 0.0, 1.0))
        dist =
            use_emb && !isempty(va) ? st.attention_alpha * env.attention_tune_alpha * norm(va - embed(task, nb.params)) :
            rand(rng)
        suf = rand(rng) * st.attention_beta * env.attention_tune_beta
        jitter = randn(rng) * n_amp * 0.15 * (env.stuck_counter > 0 ? st.resonance_stuck_jitter_amp : 1.0)
        suffer = st.attention_suffer_gamma * env.attention_tune_gamma * abs(suffering_profile(na) - suffering_profile(nb))
        sc = dist + suf + dmem + jitter + suffer
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

const _MATING_HIST_MAX = 64

function push_mating_history_safe!(nod::Node, mate::UInt64, q::Float64)
    push!(nod.mating_history, (mate, q))
    while length(nod.mating_history) > _MATING_HIST_MAX
        popfirst!(nod.mating_history)
    end
    return nothing
end

"""Heuristic aligned with AGENTS (suffering_similarity): похожий pain → меньший штраф в pick_partner."""
function suffering_profile(node::Node)::Float64
    nfail = isempty(node.heavy_shots) ? 0 : count(x -> !x[2], node.heavy_shots)
    failrate = isempty(node.heavy_shots) ? 0.0 : nfail / length(node.heavy_shots)
    mh = node.D
    if !isempty(node.mutation_history)
        lo = max(1, length(node.mutation_history) - 5)
        mh = mean(Float64[t[2] for t in @view(node.mutation_history[lo:end])])
    end
    clamp(node.D + 0.22 * failrate + 0.12 * mh, 0.0, 3.5)
end

function ll_score(task::AbstractTask, ch::Dict{Symbol, Any}, mw::Vector{Float64}, env::Environment, st::Settings)::Float64
    r1, _ = eval_maybe_cached(task, env, st, ch, L1)
    r2, _ = eval_maybe_cached(task, env, st, ch, L2)
    delete!(ch, :_factor)
    return mw[1] * normalize(task, L1, r1) + mw[2] * normalize(task, L2, r2)
end

"""Two-stage offspring filter: discard before L2 if normalized L1 is above gate."""
function offspring_metric_score!(
    task::AbstractTask,
    ch::Dict{Symbol, Any},
    mw::Vector{Float64},
    env::Environment,
    st::Settings,
)::Float64
    if !st.resonance_offspring_two_stage
        return ll_score(task, ch, mw, env, st)
    end
    r1, _ = eval_maybe_cached(task, env, st, ch, L1)
    n1 = normalize(task, L1, r1)
    if n1 > st.resonance_two_stage_L1_gate
        delete!(ch, :_factor)
        return Inf
    end
    r2, _ = eval_maybe_cached(task, env, st, ch, L2)
    delete!(ch, :_factor)
    return mw[1] * n1 + mw[2] * normalize(task, L2, r2)
end

function resonance_pr(env::Environment, st::Settings, a::UInt64, b::UInt64)::Float64
    st.attention_gamma * env.attention_tune_gamma * 0.65 *
    get(env.resonance_memory, (min(a, b), max(a, b)), 0.35)
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
