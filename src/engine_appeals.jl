function penalize_metric_l3_after_successful_appeal!(env::Environment, amt::Float64 = 0.07)
    w = env.metric_weights
    w[3] = max(1e-4, (w[3] * (1.0 - amt)))
    sm = sum(w)
    sm > 0 && (w ./= sm)
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

function metric_appeal_dispatch_after_shot!(
    env::Environment,
    task::AbstractTask,
    st::Settings,
    rng::AbstractRNG,
    node::Node,
    k::Int,
    snap_n1::Float64,
    snap_n2::Float64,
    snap_n3::Float64,
)
    mw = Vector{Float64}(env.metric_weights)
    if k == 1 && st.appeal_l1_challenge_l2
        n2_prior = snap_n2
        raw2_fresh, _ = eval_maybe_cached(task, env, st, node.params, L2)
        n2_fresh = normalize(task, L2, raw2_fresh)
        delete!(node.params, :_factor)
        if abs(n2_fresh - n2_prior) <= st.appeal_l1_challenge_gap
            return nothing
        end
        cost =
            min(
                st.appeal_hp_cost_light,
                max(1e-6, st.appeal_l1_challenge_hp_frac * node.hp),
            )
        if node.hp < cost
            return nothing
        end
        node.hp -= cost
        node.metric_components[2] = n2_fresh
        finalize_metric_D!(task, node, mw, k, st)
        record_recent_event!(
            env,
            st,
            Dict{Symbol, Any}(
                :tick_sim => UInt64(env.tick),
                :type => "SHOT",
                :node_id => node.id,
                :level_idx => UInt8(2),
                :appeal_challenge => true,
            ),
        )
        return nothing
    end
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
            finalize_metric_D!(task, node, mw, k, st)
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
