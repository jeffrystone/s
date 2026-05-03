function child_outperforms_parents(
    task::AbstractTask,
    env::Environment,
    params_ch::Dict{Symbol, Any},
    pa::Node,
    pb::Node,
    st::Settings,
)::Bool
    mwv = Vector{Float64}(env.metric_weights)
    sC =
        offspring_metric_score!(task, copy(params_ch), mwv, env, st)
    !isfinite(sC) && return false
    sA = ll_score(task, copy(pa.params), mwv, env, st)
    sB = ll_score(task, copy(pb.params), mwv, env, st)
    midparent = Float64((sA + sB) * 0.5)
    baseline = Float64(min(sA, sB))
    improved = (sC < baseline - 0.012) || (sC < midparent - 0.035)
end

function perform_resonance_between!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    rng::AbstractRNG,
    aid::UInt64,
    bid::UInt64,
)
    na = fetch_node(env.nodes, aid)
    nb = fetch_node(env.nodes, bid)
    (na === nothing || nb === nothing) &&
        return (child_added = false, child_improved = false, op_used = :none)

    ops = Symbol[k for k in keys(env.crossover_weights)]
    isempty(ops) && return (child_added = false, child_improved = false, op_used = :none)

    wt = Float64[max(1e-6, get(env.crossover_weights, o, 1.0)) for o in ops]
    best_p = Dict{Symbol, Any}()
    best_s::Float64 = Inf
    best_op::Symbol = ops[1]

    Nt = offspring_n(max(na.hp, 1.0), max(nb.mp, 1.0))
    mwv::Vector{Float64} = Vector{Float64}(env.metric_weights)

    use_parallel =
        st.parallel_offspring &&
            Nt >= st.parallel_offspring_min_trials &&
            !(st.parallel_offspring_disable_with_eval_cache && st.evaluate_cache_enabled)

    if use_parallel
        base_u = rand(rng, UInt64)
        scores_th = Vector{Float64}(undef, Nt)
        ch_th = Vector{Dict{Symbol, Any}}(undef, Nt)
        op_th = Vector{Symbol}(undef, Nt)
        Base.Threads.@threads for ii in eachindex(scores_th)
            u =
                xor(
                    xor(base_u, UInt64(ii)),
                    UInt64(Base.Threads.threadid()) % UInt64(1024) << 40,
                )
            thr_rng = Random.Xoshiro(u)
            op_th[ii] = wsample(thr_rng, ops, wt)
            ch_th[ii] =
                crossover(task, na.params, nb.params, op_th[ii]; rng = thr_rng)
            scores_th[ii] = offspring_metric_score!(
                task,
                ch_th[ii],
                mwv,
                env,
                st,
            )
        end
        for ii in eachindex(scores_th)
            s = scores_th[ii]
            if s < best_s
                best_s = s
                best_p = ch_th[ii]
                best_op = op_th[ii]
            end
        end
    else
        for _ = 1:Nt
            op = wsample(rng, ops, wt)
            ch = crossover(task, na.params, nb.params, op; rng = rng)
            sc = offspring_metric_score!(task, ch, mwv, env, st)
            if sc < best_s
                best_s = sc
                best_p = ch
                best_op = op
            end
        end
    end

    if !isfinite(best_s) || best_s > 1e18
        return (child_added = false, child_improved = false, op_used = best_op)
    end

    improved =
        child_outperforms_parents(task, env, best_p, na, nb, st)

    cid = env.next_id
    env.next_id += UInt64(1)
    scale = clamp(2.15 - 1.45 * Float64(best_s), 0.22, 1.12)
    newborn = Node(
        cid,
        copy(best_p);
        hp = st.default_hp * scale,
        mp = st.default_mp * 0.88,
        D = 0.5,
    )
    warm_start!(task, newborn, st)

    den = env.exploitation_budget + env.exploration_budget + 1e-9
    tax = newborn.hp * 0.055 * clamp(env.exploration_budget / den, 0.12, 0.95)
    newborn.hp = max(4.0, newborn.hp - tax * 0.65)
    env.exploration_budget += tax * 0.85

    push!(env.nodes, newborn)

    cost_a = min(78.0, 8.5 + na.hp * 0.07)
    cost_b = min(55.0, 6.0 + nb.hp * 0.05)
    na.hp = max(0.0, na.hp - cost_a)
    nb.hp = max(0.0, nb.hp - cost_b * 0.45)
    na.mp *= 0.90
    nb.mp *= 0.87

    qq = resonance_pr(env, st, aid, bid)
    push_mating_history_safe!(na, bid, qq)
    push_mating_history_safe!(nb, aid, qq)

    na.resonance_win_streak += 1
    nb.resonance_win_streak += 1

    key = aid < bid ? (aid, bid) : (bid, aid)
    succ = improved ? 0.92 : 0.38
    env.resonance_memory[key] =
        clamp(0.42 * succ + 0.58 * get(env.resonance_memory, key, 0.45), 0.05, 0.99)

    if st.crossover_learning_enabled
        η = st.crossover_learning_eta
        w0 = env.crossover_weights[best_op]
        env.crossover_weights[best_op] =
            improved ? max(1e-4, w0 * (1 + η)) : max(1e-4, w0 * (1 - η * 0.5))
        sm = sum(values(env.crossover_weights))
        if sm > 0
            for ky in keys(env.crossover_weights)
                env.crossover_weights[ky] /= sm
            end
        end
    end

    record_recent_event!(
        env,
        st,
        Dict{Symbol, Any}(
            :tick_sim => UInt64(env.tick),
            :type => "RESONANCE",
            :node_a => aid,
            :node_b => bid,
            :child_id => cid,
        ),
    )

    return (child_added = true, child_improved = improved, op_used = best_op)
end

function handle_resonance!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    t0 = time()
    perform_resonance_between!(env, task, st, rng, ev.node_id, ev.partner_id)
    elapsed = max(time() - t0, 1e-9)
    account_event_walltime!(env, ev, elapsed)
    nothing
end

function handle_analysis_evt!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    t0 = time()
    analysis_pass!(env, task, st; rng = rng)
    elapsed = max(time() - t0, 1e-9)
    account_event_walltime!(env, ev, elapsed)
    nothing
end
