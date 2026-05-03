"""§4.5 ANALYSIS-проход: калибровка L3/L4, затухание шрамов, бюджеты, застой."""

function analysis_pass!(
    env::Environment,
    task::AbstractTask,
    st::Settings;
    rng::AbstractRNG = default_rng(),
)
    tn = UInt64(env.tick)

    maybe_calibration_l34_weights!(env, st)
    maybe_push_population_l34_pairs!(env, st; rng = rng)

    if st.calibration_extra_node_samples && !isempty(env.nodes)
        picks::Vector{Int} = shuffle(rng, collect(eachindex(env.nodes)))
        m = min(max(1, st.calibration_extra_nodes_per_analysis), length(picks))
        for kk in picks[1:m]
            nod = env.nodes[kk]
            push_metric_l34_pair!(
                env,
                st,
                nod.metric_components[3],
                nod.metric_components[4],
            )
        end
    end

    filter!(s -> scar_potential(s, tn) >= st.scar_eps, env.scars)

    avgD = isempty(env.nodes) ? 1.0 : Float64(mean(n.D for n in env.nodes))
    push!(env.d_history, avgD)

    denom = env.exploitation_budget + env.exploration_budget
    r_expl = denom > 1e-12 ? clamp(env.exploration_budget / denom, 0.0, 1.0) : 0.5
    push!(env.exploration_ratio_history, r_expl)

    sw = max(3, st.stuck_window)
    if length(env.d_history) >= sw
        hist = env.d_history[(end-sw+1):end]
        half = div(sw, 2)
        early = mean(hist[1:half])
        late = mean(hist[(half+1):end])
        if late >= early - 1e-3
            env.stuck_counter += 1
        else
            env.stuck_counter = 0
        end

        if env.stuck_counter >= st.stuck_ticks && denom > 1e-9
            xfer = env.exploitation_budget * Float64(st.exploration_transfer)
            env.exploitation_budget = max(0.0, env.exploitation_budget - xfer)
            env.exploration_budget += xfer
            env.stuck_counter = 0
        elseif late <= early - 0.035 && denom > 1e-9
            xfer2 = env.exploitation_budget * min(0.08, Float64(st.exploration_transfer) * 0.45)
            env.exploration_budget = max(0.0, env.exploration_budget - xfer2 * 0.6)
            env.exploitation_budget += xfer2 * 0.85
        end
    end

    epsn = 1e-9
    filter!(n -> (n.hp > epsn || n.mp > epsn || n.mp_frozen), env.nodes)

    for n in env.nodes
        if n.mp_frozen && n.resonance_win_streak >= 5
            n.mp_frozen = false
            n.mp = max(n.mp, 12.0)
            n.resonance_win_streak = 0
        end
    end

    if avgD <= 0.48
        for nod in env.nodes
            rupture_scars!(env, task, nod, st)
        end
    end

    if tn >= UInt64(max(1, st.cold_start_ticks))
        env.cold_start = false
    end
    nothing
end

"""Перепланировать событие на такте (cold: без резонанса, дешёвые быстрые метрики)."""
function rebuild_schedule!(env::Environment, task::AbstractTask, st::Settings; rng::AbstractRNG)
    clear_events!(env)
    tn = UInt64(env.tick)
    cold_tick = tn < UInt64(max(1, st.cold_start_ticks))
    mw::Vector{Float64} = env.metric_weights

    for node in env.nodes
        (node.hp > 1e-9 && node.active) || continue

        Lev = choose_shot_level(node, st, cold_tick)
        if Lev !== nothing
            k = level_index(Lev)
            pr_sh = clamp((1.0 - node.D) * node.hp * mw[k], 1e-4, 1_900.0)
            enqueue_evt!(
                env,
                Event(SHOT; node_id = node.id, shot_level_idx = UInt8(k)),
                pr_sh,
            )
        end

        if !cold_tick
            heav_ok =
                node.D <= st.D_thresh_heavy &&
                    node.hp >= st.heavy_shot_hp_min &&
                    node.hp + 1e-9 >= Float64(st.cost[5]) &&
                    !strong_scar_near(task, env, node, st)
            if heav_ok
                pr_h = clamp((1.0 - node.D) * node.hp * mw[5] * 5.25, 0.12, 1_050.0)
                enqueue_evt!(
                    env,
                    Event(HEAVY_SHOT; node_id = node.id, shot_level_idx = UInt8(5)),
                    pr_h,
                )
            end
        end
    end

    if !cold_tick
        ids = shuffle(rng, [n.id for n in env.nodes])
        paired = UInt64[]
        touched(nid::UInt64) = nid in paired
        for aid::UInt64 in ids
            touched(aid) && continue
            na = fetch_node(env.nodes, aid)
            na === nothing && continue
            na.hp < st.resonance_initiator_hp_floor && continue
            cand = res_candidates(env, aid)
            isempty(cand) && continue

            bid = if st.use_kdtree_resonance && supports_embed(task)
                pick_partner_kdtree(task, env, aid, cand, rng, st)
            else
                pick_partner(task, env, aid, cand, rng, st)
            end
            bid === aid && continue
            touched(bid) && continue

            nb = fetch_node(env.nodes, bid)
            nb === nothing && continue
            rp = resonance_pr(env, st, aid, bid) * clamp((na.mp + nb.mp) / 90.0, 0.12, 3.85)
            push!(paired, aid)
            push!(paired, bid)
            enqueue_evt!(
                env,
                Event(RESONANCE; node_id = aid, partner_id = bid),
                rp,
            )
        end
    end

    # M1 ANALYSIS-slot: литеральный маленький quantum проигрывал SHOT (~1900) и голодал очередь.
    ai = UInt64(max(1, st.analysis_interval))
    if tn % ai == UInt64(0) && !st.analysis_calendar_exclusive_slot
        pr_an = Float64(
            if st.analysis_priority_force_high
                max(Float64(st.analysis_priority_floor), Float64(st.analysis_priority_quantum) * 1_000)
            else
                Float64(max(st.analysis_priority_floor, Float64(st.analysis_priority_quantum)))
            end,
        )
        pr_final = Float64(max(pr_an, Float64(st.analysis_min_priority_when_due)))
        enqueue_evt!(env, Event(ANALYSIS), pr_final)
    end

    if cold_tick
        tot = max(50.0, env.exploitation_budget + env.exploration_budget)
        env.exploration_budget = tot * (1 - 8e-3)
        env.exploitation_budget = tot - env.exploration_budget
    end

    nothing
end
