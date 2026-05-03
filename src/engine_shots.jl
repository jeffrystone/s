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

function penalize_metric_l3_after_successful_appeal!(env::Environment, amt::Float64 = 0.07)
    w = env.metric_weights
    w[3] = max(1e-4, (w[3] * (1.0 - amt)))
    sm = sum(w)
    sm > 0 && (w ./= sm)
    nothing
end

function metric_appeal_dispatch_after_shot!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    rng::AbstractRNG,
    node::Node,
    k::Int,
    snap_n2::Float64,
    snap_n3::Float64,
)
    if k == 2 && st.appeal_l2_challenge_l3
        n2 = node.metric_components[2]
        if snap_n3 - n2 > st.appeal_l2_vs_l3_min_gap &&
           n2 < st.appeal_l3_threshold && snap_n3 > st.appeal_l4_threshold
            cost = min(st.appeal_hp_cost_heavy * 1.35, 0.55 * node.hp)
            node.hp >= cost || return nothing
            node.hp -= cost
            raw3, _ = eval_maybe_cached(task, env, st, node.params, L3)
            node.metric_components[3] = normalize(task, L3, raw3)
            delete!(node.params, :_factor)
            recompute_D!(node, Vector{Float64}(env.metric_weights))
            if snap_n3 - node.metric_components[3] > st.appeal_min_gap
                penalize_metric_l3_after_successful_appeal!(env, 0.035)
            end
            push_metric_l34_pair!(env, st, node.metric_components[3], node.metric_components[4])
            record_recent_event!(
                env,
                st,
                Dict{Symbol, Any}(
                    :tick_sim => UInt64(env.tick),
                    :type => "SHOT",
                    :node_id => node.id,
                    :level_idx => UInt8(3),
                    :appeal_challenge => true,
                ),
            )
        end
        return nothing
    end
    if k == 3
        appeal_post_l23!(env, task, st, rng, node, snap_n2, node.metric_components[3])
    elseif k == 4
        appeal_post_l4!(env, task, st, rng, node, snap_n3, node.metric_components[4])
    end
    nothing
end

function appeal_post_l23!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    rng::AbstractRNG,
    node::Node,
    n2::Float64,
    n3::Float64,
)
    st.appeal_extend_L2_vs_L3 || return
    gap = n3 - n2
    if gap > st.appeal_l2_vs_l3_min_gap && n2 < st.appeal_l3_threshold && n3 > st.appeal_l4_threshold
        cost = min(st.appeal_hp_cost_light, 0.45 * node.hp)
        if node.hp < cost
            return
        end
        node.hp -= cost
        raw4, _ = eval_maybe_cached(task, env, st, node.params, L4)
        n4 = normalize(task, L4, raw4)
        delete!(node.params, :_factor)
        if n4 + 0.08 < n3
            penalize_metric_l3_after_successful_appeal!(env, 0.05)
        end
    end
    nothing
end

function appeal_post_l4!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    rng::AbstractRNG,
    node::Node,
    n3_b::Float64,
    n4::Float64,
)
    st.appeal_l3_vs_l4 || return
    gap = n4 - n3_b
    if gap <= st.appeal_min_gap || n3_b >= st.appeal_l3_threshold || n4 <= st.appeal_l4_threshold
        return
    end
    cost = min(st.appeal_hp_cost_heavy, 0.55 * node.hp)
    if node.hp < cost
        return
    end
    node.hp -= cost
    if st.appeal_use_l5_recheck
        raw5, ok5 = eval_maybe_cached(task, env, st, node.params, L5)
        n5 = normalize(task, L5, raw5)
        delete!(node.params, :_factor)
        if ok5 || n5 + 0.05 < n4
            penalize_metric_l3_after_successful_appeal!(env, 0.08)
        end
    else
        raw5, _ = eval_maybe_cached(task, env, st, node.params, L4)
        n5 = normalize(task, L4, raw5)
        delete!(node.params, :_factor)
        if n5 + 0.04 < n4
            penalize_metric_l3_after_successful_appeal!(env, 0.09)
        end
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

    snap_n2 = node.metric_components[2]
    snap_n3 = node.metric_components[3]
    t0 = time()
    raw, okL5 = eval_maybe_cached(task, env, st, node.params, L)
    elapsed = max(time() - t0, 1e-9)
    account_event_walltime!(env, ev, elapsed)

    nrm = normalize(task, L, raw)
    node.metric_components[k] = nrm
    recompute_D!(node, mw)
    push!(node.mutation_history, (nameof(L), nrm))

    if st.appeal_unified_dispatch
        metric_appeal_dispatch_after_shot!(
            env,
            task,
            st,
            rng,
            node,
            k,
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
    node.metric_components[5] = normalize(task, L5, raw)
    recompute_D!(node, mw)
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
