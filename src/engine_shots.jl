function account_event_walltime!(env::Environment, ev::Event, seconds::Float64)
    Δ = clamp(Float64(seconds), 1e-12, 9_999.9)
    sym = event_time_symbol(ev.type)
    env.event_time_s[sym] = get(env.event_time_s, sym, 0.0) + Δ
    if ev.type !== ANALYSIS && ev.node_id !== UInt64(0)
        nid = ev.node_id
        env.per_node_time_s[nid] = get(env.per_node_time_s, nid, 0.0) + Δ
    end
    nothing
end

function handle_shot!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    node = fetch_node(env.nodes, ev.node_id)
    node === nothing && return
    cold_tick = UInt64(env.tick) < UInt64(max(1, st.cold_start_ticks))
    mw = env.metric_weights

    L::Type{<:MetricLevel} =
        if ev.shot_level_idx == UInt8(0)
            ll = choose_shot_level(node, st, cold_tick)
            ll === nothing && return
            ll
        else
            _LEVELS[Int(ev.shot_level_idx)]
        end

    k = level_index(L)
    cst = effcost(st, k, cold_tick)
    if node.hp + 1e-12 < cst
        return
    end
    node.hp -= cst

    snap_n1 = node.metric_components[1]
    snap_n2 = node.metric_components[2]
    snap_n3 = node.metric_components[3]
    t0 = time()
    raw, okL5 = eval_maybe_cached(task, env, st, node.params, L)
    elapsed = max(time() - t0, 1e-9)
    account_event_walltime!(env, ev, elapsed)

    nrm = normalize(task, L, raw)
    prev_ck = node.metric_components[k]
    node.metric_components[k] = nrm
    finalize_metric_D!(task, node, mw, k, st; prev_at_k = prev_ck)
    push!(node.mutation_history, (nameof(L), nrm))

    if st.appeal_unified_dispatch
        metric_appeal_dispatch_after_shot!(
            env,
            task,
            st,
            rng,
            node,
            k,
            snap_n1,
            snap_n2,
            snap_n3,
        )
    else
        if k == 3
            appeal_post_l23!(env, task, st, rng, node, snap_n2, node.metric_components[3])
        elseif k == 4
            appeal_post_l4!(env, task, st, rng, node, snap_n3, node.metric_components[4])
        end
    end

    if k == 3 || k == 4
        push_metric_l34_pair!(
            env,
            st,
            node.metric_components[3],
            node.metric_components[4],
        )
    end

    record_recent_event!(
        env,
        st,
        Dict{Symbol, Any}(
            :tick_sim => UInt64(env.tick),
            :type => "SHOT",
            :node_id => node.id,
            :level_idx => UInt8(k),
            :cold => cold_tick,
        ),
    )

    rupture_scars!(env, task, node, st)

    if okL5 && haskey(node.params, :_factor)
        env.stop_reason = :factor_found
    elseif k == level_index(L5) && okL5
        env.stop_reason = :factor_found
    end
    nothing
end

function handle_heavy_shot!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    ev::Event;
    rng::AbstractRNG,
)
    node = fetch_node(env.nodes, ev.node_id)
    node === nothing && return
    cold_tick = UInt64(env.tick) < UInt64(max(1, st.cold_start_ticks))
    cold_tick && return

    k = 5
    cst = Float64(st.cost[k])
    if node.hp + 1e-9 < cst || node.D > st.D_thresh_heavy + 1e-6
        return
    end
    if strong_scar_near(task, env, node, st)
        return
    end

    node.hp -= cst
    D_old = node.D
    mw = env.metric_weights

    t0 = time()
    raw, ok = eval_maybe_cached(task, env, st, node.params, L5)
    elapsed = max(time() - t0, 1e-9)
    account_event_walltime!(env, ev, elapsed)

    delete!(node.params, :_factor)
    prev5 = node.metric_components[5]
    nrm5 = normalize(task, L5, raw)
    node.metric_components[5] = nrm5
    finalize_metric_D!(task, node, mw, k, st; prev_at_k = prev5)
    push!(node.mutation_history, (:heavy_L5, node.metric_components[5]))
    push!(node.heavy_shots, (D_old, ok))

    if ok
        env.stop_reason = :factor_found
        record_recent_event!(
            env,
            st,
            Dict{Symbol, Any}(
                :tick_sim => UInt64(env.tick),
                :type => "HEAVY_HIT",
                :node_id => node.id,
            ),
        )
        return
    end

    node.hp = max(2.0, node.hp * 0.035)
    node.mp *= 0.55
    node.mp_frozen = true

    cen, rad, failv, dec = failure_scar_meta(task, node.params)
    push!(
        env.scars,
        Scar(
            env.next_scar_id,
            cen,
            rad,
            1.0,
            failv,
            dec,
            UInt64(env.tick),
        ),
    )
    env.next_scar_id += UInt64(1)

    record_recent_event!(
        env,
        st,
        Dict{Symbol, Any}(
            :tick_sim => UInt64(env.tick),
            :type => "HEAVY_FAIL",
            :node_id => node.id,
        ),
    )
    nothing
end
